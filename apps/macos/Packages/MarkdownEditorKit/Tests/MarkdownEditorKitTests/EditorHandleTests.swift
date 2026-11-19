import AppKit
import Testing

@testable import MarkdownEditorKit

@MainActor
@Suite("Editor handle and task edits")
struct EditorHandleTests {
    /// A text view with an undo manager, like in the document window.
    @MainActor
    private final class Editor: NSObject, NSTextViewDelegate {
        let textView: NSTextView
        let handle = EditorHandle()
        let undoManager = UndoManager()

        init(_ text: String) {
            textView = MarkdownTextView.makeTextView(text: text)
            super.init()
            textView.delegate = self
            handle.textView = textView
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    @Test("Task edits come from the core and point at the bracket content")
    func taskEdits() throws {
        let text = "Ü\r\n\r\n- [ ] a\n- [x] b"
        let first = try #require(MarkdownRenderer.taskEdit(in: text, index: 0))
        #expect(first.replacement == "x")
        #expect(Array(text.utf8)[first.utf8Offset] == UInt8(ascii: " "))
        let second = try #require(MarkdownRenderer.taskEdit(in: text, index: 1))
        #expect(second.replacement == " ")
        #expect(MarkdownRenderer.taskEdit(in: text, index: 2) == nil)
        #expect(MarkdownRenderer.taskEdit(in: text, index: -1) == nil)
    }

    @Test("Byte ranges convert to text ranges only on character boundaries")
    func ranges() {
        let text = "aü🌍b"
        #expect(
            EditorHandle.range(utf8Offset: 0, utf8Length: 1, in: text)
                == NSRange(location: 0, length: 1))
        #expect(
            EditorHandle.range(utf8Offset: 1, utf8Length: 2, in: text)
                == NSRange(location: 1, length: 1))
        #expect(
            EditorHandle.range(utf8Offset: 3, utf8Length: 4, in: text)
                == NSRange(location: 2, length: 2))
        #expect(
            EditorHandle.range(utf8Offset: 7, utf8Length: 1, in: text)
                == NSRange(location: 4, length: 1))
        #expect(EditorHandle.range(utf8Offset: 2, utf8Length: 1, in: text) == nil, "inside ü")
        #expect(EditorHandle.range(utf8Offset: 4, utf8Length: 1, in: text) == nil, "inside 🌍")
        #expect(EditorHandle.range(utf8Offset: 8, utf8Length: 1, in: text) == nil, "past the end")
        #expect(EditorHandle.range(utf8Offset: -1, utf8Length: 1, in: text) == nil)
        #expect(EditorHandle.range(utf8Offset: 0, utf8Length: -1, in: text) == nil)
    }

    @Test("Toggling changes one character and can be undone")
    func toggleAndUndo() throws {
        let text = "- [ ] ü task"
        let editor = Editor(text)
        let (textView, handle, undoManager) = (editor.textView, editor.handle, editor.undoManager)
        let edit = try #require(MarkdownRenderer.taskEdit(in: text, index: 0))
        #expect(
            handle.replace(
                utf8Offset: edit.utf8Offset, utf8Length: 1, with: edit.replacement,
                ifTextIs: text, actionName: "Toggle Task"))
        #expect(textView.string == "- [x] ü task")
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Toggle Task")
        undoManager.undo()
        #expect(textView.string == text)
    }

    @Test("Nothing changes when the text is not the expected one")
    func staleText() {
        let editor = Editor("- [ ] a changed")
        let (textView, handle, undoManager) = (editor.textView, editor.handle, editor.undoManager)
        #expect(
            !handle.replace(
                utf8Offset: 3, utf8Length: 1, with: "x", ifTextIs: "- [ ] a", actionName: "x"))
        #expect(textView.string == "- [ ] a changed")
        #expect(!undoManager.canUndo)
        #expect(
            !EditorHandle().replace(
                utf8Offset: 3, utf8Length: 1, with: "x", ifTextIs: "- [ ] a", actionName: "x"),
            "without a text view")
    }
}
