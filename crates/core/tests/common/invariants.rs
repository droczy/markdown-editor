//! Independent checker for the security invariants of rendered HTML.
//!
//! It deliberately does not reuse the sanitizer's configuration: it encodes
//! the expected policy a second time, so a mistake in the sanitizer setup is
//! caught here. Shared by the integration tests and the fuzz targets.

#![allow(dead_code, clippy::missing_panics_doc, clippy::expect_used)]

/// Elements that may appear in the output.
#[rustfmt::skip]
const ALLOWED_TAGS: &[&str] = &[
    "a", "blockquote", "br", "code", "del", "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "img",
    "input", "li", "ol", "p", "pre", "strong", "table", "tbody", "td", "th", "thead", "tr", "ul",
];

/// A start tag found in the output.
#[derive(Debug)]
pub struct Tag {
    pub name: String,
    pub attributes: Vec<(String, String)>,
}

/// Panics with a descriptive message if `html` violates any invariant.
pub fn assert_safe_html(html: &str, input: &str) {
    for tag in parse_tags(html) {
        assert!(
            ALLOWED_TAGS.contains(&tag.name.as_str()),
            "forbidden element <{}>\ninput: {input:?}\nhtml: {html}",
            tag.name
        );
        for (name, value) in &tag.attributes {
            assert!(
                is_allowed_attribute(&tag.name, name, value),
                "forbidden attribute {name}={value:?} on <{}>\ninput: {input:?}\nhtml: {html}",
                tag.name
            );
        }
    }
}

fn is_allowed_attribute(tag: &str, name: &str, value: &str) -> bool {
    match (tag, name) {
        ("a", "href") => is_allowed_link(value),
        ("a", "rel") => value == "noopener noreferrer",
        ("a" | "img", "title") | ("img", "alt") => true,
        ("img", "src") => is_local_relative(value),
        ("input", "type") => value == "checkbox",
        ("input", "checked" | "disabled") => value.is_empty(),
        ("ol", "start") => value.chars().all(|c| c.is_ascii_digit()),
        ("pre", "lang") => {
            !value.is_empty()
                && value
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_+#.".contains(c))
        }
        ("td" | "th", "align") => matches!(value, "left" | "center" | "right"),
        _ => false,
    }
}

/// Link targets: only `http`, `https` and `mailto` schemes, or relative.
fn is_allowed_link(value: &str) -> bool {
    match url_scheme(value) {
        Some(scheme) => matches!(scheme.as_str(), "http" | "https" | "mailto"),
        None => true,
    }
}

/// The scheme as a browser determines it (WHATWG URL standard): leading C0
/// controls and spaces are trimmed, tabs and newlines removed anywhere, and a
/// scheme is an ASCII letter followed by letters, digits, `+`, `-` or `.`.
fn url_scheme(value: &str) -> Option<String> {
    let cleaned: String = value
        .chars()
        .filter(|c| !matches!(c, '\t' | '\n' | '\r'))
        .collect();
    let cleaned = cleaned.trim_start_matches(|c: char| c <= ' ');
    let (scheme, _) = cleaned.split_once(':')?;
    let mut chars = scheme.chars();
    let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    valid.then(|| scheme.to_ascii_lowercase())
}

/// Image sources: stricter than links, any colon before the first path
/// delimiter counts as a scheme (mirrors the production rule).
fn is_local_relative(value: &str) -> bool {
    let cleaned: String = value
        .chars()
        .filter(|c| !matches!(c, '\t' | '\n' | '\r'))
        .collect();
    let cleaned = cleaned.trim_start_matches(|c: char| c <= ' ');
    !cleaned.is_empty() && !cleaned.starts_with(['/', '\\']) && scheme_of(cleaned).is_none()
}

fn scheme_of(url: &str) -> Option<&str> {
    let end = url.find(['/', '\\', '?', '#']).unwrap_or(url.len());
    url[..end].find(':').map(|colon| &url[..colon])
}

/// Minimal parser for the serializer output of ammonia/html5ever: text
/// content never contains a raw `<`, attributes are always double-quoted.
pub fn parse_tags(html: &str) -> Vec<Tag> {
    let mut tags = Vec::new();
    let mut rest = html;
    while let Some(start) = rest.find('<') {
        rest = &rest[start + 1..];
        if rest.starts_with('/') {
            continue;
        }
        let name_end = rest
            .find(|c: char| c.is_whitespace() || c == '>' || c == '/')
            .unwrap_or(rest.len());
        let name = rest[..name_end].to_ascii_lowercase();
        rest = &rest[name_end..];
        let mut attributes = Vec::new();
        loop {
            rest = rest.trim_start();
            if rest.is_empty() || rest.starts_with('>') || rest.starts_with("/>") {
                break;
            }
            let attr_end = rest
                .find(|c: char| c == '=' || c.is_whitespace() || c == '>')
                .unwrap_or(rest.len());
            let attr_name = rest[..attr_end].to_ascii_lowercase();
            rest = &rest[attr_end..];
            let mut value = String::new();
            if let Some(after_eq) = rest.strip_prefix("=\"") {
                let close = after_eq.find('"').expect("unterminated attribute value");
                value = decode_entities(&after_eq[..close]);
                rest = &after_eq[close + 1..];
            }
            attributes.push((attr_name, value));
        }
        tags.push(Tag { name, attributes });
    }
    tags
}

fn decode_entities(value: &str) -> String {
    value
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", "\u{a0}")
        .replace("&amp;", "&")
}
