//! Decides what happens when the user clicks a link in the preview.
//!
//! The input is the absolute URL the web engine resolved the link to, never
//! the raw `href`: only after resolution is the scheme known for certain
//! (for example, `java%09script:x` is a relative link, not a scheme). Only
//! `http`, `https` and `mailto` may ever leave the app, and only after the
//! user confirmed it.

use crate::PAGE_BASE_URL;

/// Longest URL, in bytes, that may be opened. Longer URLs cannot be shown
/// in full in the confirmation dialog, so they are blocked.
pub const MAX_LINK_BYTES: usize = 4096;

/// What the app does with a clicked link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkAction {
    /// An `http` or `https` link: open it in the default browser after the
    /// user confirmed it.
    OpenInBrowser {
        /// The host (and port, if any) for the confirmation dialog, without
        /// user name or password, so a link cannot pretend to lead to a
        /// different site.
        host: String,
    },
    /// A `mailto` link: open the default email app after the user confirmed
    /// it.
    OpenInEmailApp {
        /// The recipients as written in the link (may be empty).
        recipients: String,
    },
    /// A relative link to another file or to a position in the document.
    /// Not supported yet.
    Unsupported,
    /// Anything else (`file:`, other apps' schemes, malformed URLs, overlong
    /// URLs). Never opened.
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
///     LinkAction::OpenInBrowser { host: "example.com".into() }
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
            Some(host) => LinkAction::OpenInBrowser { host },
            None => LinkAction::Blocked,
        },
        "mailto" => LinkAction::OpenInEmailApp {
            recipients: rest.split(['?', '#']).next().unwrap_or_default().to_owned(),
        },
        scheme if is_page_scheme(scheme) => LinkAction::Unsupported,
        _ => LinkAction::Blocked,
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

    fn browser(host: &str) -> LinkAction {
        LinkAction::OpenInBrowser { host: host.into() }
    }

    fn email(recipients: &str) -> LinkAction {
        LinkAction::OpenInEmailApp {
            recipients: recipients.into(),
        }
    }

    #[test]
    fn web_links_open_in_the_browser() {
        assert_eq!(link_action("https://example.com/"), browser("example.com"));
        assert_eq!(link_action("http://example.com"), browser("example.com"));
        assert_eq!(
            link_action("https://example.com:8443/a?b=c#d"),
            browser("example.com:8443")
        );
        assert_eq!(link_action("HTTPS://example.com/"), browser("example.com"));
        assert_eq!(link_action("https://[::1]:8080/"), browser("[::1]:8080"));
        assert_eq!(link_action("https://[::1]/"), browser("[::1]"));
        assert_eq!(
            link_action("https://xn--80ak6aa92e.com/"),
            browser("xn--80ak6aa92e.com")
        );
    }

    #[test]
    fn user_information_is_not_shown_as_the_host() {
        assert_eq!(
            link_action("https://www.apple.com@evil.example/"),
            browser("evil.example")
        );
        assert_eq!(
            link_action("https://user:secret@example.com:1/"),
            browser("example.com:1")
        );
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
    fn email_links_open_the_email_app() {
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
        assert_eq!(link_action(&longest), browser("example.com"));
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
