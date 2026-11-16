import SwiftUI

/// The document window's content: the editor on the left, the preview on the
/// right, each taking exactly half of the width.
public struct DocumentEditorView: View {
    @Binding var text: String
    @State private var preview = PreviewController()
    @Environment(\.undoManager) private var undoManager
    @AppStorage(TextZoom.storageKey) private var zoom = TextZoom.actualSize

    /// Creates the editor and preview for `text`.
    public init(text: Binding<String>) {
        _text = text
    }

    /// Editor and preview side by side.
    public var body: some View {
        HStack(spacing: 0) {
            MarkdownTextView(
                text: $text, undoManager: undoManager, zoom: TextZoom.clamped(zoom)
            ) { preview.textDidChange($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PreviewPane(controller: preview, zoom: TextZoom.clamped(zoom))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 400)
        .task { preview.show(text) }
    }
}

/// The preview with a notice above it when the document cannot be rendered.
struct PreviewPane: View {
    let controller: PreviewController
    let zoom: Double

    var body: some View {
        PreviewWebView(page: controller.page, zoom: zoom) { url, window in
            LinkConfirmation.handle(url, in: window)
        }
        .opacity(controller.failure == nil ? 1 : 0.35)
        .accessibilityIdentifier("preview")
        .overlay(alignment: .top) {
            if let failure = controller.failure {
                Label(
                    failure.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .accessibilityIdentifier("previewError")
            }
        }
    }
}
