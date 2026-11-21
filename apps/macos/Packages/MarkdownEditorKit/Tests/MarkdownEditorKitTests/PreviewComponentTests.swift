import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkdownEditorKit

@Suite("Page and links across the boundary")
struct PageAndLinkTests {
    @Test("The page is loaded with the core's base URL")
    func baseURL() {
        #expect(MarkdownRenderer.pageBaseURL.absoluteString == "markdown-preview://document/")
    }

    @Test("The empty page carries the policy; the content goes into it")
    func pageContent() async throws {
        let page = MarkdownRenderer.emptyPage
        #expect(page.hasPrefix("<!DOCTYPE html>"))
        #expect(page.contains(MarkdownRenderer.pageContentSecurityPolicy))
        #expect(page.contains("<body>\n<main>\n</main>\n</body>"))
        #expect(try await MarkdownRenderer.renderPageContent("# Hi") == "<h1>Hi</h1>\n")
        let tasks = try await MarkdownRenderer.renderPageContent("- [ ] a", taskToken: "t-1")
        #expect(tasks.contains("href=\"markdown-preview://task/t-1/0\""))
    }

    @Test("Page errors are typed like render errors")
    func pageErrors() async {
        let limit = MarkdownRenderer.maxInputBytes
        let markdown = String(repeating: "a", count: Int(limit) + 1)
        await #expect(throws: MarkdownRenderer.Failure.inputTooLarge(size: limit + 1, limit: limit))
        {
            try await MarkdownRenderer.renderPageContent(markdown)
        }
    }

    @Test(
        "Link decisions cross the boundary",
        arguments: [
            (
                "https://example.com/a",
                PreviewLinkAction.copyWebAddress(
                    address: "https://example.com/a", host: "example.com")
            ),
            (
                "https://user@evil.example/",
                .copyWebAddress(address: "https://user@evil.example/", host: "evil.example")
            ),
            ("mailto:a%40example.com?subject=x", .copyEmailAddress("a@example.com")),
            ("markdown-preview://document/other.md", .unsupported),
            ("file:///etc/passwd", .blocked),
            ("javascript:alert(1)", .blocked),
            ("markdown-preview://task/k-1/2", .toggleTask(token: "k-1", index: 2)),
            ("markdown-preview://task/k/01", .unsupported),
        ])
    func linkActions(url: String, expected: PreviewLinkAction) throws {
        #expect(PreviewLinkAction(resolvedURL: try #require(URL(string: url))) == expected)
    }
}

@Suite("Navigation policy")
struct NavigationDecisionTests {
    let base = MarkdownRenderer.pageBaseURL
    let web = URL(string: "https://example.com/")

    @Test("Only the expected own load of the page is allowed")
    func ownLoad() {
        #expect(
            NavigationDecision(navigationType: .other, url: base, expectsOwnLoad: true)
                == .allowOwnLoad)
        #expect(
            NavigationDecision(navigationType: .other, url: base, expectsOwnLoad: false)
                == .refuse)
        #expect(
            NavigationDecision(navigationType: .other, url: web, expectsOwnLoad: true)
                == .refuse)
        #expect(
            NavigationDecision(navigationType: .reload, url: base, expectsOwnLoad: true)
                == .refuse)
    }

    @Test("Clicked links are handed to the app")
    func links() throws {
        let web = try #require(web)
        #expect(
            NavigationDecision(navigationType: .linkActivated, url: web, expectsOwnLoad: true)
                == .openLink(web))
        #expect(
            NavigationDecision(navigationType: .linkActivated, url: nil, expectsOwnLoad: false)
                == .refuse)
    }

    @Test(
        "Every other navigation is refused",
        arguments: [
            WKNavigationType.formSubmitted, .formResubmitted, .backForward, .reload, .other,
        ])
    func others(type: WKNavigationType) {
        #expect(
            NavigationDecision(navigationType: type, url: web, expectsOwnLoad: false) == .refuse)
    }
}

@MainActor
@Suite("Copying links")
struct LinkCopyTests {
    /// A private pasteboard, so the tests never touch the user's clipboard.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))

    private var copied: String? { pasteboard.string(forType: .string) }

    @Test("Web links copy the whole address and name the real host")
    func webLink() throws {
        let notice = try #require(
            LinkCopy.handle(
                .copyWebAddress(address: "https://user@evil.example/x", host: "evil.example"),
                pasteboard: pasteboard))
        #expect(copied == "https://user@evil.example/x")
        #expect(notice.title == "Link copied: evil.example")
        #expect(notice.detail == "https://user@evil.example/x")
        #expect(notice.copied)
    }

    @Test("Email links copy only the address")
    func emailLink() throws {
        let notice = try #require(
            LinkCopy.handle(.copyEmailAddress("a@example.com"), pasteboard: pasteboard))
        #expect(copied == "a@example.com")
        #expect(notice.title == "Email address copied")
        #expect(notice.copied)
    }

    @Test(
        "Nothing is copied for empty email links, other files and blocked links",
        arguments: [PreviewLinkAction.copyEmailAddress(""), .unsupported, .blocked])
    func nothingCopied(action: PreviewLinkAction) throws {
        pasteboard.clearContents()
        pasteboard.setString("unchanged", forType: .string)
        let notice = try #require(LinkCopy.handle(action, pasteboard: pasteboard))
        #expect(copied == "unchanged")
        #expect(!notice.copied)
    }

    @Test("Task checkboxes are not handled here")
    func taskToggle() {
        #expect(LinkCopy.handle(.toggleTask(token: "t", index: 0), pasteboard: pasteboard) == nil)
        #expect(copied == nil)
    }

    @Test("Blocked links stay blocked across the boundary and are never copied")
    func blockedFromCore() throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "x-apple-helpviewer://x"] {
            let action = PreviewLinkAction(resolvedURL: try #require(URL(string: url)))
            #expect(action == .blocked, "\(url)")
            _ = LinkCopy.handle(action, pasteboard: pasteboard)
        }
        #expect(copied == nil)
    }

    @Test("The explanation is shown only once")
    func explanationOnce() throws {
        LinkCopy.explainedThisSession = false
        defer { LinkCopy.explainedThisSession = false }
        let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        var shown: [String] = []
        let record: (NSAlert, NSWindow) -> Void = { alert, _ in shown.append(alert.messageText) }
        LinkCopy.explainOnce(in: nil, defaults: defaults, present: record)
        #expect(shown.isEmpty, "shown without a window")
        LinkCopy.explainOnce(in: window, defaults: defaults, present: record)
        #expect(shown == ["Links are copied, not opened"])
        #expect(defaults.bool(forKey: LinkCopy.hintShownKey))
        LinkCopy.explainOnce(in: window, defaults: defaults, present: record)
        #expect(shown.count == 1, "shown a second time")
        #expect(LinkCopy.makeHint().buttons.map(\.title) == ["OK"])
    }
}

@MainActor
@Suite("Preview web view")
struct PreviewWebViewConfigurationTests {
    @Test("The configuration is locked down")
    func configuration() {
        let configuration = PreviewWebView.makeConfiguration()
        #expect(!configuration.websiteDataStore.isPersistent)
        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(configuration.defaultWebpagePreferences.isLockdownModeEnabled)
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(!configuration.preferences.isElementFullscreenEnabled)
        #expect(!configuration.preferences.isFraudulentWebsiteWarningEnabled)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback == .all)
        #expect(!configuration.allowsAirPlayForMediaPlayback)
        #expect(configuration.writingToolsBehavior == .none)
        #expect(configuration.userContentController.userScripts.isEmpty)
    }

    @Test("The web view offers no link previews, gestures or drops")
    func webView() {
        let webView = PreviewWKWebView(
            frame: .zero, configuration: PreviewWebView.makeConfiguration())
        #expect(!webView.allowsLinkPreview)
        #expect(!webView.allowsBackForwardNavigationGestures)
        #expect(!webView.allowsMagnification)
        #expect(webView.registeredDraggedTypes.isEmpty)
        #expect(webView.validRequestor(forSendType: .string, returnType: nil) == nil)
        #expect(webView.validRequestor(forSendType: .URL, returnType: .string) == nil)
    }

    @Test("The context menu keeps only copy and look up")
    func contextMenu() {
        let menu = NSMenu()
        func item(_ identifier: String) -> NSMenuItem {
            let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            return item
        }
        menu.addItem(item("WKMenuItemIdentifierOpenLink"))
        menu.addItem(item("WKMenuItemIdentifierDownloadLinkedFile"))
        menu.addItem(.separator())
        menu.addItem(item("WKMenuItemIdentifierCopyLink"))
        menu.addItem(.separator())
        menu.addItem(.separator())
        menu.addItem(item("WKMenuItemIdentifierLookUp"))
        menu.addItem(item("WKMenuItemIdentifierSearchWeb"))
        menu.addItem(item("WKMenuItemIdentifierShareMenu"))
        menu.addItem(NSMenuItem(title: "Services", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(item("WKMenuItemIdentifierCopy"))
        menu.addItem(.separator())
        menu.addItem(item("WKMenuItemIdentifierReload"))

        PreviewWKWebView.filter(menu)

        #expect(
            menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
                "WKMenuItemIdentifierCopyLink", "-", "WKMenuItemIdentifierLookUp", "-",
                "WKMenuItemIdentifierCopy",
            ])
    }

    @Test("The content blocker compiles and is reused")
    func contentBlocker() async throws {
        let first = try await ContentBlocker.ruleList()
        let second = try await ContentBlocker.ruleList()
        #expect(first === second)
        #expect(first.identifier == ContentBlocker.identifier)
    }
}

@MainActor
@Suite("Editor")
struct MarkdownTextViewTests {
    @Test("The editor never changes text on its own")
    func configuration() {
        let textView = MarkdownTextView.makeTextView(text: "")
        // TextKit 1 with non-contiguous layout copes with long paragraphs
        // (SR-2026-004).
        #expect(textView.textLayoutManager == nil, "uses TextKit 2")
        #expect(textView.layoutManager?.allowsNonContiguousLayout == true)
        #expect(!textView.isRichText)
        #expect(!textView.importsGraphics)
        #expect(textView.allowsUndo)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        #expect(!textView.isGrammarCheckingEnabled)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
        #expect(!textView.isAutomaticTextCompletionEnabled)
        #expect(!textView.smartInsertDeleteEnabled)
        #expect(textView.inlinePredictionType == .no)
        #expect(textView.mathExpressionCompletionType == .no)
        #expect(textView.writingToolsBehavior == .none)
        #expect(textView.font == NSFont.systemFont(ofSize: NSFont.systemFontSize))
        #expect(textView.textContainer?.widthTracksTextView == true)
        #expect(textView.accessibilityIdentifier() == "editor")
    }

    @Test("A long paragraph without line breaks opens and edits quickly (SR-2026-004)")
    func longParagraph() {
        // About 2 MB in one paragraph, like minified data saved as text.
        let text = String(repeating: "[a](b) ", count: 300_000)
        let start = ContinuousClock.now
        // The order of SwiftUI's makeNSView: the scroll view has no size yet.
        let textView = MarkdownTextView.makeTextView(text: text)
        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        scrollView.layoutSubtreeIfNeeded()
        textView.insertText("x", replacementRange: NSRange(location: 1_000_000, length: 0))
        scrollView.layoutSubtreeIfNeeded()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(3), "took \(elapsed)")
    }

    @Test("Typed quotes and dashes stay exactly as typed")
    func noSubstitutions() {
        let textView = MarkdownTextView.makeTextView(text: "")
        textView.insertText(
            "\"quote\" -- 'single' (c) ...", replacementRange: textView.selectedRange())
        #expect(textView.string == "\"quote\" -- 'single' (c) ...")
    }
}
