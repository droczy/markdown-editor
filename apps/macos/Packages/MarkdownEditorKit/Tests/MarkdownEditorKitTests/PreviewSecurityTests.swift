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
/// It is inserted into the page directly, bypassing the sanitizer, to prove
/// that the preview's other defences hold on their own.
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

/// A page with the preview's template and policy, but hostile content.
private func hostilePage(port: UInt16, withPolicy: Bool) async throws -> String {
    let template = try await MarkdownRenderer.renderPage("")
    var page = template.replacingOccurrences(
        of: "<main>\n", with: "<main>\n\(hostileMarkup(port: port))")
    if !withPolicy {
        let policy = try #require(
            page.firstRange(of: /<meta http-equiv="Content-Security-Policy"[^>]*>/))
        page.removeSubrange(policy)
    }
    return page
}

@MainActor
@Suite("Preview security", .serialized)
struct PreviewSecurityTests {
    /// Loads `page` into a preview-configured web view, clicks the links and
    /// submits the form from the app's world, and returns the web view.
    private func loadAndPoke(
        _ page: String, withContentBlocker: Bool, delegate: StrictNavigationDelegate
    ) async throws -> WKWebView {
        let webView = PreviewWKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: PreviewWebView.makeConfiguration())
        if withContentBlocker {
            webView.configuration.userContentController.add(try await ContentBlocker.ruleList())
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(page, baseURL: MarkdownRenderer.pageBaseURL)
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
        arguments: [(true, true), (true, false), (false, true)])
    func defencesHoldAlone(withPolicy: Bool, withContentBlocker: Bool) async throws {
        let server = try await RecordingServer()
        let page = try await hostilePage(port: server.port, withPolicy: withPolicy)
        let delegate = StrictNavigationDelegate()
        let webView = try await loadAndPoke(
            page, withContentBlocker: withContentBlocker, delegate: delegate)

        #expect(server.requests.isEmpty, "the preview sent requests: \(server.requests)")
        #expect(webView.title?.isEmpty != false, "a script ran: \(webView.title ?? "")")
    }

    @Test("Without both defences the hostile page does send requests (test is sound)")
    func hostilePageIsHostile() async throws {
        let server = try await RecordingServer()
        let page = try await hostilePage(port: server.port, withPolicy: false)
        let delegate = StrictNavigationDelegate()
        _ = try await loadAndPoke(page, withContentBlocker: false, delegate: delegate)
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
        let page = try await MarkdownRenderer.renderPage("text")
        webView.loadHTMLString(
            page.replacingOccurrences(of: "<main>\n", with: "<main>\n<p id=\"probe\">p</p>"),
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

    private func page(_ version: Int, lines: Int = 300) async throws -> String {
        let text = (1...lines).map { "Line \($0)" }.joined(separator: "\n\n")
        let page = try await MarkdownRenderer.renderPage(
            "[web](https://example.com/a) [mail](mailto:a@example.com) "
                + "[file](other.md) [anchor](#top)\n\n\(text)")
        return page.replacingOccurrences(
            of: "<main>\n", with: "<main>\n<p id=\"version-\(version)\">v</p>")
    }

    @Test("Replacing the page keeps the scroll position")
    func keepsScrollPosition() async throws {
        let (webView, coordinator, _) = makePreview()
        coordinator.show(try await page(1))
        await webView.waitUntilLoaded(containing: "version-1")
        _ = await webView.evaluate("window.scrollTo(0, 1500)")
        #expect(await webView.evaluate("return window.scrollY") as? Double == 1500)

        coordinator.show(try await page(2))
        await webView.waitUntilLoaded(containing: "version-2")
        await eventually("the scroll position is restored") {
            await webView.evaluate("return window.scrollY") as? Double == 1500
        }
    }

    @Test("Clicked links are handed to the app and never navigate")
    func linksAreIntercepted() async throws {
        let (webView, coordinator, links) = makePreview()
        coordinator.show(try await page(1, lines: 1))
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
