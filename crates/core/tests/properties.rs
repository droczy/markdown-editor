//! Property-based tests: for arbitrary input the renderer must never panic
//! and must always produce output that satisfies the security invariants.

// Test code is expected to panic on failure.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use common::invariants::assert_safe_html;
use markdown_editor_core::{LinkAction, link_action, render_html};
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
            LinkAction::OpenInBrowser { host } => {
                prop_assert!(
                    lowercase.starts_with("http://") || lowercase.starts_with("https://"),
                    "{url:?}"
                );
                prop_assert!(!host.is_empty() && !host.contains(['@', '/', '?', '#']), "{url:?}");
            }
            LinkAction::OpenInEmailApp { .. } => {
                prop_assert!(lowercase.starts_with("mailto:"), "{url:?}");
            }
            LinkAction::Unsupported => {
                prop_assert!(lowercase.starts_with("markdown-preview:"), "{url:?}");
            }
            LinkAction::Blocked => {}
        }
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
