//! The complete HTML page shown in the preview: sanitized content wrapped in
//! a fixed template with a strict Content Security Policy and the stylesheet.
//!
//! The policy is the third line of defence after comrak and the sanitizer.
//! Even if markup slipped through both, the page could not load anything,
//! run scripts, submit forms or change its base URL. Only the stylesheet
//! below is allowed, identified by its hash.

use crate::{RenderError, render_html};

/// Base64-encoded SHA-256 hash of [`PAGE_STYLESHEET`]. A macro, so that it
/// can be part of the constants below.
macro_rules! stylesheet_hash {
    () => {
        "3qJLJ23zHm+5JkGHnnVjl6f4bRaukH55Egc/fVKI3w8="
    };
}

macro_rules! content_security_policy {
    () => {
        concat!(
            "default-src 'none'; style-src 'sha256-",
            stylesheet_hash!(),
            "'; base-uri 'none'; form-action 'none'"
        )
    };
}

macro_rules! stylesheet {
    () => {
        include_str!("page.css")
    };
}

/// The stylesheet of the preview page (light and dark appearance).
pub const PAGE_STYLESHEET: &str = stylesheet!();

/// Base64-encoded SHA-256 hash of [`PAGE_STYLESHEET`], as used in
/// [`PAGE_CONTENT_SECURITY_POLICY`].
pub const PAGE_STYLESHEET_HASH: &str = stylesheet_hash!();

/// Content Security Policy of the preview page: nothing may be loaded,
/// executed or submitted; the only allowed style is [`PAGE_STYLESHEET`].
pub const PAGE_CONTENT_SECURITY_POLICY: &str = content_security_policy!();

/// Base URL the platform must use when it loads the page. Relative links in
/// the document resolve against it, so a click on one can be told apart from
/// a link to an external website (see [`crate::link_action`]).
pub const PAGE_BASE_URL: &str = "markdown-preview://document/";

/// Everything before the content. The policy comes first, before anything
/// that it has to govern.
const PAGE_START: &str = concat!(
    "<!DOCTYPE html>\n<html>\n<head>\n",
    "<meta http-equiv=\"Content-Security-Policy\" content=\"",
    content_security_policy!(),
    "\">\n",
    "<meta charset=\"utf-8\">\n",
    "<meta name=\"color-scheme\" content=\"light dark\">\n",
    "<style>",
    stylesheet!(),
    "</style>\n</head>\n<body>\n<main>\n"
);

const PAGE_END: &str = "</main>\n</body>\n</html>\n";

/// Renders untrusted Markdown to a complete HTML page for the preview.
///
/// The content is the output of [`render_html`]; this function only adds the
/// fixed template around it. The platform must still disable JavaScript,
/// block navigation and load the page with [`PAGE_BASE_URL`].
///
/// # Errors
///
/// The same as [`render_html`].
///
/// # Examples
///
/// ```
/// let page = markdown_editor_core::render_page("# Hello").unwrap();
/// assert!(page.contains("<h1>Hello</h1>"));
/// assert!(page.contains(markdown_editor_core::PAGE_CONTENT_SECURITY_POLICY));
/// ```
pub fn render_page(markdown: &str) -> Result<String, RenderError> {
    let content = render_html(markdown)?;
    let mut page = String::with_capacity(PAGE_START.len() + content.len() + PAGE_END.len());
    page.push_str(PAGE_START);
    page.push_str(&content);
    page.push_str(PAGE_END);
    Ok(page)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn page_wraps_the_rendered_content() {
        let page = render_page("# Title\n\ntext").unwrap();
        assert_eq!(
            page,
            format!("{PAGE_START}<h1>Title</h1>\n<p>text</p>\n{PAGE_END}")
        );
    }

    #[test]
    fn policy_is_the_first_element_of_the_head() {
        let page = render_page("").unwrap();
        let head = page.split_once("<head>\n").unwrap().1;
        assert!(head.starts_with(&format!(
            "<meta http-equiv=\"Content-Security-Policy\" content=\"{PAGE_CONTENT_SECURITY_POLICY}\">\n"
        )));
    }

    #[test]
    fn policy_blocks_everything_except_the_stylesheet() {
        assert_eq!(
            PAGE_CONTENT_SECURITY_POLICY,
            "default-src 'none'; style-src 'sha256-3qJLJ23zHm+5JkGHnnVjl6f4bRaukH55Egc/fVKI3w8='; \
             base-uri 'none'; form-action 'none'"
        );
        assert!(PAGE_CONTENT_SECURITY_POLICY.contains(PAGE_STYLESHEET_HASH));
    }

    #[test]
    fn stylesheet_is_embedded_unchanged() {
        // The hash covers exactly the text between the style tags.
        let page = render_page("").unwrap();
        assert!(page.contains(&format!("<style>{PAGE_STYLESHEET}</style>")));
    }

    #[test]
    fn stylesheet_cannot_end_the_style_element_or_the_policy_attribute() {
        assert!(!PAGE_STYLESHEET.contains("</"));
        assert!(!PAGE_CONTENT_SECURITY_POLICY.contains('"'));
    }

    #[test]
    fn errors_are_passed_on() {
        let markdown = "a".repeat(crate::MAX_INPUT_BYTES + 1);
        assert_eq!(
            render_page(&markdown),
            Err(render_html(&markdown).unwrap_err())
        );
    }

    #[test]
    fn base_url_uses_its_own_scheme() {
        assert_eq!(PAGE_BASE_URL, "markdown-preview://document/");
    }
}
