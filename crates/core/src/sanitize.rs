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

/// Longest run of text, in bytes, that may contain characters needing
/// escaping before it is split off into its own text node (see
/// [`separate_long_text_runs`]).
const MAX_ESCAPED_RUN: usize = 256;

/// Most work allowed for escaping one attribute value (see [`escape_cost`]);
/// more expensive values are removed. Real URLs, titles and image
/// descriptions stay far below this: a URL of 8 000 bytes with 100 `&` costs
/// at most 800 000.
const MAX_ATTRIBUTE_ESCAPE_COST: usize = 1 << 20;

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
    clean(&separate_long_text_runs(html, MAX_ESCAPED_RUN))
}

fn clean(html: &str) -> String {
    SANITIZER.clean(html).to_string()
}

/// Splits long runs of text that contain characters needing escaping by
/// inserting empty comments, which the sanitizer removes again.
///
/// When the sanitized HTML is serialized, escaping a text node takes time
/// proportional to the number of `&` and U+0080 to U+00BF characters (UTF-8
/// lead byte `0xC2`, including the no-break space) times the length of the
/// node: quadratic for long paragraphs or code blocks. After this function,
/// such characters are at most `max_run` bytes plus one character or
/// character reference away from the end of their node, so the total work is
/// linear in the input size. The
/// output does not change, because adjacent text nodes are serialized one
/// after the other.
///
/// Expects HTML as produced by comrak: in text, `<` only starts a tag and
/// `&` only starts a character reference; attribute values are quoted with
/// `"`.
fn separate_long_text_runs(html: &str, max_run: usize) -> Cow<'_, str> {
    const SEPARATOR: &str = "<!---->";
    let mut separated = String::new();
    let mut copied = 0;
    let mut in_tag = false;
    let mut in_quotes = false;
    let mut in_reference = false;
    let mut run = 0;
    let mut needs_escaping = false;

    for (i, &byte) in html.as_bytes().iter().enumerate() {
        if in_tag {
            match byte {
                b'"' => in_quotes = !in_quotes,
                b'>' if !in_quotes => in_tag = false,
                _ => {}
            }
            continue;
        }
        if in_reference {
            match byte {
                b'#' | b'0'..=b'9' | b'A'..=b'Z' | b'a'..=b'z' => {
                    run += 1;
                    continue;
                }
                b';' => {
                    in_reference = false;
                    run += 1;
                    continue;
                }
                _ => in_reference = false,
            }
        }
        if byte == b'<' {
            in_tag = true;
            in_quotes = false;
            run = 0;
            needs_escaping = false;
            continue;
        }
        // Outside tags and character references, a byte that is not a UTF-8
        // continuation byte starts a character: a safe place to split.
        let starts_character = byte & 0xC0 != 0x80;
        if starts_character && needs_escaping && run >= max_run {
            separated.push_str(&html[copied..i]);
            separated.push_str(SEPARATOR);
            copied = i;
            run = 0;
            needs_escaping = false;
        }
        match byte {
            b'&' => {
                in_reference = true;
                needs_escaping = true;
            }
            0xC2 => needs_escaping = true,
            _ => {}
        }
        run += 1;
    }

    if separated.is_empty() {
        Cow::Borrowed(html)
    } else {
        separated.push_str(&html[copied..]);
        Cow::Owned(separated)
    }
}

/// Work needed to escape an attribute value when serializing it: for every
/// `&` and every U+0080 to U+00BF character, the distance to the next `"`,
/// `<` or `>`, or to the end of the value.
fn escape_cost(value: &str) -> usize {
    let mut cost = 0_usize;
    let mut next_stop = value.len();
    for (i, &byte) in value.as_bytes().iter().enumerate().rev() {
        match byte {
            b'"' | b'<' | b'>' => next_stop = i,
            b'&' | 0xC2 => cost = cost.saturating_add(next_stop - i),
            _ => {}
        }
    }
    cost
}

fn filter_attribute<'u>(element: &str, attribute: &str, value: &'u str) -> Option<Cow<'u, str>> {
    let allowed = escape_cost(value) <= MAX_ATTRIBUTE_ESCAPE_COST
        && match (element, attribute) {
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
    use proptest::prelude::*;

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

    #[test]
    fn text_without_characters_needing_escaping_is_not_copied() {
        let html = "<p>plain text</p>\n<pre><code>more text\n</code></pre>\n";
        assert!(matches!(separate_long_text_runs(html, 0), Cow::Borrowed(_)));
    }

    #[test]
    fn long_text_runs_are_separated_between_characters() {
        assert_eq!(
            separate_long_text_runs("<p>&amp;&amp;&amp;</p>", 0),
            "<p>&amp;<!---->&amp;<!---->&amp;</p>"
        );
        assert_eq!(
            separate_long_text_runs("<p>\u{b0}\u{b0}\u{b0}</p>", 0),
            "<p>\u{b0}<!---->\u{b0}<!---->\u{b0}</p>"
        );
        // Split at the first character after 8 bytes that contain an `&`.
        assert_eq!(
            separate_long_text_runs("<p>aaaa&amp;aaaa&amp;</p>", 8),
            "<p>aaaa&amp;<!---->aaaa&amp;</p>"
        );
        assert_eq!(
            separate_long_text_runs("<p>aaaaaaaaaa&amp;a</p>", 8),
            "<p>aaaaaaaaaa&amp;<!---->a</p>"
        );
        // A character reference counts with all of its bytes, including `;`.
        assert_eq!(
            separate_long_text_runs("<p>&amp;a&amp;</p>", 5),
            "<p>&amp;<!---->a&amp;</p>"
        );
    }

    #[test]
    fn unterminated_character_references_end_at_the_next_other_character() {
        // comrak always terminates references; never split inside `&ab`.
        assert_eq!(
            separate_long_text_runs("<p>&ab c&amp;d</p>", 0),
            "<p>&ab<!----> c&amp;<!---->d</p>"
        );
    }

    #[test]
    fn short_text_runs_and_tags_are_not_separated() {
        let html = "<p>a &amp; b &lt; c</p><a href=\"?a&amp;b&amp;c\" title=\"x > &amp; y\">t</a>";
        assert!(matches!(
            separate_long_text_runs(html, 16),
            Cow::Borrowed(_)
        ));
        // Attribute values are never split, even with the smallest limit.
        let html = "<a href=\"?a&amp;b&amp;c\" title=\"x > &amp; y\">t</a>";
        assert!(matches!(separate_long_text_runs(html, 0), Cow::Borrowed(_)));
    }

    #[test]
    fn escape_cost_counts_distance_to_next_stop() {
        assert_eq!(escape_cost("plain"), 0);
        // `&` at 1 scans to `<` at 3, `&` at 5 scans to the end at 6.
        assert_eq!(escape_cost("a&b<c&"), 3);
        assert_eq!(escape_cost("&\"&>&"), 3);
        // U+00B0 is encoded as 0xC2 0xB0.
        assert_eq!(escape_cost("\u{b0}"), 2);
        assert_eq!(escape_cost("\u{e9}"), 0);
    }

    #[test]
    fn expensive_attribute_values_are_removed() {
        let expensive = format!("<a href=\"?{}\">x</a>", "&amp;".repeat(2_000));
        assert_eq!(
            sanitize(&expensive),
            r#"<a rel="noopener noreferrer">x</a>"#
        );
        let ordinary = r#"<a href="https://example.com/?a=1&amp;b=2&amp;c=3">x</a>"#;
        assert_eq!(
            sanitize(ordinary),
            r#"<a href="https://example.com/?a=1&amp;b=2&amp;c=3" rel="noopener noreferrer">x</a>"#
        );
    }

    /// Fragments that produce text needing escaping next to tags, character
    /// references, code blocks, tables and attributes.
    #[rustfmt::skip]
    const FRAGMENTS: &[&str] = &[
        "&", "&amp;", "&lt;", "&#38;", "\u{b0}", "\u{a0}", "\u{e9}", "\u{1f30d}", "<", ">", "\"",
        "'", "a", " ", "\n", "\n\n", "*", "_", "`", "```\n", "    ", "[", "](", ")", "![",
        "](a&b.png \"t&\")", "|", "|-|\n", "> ", "- ", "1. ", "# ", "\\", "<b>", "&&",
        "https://a.example/?b&c", "www.a.example",
    ];

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(2_000))]

        /// The separators must never change the sanitized output.
        #[test]
        fn separating_text_runs_does_not_change_output(
            parts in prop::collection::vec(prop::sample::select(FRAGMENTS), 0..120),
            max_run in 0_usize..24,
        ) {
            let html = comrak::markdown_to_html(&parts.concat(), &crate::markdown_options());
            prop_assert_eq!(clean(&separate_long_text_runs(&html, max_run)), clean(&html));
        }
    }
}
