import Foundation
import Testing

@testable import MarkdownEditorKit

/// Holds callers until the test lets them pass, one at a time.
actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals: [String] = []

    func pass(_ label: String) async {
        arrivals.append(label)
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Lets the earliest waiting caller pass, waiting for one to arrive.
    func openOne() async {
        while waiting.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        waiting.removeFirst().resume()
    }

    var waitingCount: Int { waiting.count }
}

/// Waits until `condition` holds; fails the test after a timeout.
@MainActor
private func eventually(
    _ description: String, _ condition: @MainActor () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}

@MainActor
@Suite("PreviewController")
struct PreviewControllerTests {
    let renders = Gate()
    let pauses = Gate()

    func makeController() -> PreviewController {
        let renders = renders
        let pauses = pauses
        return PreviewController(
            delay: .milliseconds(200),
            render: { text throws(MarkdownRenderer.Failure) in
                await renders.pass(text)
                if text == "bad" {
                    throw .internalError("bad")
                }
                return "page:\(text)"
            },
            sleep: { _ in await pauses.pass("pause") })
    }

    @Test("An opened document is rendered at once, without a pause")
    func showRendersImmediately() async {
        let controller = makeController()
        controller.show("a")
        await eventually("rendering starts") { await renders.arrivals == ["a"] }
        #expect(await pauses.arrivals.isEmpty)
        await renders.openOne()
        await eventually("the page is shown") { controller.page == "page:a" }
        #expect(controller.failure == nil)
    }

    @Test("Typing renders only after a pause, and only the latest text")
    func typingWaitsForPause() async {
        let controller = makeController()
        controller.textDidChange("a")
        controller.textDidChange("ab")
        await eventually("both pauses started") { await pauses.waitingCount == 2 }
        #expect(await renders.arrivals.isEmpty)

        // The first pause was superseded by the second one: only the latest
        // text is rendered, once.
        await pauses.openOne()
        await pauses.openOne()
        await eventually("the latest text renders") { await renders.arrivals == ["ab"] }
        await renders.openOne()
        await eventually("the page is shown") { controller.page == "page:ab" }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await renders.arrivals == ["ab"])
    }

    @Test("Only one render runs at a time; the latest text follows")
    func oneRenderAtATime() async {
        let controller = makeController()
        controller.show("a")
        await eventually("the first render runs") { await renders.waitingCount == 1 }

        controller.textDidChange("b")
        controller.textDidChange("bc")
        await eventually("both pauses started") { await pauses.waitingCount == 2 }
        await pauses.openOne()
        await pauses.openOne()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await renders.arrivals == ["a"], "a second render started in parallel")

        await renders.openOne()
        await eventually("the latest text renders next") {
            await renders.arrivals == ["a", "bc"]
        }
        #expect(controller.page == "page:a")
        await renders.openOne()
        await eventually("the latest page is shown") { controller.page == "page:bc" }
    }

    @Test("A failure keeps the last page until the text renders again")
    func failureKeepsLastPage() async {
        let controller = makeController()
        controller.show("a")
        await renders.openOne()
        await eventually("the first page is shown") { controller.page == "page:a" }

        controller.show("bad")
        await eventually("the bad text renders") { await renders.waitingCount == 1 }
        await renders.openOne()
        await eventually("the failure is reported") { controller.failure != nil }
        #expect(controller.failure == .internalError("bad"))
        #expect(controller.page == "page:a")

        controller.show("c")
        await eventually("the next text renders") { await renders.waitingCount == 1 }
        await renders.openOne()
        await eventually("the new page is shown") { controller.page == "page:c" }
        #expect(controller.failure == nil)
    }

    @Test("The default renderer produces a preview page")
    func defaultRenderer() async {
        let controller = PreviewController(delay: .zero)
        controller.show("# Title")
        await eventually("the page is shown") { controller.page != nil }
        #expect(controller.page?.contains("<h1>Title</h1>") == true)
        #expect(controller.page?.contains(MarkdownRenderer.pageContentSecurityPolicy) == true)
    }
}
