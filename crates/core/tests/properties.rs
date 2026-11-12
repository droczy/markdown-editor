//! Property-based tests: for arbitrary input the renderer must never panic
//! and must always produce output that satisfies the security invariants.

// Test code is expected to panic on failure.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use common::invariants::assert_safe_html;
use markdown_editor_core::render_html;
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
}
