//! Decides what happens when the user clicks a link in the preview.
//!
//! The preview never opens links: a click on an `http`, `https` or `mailto`
//! link copies its address, so that the user can paste it into a browser or
//! email app. The input is the absolute URL the web engine resolved the
//! link to, never the raw `href`: only after resolution is the scheme known
//! for certain (for example, `java%09script:x` is a relative link, not a
//! scheme).

use crate::page::TASK_LINK_PREFIX;
use crate::{PAGE_BASE_URL, is_valid_task_token};

/// Longest URL, in bytes, that may be copied. Longer URLs are blocked: they
/// are not real web addresses and could hide something in their length.
pub const MAX_LINK_BYTES: usize = 4096;

/// What the app does with a clicked link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkAction {
    /// An `http` or `https` link: copy its address.
    CopyWebAddress {
        /// The text to copy: the whole address, printable ASCII only (no
        /// spaces, line breaks or invisible characters), at most
        /// [`MAX_LINK_BYTES`] bytes.
        address: String,
        /// The host (and port, if any) to show, without user name or
        /// password, so a link cannot pretend to lead to a different site.
        host: String,
    },
    /// A `mailto` link: copy the email address.
    CopyEmailAddress {
        /// The text to copy: the recipients, with percent escapes decoded
        /// when the result is printable ASCII (otherwise as written). Empty
        /// if the link has no recipient.
        address: String,
    },
    /// A click on a task checkbox in the preview: check or uncheck the task
    /// with this index (see [`crate::toggle_task`]), but only if the token
    /// is the one the shown page was rendered with.
    ToggleTask {
        /// The token of the page the checkbox belongs to.
        token: String,
        /// Index of the task in document order, counted from 0.
        index: usize,
    },
    /// A relative link to another file or to a position in the document.
    /// Not supported yet.
    Unsupported,
    /// Anything else (`file:`, other apps' schemes, malformed URLs, overlong
    /// URLs). Neither opened nor copied.
    Blocked,
}

/// Decides what to do with a click on a link that resolved to `url`.
///
/// `url` must be the absolute URL as resolved by the web engine against
/// [`PAGE_BASE_URL`]. Such URLs consist of printable ASCII only; anything
/// else is blocked.
///
/// # Examples
///
/// ```
/// use markdown_editor_core::{link_action, LinkAction};
///
/// assert_eq!(
///     link_action("https://example.com/page"),
///     LinkAction::CopyWebAddress {
///         address: "https://example.com/page".into(),
///         host: "example.com".into(),
///     }
/// );
/// assert_eq!(link_action("file:///etc/passwd"), LinkAction::Blocked);
/// ```
#[must_use]
pub fn link_action(url: &str) -> LinkAction {
    if url.len() > MAX_LINK_BYTES || !url.bytes().all(|byte| byte.is_ascii_graphic()) {
        return LinkAction::Blocked;
    }
    let Some((scheme, rest)) = url.split_once(':') else {
        return LinkAction::Blocked;
    };
    if !is_scheme(scheme) {
        return LinkAction::Blocked;
    }
    match scheme.to_ascii_lowercase().as_str() {
        "http" | "https" => match host(rest) {
            Some(host) => LinkAction::CopyWebAddress {
                address: url.to_owned(),
                host,
            },
            None => LinkAction::Blocked,
        },
        "mailto" => {
            let recipients = rest.split(['?', '#']).next().unwrap_or_default();
            LinkAction::CopyEmailAddress {
                address: percent_decoded(recipients).unwrap_or_else(|| recipients.to_owned()),
            }
        }
        scheme if is_page_scheme(scheme) => task_link(url).unwrap_or(LinkAction::Unsupported),
        _ => LinkAction::Blocked,
    }
}

/// Parses exactly `markdown-preview://task/<token>/<index>`: a valid token,
/// a decimal index without leading zeros, nothing else.
fn task_link(url: &str) -> Option<LinkAction> {
    let (scheme, _) = url.split_once(':')?;
    let rest = &url[scheme.len()..];
    let (_, prefix_rest) = TASK_LINK_PREFIX.split_once(':')?;
    let (token, index) = rest
        .strip_prefix(':')?
        .strip_prefix(prefix_rest)?
        .split_once('/')?;
    let canonical_index = !index.is_empty()
        && index.bytes().all(|byte| byte.is_ascii_digit())
        && (index == "0" || !index.starts_with('0'));
    if !is_valid_task_token(token) || !canonical_index {
        return None;
    }
    Some(LinkAction::ToggleTask {
        token: token.to_owned(),
        index: index.parse().ok()?,
    })
}

/// `text` with `%XX` escapes decoded, if the result is printable ASCII
/// without spaces; `None` otherwise (also for malformed escapes).
///
/// Splits at `%` instead of stepping through positions by hand, so that no
/// change to a position counter can turn the loop into an endless one.
fn percent_decoded(text: &str) -> Option<String> {
    let mut parts = text.split('%');
    let mut decoded = parts.next()?.as_bytes().to_vec();
    for part in parts {
        // `None` if fewer than two bytes follow or they split a character.
        let (digits, rest) = part.split_at_checked(2)?;
        // `from_str_radix` alone would also accept a sign, as in `%+1`.
        if !digits.as_bytes().iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        decoded.push(u8::from_str_radix(digits, 16).ok()?);
        decoded.extend_from_slice(rest.as_bytes());
    }
    if decoded.iter().all(u8::is_ascii_graphic) {
        String::from_utf8(decoded).ok()
    } else {
        None
    }
}

/// A URL scheme: an ASCII letter followed by letters, digits, `+`, `-` or
/// `.` (RFC 3986, section 3.1).
fn is_scheme(scheme: &str) -> bool {
    let mut bytes = scheme.bytes();
    bytes
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic())
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.'))
}

fn is_page_scheme(scheme: &str) -> bool {
    PAGE_BASE_URL
        .split_once(':')
        .is_some_and(|(page_scheme, _)| page_scheme == scheme)
}

/// The host and port of a hierarchical URL's remainder (`//authority/...`),
/// without user information. `None` if there is no host.
fn host(rest: &str) -> Option<String> {
    let authority = rest
        .strip_prefix("//")?
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default();
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    // Without the port. IPv6 literals like `[::1]` end in `]`, so their
    // colons are never taken for the port separator.
    let name = host.rsplit_once(':').map_or(host, |(name, port)| {
        if port.bytes().all(|byte| byte.is_ascii_digit()) {
            name
        } else {
            host
        }
    });
    (!name.is_empty()).then(|| host.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host_of(action: &LinkAction) -> Option<&str> {
        match action {
            LinkAction::CopyWebAddress { host, .. } => Some(host),
            _ => None,
        }
    }

    fn email(address: &str) -> LinkAction {
        LinkAction::CopyEmailAddress {
            address: address.into(),
        }
    }

    #[test]
    fn web_links_are_copied_with_their_real_host() {
        assert_eq!(
            host_of(&link_action("https://example.com/")),
            Some("example.com")
        );
        assert_eq!(
            host_of(&link_action("http://example.com")),
            Some("example.com")
        );
        assert_eq!(
            host_of(&link_action("https://example.com:8443/a?b=c#d")),
            Some("example.com:8443")
        );
        assert_eq!(
            host_of(&link_action("HTTPS://example.com/")),
            Some("example.com")
        );
        assert_eq!(
            host_of(&link_action("https://[::1]:8080/")),
            Some("[::1]:8080")
        );
        assert_eq!(host_of(&link_action("https://[::1]/")), Some("[::1]"));
        assert_eq!(
            host_of(&link_action("https://xn--80ak6aa92e.com/")),
            Some("xn--80ak6aa92e.com")
        );
    }

    #[test]
    fn user_information_is_not_shown_as_the_host() {
        assert_eq!(
            host_of(&link_action("https://www.apple.com@evil.example/")),
            Some("evil.example")
        );
        assert_eq!(
            host_of(&link_action("https://user:secret@example.com:1/")),
            Some("example.com:1")
        );
    }

    #[test]
    fn web_links_copy_the_whole_address() {
        assert_eq!(
            link_action("https://user@example.com:8443/a?b=c#d"),
            LinkAction::CopyWebAddress {
                address: "https://user@example.com:8443/a?b=c#d".into(),
                host: "example.com:8443".into(),
            }
        );
    }

    #[test]
    fn email_addresses_are_decoded_only_to_printable_text() {
        assert_eq!(
            link_action("mailto:a%40example.com"),
            email("a@example.com")
        );
        assert_eq!(
            link_action("mailto:%61@example.com"),
            email("a@example.com")
        );
        // Decoding would produce a space, a line break or non-ASCII text:
        // copy the address as written instead.
        assert_eq!(
            link_action("mailto:a%20b@example.com"),
            email("a%20b@example.com")
        );
        assert_eq!(
            link_action("mailto:a%0Ab@example.com"),
            email("a%0Ab@example.com")
        );
        assert_eq!(
            link_action("mailto:%C3%A4@example.com"),
            email("%C3%A4@example.com")
        );
        // Malformed escapes are kept as written.
        assert_eq!(
            link_action("mailto:a%4@example.com"),
            email("a%4@example.com")
        );
        assert_eq!(
            link_action("mailto:a%+1@example.com"),
            email("a%+1@example.com")
        );
        assert_eq!(link_action("mailto:a%"), email("a%"));
    }

    #[test]
    fn percent_decoding_requires_two_hex_digits() {
        assert_eq!(percent_decoded("a%41b"), Some("aAb".into()));
        assert_eq!(percent_decoded("%7e"), Some("~".into()));
        assert_eq!(percent_decoded("%41%42c"), Some("ABc".into()));
        assert_eq!(percent_decoded(""), Some(String::new()));
        assert_eq!(percent_decoded("%4"), None);
        assert_eq!(percent_decoded("%4g"), None);
        assert_eq!(percent_decoded("%%41"), None);
        assert_eq!(percent_decoded("%+1"), None);
        assert_eq!(percent_decoded("%é"), None);
        assert_eq!(percent_decoded("%4é"), None);
        assert_eq!(percent_decoded("%20"), None);
        assert_eq!(percent_decoded("%7F"), None);
    }

    #[test]
    fn web_links_without_host_are_blocked() {
        assert_eq!(link_action("https:"), LinkAction::Blocked);
        assert_eq!(link_action("https:example.com"), LinkAction::Blocked);
        assert_eq!(link_action("https:///path"), LinkAction::Blocked);
        assert_eq!(link_action("https://user@/"), LinkAction::Blocked);
        assert_eq!(link_action("https://:443/"), LinkAction::Blocked);
    }

    #[test]
    fn email_links_copy_the_address() {
        assert_eq!(link_action("mailto:a@example.com"), email("a@example.com"));
        assert_eq!(
            link_action("mailto:a@example.com,b@example.com?subject=hi"),
            email("a@example.com,b@example.com")
        );
        assert_eq!(link_action("MAILTO:?subject=hi"), email(""));
        assert_eq!(
            link_action("mailto:a@example.com#x"),
            email("a@example.com")
        );
    }

    #[test]
    fn relative_links_are_not_supported_yet() {
        for url in [
            "markdown-preview://document/other.md",
            "markdown-preview://document/#heading",
            "markdown-preview://document/java%09script:alert(1)",
            "MARKDOWN-PREVIEW://document/",
        ] {
            assert_eq!(link_action(url), LinkAction::Unsupported, "{url}");
        }
    }

    fn toggle(token: &str, index: usize) -> LinkAction {
        LinkAction::ToggleTask {
            token: token.into(),
            index,
        }
    }

    #[test]
    fn task_links_toggle_tasks() {
        assert_eq!(
            link_action("markdown-preview://task/abc-1/0"),
            toggle("abc-1", 0)
        );
        assert_eq!(link_action("markdown-preview://task/T/42"), toggle("T", 42));
        assert_eq!(link_action("MARKDOWN-PREVIEW://task/t/7"), toggle("t", 7));
    }

    #[test]
    fn malformed_task_links_do_nothing() {
        for url in [
            "markdown-preview://task/",
            "markdown-preview://task/t",
            "markdown-preview://task/t/",
            "markdown-preview://task//1",
            "markdown-preview://task/t/01",
            "markdown-preview://task/t/-1",
            "markdown-preview://task/t/1/",
            "markdown-preview://task/t/1?x",
            "markdown-preview://task/t/1#x",
            "markdown-preview://task/t/1/2",
            "markdown-preview://task/a_b/1",
            "markdown-preview://task/t/99999999999999999999999999",
            "markdown-preview://TASK/t/1",
            "markdown-preview://document/task/t/1",
            "markdown-preview:task/t/1",
        ] {
            assert_eq!(link_action(url), LinkAction::Unsupported, "{url}");
        }
        assert_eq!(
            link_action(&format!("markdown-preview://task/{}/1", "a".repeat(65))),
            LinkAction::Unsupported
        );
    }

    #[test]
    fn every_other_scheme_is_blocked() {
        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,x",
            "about:blank",
            "blob:https://example.com/x",
            "ftp://example.com/",
            "x-apple-helpviewer://x",
            "ssh://example.com",
            "tel:123",
            "markdown-preview-x://document/",
        ] {
            assert_eq!(link_action(url), LinkAction::Blocked, "{url}");
        }
    }

    #[test]
    fn malformed_urls_are_blocked() {
        for url in [
            "",
            "example.com",
            ":x",
            "1http://example.com/",
            "ht tp://example.com/",
            "h_ttp://example.com/",
            "https://example.com/ path",
            "https://example.com/\u{202e}",
            "https://exämple.com/",
            "https://example.com/\n",
        ] {
            assert_eq!(link_action(url), LinkAction::Blocked, "{url:?}");
        }
    }

    #[test]
    fn overlong_urls_are_blocked() {
        let prefix = "https://example.com/";
        let longest = format!("{prefix}{}", "a".repeat(MAX_LINK_BYTES - prefix.len()));
        assert_eq!(host_of(&link_action(&longest)), Some("example.com"));
        assert_eq!(link_action(&format!("{longest}a")), LinkAction::Blocked);
    }

    #[test]
    fn schemes_follow_rfc_3986() {
        assert!(is_scheme("a"));
        assert!(is_scheme("a+b-c.d1"));
        assert!(!is_scheme(""));
        assert!(!is_scheme("1a"));
        assert!(!is_scheme("+a"));
        assert!(!is_scheme("a_b"));
    }
}
