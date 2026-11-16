//! Property-based tests: for arbitrary input the renderer must never panic
//! and must always produce output that satisfies the security invariants.

// Test code is expected to panic on failure.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use common::invariants::assert_safe_html;
use markdown_editor_core::{LinkAction, link_action, render_html, render_page, toggle_task};
use proptest::prelude::*;

/// Fragments that commonly interact in parsers and sanitizers. Random
/// combinations reach far more interesting states than uniform random text.
#[rustfmt::skip]
const FRAGMENTS: &[&str] = &[
    "<", ">", "</", "/>", "script", "img", "svg", "a", " src=", " href=", " onerror=", "=",
    "\"", "'", "`", "```", "~~~", "[", "]", "(", ")", "![", "](", "]:", "|", "---", "- [ ] ",
    "- [x] ", "* ", "1. ", "> ", "#", "*", "_", "~~", "\\", "&", "&#", ";", "x6A", "http:",
    "https:", "javascript:", "data:", "file:", "mailto:", "//", "www.", ".com", "@", ":", " ",
    "\t", "\n", "\n\n", "    ", "a", "\u{0}", "\u{200b}", "é", "🌍",
];

fn markdown_like() -> impl Strategy<Value = String> {
    prop::collection::vec(prop::sample::select(FRAGMENTS), 0..200).prop_map(|parts| parts.concat())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2_000))]

    #[test]
    fn arbitrary_text_renders_safely(input in any::<String>()) {
        let html = render_html(&input).expect("input is below the size limit");
        assert_safe_html(&html, &input);
    }

    #[test]
    fn markdown_like_text_renders_safely(input in markdown_like()) {
        let html = render_html(&input).expect("input is below the size limit");
        assert_safe_html(&html, &input);
    }

    #[test]
    fn rendering_is_deterministic(input in markdown_like()) {
        prop_assert_eq!(render_html(&input), render_html(&input));
    }

    #[test]
    fn only_web_and_email_links_leave_the_app(url in url_like()) {
        let lowercase = url.to_ascii_lowercase();
        match link_action(&url) {
            LinkAction::CopyWebAddress { address, host } => {
                prop_assert!(
                    lowercase.starts_with("http://") || lowercase.starts_with("https://"),
                    "{url:?}"
                );
                prop_assert!(!host.is_empty() && !host.contains(['@', '/', '?', '#']), "{url:?}");
                prop_assert_eq!(&address, &url);
                prop_assert!(address.bytes().all(|byte| byte.is_ascii_graphic()), "{url:?}");
            }
            LinkAction::CopyEmailAddress { address } => {
                prop_assert!(lowercase.starts_with("mailto:"), "{url:?}");
                // What is copied never contains spaces, line breaks or
                // invisible characters.
                prop_assert!(address.bytes().all(|byte| byte.is_ascii_graphic()), "{url:?}");
            }
            LinkAction::ToggleTask { .. } => {
                prop_assert!(lowercase.starts_with("markdown-preview://task/"), "{url:?}");
            }
            LinkAction::Unsupported => {
                prop_assert!(lowercase.starts_with("markdown-preview:"), "{url:?}");
            }
            LinkAction::Blocked => {}
        }
    }
}

/// Documents with task items in many shapes: nested, quoted, ordered, with
/// different line endings, tabs, non-ASCII text and things that look like
/// tasks but are not.
fn tasks_like() -> impl Strategy<Value = String> {
    #[rustfmt::skip]
    const PARTS: &[&str] = &[
        "- [ ] ", "- [x] ", "* [X] ", "1. [ ] ", "  - [ ] ", "> - [x] ", "-\t[ ] ", "- [] ",
        "- [y] ", "`- [ ]`", "text", "ä", "🌍", "\u{feff}", "\0", "\n", "\r\n", "\r", "\n\n",
        "[ ]", "x", "    ", "\t",
    ];
    prop::collection::vec(prop::sample::select(PARTS), 0..40).prop_map(|parts| parts.concat())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2_000))]

    /// Toggling a task changes exactly one byte, from a space to `x` or
    /// back, and the preview shows exactly as many task links as there are
    /// tasks to toggle.
    #[test]
    fn toggling_a_task_changes_exactly_one_character(markdown in tasks_like()) {
        let page = render_page(&markdown, Some("t")).expect("input is below the limits");
        let content = page.split_once("<main>").map_or("", |(_, content)| content);
        let links = content.matches("markdown-preview://task/t/").count();
        for index in 0..links {
            let toggle = toggle_task(&markdown, index);
            prop_assert!(toggle.is_some(), "task {index} of {markdown:?}");
            let toggle = toggle.unwrap_or_else(|| unreachable!());
            let old = markdown.as_bytes()[toggle.offset];
            prop_assert!(matches!(old, b' ' | b'x' | b'X'), "{markdown:?}");
            prop_assert_eq!(toggle.replacement == 'x', old == b' ');
            let mut text = markdown.clone();
            text.replace_range(toggle.offset..=toggle.offset, &toggle.replacement.to_string());
            prop_assert_eq!(text.len(), markdown.len());
            let changed = text.bytes().zip(markdown.bytes()).filter(|(a, b)| a != b).count();
            prop_assert_eq!(changed, 1);
            // The same task, now toggled back, restores the original.
            let back = toggle_task(&text, index);
            prop_assert_eq!(back.map(|t| t.offset), Some(toggle.offset));
        }
        prop_assert_eq!(toggle_task(&markdown, links), None);
    }
}

/// URL-shaped strings built from fragments that matter for scheme and host
/// detection.
fn url_like() -> impl Strategy<Value = String> {
    #[rustfmt::skip]
    const PARTS: &[&str] = &[
        "http", "https", "HTTPS", "mailto", "javascript", "file", "markdown-preview", "data", ":",
        "//", "/", "@", "?", "#", "[", "]", "::1", "8080", "example.com", "user", "%09", "%40",
        " ", "\t", "\u{202e}", "é", ".", "-", "+", "1",
    ];
    prop::collection::vec(prop::sample::select(PARTS), 0..12).prop_map(|parts| parts.concat())
}
