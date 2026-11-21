//! The complete HTML page shown in the preview: sanitized content wrapped in
//! a fixed template with a strict Content Security Policy and the stylesheet.
//!
//! The platform loads the template once ([`EMPTY_PAGE`]) and then shows each
//! version of the document by replacing the content of its `main` element
//! with [`render_page_content`]. The page is never reloaded for an edit, so
//! the scroll position stays and an edit appears at once.
//!
//! The policy is the third line of defence after comrak and the sanitizer.
//! Even if markup slipped through both, the page could not load anything,
//! run scripts, submit forms or change its base URL. Only the stylesheet
//! below is allowed, identified by its hash.

use std::fmt::Write;

use crate::{RenderError, is_valid_task_token, render_html};

/// Base64-encoded SHA-256 hash of [`PAGE_STYLESHEET`]. A macro, so that it
/// can be part of the constants below.
macro_rules! stylesheet_hash {
    () => {
        "/P8dq8Cc6DE+dvQC1ORGbm7rYJe5EChdguBfHCVmkZc="
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

/// Start of the links that check or uncheck a task:
/// `markdown-preview://task/<token>/<index>`. Documents cannot produce such
/// links: the sanitizer removes protocol-relative links (`//task/...`), and
/// the token is random for every page.
pub(crate) const TASK_LINK_PREFIX: &str = "markdown-preview://task/";

/// Everything before the content. The policy comes first, before anything
/// that it has to govern.
macro_rules! page_start {
    () => {
        concat!(
            "<!DOCTYPE html>\n<html>\n<head>\n",
            "<meta http-equiv=\"Content-Security-Policy\" content=\"",
            content_security_policy!(),
            "\">\n",
            "<meta charset=\"utf-8\">\n",
            "<meta name=\"color-scheme\" content=\"light dark\">\n",
            "<style>",
            stylesheet!(),
            "</style>\n</head>\n<body>\n<main>\n"
        )
    };
}

/// Everything after the content.
macro_rules! page_end {
    () => {
        "</main>\n</body>\n</html>\n"
    };
}

const PAGE_START: &str = page_start!();
const PAGE_END: &str = page_end!();

/// The preview page without content: the template with the policy and the
/// stylesheet, and an empty `main` element, the only child of `body`. The
/// platform loads it once (with [`PAGE_BASE_URL`]) and puts the output of
/// [`render_page_content`] into that element.
pub const EMPTY_PAGE: &str = concat!(page_start!(), page_end!());

/// Renders untrusted Markdown to a complete HTML page for the preview.
///
/// The content is the output of [`render_html`]; this function only adds the
/// fixed template around it. The platform must still disable JavaScript,
/// block navigation and load the page with [`PAGE_BASE_URL`].
///
/// With a `task_token` (see [`is_valid_task_token`]), every task checkbox
/// becomes a link to `markdown-preview://task/<token>/<index>`, which the
/// platform handles with [`crate::toggle_task`]. The token should be random
/// for every page. An invalid token is ignored (checkboxes stay inert).
///
/// # Errors
///
/// The same as [`render_html`].
///
/// # Examples
///
/// ```
/// let page = markdown_editor_core::render_page("# Hello", None).unwrap();
/// assert!(page.contains("<h1>Hello</h1>"));
/// assert!(page.contains(markdown_editor_core::PAGE_CONTENT_SECURITY_POLICY));
///
/// let page = markdown_editor_core::render_page("- [ ] task", Some("t1")).unwrap();
/// assert!(page.contains("href=\"markdown-preview://task/t1/0\""));
/// ```
pub fn render_page(markdown: &str, task_token: Option<&str>) -> Result<String, RenderError> {
    let content = render_page_content(markdown, task_token)?;
    let mut page = String::with_capacity(PAGE_START.len() + content.len() + PAGE_END.len());
    page.push_str(PAGE_START);
    page.push_str(&content);
    page.push_str(PAGE_END);
    Ok(page)
}

/// Renders untrusted Markdown to the content of the preview page: exactly
/// what [`render_page`] puts into the page's `main` element.
///
/// The platform shows it by replacing the content of the `main` element of
/// [`EMPTY_PAGE`], so that the page's policy applies to it as well. The
/// `task_token` works as in [`render_page`].
///
/// # Errors
///
/// The same as [`render_html`].
///
/// # Examples
///
/// ```
/// use markdown_editor_core::{EMPTY_PAGE, render_page, render_page_content};
///
/// let content = render_page_content("- [ ] task", Some("t1")).unwrap();
/// assert!(content.contains("href=\"markdown-preview://task/t1/0\""));
/// let page = EMPTY_PAGE.replace("<main>\n", &format!("<main>\n{content}"));
/// assert_eq!(page, render_page("- [ ] task", Some("t1")).unwrap());
/// ```
pub fn render_page_content(
    markdown: &str,
    task_token: Option<&str>,
) -> Result<String, RenderError> {
    let content = render_html(markdown)?;
    Ok(match task_token {
        Some(token) if is_valid_task_token(token) => link_tasks(&content, token),
        _ => content,
    })
}

/// Replaces every task checkbox of sanitized `content` with a link that
/// checks or unchecks it. The checkbox inside only shows the state: it
/// cannot be focused or clicked itself (see the stylesheet), so the click
/// reaches the link.
///
/// Sanitized content contains `<input` only as task checkboxes: raw HTML in
/// the document is escaped, so `<` in text is always `&lt;`. They appear in
/// document order, the order [`crate::toggle_task`] counts in.
fn link_tasks(content: &str, token: &str) -> String {
    let mut linked = String::with_capacity(content.len() + content.len() / 8);
    let mut rest = content;
    let mut index = 0_usize;
    while let Some(start) = rest.find("<input ") {
        let Some(length) = rest[start..].find('>') else {
            break;
        };
        let end = start + length + 1;
        let checked = rest[start..end].contains(" checked=");
        linked.push_str(&rest[..start]);
        // Writing into a String cannot fail.
        let _ = write!(
            linked,
            "<a href=\"{TASK_LINK_PREFIX}{token}/{index}\" role=\"checkbox\" \
             aria-checked=\"{checked}\" aria-label=\"Task\">\
             <input type=\"checkbox\" tabindex=\"-1\" aria-hidden=\"true\"{}></a>",
            if checked { " checked=\"\"" } else { "" }
        );
        rest = &rest[end..];
        index += 1;
    }
    linked.push_str(rest);
    linked
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn page_wraps_the_rendered_content() {
        let page = render_page("# Title\n\ntext", None).unwrap();
        assert_eq!(
            page,
            format!("{PAGE_START}<h1>Title</h1>\n<p>text</p>\n{PAGE_END}")
        );
    }

    #[test]
    fn empty_page_is_the_template_without_content() {
        assert_eq!(EMPTY_PAGE, render_page("", None).unwrap());
        assert_eq!(EMPTY_PAGE, format!("{PAGE_START}{PAGE_END}"));
        // The platform finds the element to fill as the only child of body.
        assert!(EMPTY_PAGE.ends_with("<body>\n<main>\n</main>\n</body>\n</html>\n"));
        assert_eq!(EMPTY_PAGE.matches("<main>").count(), 1);
    }

    #[test]
    fn content_is_what_the_page_wraps() {
        for (markdown, token) in [
            ("# Title\n\ntext", None),
            ("- [ ] open\n- [x] done", Some("abc-1")),
            ("- [ ] open", Some("not valid")),
            ("", None),
        ] {
            let content = render_page_content(markdown, token).unwrap();
            assert_eq!(
                render_page(markdown, token).unwrap(),
                format!("{PAGE_START}{content}{PAGE_END}"),
                "{markdown:?}"
            );
        }
        assert_eq!(render_page_content("- [ ] a", None), render_html("- [ ] a"));
        let markdown = "a".repeat(crate::MAX_INPUT_BYTES + 1);
        assert_eq!(
            render_page_content(&markdown, None),
            Err(render_html(&markdown).unwrap_err())
        );
    }

    #[test]
    fn policy_is_the_first_element_of_the_head() {
        let page = render_page("", None).unwrap();
        let head = page.split_once("<head>\n").unwrap().1;
        assert!(head.starts_with(&format!(
            "<meta http-equiv=\"Content-Security-Policy\" content=\"{PAGE_CONTENT_SECURITY_POLICY}\">\n"
        )));
    }

    #[test]
    fn policy_blocks_everything_except_the_stylesheet() {
        assert_eq!(
            PAGE_CONTENT_SECURITY_POLICY,
            "default-src 'none'; style-src 'sha256-/P8dq8Cc6DE+dvQC1ORGbm7rYJe5EChdguBfHCVmkZc='; \
             base-uri 'none'; form-action 'none'"
        );
        assert!(PAGE_CONTENT_SECURITY_POLICY.contains(PAGE_STYLESHEET_HASH));
    }

    #[test]
    fn stylesheet_is_embedded_unchanged() {
        // The hash covers exactly the text between the style tags.
        let page = render_page("", None).unwrap();
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
            render_page(&markdown, Some("t")),
            Err(render_html(&markdown).unwrap_err())
        );
    }

    #[test]
    fn task_checkboxes_become_links_with_the_token() {
        let page = render_page("- [ ] open\n- [x] done\n\n`<input >`", Some("abc-1")).unwrap();
        assert!(page.contains(
            "<li><a href=\"markdown-preview://task/abc-1/0\" role=\"checkbox\" \
             aria-checked=\"false\" aria-label=\"Task\"><input type=\"checkbox\" \
             tabindex=\"-1\" aria-hidden=\"true\"></a> open</li>"
        ));
        assert!(page.contains(
            "<li><a href=\"markdown-preview://task/abc-1/1\" role=\"checkbox\" \
             aria-checked=\"true\" aria-label=\"Task\"><input type=\"checkbox\" \
             tabindex=\"-1\" aria-hidden=\"true\" checked=\"\"></a> done</li>"
        ));
        // Text that looks like a tag is escaped and stays text.
        assert!(page.contains("<code>&lt;input &gt;</code>"));
        // Only the two checkboxes link to tasks (the stylesheet mentions the
        // address as well, so count in the content only).
        let content = page.split_once("<main>").unwrap().1;
        assert_eq!(content.matches("markdown-preview://task/").count(), 2);
    }

    #[test]
    fn without_a_valid_token_checkboxes_stay_inert() {
        let inert = render_page("- [x] done", None).unwrap();
        assert!(inert.contains("<input type=\"checkbox\" checked=\"\" disabled=\"\">"));
        for token in ["", "a/b", "a\"b", "x y"] {
            assert_eq!(
                render_page("- [x] done", Some(token)).unwrap(),
                inert,
                "{token:?}"
            );
        }
    }

    #[test]
    fn content_without_closing_bracket_is_kept() {
        assert_eq!(link_tasks("a <input b", "t"), "a <input b");
        assert_eq!(link_tasks("no tasks", "t"), "no tasks");
    }

    #[test]
    fn base_url_uses_its_own_scheme() {
        assert_eq!(PAGE_BASE_URL, "markdown-preview://document/");
    }
}
