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
/// Generous bound: catches quadratic blow-ups, not small slowdowns.
const TIME_LIMIT: Duration = Duration::from_secs(10);

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
                Err(RenderError::NestingTooDeep { .. }) => {}
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

#[test]
fn large_ordinary_document() {
    let section =
        "# Title\n\nSome *text* with a [link](https://example.com).\n\n- item\n- item\n\n";
    render_on_small_stack(section.repeat(50_000));
}
