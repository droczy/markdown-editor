//! Denial-of-service resistance: pathological inputs must render without
//! crashing (e.g. stack overflow) and within reasonable time.
//!
//! Rendering runs on a thread with a 512 KiB stack, the default size of
//! secondary threads on macOS, because the app renders off the main thread.

// Test code is expected to panic on failure.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use std::time::{Duration, Instant};

use common::invariants::assert_safe_html;
use markdown_editor_core::{RenderError, render_html};

const SMALL_STACK: usize = 512 * 1024;
/// Generous bound: catches quadratic blow-ups, not small slowdowns. CI runs
/// these tests in release mode; unoptimized builds get more time.
const TIME_LIMIT: Duration = if cfg!(debug_assertions) {
    Duration::from_secs(60)
} else {
    Duration::from_secs(10)
};

/// Renders on a small stack within the time limit. Rejections caused by
/// the documented limits count as success; panics and timeouts do not.
fn render_on_small_stack(input: String) {
    std::thread::Builder::new()
        .stack_size(SMALL_STACK)
        .spawn(move || {
            let start = Instant::now();
            let result = render_html(&input);
            let elapsed = start.elapsed();
            assert!(elapsed < TIME_LIMIT, "took {elapsed:?}");
            match result {
                Ok(html) => assert_safe_html(&html, "<large input>"),
                Err(RenderError::NestingTooDeep { .. } | RenderError::TooManyNodes { .. }) => {}
                Err(other) => panic!("unexpected error: {other}"),
            }
        })
        .expect("thread spawns")
        .join()
        .expect("rendering thread did not panic");
}

#[test]
fn deeply_nested_block_quotes() {
    render_on_small_stack(format!("{}x", ">".repeat(1_000_000)));
}

#[test]
fn block_quotes_just_below_limit_are_fast() {
    render_on_small_stack(format!(
        "{}x",
        ">".repeat(markdown_editor_core::MAX_NESTING_DEPTH - 3)
    ));
}

#[test]
fn deeply_nested_lists() {
    let mut input = String::new();
    for depth in 0..2_000 {
        input.push_str(&"  ".repeat(depth));
        input.push_str("- x\n");
    }
    render_on_small_stack(input);
}

#[test]
fn deeply_nested_mixed_containers() {
    render_on_small_stack(format!("{}x", "> - ".repeat(200_000)));
}

#[test]
fn deeply_nested_emphasis() {
    render_on_small_stack(format!("{}x{}", "*".repeat(100_000), "*".repeat(100_000)));
}

#[test]
fn many_unclosed_brackets() {
    render_on_small_stack("[".repeat(500_000));
}

#[test]
fn many_unclosed_link_openers() {
    render_on_small_stack("![a](".repeat(200_000));
}

#[test]
fn many_backticks() {
    render_on_small_stack("`a``".repeat(200_000));
}

#[test]
fn wide_table() {
    let header = "|a".repeat(10_000) + "|\n";
    let separator = "|-".repeat(10_000) + "|\n";
    let row = "|x".repeat(10_000) + "|\n";
    render_on_small_stack(header + &separator + &row.repeat(10));
}

/// Short rows are filled up to the header width, so a small document can
/// exceed the node limit.
#[test]
fn many_tables_with_short_rows_are_rejected_quickly() {
    let table = "|a".repeat(500) + "|\n" + &"|-".repeat(500) + "|\n" + &"x\n".repeat(1_000) + "\n";
    let input = table.repeat(1_000);
    let start = Instant::now();
    assert_eq!(
        render_html(&input),
        Err(RenderError::TooManyNodes {
            limit: markdown_editor_core::MAX_NODES
        })
    );
    assert!(start.elapsed() < TIME_LIMIT);
}

/// The node limit must not reject realistic documents up to the size limit.
#[test]
fn prose_up_to_the_size_limit_is_accepted() {
    let paragraph = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do *eiusmod*\n\
        tempor incididunt ut labore et dolore magna aliqua: see [the docs](https://example.com)\n\
        or `some_code()`. Contact me@example.com or www.example.com; 5 > 3 & 2 < 4.\n\
        Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip.\n\n";
    let section = format!(
        "## Chapter\n\n{}- a list item with **bold** text\n- another item\n\n",
        paragraph.repeat(4)
    );
    let input = section.repeat(markdown_editor_core::MAX_INPUT_BYTES / section.len());
    let html = render_html(&input).expect("prose is accepted");
    assert_safe_html(&html, "<prose>");
}

/// About 4 MiB of `unit` between `prefix` and `suffix`. With quadratic
/// escaping, each of the following inputs took 80 to 290 seconds.
fn fill(prefix: &str, unit: &str, suffix: &str) -> String {
    format!("{prefix}{}{suffix}", unit.repeat((4 << 20) / unit.len()))
}

// Escaping text and attribute values must take linear time, also for long
// runs full of characters that need escaping.

#[test]
fn long_code_block_with_many_ampersands() {
    render_on_small_stack(fill("```\n", "a && b\n", "```\n"));
}

#[test]
fn long_paragraph_with_many_latin1_symbols() {
    render_on_small_stack(fill("", "\u{b0}\u{a0}", ""));
}

#[test]
fn long_link_destination_with_many_ampersands() {
    render_on_small_stack(fill("[a](<", "&", ">)"));
}

#[test]
fn long_link_title_with_many_ampersands() {
    render_on_small_stack(fill("[a](b \"", "&", "\")"));
}

#[test]
fn large_ordinary_document() {
    let section =
        "# Title\n\nSome *text* with a [link](https://example.com).\n\n- item\n- item\n\n";
    render_on_small_stack(section.repeat(50_000));
}
