import Foundation
import Observation

/// A rendered preview page and what it was rendered from.
public struct PreviewPage: Equatable, Sendable {
    /// The content of the page (see
    /// ``MarkdownRenderer/renderPageContent(_:taskToken:)``).
    public let content: String
    /// The Markdown text the page shows.
    public let text: String
    /// The random token in the page's task checkbox links. A click is only
    /// applied if it carries the token of the page that is shown.
    public let taskToken: String
}

/// Keeps the preview in step with the document text.
///
/// Rendering starts after a short pause in typing, so fast typing does not
/// queue up work. At most one render runs at a time; text that changes while
/// a render runs is rendered right after it, so the preview always ends up
/// showing the latest text.
@MainActor
@Observable
public final class PreviewController {
    /// Renders Markdown (first argument) to the content of a preview page
    /// whose task checkboxes carry the token (second argument).
    public typealias Render =
        @Sendable (String, String) async throws(MarkdownRenderer.Failure) -> String
    /// Waits for the given duration; throws if the wait was cancelled.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The last page that rendered successfully, or `nil` before the first.
    public private(set) var page: PreviewPage?

    /// Why the latest text could not be rendered, or `nil` if it could.
    /// ``page`` keeps the last successful result in the meantime.
    public private(set) var failure: MarkdownRenderer.Failure?

    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let render: Render
    @ObservationIgnored private let sleep: Sleep

    /// Text that has not been rendered yet.
    @ObservationIgnored private var pendingText: String?
    /// Identifies the current pause; an older pause that ends is ignored.
    @ObservationIgnored private var pause = 0
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var isPausing = false
    @ObservationIgnored private var isRendering = false

    /// Creates a controller that renders `delay` after the last change.
    public init(
        delay: Duration = .milliseconds(200),
        render: @escaping Render = { markdown, token throws(MarkdownRenderer.Failure) in
            try await MarkdownRenderer.renderPageContent(markdown, taskToken: token)
        },
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
    ) {
        self.delay = delay
        self.render = render
        self.sleep = sleep
    }

    /// Shows `text` as soon as possible, without waiting for a pause. Used
    /// when a document is opened.
    public func show(_ text: String) {
        pendingText = text
        renderNow()
    }

    /// Renders the latest text at once instead of after the pause. Used after
    /// a click on a task checkbox, which deserves an immediate answer.
    public func renderNow() {
        pause += 1
        pauseTask?.cancel()
        isPausing = false
        renderIfIdle()
    }

    /// Schedules `text` to be rendered after a pause in typing.
    public func textDidChange(_ text: String) {
        pendingText = text
        pause += 1
        isPausing = true
        let current = pause
        let delay = delay
        let sleep = sleep
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            self?.pauseDidEnd(current)
        }
    }

    private func pauseDidEnd(_ ended: Int) {
        guard ended == pause else { return }
        isPausing = false
        renderIfIdle()
    }

    private func renderIfIdle() {
        guard !isRendering, !isPausing, let text = pendingText else { return }
        pendingText = nil
        isRendering = true
        let render = render
        // A new random token for every page, so that a click on a stale page
        // or a link made up by a document can never toggle a task.
        let token = UUID().uuidString
        Task { [weak self] in
            let result: Result<PreviewPage, MarkdownRenderer.Failure>
            do throws(MarkdownRenderer.Failure) {
                let content = try await render(text, token)
                result = .success(PreviewPage(content: content, text: text, taskToken: token))
            } catch {
                result = .failure(error)
            }
            self?.didRender(result)
        }
    }

    private func didRender(_ result: Result<PreviewPage, MarkdownRenderer.Failure>) {
        isRendering = false
        switch result {
        case .success(let page):
            self.page = page
            failure = nil
        case .failure(let error):
            failure = error
        }
        renderIfIdle()
    }
}
