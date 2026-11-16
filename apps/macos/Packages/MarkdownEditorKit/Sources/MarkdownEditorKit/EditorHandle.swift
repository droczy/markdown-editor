import AppKit

/// Lets other parts of the window change the editor's text the way typing
/// does: the change can be undone and marks the document as edited.
@MainActor
public final class EditorHandle {
    /// The editor's text view, set by ``MarkdownTextView``.
    weak var textView: NSTextView?

    /// Creates a handle that is not connected to an editor yet.
    public init() {}

    /// Replaces `utf8Length` bytes at `utf8Offset` of the text with
    /// `replacement`, but only if the editor still shows exactly `expected`
    /// and the range lies on character boundaries. Returns whether the text
    /// was changed.
    @discardableResult
    func replace(
        utf8Offset: Int, utf8Length: Int, with replacement: String, ifTextIs expected: String,
        actionName: String
    ) -> Bool {
        guard let textView, textView.string == expected,
            let range = Self.range(utf8Offset: utf8Offset, utf8Length: utf8Length, in: expected),
            textView.shouldChangeText(in: range, replacementString: replacement)
        else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        return true
    }

    /// The UTF-16 range of a UTF-8 byte range, or `nil` if it is outside
    /// the text or splits a character.
    static func range(utf8Offset: Int, utf8Length: Int, in text: String) -> NSRange? {
        let utf8 = text.utf8
        guard utf8Offset >= 0, utf8Length >= 0,
            let start = utf8.index(utf8.startIndex, offsetBy: utf8Offset, limitedBy: utf8.endIndex),
            let end = utf8.index(start, offsetBy: utf8Length, limitedBy: utf8.endIndex),
            start.samePosition(in: text.unicodeScalars) != nil,
            end.samePosition(in: text.unicodeScalars) != nil
        else { return nil }
        return NSRange(start..<end, in: text)
    }
}
