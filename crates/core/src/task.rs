//! Checking and unchecking task list items (`- [ ]` / `- [x]`) from the
//! preview.
//!
//! The preview turns each task checkbox into a link to
//! `markdown-preview://task/<token>/<index>` (see [`crate::render_page`]).
//! When the user clicks it, the platform checks the token and that the text
//! has not changed since the page was rendered, then applies the edit from
//! [`toggle_task`]: exactly one character between the brackets changes.

use crate::{MAX_INPUT_BYTES, MAX_NODES, markdown_options, parse_within_limit};

/// Longest accepted task link token, in bytes.
pub const MAX_TASK_TOKEN_BYTES: usize = 64;

/// An edit of the Markdown source that checks or unchecks one task.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskToggle {
    /// Byte offset of the character between the brackets.
    pub offset: usize,
    /// The character that replaces it: `x` to check, a space to uncheck.
    pub replacement: char,
}

/// Returns the edit that checks or unchecks the task item with the given
/// index (counted from 0 in document order), or `None` if there is no such
/// task or the document exceeds a resource limit.
///
/// The edit replaces the single ASCII character between the brackets, so
/// all other bytes of the document stay unchanged.
///
/// # Examples
///
/// ```
/// use markdown_editor_core::{toggle_task, TaskToggle};
///
/// assert_eq!(
///     toggle_task("- [ ] open\n- [x] done\n", 1),
///     Some(TaskToggle { offset: 14, replacement: ' ' })
/// );
/// ```
#[must_use]
pub fn toggle_task(markdown: &str, index: usize) -> Option<TaskToggle> {
    if markdown.len() > MAX_INPUT_BYTES {
        return None;
    }
    let options = markdown_options();
    let arena = comrak::Arena::new();
    let root = parse_within_limit(&arena, markdown, &options, MAX_NODES)?;
    let position = root
        .descendants()
        .filter_map(|node| match node.data().value {
            comrak::nodes::NodeValue::TaskItem(ref task) => Some(task.symbol_sourcepos.start),
            _ => None,
        })
        .nth(index)?;
    let offset = byte_offset(markdown, position.line, position.column)?;
    Some(TaskToggle {
        offset,
        replacement: replacement_at(markdown, offset)?,
    })
}

/// The character that toggles the task symbol at `offset`, or `None` if
/// `offset` does not point at the symbol between brackets. A mismatch would
/// mean the positions are not understood correctly, so nothing is changed.
fn replacement_at(markdown: &str, offset: usize) -> Option<char> {
    match markdown
        .as_bytes()
        .get(offset.checked_sub(1)?..=offset + 1)?
    {
        [b'[', b' ', b']'] => Some('x'),
        [b'[', b'x' | b'X', b']'] => Some(' '),
        _ => None,
    }
}

/// Whether `token` may be used in task links: 1 to [`MAX_TASK_TOKEN_BYTES`]
/// ASCII letters, digits or hyphens (a UUID, for example).
#[must_use]
pub fn is_valid_task_token(token: &str) -> bool {
    (1..=MAX_TASK_TOKEN_BYTES).contains(&token.len())
        && token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

/// Converts a 1-based line and byte column, as reported by comrak, to a
/// byte offset. Lines end with `\n`, `\r\n` or a lone `\r` (CommonMark).
fn byte_offset(markdown: &str, line: usize, column: usize) -> Option<usize> {
    let bytes = markdown.as_bytes();
    let mut line_start = 0;
    for _ in 1..line {
        let end = bytes[line_start..]
            .iter()
            .position(|&byte| byte == b'\n' || byte == b'\r')?
            + line_start;
        line_start = if bytes[end] == b'\r' && bytes.get(end + 1) == Some(&b'\n') {
            end + 2
        } else {
            end + 1
        };
    }
    let offset = line_start + column.checked_sub(1)?;
    (offset < bytes.len()).then_some(offset)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toggled(markdown: &str, index: usize) -> Option<String> {
        let toggle = toggle_task(markdown, index)?;
        let mut text = markdown.to_owned();
        text.replace_range(
            toggle.offset..=toggle.offset,
            toggle.replacement.encode_utf8(&mut [0; 4]),
        );
        Some(text)
    }

    #[test]
    fn checks_and_unchecks_tasks() {
        let markdown = "- [ ] open\n- [x] done\n- [X] upper\n";
        assert_eq!(
            toggled(markdown, 0).as_deref(),
            Some("- [x] open\n- [x] done\n- [X] upper\n")
        );
        assert_eq!(
            toggled(markdown, 1).as_deref(),
            Some("- [ ] open\n- [ ] done\n- [X] upper\n")
        );
        assert_eq!(
            toggled(markdown, 2).as_deref(),
            Some("- [ ] open\n- [x] done\n- [ ] upper\n")
        );
        assert_eq!(toggle_task(markdown, 3), None);
    }

    #[test]
    fn counts_tasks_in_document_order() {
        let markdown = "- [ ] a\n  - [ ] nested\n- [ ] b\n\n> - [ ] quoted\n\n1. [ ] ordered\n";
        let expected = [
            "- [x] a\n",
            "  - [x] nested\n",
            "- [x] b\n",
            "> - [x] quoted\n",
            "1. [x] ordered\n",
        ];
        for (index, line) in expected.iter().enumerate() {
            let text = toggled(markdown, index).unwrap_or_default();
            assert!(text.contains(line), "task {index}: {text:?}");
            assert_eq!(text.matches("[x]").count(), 1, "task {index}: {text:?}");
        }
        assert_eq!(toggle_task(markdown, expected.len()), None);
    }

    #[test]
    fn handles_every_line_ending_and_unusual_bytes() {
        for (markdown, expected) in [
            ("a\r\n\r\n- [ ] b\r\n", "a\r\n\r\n- [x] b\r\n"),
            ("a\r\r- [ ] b\r", "a\r\r- [x] b\r"),
            ("a\n\n- [ ] b", "a\n\n- [x] b"),
            ("\u{feff}- [ ] bom\n", "\u{feff}- [x] bom\n"),
            ("-\t[ ] tab\n", "-\t[x] tab\n"),
            ("äöü\n\n- [ ] ü\n", "äöü\n\n- [x] ü\n"),
            ("a\0b\n\n- [ ] after nul\n", "a\0b\n\n- [x] after nul\n"),
            ("- [ ]\tx\n", "- [x]\tx\n"),
        ] {
            assert_eq!(
                toggled(markdown, 0).as_deref(),
                Some(expected),
                "{markdown:?}"
            );
        }
    }

    #[test]
    fn documents_without_tasks_or_above_limits_give_nothing() {
        assert_eq!(toggle_task("", 0), None);
        assert_eq!(toggle_task("- [] not a task\n- [y] neither\n", 0), None);
        assert_eq!(toggle_task("`- [ ] code`\n", 0), None);
        let too_large = format!("- [ ] a\n{}", "b".repeat(MAX_INPUT_BYTES));
        assert_eq!(toggle_task(&too_large, 0), None);
    }

    #[test]
    fn documents_at_the_size_limit_can_be_toggled() {
        let prefix = "- [ ] a\n\n";
        let at_limit = format!("{prefix}{}", "b".repeat(MAX_INPUT_BYTES - prefix.len()));
        assert_eq!(at_limit.len(), MAX_INPUT_BYTES);
        assert_eq!(
            toggle_task(&at_limit, 0),
            Some(TaskToggle {
                offset: 3,
                replacement: 'x'
            })
        );
    }

    #[test]
    fn byte_offsets_follow_commonmark_line_endings() {
        assert_eq!(byte_offset("ab", 1, 1), Some(0));
        assert_eq!(byte_offset("ab", 1, 2), Some(1));
        assert_eq!(byte_offset("ab", 1, 3), None);
        assert_eq!(byte_offset("ab", 1, 0), None);
        assert_eq!(byte_offset("a\nb", 2, 1), Some(2));
        assert_eq!(byte_offset("a\r\nb", 2, 1), Some(3));
        assert_eq!(byte_offset("a\rb", 2, 1), Some(2));
        assert_eq!(byte_offset("a\r", 2, 1), None);
        assert_eq!(byte_offset("a", 2, 1), None);
    }

    #[test]
    fn only_the_symbol_between_brackets_is_replaced() {
        assert_eq!(replacement_at("[ ]", 1), Some('x'));
        assert_eq!(replacement_at("[x]", 1), Some(' '));
        assert_eq!(replacement_at("[X]", 1), Some(' '));
        assert_eq!(replacement_at("[y]", 1), None);
        assert_eq!(replacement_at("( )", 1), None);
        assert_eq!(replacement_at("[ )", 1), None);
        assert_eq!(replacement_at("[ ]", 0), None);
        assert_eq!(replacement_at("[ ]", 2), None);
        assert_eq!(replacement_at("[ ", 1), None);
    }

    #[test]
    fn task_tokens_are_short_and_plain() {
        assert!(is_valid_task_token("0f3c9a2e-7b1d-4c5e-9f00-123456789abc"));
        assert!(is_valid_task_token("A"));
        assert!(is_valid_task_token(&"a".repeat(MAX_TASK_TOKEN_BYTES)));
        assert!(!is_valid_task_token(""));
        assert!(!is_valid_task_token(&"a".repeat(MAX_TASK_TOKEN_BYTES + 1)));
        for token in ["a/b", "a b", "a\"b", "a<b", "ä", "a_b", "a.b", "a%20"] {
            assert!(!is_valid_task_token(token), "{token}");
        }
    }
}
