//! Fuzz target: arbitrary bytes as Markdown must never crash the renderer or
//! produce output that violates the security invariants.
#![no_main]

#[path = "../../crates/core/tests/common/invariants.rs"]
mod invariants;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let input = String::from_utf8_lossy(data);
    if let Ok(html) = markdown_editor_core::render_html(&input) {
        invariants::assert_safe_html(&html, &input);
    }
});
