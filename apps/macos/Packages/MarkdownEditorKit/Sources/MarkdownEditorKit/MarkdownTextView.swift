import AppKit
import SwiftUI

/// The Markdown editor: a plain-text `NSTextView`.
///
/// The text view uses TextKit 1 with non-contiguous layout. TextKit 2 lays
/// out and draws each paragraph as a whole, so a long paragraph, such as a
/// file without line breaks or an embedded image in Base64, made the app
/// unresponsive for minutes (SR-2026-004).
///
/// Everything that would change the text without the user typing it is
/// turned off: smart quotes and dashes, text replacement, spelling
/// correction, link and data detection, inline predictions and writing
/// tools. Pasted text arrives as plain text.
public struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    /// The document's undo manager. The editor registers every change there,
    /// which also marks the document as edited.
    let undoManager: UndoManager?
    /// Zoom factor of the text (1 is the system font size).
    let zoom: Double
    /// Lets the window apply edits such as task toggles (optional).
    let handle: EditorHandle?
    /// Called after every change of the text, by the user or from outside.
    let onChange: @MainActor (String) -> Void

    /// Creates an editor for `text` that registers changes with
    /// `undoManager`.
    public init(
        text: Binding<String>, undoManager: UndoManager?, zoom: Double = 1,
        handle: EditorHandle? = nil, onChange: @escaping @MainActor (String) -> Void
    ) {
        _text = text
        self.undoManager = undoManager
        self.zoom = zoom
        self.handle = handle
        self.onChange = onChange
    }

    /// Creates the delegate that passes changes to the binding.
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Creates the scrollable text view.
    public func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView(text: text, zoom: zoom)
        context.coordinator.lastText = text
        textView.delegate = context.coordinator
        handle?.textView = textView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        return scrollView
    }

    /// Writes text changed from outside into the text view.
    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if let textView = scrollView.documentView as? NSTextView,
            textView.font?.pointSize != Self.fontSize(zoom: zoom)
        {
            Self.applyFont(to: textView, zoom: zoom)
        }
        // Only text changed from outside (e.g. "Revert To") is written back;
        // comparing with the last known text is cheap when nothing changed,
        // because both share the same storage.
        guard text != coordinator.lastText,
            let textView = scrollView.documentView as? NSTextView
        else { return }
        coordinator.lastText = text
        textView.string = text
        onChange(text)
    }

    /// The editor's text view (TextKit 1, see above), configured and
    /// showing `text`. Separate for testing.
    static func makeTextView(text: String, zoom: Double = 1) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: false)
        // Lays out only what is needed, also within a long paragraph.
        textView.layoutManager?.allowsNonContiguousLayout = true
        configure(textView)
        applyFont(to: textView, zoom: zoom)
        textView.string = text
        return textView
    }

    /// Applies the editor settings. Separate for testing.
    static func configure(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsDocumentBackgroundColorChange = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.inlinePredictionType = .no
        textView.mathExpressionCompletionType = .no
        textView.writingToolsBehavior = .none

        applyFont(to: textView, zoom: 1)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 16)

        // Wrap lines at the right edge instead of scrolling sideways.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.setAccessibilityIdentifier("editor")
    }

    /// The font size for `zoom`: the system font size, scaled. Not rounded,
    /// so that the editor grows by the same ratio as the preview.
    static func fontSize(zoom: Double) -> CGFloat {
        NSFont.systemFontSize * zoom
    }

    /// Sets the system font at the size for `zoom` for all text (the editor
    /// is plain text, so there is only one font).
    static func applyFont(to textView: NSTextView, zoom: Double) {
        let font = NSFont.systemFont(ofSize: fontSize(zoom: zoom))
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }

    /// Passes changes from the text view to the binding.
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        /// The text as last synchronized with the binding.
        var lastText = ""

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        /// The document's undo manager, so edits mark the document as edited.
        public func undoManager(for view: NSTextView) -> UndoManager? {
            parent.undoManager
        }

        /// Passes the new text to the binding and to `onChange`.
        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let text = textView.string
            lastText = text
            parent.text = text
            parent.onChange(text)
        }
    }
}
