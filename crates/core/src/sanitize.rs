//! Second line of defence: allowlist-based HTML sanitization.

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

/// Elements comrak emits for the enabled Markdown features. Nothing else is
/// allowed through.
#[rustfmt::skip]
const ALLOWED_TAGS: &[&str] = &[
    "a", "blockquote", "br", "code", "del", "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "img",
    "input", "li", "ol", "p", "pre", "strong", "table", "tbody", "td", "th", "thead", "tr", "ul",
];

/// Allowed attributes per element.
const ALLOWED_ATTRIBUTES: &[(&str, &[&str])] = &[
    ("a", &["href", "title"]),
    ("img", &["src", "alt", "title"]),
    // `type` is deliberately missing here: ammonia would then accept any
    // value. It is allowed only as `type="checkbox"` via
    // `tag_attribute_values` below.
    ("input", &["checked", "disabled"]),
    ("ol", &["start"]),
    ("pre", &["lang"]),
    ("td", &["align"]),
    ("th", &["align"]),
];

/// URL schemes allowed in links. Everything else (`javascript:`, `data:`,
/// `file:`, …) is removed.
const ALLOWED_URL_SCHEMES: &[&str] = &["http", "https", "mailto"];

static SANITIZER: LazyLock<ammonia::Builder<'static>> = LazyLock::new(|| {
    let mut builder = ammonia::Builder::empty();
    builder
        .tags(ALLOWED_TAGS.iter().copied().collect())
        .tag_attributes(
            ALLOWED_ATTRIBUTES
                .iter()
                .map(|(tag, attributes)| (*tag, attributes.iter().copied().collect()))
                .collect(),
        )
        // Task list checkboxes must stay read-only checkboxes.
        .tag_attribute_values(HashMap::from([(
            "input",
            HashMap::from([("type", HashSet::from(["checkbox"]))]),
        )]))
        .set_tag_attribute_values(HashMap::from([(
            "input",
            HashMap::from([("disabled", "")]),
        )]))
        .url_schemes(ALLOWED_URL_SCHEMES.iter().copied().collect())
        .url_relative(ammonia::UrlRelative::PassThrough)
        .link_rel(Some("noopener noreferrer"))
        .strip_comments(true)
        .attribute_filter(filter_attribute);
    builder
});

/// Sanitizes HTML produced by comrak.
pub(crate) fn sanitize(html: &str) -> String {
    SANITIZER.clean(html).to_string()
}

fn filter_attribute<'u>(element: &str, attribute: &str, value: &'u str) -> Option<Cow<'u, str>> {
    let allowed = match (element, attribute) {
        ("img", "src") => is_local_relative_url(value),
        ("pre", "lang") => is_plain_language_name(value),
        _ => true,
    };
    allowed.then_some(Cow::Borrowed(value))
}

/// Code block languages such as `rust`, `c++`, `objective-c` or `c#`. The
/// value is escaped anyway, but later stages (syntax highlighting) should only
/// ever see plain identifiers.
fn is_plain_language_name(value: &str) -> bool {
    (1..=32).contains(&value.len())
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '+' | '#' | '.'))
}

/// Returns `true` only for relative paths such as `images/a.png` that resolve
/// inside the document's folder hierarchy.
///
/// Rejected: any scheme (`https:`, `data:`, `file:`, `C:`), protocol-relative
/// URLs (`//host`), absolute paths (`/etc`), backslash variants that browsers
/// normalize to slashes, and empty values.
///
/// Path traversal (`../`) is *not* checked here; the platform layer must
/// resolve paths and enforce the sandbox before loading any file.
fn is_local_relative_url(value: &str) -> bool {
    // Browsers strip tabs and newlines anywhere in a URL and trim leading
    // control characters and spaces, so check the normalized form.
    let normalized: String = value
        .chars()
        .filter(|c| !matches!(c, '\t' | '\n' | '\r'))
        .collect();
    let trimmed = normalized.trim_start_matches(|c: char| c <= ' ');

    if trimmed.is_empty() || trimmed.starts_with(['/', '\\']) {
        return false;
    }
    // A colon before the first path, query or fragment delimiter marks a scheme.
    let first_delimiter = trimmed.find(['/', '\\', '?', '#']).unwrap_or(trimmed.len());
    !trimmed[..first_delimiter].contains(':')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_relative_urls_are_allowed() {
        for url in [
            "a.png",
            "images/a.png",
            "../a.png",
            "./a b.png",
            "a.png?x=1#y",
            "dir/a:b.png",
        ] {
            assert!(is_local_relative_url(url), "{url}");
        }
    }

    #[test]
    fn non_local_urls_are_rejected() {
        for url in [
            "",
            " ",
            "https://example.com/a.png",
            "HTTP://example.com/a.png",
            "data:image/png;base64,AAAA",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "C:\\a.png",
            "//example.com/a.png",
            "\\\\server\\share\\a.png",
            "/\\example.com",
            "/etc/passwd",
            " //example.com",
            "\t/\t/example.com",
            "\u{1}https://example.com",
            "ht\ntps://example.com",
        ] {
            assert!(!is_local_relative_url(url), "{url:?}");
        }
    }

    #[test]
    fn plain_language_names_are_allowed() {
        for name in [
            "rust",
            "c++",
            "c#",
            "objective-c",
            "shell_session",
            "vue.js",
        ] {
            assert!(is_plain_language_name(name), "{name}");
        }
    }

    #[test]
    fn unusual_language_names_are_rejected() {
        for name in ["", "a b", "\"><x>", "rust;", &"a".repeat(33)] {
            assert!(!is_plain_language_name(name), "{name:?}");
        }
    }

    #[test]
    fn checkbox_is_forced_disabled() {
        assert_eq!(
            sanitize(r#"<input type="checkbox" checked="">"#),
            r#"<input type="checkbox" checked="" disabled="">"#
        );
    }

    #[test]
    fn non_checkbox_input_loses_type() {
        assert_eq!(sanitize(r#"<input type="text">"#), r#"<input disabled="">"#);
    }

    /// RUSTSEC-2026-0533 (mutation XSS by mixing MathML and SVG). The
    /// allowlist contains no MathML, SVG or raw-text elements, so this layer
    /// alone removes the payloads completely, without relying on comrak.
    #[test]
    fn mathml_svg_mutation_xss_is_removed() {
        for payload in [
            "<math><mi><math><iframe><!--</iframe><img src onerror=alert(1)>-->",
            "<math><mi><svg><iframe><!--</iframe><img src onerror=alert(1)>-->",
            "<svg><foreignObject><math><iframe><!--</iframe><img src onerror=alert(1)>-->",
        ] {
            assert_eq!(sanitize(payload), "", "{payload}");
        }
    }
}
