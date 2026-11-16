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

    @Test("Pages carry the policy and the content")
    func pageContent() async throws {
        let page = try await MarkdownRenderer.renderPage("# Hi")
        #expect(page.hasPrefix("<!DOCTYPE html>"))
        #expect(page.contains(MarkdownRenderer.pageContentSecurityPolicy))
        #expect(page.contains("<h1>Hi</h1>"))
    }

    @Test("Page errors are typed like render errors")
    func pageErrors() async {
        let limit = MarkdownRenderer.maxInputBytes
        let markdown = String(repeating: "a", count: Int(limit) + 1)
        await #expect(throws: MarkdownRenderer.Failure.inputTooLarge(size: limit + 1, limit: limit))
        {
            try await MarkdownRenderer.renderPage(markdown)
        }
    }

    @Test(
        "Link decisions cross the boundary",
        arguments: [
            ("https://example.com/a", PreviewLinkAction.openInBrowser(host: "example.com")),
            ("https://user@evil.example/", .openInBrowser(host: "evil.example")),
            ("mailto:a@example.com?subject=x", .openInEmailApp(recipients: "a@example.com")),
            ("markdown-preview://document/other.md", .unsupported),
            ("file:///etc/passwd", .blocked),
            ("javascript:alert(1)", .blocked),
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
@Suite("Link confirmation")
struct LinkConfirmationTests {
    // A fallback instead of `!` (swift-format forbids force unwrapping); the
    // tests below check the address, so a wrong URL would fail them.
    let url = URL(string: "https://example.com/path?q=1") ?? URL(filePath: "/")

    @Test("Web links ask first; Open has no key equivalent")
    func webLink() {
        let alert = LinkConfirmation.makeAlert(
            for: .openInBrowser(host: "example.com"), url: url)
        #expect(alert.messageText.contains("“example.com”"))
        #expect(alert.informativeText.contains("https://example.com/path?q=1"))
        #expect(alert.buttons.map(\.title) == ["Cancel", "Open"])
        #expect(alert.buttons[1].keyEquivalent.isEmpty)
    }

    @Test("Email links ask first; Open has no key equivalent")
    func emailLink() throws {
        let mail = try #require(URL(string: "mailto:a@example.com"))
        let alert = LinkConfirmation.makeAlert(
            for: .openInEmailApp(recipients: "a@example.com"), url: mail)
        #expect(alert.messageText.contains("“a@example.com”"))
        #expect(alert.buttons.map(\.title) == ["Cancel", "Open"])
        #expect(alert.buttons[1].keyEquivalent.isEmpty)
        let noRecipient = LinkConfirmation.makeAlert(
            for: .openInEmailApp(recipients: ""), url: mail)
        #expect(noRecipient.messageText == "Write an email?")
    }

    @Test(
        "Unsupported and blocked links only explain",
        arguments: [PreviewLinkAction.unsupported, .blocked])
    func explanationOnly(action: PreviewLinkAction) {
        let alert = LinkConfirmation.makeAlert(for: action, url: url)
        #expect(alert.buttons.map(\.title) == ["OK"])
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
        let textView = NSTextView(usingTextLayoutManager: true)
        MarkdownTextView.configure(textView)
        #expect(textView.textLayoutManager != nil, "TextKit 2")
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

    @Test("Typed quotes and dashes stay exactly as typed")
    func noSubstitutions() {
        let textView = NSTextView(usingTextLayoutManager: true)
        MarkdownTextView.configure(textView)
        textView.insertText(
            "\"quote\" -- 'single' (c) ...", replacementRange: textView.selectedRange())
        #expect(textView.string == "\"quote\" -- 'single' (c) ...")
    }
}
