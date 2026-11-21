import AppKit
import SwiftUI
import WebKit

/// Shows preview content from
/// ``MarkdownRenderer/renderPageContent(_:taskToken:)``.
///
/// The web view loads ``MarkdownRenderer/emptyPage`` once and then shows
/// every new version of the document by replacing the content of the page's
/// `main` element. The page is not reloaded, so an edit appears at once and
/// the scroll position stays where it is.
///
/// The content is untrusted, so the web view is locked down in several
/// independent ways (see ``PreviewWebView/makeConfiguration()``): the page's
/// Content Security Policy, which applies to the replaced content as well,
/// JavaScript of the page disabled, a content blocker that refuses every load
/// apart from the page itself, nothing stored on disk, and every navigation
/// cancelled. Clicked links are handed to `onLink` instead.
///
/// The app itself runs one fixed script in its own, isolated JavaScript
/// world to replace the content; the content is passed to it as data. The
/// page cannot see or change this script.
public struct PreviewWebView: NSViewRepresentable {
    /// The content to show; `nil` shows nothing.
    public let content: String?
    /// Zoom factor of the page (1 is the normal size).
    public let zoom: Double
    /// Called with the resolved URL and the preview's window when the user
    /// clicks a link.
    public let onLink: @MainActor (URL, NSWindow?) -> Void

    /// Creates a preview for `content`.
    public init(
        content: String?, zoom: Double = 1,
        onLink: @escaping @MainActor (URL, NSWindow?) -> Void
    ) {
        self.content = content
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

    /// Shows the current content.
    public func updateNSView(_ webView: PreviewWKWebView, context: Context) {
        context.coordinator.onLink = onLink
        if webView.pageZoom != zoom {
            webView.pageZoom = zoom
        }
        if let content {
            context.coordinator.show(content)
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
/// system services (such as "Open" for a link, which would open it) and does
/// not accept drops (a dropped file would otherwise be opened in it).
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

/// Loads the preview page, replaces its content and enforces the navigation
/// rules.
@MainActor
public final class PreviewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Called with the resolved URL and the window when the user clicks a
    /// link.
    var onLink: @MainActor (URL, NSWindow?) -> Void

    /// Number of times the empty page was loaded (for tests).
    private(set) var pageLoads = 0

    private weak var webView: WKWebView?
    /// Whether the content blocker is installed; nothing loads before.
    private var isReady = false
    /// Whether the empty page is not loaded, loading, ready for content or
    /// given up on.
    private var page = PageState.notLoaded
    /// The content most recently requested by ``show(_:)``.
    private var requestedContent: String?
    /// The content the page shows, if it shows the requested one or an
    /// earlier one.
    private var shownContent: String?
    /// Whether the content is being replaced right now.
    private var isReplacing = false
    /// How often the page may still be loaded again after it failed (its
    /// process ended, or the content could not be replaced) before the
    /// content changes. Bounds the work a document can cause, for example
    /// one that makes the page's process run out of memory every time.
    private var retriesLeft = PreviewCoordinator.retries
    /// Number of loads started by the app that the navigation policy has not
    /// seen yet. Every other navigation is refused.
    private var expectedLoads = 0

    static let retries = 2

    private enum PageState {
        case notLoaded, loading, loaded
        /// The page failed too often since the content last changed; it is
        /// loaded again only for new content.
        case failed
    }

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
                update()
            } catch {
                // Fail closed: without the content blocker, nothing is shown.
                assertionFailure("content blocker could not be compiled: \(error)")
            }
        }
    }

    /// Shows `content` in place of the current content.
    func show(_ content: String) {
        guard content != requestedContent else { return }
        requestedContent = content
        retriesLeft = Self.retries
        if page == .failed {
            page = .notLoaded
        }
        update()
    }

    /// Takes the next step towards showing the requested content: loads the
    /// empty page if needed, then replaces its content. One step at a time;
    /// each step calls this again when it ends.
    private func update() {
        guard isReady, !isReplacing, let webView, let content = requestedContent else { return }
        switch page {
        case .notLoaded:
            page = .loading
            shownContent = nil
            pageLoads += 1
            expectedLoads += 1
            webView.loadHTMLString(
                MarkdownRenderer.emptyPage, baseURL: MarkdownRenderer.pageBaseURL)
        case .loading, .failed:
            return
        case .loaded:
            guard content != shownContent else { return }
            isReplacing = true
            Task {
                let replaced = await Self.replaceContent(of: webView, with: content)
                isReplacing = false
                if page != .loaded {
                    // The page failed in the meantime: load it again, if
                    // ``pageFailed()`` did not give up.
                    update()
                } else if replaced {
                    shownContent = content
                    update()
                } else {
                    pageFailed()
                }
            }
        }
    }

    /// Loads the page again after it failed, unless it failed too often
    /// since the content last changed. Then it stays failed, also for a
    /// content replacement that ends later, until the content changes.
    private func pageFailed() {
        shownContent = nil
        guard retriesLeft > 0 else {
            page = .failed
            return
        }
        retriesLeft -= 1
        page = .notLoaded
        update()
    }

    /// Replaces the content of the page's `main` element with `content`.
    /// Returns whether the page had that element and the content was
    /// replaced.
    ///
    /// The script runs in the app's isolated world, and the content is passed
    /// as an argument, never spliced into the code. It is parsed like the
    /// body of a page that contained it: scripts in it never run, and the
    /// page's policy and the content blocker apply to everything it would
    /// load. The script takes `querySelector` from the prototype, because
    /// elements with a `name` could shadow it on `document` (the sanitizer
    /// removes `name`, so this only matters if markup ever slipped through).
    static func replaceContent(of webView: WKWebView, with content: String) async -> Bool {
        let result = try? await webView.callAsyncJavaScript(
            """
            const main = Document.prototype.querySelector.call(document, "body > main");
            if (main === null) {
              return false;
            }
            main.innerHTML = content;
            return true;
            """,
            arguments: ["content": content], in: nil, contentWorld: .defaultClient)
        return result as? Bool == true
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

    /// Puts the content into the page once it is loaded.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard page == .loading else { return }
        page = .loaded
        update()
    }

    /// Tries again if the page could not be loaded.
    public func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error
    ) {
        if page == .loading {
            pageFailed()
        }
    }

    /// Tries again if the page could not be loaded.
    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        if page == .loading {
            pageFailed()
        }
    }

    /// Shows the page and its content again after the page's process ended
    /// (for example, it crashed).
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageFailed()
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
