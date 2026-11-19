import SwiftUI

/// The document window's content: the editor on the left, the preview on the
/// right, each taking exactly half of the width.
public struct DocumentEditorView: View {
    @Binding var text: String
    @State private var preview = PreviewController()
    @State private var editor = EditorHandle()
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
                text: $text, undoManager: undoManager, zoom: TextZoom.clamped(zoom),
                handle: editor
            ) { preview.textDidChange($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PreviewPane(controller: preview, zoom: TextZoom.clamped(zoom)) { token, index in
                toggleTask(token: token, index: index)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 400)
        .task { preview.show(text) }
    }

    /// Checks or unchecks a task after a click on its checkbox in the
    /// preview. Ignored unless the click came from the page that is shown
    /// and the text has not changed since that page was rendered (otherwise
    /// the index could point to a different task).
    private func toggleTask(token: String, index: Int) {
        guard let page = preview.page, page.taskToken == token, page.text == text,
            let edit = MarkdownRenderer.taskEdit(in: text, index: index)
        else { return }
        editor.replace(
            utf8Offset: edit.utf8Offset, utf8Length: 1, with: edit.replacement, ifTextIs: text,
            actionName: "Toggle Task")
    }
}

/// The preview with a notice above it when the document cannot be rendered.
struct PreviewPane: View {
    let controller: PreviewController
    let zoom: Double
    /// Called with token and index when a task checkbox is clicked.
    let onToggleTask: @MainActor (String, Int) -> Void

    /// The notice after the last click on a link, shown for a moment.
    @State private var notice: LinkCopy.Notice?
    @State private var noticeTask: Task<Void, Never>?

    var body: some View {
        PreviewWebView(page: controller.page?.html, zoom: zoom) { url, window in
            let action = PreviewLinkAction(resolvedURL: url)
            if case .toggleTask(let token, let index) = action {
                onToggleTask(token, index)
            } else if let notice = LinkCopy.handle(action) {
                show(notice)
                if notice.copied {
                    LinkCopy.explainOnce(in: window)
                }
            }
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
        .overlay(alignment: .bottom) {
            if let notice {
                NoticeView(notice: notice)
                    .padding(12)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
    }

    /// Shows `notice` for a moment. It appears at once, and a new notice
    /// replaces the current one at once, so a click gets an immediate
    /// answer; only hiding it is animated, with a short fade.
    private func show(_ notice: LinkCopy.Notice) {
        self.notice = notice
        AccessibilityNotification.Announcement(
            [notice.title, notice.detail].compactMap(\.self).joined(separator: ", ")
        ).post()
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.15)) {
                    self.notice = nil
                }
            }
        }
    }
}

/// The notice after a click on a link: what was copied, or why nothing was.
struct NoticeView: View {
    let notice: LinkCopy.Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.copied ? "doc.on.clipboard" : "info.circle")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.callout.weight(.medium))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [notice.title, notice.detail].compactMap(\.self).joined(separator: ", ")
        )
        .accessibilityIdentifier("linkNotice")
    }
}
