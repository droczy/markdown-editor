import Foundation
import Observation

/// Keeps the preview in step with the document text.
///
/// Rendering starts after a short pause in typing, so fast typing does not
/// queue up work. At most one render runs at a time; text that changes while
/// a render runs is rendered right after it, so the preview always ends up
/// showing the latest text.
@MainActor
@Observable
public final class PreviewController {
    /// Renders Markdown to a complete preview page.
    public typealias Render = @Sendable (String) async throws(MarkdownRenderer.Failure) -> String
    /// Waits for the given duration; throws if the wait was cancelled.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The last page that rendered successfully, or `nil` before the first.
    public private(set) var page: String?

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
        render: @escaping Render = { markdown throws(MarkdownRenderer.Failure) in
            try await MarkdownRenderer.renderPage(markdown)
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
        Task { [weak self] in
            let result: Result<String, MarkdownRenderer.Failure>
            do throws(MarkdownRenderer.Failure) {
                result = .success(try await render(text))
            } catch {
                result = .failure(error)
            }
            self?.didRender(result)
        }
    }

    private func didRender(_ result: Result<String, MarkdownRenderer.Failure>) {
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
