//! Snapshot tests: the rendered HTML of every supported feature is recorded in
//! `tests/snapshots/` and reviewed by hand. Any change in output fails the
//! test until the new snapshot is reviewed and accepted.

// Test code is expected to panic on failure.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use common::invariants::assert_safe_html;
use markdown_editor_core::{render_html, render_page};

fn render(markdown: &str) -> String {
    let html = render_html(markdown).expect("renders");
    assert_safe_html(&html, markdown);
    html
}

#[test]
fn commonmark_blocks() {
    insta::assert_snapshot!(render(
        "# Heading 1\n## Heading 2\n###### Heading 6\n\nSetext\n===\n\n\
         A paragraph with *emphasis*, **strong**, `code` and a hard  \nline break.\n\n\
         > A quote\n> > nested\n\n---\n\n\
         1. one\n2. two\n\n3) starts at three\n\n- bullet\n  - nested\n\n\
         ```rust\nfn main() {}\n```\n\n    indented code\n"
    ));
}

#[test]
fn commonmark_inlines() {
    insta::assert_snapshot!(render(
        "[link](https://example.com \"title\") [ref][r] <https://example.com> \
         ![image](images/a.png \"title\") \\*escaped\\* &amp; &copy; &#35;\n\n\
         [r]: other.md"
    ));
}

#[test]
fn gfm_table() {
    insta::assert_snapshot!(render(
        "| left | center | right |\n|:-----|:------:|------:|\n| a | b | c |\n| `x` | **y** | ~~z~~ |"
    ));
}

#[test]
fn gfm_task_list() {
    insta::assert_snapshot!(render("- [ ] open\n- [x] done\n  - [X] nested done"));
}

#[test]
fn gfm_strikethrough_and_autolinks() {
    insta::assert_snapshot!(render(
        "~~gone~~ www.example.com https://example.com/path?q=1 mail@example.com"
    ));
}

#[test]
fn unicode_text_is_preserved() {
    insta::assert_snapshot!(render("Grüße 🌍 — 日本語 — مرحبا\n\n# Ünïcödé"));
}

/// The example document in `docs/example.md` shows the features to users, on
/// GitHub and in the app. Its snapshot is the content of the preview page as
/// the app renders it, with task checkboxes as links (fixed token). The page
/// template around it is tested in `page.rs`.
#[test]
fn example_document() {
    let markdown = include_str!("../../../docs/example.md");
    let html = render(markdown);
    // The example uses only what the app supports: no raw HTML, which would
    // show as escaped text, and no images, which show as placeholders.
    assert!(!html.contains("&lt;"), "raw HTML in the example document");
    assert!(!html.contains("<img"), "image in the example document");

    let page = render_page(markdown, Some("snapshot")).expect("renders");
    let content = page
        .split_once("<main>\n")
        .and_then(|(_, rest)| rest.split_once("</main>"))
        .expect("page has a main element")
        .0;
    insta::assert_snapshot!(content);
}
