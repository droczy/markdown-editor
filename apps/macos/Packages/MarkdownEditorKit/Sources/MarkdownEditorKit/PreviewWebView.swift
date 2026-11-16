import AppKit
import SwiftUI
import WebKit

/// Shows a preview page from ``MarkdownRenderer/renderPage(_:)``.
///
/// The page is untrusted content, so the web view is locked down in several
/// independent ways (see ``PreviewWebView/makeConfiguration()``):
/// JavaScript of the page is disabled, a content blocker refuses every load
/// apart from the page itself, nothing is stored on disk, and every
/// navigation is cancelled. Clicked links are handed to `onLink` instead.
///
/// The app itself runs two fixed scripts in its own, isolated JavaScript
/// world, to keep the scroll position when the page is replaced. The page
/// cannot see or change these scripts.
public struct PreviewWebView: NSViewRepresentable {
    /// The page to show; `nil` shows nothing.
    public let page: String?
    /// Zoom factor of the page (1 is the normal size).
    public let zoom: Double
    /// Called with the resolved URL and the preview's window when the user
    /// clicks a link.
    public let onLink: @MainActor (URL, NSWindow?) -> Void

    /// Creates a preview for `page`.
    public init(
        page: String?, zoom: Double = 1, onLink: @escaping @MainActor (URL, NSWindow?) -> Void
    ) {
        self.page = page
        self.zoom = zoom
        self.onLink = onLink
    }

    /// Creates the coordinator that loads pages and enforces the rules.
    public func makeCoordinator() -> PreviewCoordinator {
        PreviewCoordinator(onLink: onLink)
    }

    /// Creates the locked-down web view.
    public func makeNSView(context: Context) -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: .zero, configuration: Self.makeConfiguration())
        context.coordinator.attach(webView)
        return webView
    }

    /// Shows the current page.
    public func updateNSView(_ webView: PreviewWKWebView, context: Context) {
        context.coordinator.onLink = onLink
        if webView.pageZoom != zoom {
            webView.pageZoom = zoom
        }
        if let page {
            context.coordinator.show(page)
        }
    }

    /// The locked-down configuration of the preview's web view.
    @MainActor
    public static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Cookies, caches and other website data stay in memory only.
        configuration.websiteDataStore = .nonPersistent()
        // Scripts of the page never run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Lockdown Mode turns off complex web features the preview does not
        // need (just-in-time compilation, web fonts, WebGL and more), which
        // removes most of the engine's attack surface.
        configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        // The safe browsing check would contact a server; the preview never
        // navigates, so there is nothing to check.
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        // Text in the preview is never sent to writing assistants.
        configuration.writingToolsBehavior = .none
        // Show a new page only once it is complete, to avoid flicker.
        configuration.suppressesIncrementalRendering = true
        return configuration
    }
}

/// The preview's web view: offers only harmless context menu items, no
/// system services (such as "Open" for a link, which would bypass the
/// confirmation) and does not accept drops (a dropped file would otherwise
/// be opened in it).
public final class PreviewWKWebView: WKWebView {
    /// Context menu items that are kept; everything else (open link,
    /// download, share, search the web, reload, …) is removed.
    static let allowedMenuItems: Set<String> = [
        "WKMenuItemIdentifierCopy",
        "WKMenuItemIdentifierCopyLink",
        "WKMenuItemIdentifierLookUp",
    ]

    override public init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        allowsLinkPreview = false
        allowsBackForwardNavigationGestures = false
        allowsMagnification = false
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("not used")
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unregisterDraggedTypes()
    }

    /// Offers nothing to the system's services, so the context menu shows no
    /// services.
    override public func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        nil
    }

    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        Self.filter(menu)
        super.willOpenMenu(menu, with: event)
    }

    /// Removes every item that is not explicitly allowed, including
    /// separators left at the edges.
    static func filter(_ menu: NSMenu) {
        for item in menu.items
        where !allowedMenuItems.contains(item.identifier?.rawValue ?? "") && !item.isSeparatorItem {
            menu.removeItem(item)
        }
        while let first = menu.items.first, first.isSeparatorItem {
            menu.removeItem(first)
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
        // Collapse runs of separators.
        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator {
                menu.removeItem(item)
            }
            previousWasSeparator = item.isSeparatorItem
        }
    }
}

/// Loads pages into the preview's web view and enforces the navigation rules.
@MainActor
public final class PreviewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Called with the resolved URL and the window when the user clicks a
    /// link.
    var onLink: @MainActor (URL, NSWindow?) -> Void

    private weak var webView: WKWebView?
    /// Whether the content blocker is installed; nothing loads before.
    private var isReady = false
    /// The page most recently requested by ``show(_:)``.
    private var requestedPage: String?
    /// A page waiting to be loaded.
    private var pendingPage: String?
    /// Whether a page is loading right now.
    private var isLoading = false
    /// Whether a page has been shown already (there is a scroll position).
    private var hasShownPage = false
    /// Number of loads started by the app that the navigation policy has not
    /// seen yet. Every other navigation is refused.
    private var expectedLoads = 0
    /// Scroll position to restore once the loading page has finished.
    private var scrollPosition: Double?

    init(onLink: @escaping @MainActor (URL, NSWindow?) -> Void) {
        self.onLink = onLink
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Task {
            do {
                let rules = try await ContentBlocker.ruleList()
                webView.configuration.userContentController.add(rules)
                isReady = true
                loadIfIdle()
            } catch {
                // Fail closed: without the content blocker, nothing is shown.
                assertionFailure("content blocker could not be compiled: \(error)")
            }
        }
    }

    /// Shows `page`, replacing the current one while keeping the scroll
    /// position.
    func show(_ page: String) {
        guard page != requestedPage else { return }
        requestedPage = page
        pendingPage = page
        loadIfIdle()
    }

    private func loadIfIdle() {
        guard isReady, !isLoading, let page = pendingPage, let webView else { return }
        pendingPage = nil
        isLoading = true
        Task {
            if hasShownPage {
                scrollPosition = await Self.scrollPosition(of: webView)
            }
            expectedLoads += 1
            webView.loadHTMLString(page, baseURL: MarkdownRenderer.pageBaseURL)
        }
    }

    private func loadDidEnd() {
        isLoading = false
        loadIfIdle()
    }

    // MARK: Scroll position (app-only scripts in an isolated world)

    private static func scrollPosition(of webView: WKWebView) async -> Double? {
        let result = try? await webView.callAsyncJavaScript(
            "return window.scrollY", arguments: [:], in: nil, contentWorld: .defaultClient)
        return (result as? NSNumber)?.doubleValue
    }

    private static func scroll(_ webView: WKWebView, to position: Double) async {
        // The position is passed as an argument, never spliced into the code.
        _ = try? await webView.callAsyncJavaScript(
            "window.scrollTo(0, position)", arguments: ["position": position], in: nil,
            contentWorld: .defaultClient)
    }

    // MARK: WKNavigationDelegate

    /// Allows only the app's own page loads; hands clicked links to the app.
    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let decision = NavigationDecision(
            navigationType: navigationAction.navigationType,
            url: navigationAction.request.url,
            expectsOwnLoad: expectedLoads > 0)
        switch decision {
        case .allowOwnLoad:
            expectedLoads -= 1
            return .allow
        case .openLink(let url):
            onLink(url, webView.window)
            return .cancel
        case .refuse:
            return .cancel
        }
    }

    /// Accepts only the response for the app's own page.
    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.isForMainFrame
            && navigationResponse.response.url == MarkdownRenderer.pageBaseURL ? .allow : .cancel
    }

    /// Restores the scroll position, then loads the next page if any.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        hasShownPage = true
        if let position = scrollPosition {
            scrollPosition = nil
            Task {
                await Self.scroll(webView, to: position)
                loadDidEnd()
            }
        } else {
            loadDidEnd()
        }
    }

    /// Continues with the next page.
    public func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error
    ) {
        loadDidEnd()
    }

    /// Continues with the next page.
    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        loadDidEnd()
    }

    /// Shows the page again after the page's process ended.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's process ended (e.g. it crashed): show the page again.
        isLoading = false
        hasShownPage = false
        pendingPage = requestedPage
        loadIfIdle()
    }

    // MARK: WKUIDelegate

    /// Never opens new windows.
    public func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Never open new windows; the link itself was handled by the
        // navigation policy.
        nil
    }
}

/// The navigation policy of the preview, separate from WebKit for testing.
enum NavigationDecision: Equatable {
    /// The page load the app started itself.
    case allowOwnLoad
    /// A clicked link: cancel the navigation and hand the link to the app.
    case openLink(URL)
    /// Everything else: cancel.
    case refuse

    init(navigationType: WKNavigationType, url: URL?, expectsOwnLoad: Bool) {
        switch navigationType {
        case .other where expectsOwnLoad && url == MarkdownRenderer.pageBaseURL:
            self = .allowOwnLoad
        case .linkActivated:
            self = url.map { .openLink($0) } ?? .refuse
        default:
            self = .refuse
        }
    }
}

/// A content rule list that blocks every load: images, styles, fonts, media,
/// frames and navigation. The page itself is loaded from memory and is not
/// affected.
enum ContentBlocker {
    static let identifier = "io.github.droczy.markdowneditor.block-everything"
    static let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    @MainActor private static var compiled: Task<WKContentRuleList, any Error>?

    /// The compiled rule list (compiled once per app run).
    @MainActor
    static func ruleList() async throws -> WKContentRuleList {
        if let compiled {
            return try await compiled.value
        }
        let task = Task<WKContentRuleList, any Error> { @MainActor in
            guard
                let list = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: rules)
            else {
                throw CocoaError(.featureUnsupported)
            }
            return list
        }
        compiled = task
        return try await task.value
    }
}
