import AppKit
import CryptoKit
import Foundation
import Network
import Testing
import WebKit
import os

@testable import MarkdownEditorKit

/// A local HTTP server that records every request. The preview must never
/// send one, whatever the page contains.
private final class RecordingServer: @unchecked Sendable {
    private let listener: NWListener
    private let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])
    let port: UInt16

    var requests: [String] { recorded.withLock { $0 } }

    init() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let recorded = recorded
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let line =
                    data.map { String(decoding: $0, as: UTF8.self) }?
                    .split(separator: "\r\n").first.map(String.init) ?? "?"
                recorded.withLock { $0.append(line) }
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let port: UInt16?
                let failure: (any Error)?
                switch state {
                case .ready:
                    (port, failure) = (listener.port?.rawValue, nil)
                case .failed(let error):
                    (port, failure) = (nil, error)
                default:
                    return
                }
                let first = resumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                guard first else { return }
                if let port {
                    continuation.resume(returning: port)
                } else {
                    continuation.resume(throwing: failure ?? CocoaError(.featureUnsupported))
                }
            }
            listener.start(queue: .global())
        }
    }

    deinit {
        listener.cancel()
    }
}

/// Allows exactly the page load and records every other navigation.
@MainActor
private final class StrictNavigationDelegate: NSObject, WKNavigationDelegate {
    private var allowedLoads = 1
    private(set) var refused: [URL?] = []

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if allowedLoads > 0 {
            allowedLoads -= 1
            return .allow
        }
        refused.append(navigationAction.request.url)
        return .cancel
    }
}

/// Waits until `condition` holds; fails the test after a timeout.
@MainActor
private func eventually(
    _ description: String, _ condition: @MainActor () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}

extension WKWebView {
    /// Runs `script` in the app's isolated world (the page's own scripts
    /// are disabled).
    @MainActor
    fileprivate func evaluate(_ script: String) async -> Any? {
        try? await callAsyncJavaScript(
            script, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    @MainActor
    fileprivate func waitUntilLoaded(containing elementID: String) async {
        await eventually("the page with #\(elementID) is loaded") {
            await self.evaluate(
                "return document.readyState === 'complete' && !!document.getElementById('\(elementID)')"
            ) as? Bool == true
        }
    }
}

/// Markup that tries every way to load something, run a script or navigate.
/// It is put into the page directly, bypassing the sanitizer, to prove that
/// the preview's other defences hold on their own.
private func hostileMarkup(port: UInt16) -> String {
    let server = "http://127.0.0.1:\(port)"
    return """
        <p id="hostile">hostile</p>
        <script>document.title = "inline script ran"</script>
        <script src="\(server)/script.js"></script>
        <img src="x" onerror="document.title = 'event handler ran'">
        <img src="\(server)/img.png">
        <img srcset="\(server)/srcset.png 1x">
        <picture><source srcset="\(server)/source.png"><img src="y"></picture>
        <input type="image" src="\(server)/input.png">
        <table background="\(server)/table.png"><tr><td>cell</td></tr></table>
        <link rel="stylesheet" href="\(server)/style.css">
        <link rel="preload" as="image" href="\(server)/preload.png">
        <link rel="prefetch" href="\(server)/prefetch">
        <link rel="icon" href="\(server)/icon.png">
        <style>@import url("\(server)/import.css"); \
        p { background: url("\(server)/style-bg.png") } \
        @font-face { font-family: x; src: url("\(server)/font.woff") } \
        body { font-family: x }</style>
        <div style="background-image: url('\(server)/inline-bg.png')">styled</div>
        <iframe src="\(server)/frame.html"></iframe>
        <video src="\(server)/video.mp4" autoplay muted></video>
        <audio src="\(server)/audio.mp3" autoplay></audio>
        <object data="\(server)/object"></object>
        <embed src="\(server)/embed">
        <svg><image href="\(server)/svg.png" width="10" height="10"/></svg>
        <base href="\(server)/">
        <img src="relative-to-base.png">
        <meta http-equiv="refresh" content="0; url=\(server)/refresh">
        <form id="form" action="\(server)/form" method="post"><input name="q" value="1"></form>
        <a id="ping" href="\(server)/link" ping="\(server)/ping">link</a>
        <a id="script-link" href="javascript:document.title='javascript url ran'">script link</a>
        """
}

/// The preview's empty page, optionally without its policy.
private func emptyPage(withPolicy: Bool) throws -> String {
    var page = MarkdownRenderer.emptyPage
    if !withPolicy {
        let policy = try #require(
            page.firstRange(of: /<meta http-equiv="Content-Security-Policy"[^>]*>/))
        page.removeSubrange(policy)
    }
    return page
}

/// How the hostile markup gets into the page.
enum HostileContent: CustomTestStringConvertible {
    /// Part of the page when it is loaded.
    case loaded
    /// Put into the loaded page in place of its content, as the preview
    /// shows every document.
    case replaced

    var testDescription: String {
        switch self {
        case .loaded: "loaded with the page"
        case .replaced: "replacing the content"
        }
    }
}

@MainActor
@Suite("Preview security", .serialized)
struct PreviewSecurityTests {
    /// Shows the hostile markup in a preview-configured web view, clicks the
    /// links and submits the form from the app's world, and returns the web
    /// view.
    private func loadAndPoke(
        port: UInt16, _ content: HostileContent, withPolicy: Bool, withContentBlocker: Bool,
        delegate: StrictNavigationDelegate
    ) async throws -> WKWebView {
        let webView = PreviewWKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: PreviewWebView.makeConfiguration())
        if withContentBlocker {
            webView.configuration.userContentController.add(try await ContentBlocker.ruleList())
        }
        webView.navigationDelegate = delegate
        let page = try emptyPage(withPolicy: withPolicy)
        switch content {
        case .loaded:
            webView.loadHTMLString(
                page.replacingOccurrences(
                    of: "<main>\n", with: "<main>\n\(hostileMarkup(port: port))"),
                baseURL: MarkdownRenderer.pageBaseURL)
        case .replaced:
            webView.loadHTMLString(page, baseURL: MarkdownRenderer.pageBaseURL)
            await eventually("the empty page is loaded") {
                await webView.evaluate(
                    "return document.readyState === 'complete' && !!document.querySelector('main')"
                ) as? Bool == true
            }
            let replaced = await PreviewCoordinator.replaceContent(
                of: webView, with: hostileMarkup(port: port))
            #expect(replaced)
        }
        await webView.waitUntilLoaded(containing: "hostile")
        _ = await webView.evaluate(
            """
            document.getElementById('ping').click();
            document.getElementById('script-link').click();
            document.getElementById('form').submit();
            """)
        // Give stray loads time to reach the server.
        try await Task.sleep(for: .seconds(1))
        return webView
    }

    @Test(
        "Each defence alone blocks every request and every script",
        arguments: [HostileContent.loaded, .replaced], [(true, true), (true, false), (false, true)])
    func defencesHoldAlone(
        content: HostileContent, defences: (withPolicy: Bool, withContentBlocker: Bool)
    ) async throws {
        let server = try await RecordingServer()
        let delegate = StrictNavigationDelegate()
        let webView = try await loadAndPoke(
            port: server.port, content, withPolicy: defences.withPolicy,
            withContentBlocker: defences.withContentBlocker, delegate: delegate)

        #expect(server.requests.isEmpty, "the preview sent requests: \(server.requests)")
        #expect(webView.title?.isEmpty != false, "a script ran: \(webView.title ?? "")")
        #expect(
            await webView.evaluate("return document.querySelectorAll('main').length") as? Int == 1,
            "the content escaped the main element")
    }

    @Test(
        "Without both defences the hostile markup does send requests (test is sound)",
        arguments: [HostileContent.loaded, .replaced])
    func hostileMarkupIsHostile(content: HostileContent) async throws {
        let server = try await RecordingServer()
        let delegate = StrictNavigationDelegate()
        _ = try await loadAndPoke(
            port: server.port, content, withPolicy: false, withContentBlocker: false,
            delegate: delegate)
        #expect(!server.requests.isEmpty)
    }

    @Test("The policy allows exactly the preview's stylesheet")
    func stylesheetIsApplied() async throws {
        let hash = Data(SHA256.hash(data: Data(MarkdownRenderer.pageStylesheet.utf8)))
            .base64EncodedString()
        #expect(hash == MarkdownRenderer.pageStylesheetHash)
        #expect(MarkdownRenderer.pageContentSecurityPolicy.contains("'sha256-\(hash)'"))

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: PreviewWebView.makeConfiguration())
        let delegate = StrictNavigationDelegate()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            MarkdownRenderer.emptyPage.replacingOccurrences(
                of: "<main>\n", with: "<main>\n<p id=\"probe\">p</p>"),
            baseURL: MarkdownRenderer.pageBaseURL)
        await webView.waitUntilLoaded(containing: "probe")
        let fontSize = await webView.evaluate(
            "return getComputedStyle(document.body).fontSize")
        #expect(fontSize as? String == "15px")
    }
}

@MainActor
@Suite("Preview coordinator", .serialized)
struct PreviewCoordinatorTests {
    private final class Links {
        var clicked: [URL] = []
    }

    private func makePreview() -> (WKWebView, PreviewCoordinator, Links) {
        let links = Links()
        let coordinator = PreviewCoordinator { url, _ in links.clicked.append(url) }
        let webView = PreviewWKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: PreviewWebView.makeConfiguration())
        coordinator.attach(webView)
        return (webView, coordinator, links)
    }

    private func content(_ version: Int, lines: Int = 300) async throws -> String {
        let text = (1...lines).map { "Line \($0)" }.joined(separator: "\n\n")
        let content = try await MarkdownRenderer.renderPageContent(
            "[web](https://example.com/a) [mail](mailto:a@example.com) "
                + "[file](other.md) [anchor](#top)\n\n\(text)")
        return "<p id=\"version-\(version)\">v</p>\(content)"
    }

    private func tasks() async throws -> String {
        let content = try await MarkdownRenderer.renderPageContent(
            "- [ ] first\n- [x] second", taskToken: "test-token")
        return "<p id=\"tasks\">t</p>\(content)"
    }

    @Test("A new version replaces the content without reloading the page")
    func replacesContentInPlace() async throws {
        let (webView, coordinator, _) = makePreview()
        coordinator.show(try await content(1, lines: 1))
        await webView.waitUntilLoaded(containing: "version-1")
        // A mark outside the content, which a reload would remove.
        _ = await webView.evaluate("document.body.dataset.mark = 'kept'")

        coordinator.show(try await content(2, lines: 1))
        await webView.waitUntilLoaded(containing: "version-2")
        #expect(
            await webView.evaluate("return !!document.getElementById('version-1')") as? Bool
                == false)
        #expect(await webView.evaluate("return document.body.dataset.mark") as? String == "kept")
        #expect(coordinator.pageLoads == 1)
    }

    @Test("Content cannot keep the next version out by shadowing what the script uses")
    func contentCannotShadowTheScript() async throws {
        let (webView, coordinator, _) = makePreview()
        // Bypasses the sanitizer, which removes `name` attributes.
        coordinator.show(
            #"<p id="version-1">v</p><img name="querySelector"><form name="querySelector"></form>"#
                + #"<img name="body"><img name="innerHTML"><img name="Document">"#)
        await webView.waitUntilLoaded(containing: "version-1")
        #expect(
            await webView.evaluate("return typeof document.querySelector") as? String == "object",
            "the test does not shadow anything")

        coordinator.show(try await content(2, lines: 1))
        await webView.waitUntilLoaded(containing: "version-2")
        #expect(coordinator.pageLoads == 1, "the page had to be loaded again")
    }

    @Test("Replacing the content keeps the scroll position")
    func keepsScrollPosition() async throws {
        let (webView, coordinator, _) = makePreview()
        coordinator.show(try await content(1))
        await webView.waitUntilLoaded(containing: "version-1")
        _ = await webView.evaluate("window.scrollTo(0, 1500)")
        #expect(await webView.evaluate("return window.scrollY") as? Double == 1500)

        coordinator.show(try await content(2))
        await webView.waitUntilLoaded(containing: "version-2")
        #expect(await webView.evaluate("return window.scrollY") as? Double == 1500)
    }

    @Test("Replaced content is governed by the page's policy and stylesheet")
    func replacedContentKeepsThePolicy() async throws {
        let (webView, coordinator, _) = makePreview()
        coordinator.show(try await content(1, lines: 1))
        await webView.waitUntilLoaded(containing: "version-1")
        let policy = await webView.evaluate(
            "return document.head.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')"
                + ".content")
        #expect(policy as? String == MarkdownRenderer.pageContentSecurityPolicy)
        let fontSize = await webView.evaluate(
            "return getComputedStyle(document.getElementById('version-1')).fontSize")
        #expect(fontSize as? String == "15px")
    }

    @Test("After the page's process ended, the page is loaded again, but not endlessly")
    func reloadsAfterTheProcessEnded() async throws {
        let (webView, coordinator, _) = makePreview()
        coordinator.show(try await content(1, lines: 1))
        await webView.waitUntilLoaded(containing: "version-1")
        #expect(coordinator.pageLoads == 1)

        // Every end of the process loads the page and the content again, up
        // to the limit; then the preview waits for the next change.
        for retry in 1...PreviewCoordinator.retries {
            // A mark that the new page does not have, to tell it apart.
            _ = await webView.evaluate("document.body.dataset.mark = 'old'")
            coordinator.webViewWebContentProcessDidTerminate(webView)
            #expect(coordinator.pageLoads == 1 + retry)
            await eventually("the new page shows the content") {
                await webView.evaluate(
                    "return !document.body.dataset.mark && !!document.getElementById('version-1')"
                ) as? Bool == true
            }
        }
        coordinator.webViewWebContentProcessDidTerminate(webView)
        try await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.pageLoads == 1 + PreviewCoordinator.retries)

        coordinator.show(try await content(2, lines: 1))
        await webView.waitUntilLoaded(containing: "version-2")
        #expect(coordinator.pageLoads == 2 + PreviewCoordinator.retries)
    }

    @Test("A click on a task checkbox is handed to the app as a task link")
    func taskCheckboxes() async throws {
        let (webView, coordinator, links) = makePreview()
        coordinator.show(try await tasks())
        await webView.waitUntilLoaded(containing: "tasks")

        _ = await webView.evaluate(
            "document.querySelectorAll('a[role=checkbox]')[1].click()")
        await eventually("the click was handed over") { links.clicked.count == 1 }
        #expect(links.clicked.first?.absoluteString == "markdown-preview://task/test-token/1")
        #expect(
            await webView.evaluate("return document.querySelectorAll('input:checked').length")
                as? Int == 1, "the checkbox changed by itself")
    }

    @Test("A click anywhere on a task checkbox reaches its link")
    func taskCheckboxHitArea() async throws {
        let (webView, coordinator, _) = makePreview()
        coordinator.show(try await tasks())
        await webView.waitUntilLoaded(containing: "tasks")

        // For each task: the link's box (also what accessibility reports)
        // covers the visible checkbox, and its centre and corners hit the
        // link, not the text next to it.
        let results = await webView.evaluate(
            """
            return [...document.querySelectorAll('a[role=checkbox]')].map(link => {
              const box = link.querySelector('input').getBoundingClientRect();
              const area = link.getBoundingClientRect();
              const covers = area.left <= box.left && area.right >= box.right
                && area.top <= box.top && area.bottom >= box.bottom;
              const points = [[box.left + box.width / 2, box.top + box.height / 2],
                [box.left + 1, box.top + 1], [box.right - 1, box.top + 1],
                [box.left + 1, box.bottom - 1], [box.right - 1, box.bottom - 1]];
              const hits = points.every(([x, y]) => document.elementFromPoint(x, y) === link);
              return `covers=${covers} hits=${hits}`;
            })
            """)
        #expect(results as? [String] == ["covers=true hits=true", "covers=true hits=true"])
    }

    @Test("Clicked links are handed to the app and never navigate")
    func linksAreIntercepted() async throws {
        let (webView, coordinator, links) = makePreview()
        coordinator.show(try await content(1, lines: 1))
        await webView.waitUntilLoaded(containing: "version-1")

        _ = await webView.evaluate(
            "for (const link of document.querySelectorAll('a')) { link.click() }")
        await eventually("all links were handed over") { links.clicked.count == 4 }
        // The policy decisions arrive asynchronously, so their order varies
        // (the same-document `#top` is sometimes decided first).
        #expect(
            Set(links.clicked.map(\.absoluteString)) == [
                "https://example.com/a",
                "mailto:a@example.com",
                "markdown-preview://document/other.md",
                "markdown-preview://document/#top",
            ])
        // WebKit applies a fragment (`#top`) within the same document even
        // though the policy cancels it; nothing is loaded.
        let shown = try #require(webView.url)
        var withoutFragment = try #require(
            URLComponents(url: shown, resolvingAgainstBaseURL: false))
        withoutFragment.fragment = nil
        #expect(withoutFragment.url == MarkdownRenderer.pageBaseURL, "navigated to \(shown)")
        #expect(
            await webView.evaluate("return !!document.getElementById('version-1')") as? Bool == true
        )
    }
}
