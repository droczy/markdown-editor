//! Platform-independent core of the markdown editor.
//!
//! The central entry point is [`render_html`], which converts **untrusted**
//! Markdown into HTML that is safe to show in the preview.
//!
//! # Security model
//!
//! Every document is treated as potentially malicious. Rendering uses two
//! independent layers so that a bug in one layer alone does not lead to
//! script execution or data leaks:
//!
//! 1. **comrak** parses CommonMark + GitHub Flavored Markdown. Raw HTML in the
//!    document is escaped (shown as text) and dangerous link schemes are
//!    removed.
//! 2. **ammonia** sanitizes the generated HTML against a strict allowlist that
//!    contains only the elements and attributes comrak legitimately produces.
//!    Remote and absolute image sources are removed, because the application
//!    must never load anything from the network.
//!
//! The preview must additionally disable JavaScript and enforce a strict
//! Content Security Policy; this crate does not rely on that.

mod sanitize;

use std::fmt;

/// Largest accepted Markdown input in bytes (10 MiB).
///
/// Larger inputs are rejected to bound memory use and rendering time.
pub const MAX_INPUT_BYTES: usize = 10 * 1024 * 1024;

/// Deepest accepted nesting of Markdown elements (block quotes, lists,
/// emphasis, …).
///
/// Real documents rarely exceed a depth of 20. The limit exists because the
/// sanitizer's run time grows quadratically with nesting depth: 100 000
/// nested block quotes would take several seconds.
pub const MAX_NESTING_DEPTH: usize = 1_000;

/// Largest accepted syntax tree, in nodes (2 000 000).
///
/// Bounds memory use and rendering time independently of the input size,
/// because some Markdown constructs expand to far more nodes than they have
/// bytes. A node costs up to about 600 bytes across all rendering stages.
/// Ordinary documents stay well below the limit: 10 MiB of prose produce
/// about one million nodes.
pub const MAX_NODES: usize = 2_000_000;

/// Errors that can occur while rendering Markdown.
/// Deliberately exhaustive: adding a variant must fail to compile in every
/// consumer (e.g. the FFI crate) until it is handled there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RenderError {
    /// The input exceeds [`MAX_INPUT_BYTES`].
    InputTooLarge {
        /// Size of the rejected input in bytes.
        size: usize,
        /// The maximum allowed size in bytes.
        limit: usize,
    },
    /// The document nests elements deeper than [`MAX_NESTING_DEPTH`].
    NestingTooDeep {
        /// Nesting depth of the rejected document.
        depth: usize,
        /// The maximum allowed depth.
        limit: usize,
    },
    /// The document's syntax tree would have more than [`MAX_NODES`] nodes.
    TooManyNodes {
        /// The maximum allowed number of nodes.
        limit: usize,
    },
}

impl fmt::Display for RenderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputTooLarge { size, limit } => write!(
                f,
                "document is too large to render ({size} bytes, limit is {limit} bytes)"
            ),
            Self::NestingTooDeep { depth, limit } => write!(
                f,
                "document is nested too deeply to render (depth {depth}, limit is {limit})"
            ),
            Self::TooManyNodes { limit } => write!(
                f,
                "document is too complex to render (more than {limit} syntax tree nodes)"
            ),
        }
    }
}

impl std::error::Error for RenderError {}

/// Renders untrusted Markdown to sanitized HTML.
///
/// Supported syntax: CommonMark plus the GitHub Flavored Markdown extensions
/// tables, task lists, strikethrough and autolinks. Raw HTML in the input is
/// escaped and therefore displayed as text.
///
/// # Errors
///
/// Returns [`RenderError::InputTooLarge`] if `markdown` is larger than
/// [`MAX_INPUT_BYTES`], [`RenderError::TooManyNodes`] if its syntax tree
/// would exceed [`MAX_NODES`], and [`RenderError::NestingTooDeep`] if it
/// nests elements deeper than [`MAX_NESTING_DEPTH`].
///
/// # Panics
///
/// Does not panic: the only fallible step writes into a `String`, which
/// cannot fail.
///
/// # Examples
///
/// ```
/// let html = markdown_editor_core::render_html("# Hello *world*").unwrap();
/// assert_eq!(html, "<h1>Hello <em>world</em></h1>\n");
/// ```
pub fn render_html(markdown: &str) -> Result<String, RenderError> {
    if markdown.len() > MAX_INPUT_BYTES {
        return Err(RenderError::InputTooLarge {
            size: markdown.len(),
            limit: MAX_INPUT_BYTES,
        });
    }
    let options = markdown_options();
    let arena = comrak::Arena::new();
    let root = parse_within_limit(&arena, markdown, &options, MAX_NODES)
        .ok_or(RenderError::TooManyNodes { limit: MAX_NODES })?;

    let depth = nesting_depth(root);
    if depth > MAX_NESTING_DEPTH {
        return Err(RenderError::NestingTooDeep {
            depth,
            limit: MAX_NESTING_DEPTH,
        });
    }

    let mut unsanitized = String::new();
    #[allow(clippy::expect_used)]
    comrak::format_html(root, &options, &mut unsanitized)
        .expect("writing into a String cannot fail");
    Ok(sanitize::sanitize(&unsanitized))
}

/// Parses `markdown`, or returns `None` if the syntax tree would have more
/// than `max_nodes` nodes.
///
/// Parsing stops shortly after the limit is reached instead of completing
/// first, so memory use stays bounded while parsing, too.
fn parse_within_limit<'a>(
    arena: &'a comrak::Arena<'a>,
    markdown: &str,
    options: &comrak::Options<'_>,
    max_nodes: usize,
) -> Option<comrak::Node<'a>> {
    // The arena holds every node allocated so far, including nodes that are
    // merged away later, so its size reflects the memory actually in use.
    let too_many_nodes = || arena.len() > max_nodes;
    let root = comrak::try_parse_document(arena, markdown, options, &too_many_nodes).ok()?;
    // comrak asks only every few hundred steps; check the final size exactly.
    (!too_many_nodes()).then_some(root)
}

/// Maximum depth of the syntax tree, computed iteratively so that deep trees
/// cannot overflow the stack.
fn nesting_depth(root: comrak::Node<'_>) -> usize {
    let mut depth = 0_usize;
    let mut max_depth = 0;
    for edge in root.traverse() {
        match edge {
            comrak::arena_tree::NodeEdge::Start(_) => {
                depth += 1;
                max_depth = max_depth.max(depth);
            }
            comrak::arena_tree::NodeEdge::End(_) => depth = depth.saturating_sub(1),
        }
    }
    max_depth
}

/// Parser and renderer settings. Changing these affects security; see the
/// crate documentation.
fn markdown_options() -> comrak::Options<'static> {
    let mut options = comrak::Options::default();
    options.extension.strikethrough = true;
    options.extension.table = true;
    options.extension.autolink = true;
    options.extension.tasklist = true;
    // Never pass raw HTML through; show it as text instead of dropping it
    // silently so that the user can see what the document contains.
    options.render.r#unsafe = false;
    options.render.escape = true;
    // Emit `<pre lang="rust">` instead of `class="language-rust"`, which keeps
    // the sanitizer allowlist free of `class` attributes.
    options.render.github_pre_lang = true;
    options
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_input_above_limit() {
        let input = "a".repeat(MAX_INPUT_BYTES + 1);
        assert_eq!(
            render_html(&input),
            Err(RenderError::InputTooLarge {
                size: MAX_INPUT_BYTES + 1,
                limit: MAX_INPUT_BYTES
            })
        );
    }

    #[test]
    fn accepts_input_at_limit() {
        let input = "a".repeat(MAX_INPUT_BYTES);
        assert!(render_html(&input).is_ok());
    }

    #[test]
    fn error_message_is_readable() {
        let error = RenderError::InputTooLarge {
            size: 20,
            limit: 10,
        };
        assert_eq!(
            error.to_string(),
            "document is too large to render (20 bytes, limit is 10 bytes)"
        );
    }

    #[test]
    fn rejects_nesting_above_limit() {
        // Document root and paragraph add two levels to the quotes.
        let input = format!("{}x", ">".repeat(MAX_NESTING_DEPTH));
        assert!(matches!(
            render_html(&input),
            Err(RenderError::NestingTooDeep {
                limit: MAX_NESTING_DEPTH,
                ..
            })
        ));
    }

    #[test]
    fn accepts_nesting_at_limit() {
        let input = format!("{}x", ">".repeat(MAX_NESTING_DEPTH - 3));
        assert!(render_html(&input).is_ok());
    }

    #[test]
    fn many_shallow_elements_are_accepted() {
        // Far more nodes than MAX_NESTING_DEPTH, but only three levels deep.
        let input = "paragraph\n\n".repeat(MAX_NESTING_DEPTH * 5);
        assert!(render_html(&input).is_ok());
    }

    #[test]
    fn nesting_depth_counts_levels_not_nodes() {
        let arena = comrak::Arena::new();
        let options = markdown_options();
        // document > block_quote > block_quote > paragraph > text
        let root = comrak::parse_document(&arena, "> > a\n\nb\n\nc", &options);
        assert_eq!(nesting_depth(root), 5);
    }

    #[test]
    fn nesting_error_message_is_readable() {
        let error = RenderError::NestingTooDeep { depth: 5, limit: 3 };
        assert_eq!(
            error.to_string(),
            "document is nested too deeply to render (depth 5, limit is 3)"
        );
    }

    #[test]
    fn node_limit_is_exact() {
        // document, then paragraph + text for each of the three paragraphs
        let markdown = "a\n\nb\n\nc";
        let options = markdown_options();
        let arena = comrak::Arena::new();
        assert!(parse_within_limit(&arena, markdown, &options, 7).is_some());
        assert_eq!(arena.len(), 7);
        let arena = comrak::Arena::new();
        assert!(parse_within_limit(&arena, markdown, &options, 6).is_none());
    }

    #[test]
    fn parsing_stops_soon_after_node_limit() {
        // Short rows are filled up to the header width: 500 000 cells.
        let markdown = "|a".repeat(500) + "|\n" + &"|-".repeat(500) + "|\n" + &"x\n".repeat(1_000);
        let options = markdown_options();
        let arena = comrak::Arena::new();
        assert!(parse_within_limit(&arena, &markdown, &options, 1_000).is_none());
        // comrak checks every 256 steps; one step adds at most a few nodes.
        assert!(arena.len() < 5_000, "allocated {} nodes", arena.len());
    }

    #[test]
    fn rejects_documents_above_node_limit() {
        // Short rows are filled up to the header width, so a small document
        // can exceed the limit.
        let table = "|a".repeat(500) + "|\n" + &"|-".repeat(500) + "|\n" + &"x\n".repeat(1_000);
        let markdown = format!("{table}\n").repeat(MAX_NODES / 500_000 + 1);
        assert!(markdown.len() < 30_000);
        assert_eq!(
            render_html(&markdown),
            Err(RenderError::TooManyNodes { limit: MAX_NODES })
        );
    }

    #[test]
    fn node_error_message_is_readable() {
        let error = RenderError::TooManyNodes { limit: 10 };
        assert_eq!(
            error.to_string(),
            "document is too complex to render (more than 10 syntax tree nodes)"
        );
    }

    #[test]
    fn empty_input_renders_empty_output() {
        assert_eq!(render_html(""), Ok(String::new()));
    }
}
