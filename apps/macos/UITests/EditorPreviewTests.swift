import XCTest

/// End-to-end tests of the editor and the preview in a new document.
///
/// Main-actor isolated as a whole: UI automation APIs must run on the main
/// thread.
@MainActor
final class EditorPreviewTests: XCTestCase {
    private var app = XCUIApplication?.none

    override func setUp() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        self.app = app
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // Skip the first-launch privacy window and the one-time explanation
        // of copied links.
        app.launchArguments += ["-privacyInfoShown", "YES", "-linkCopyHintShown", "YES"]
        app.launch()
        // Dismiss the open panel DocumentGroup may show at launch and start
        // with a new, empty document.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("n", modifierFlags: .command)
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    // MARK: - Helpers

    private var launchedApp: XCUIApplication {
        guard let app else {
            preconditionFailure("setUp did not launch the app")
        }
        return app
    }

    private var editor: XCUIElement {
        launchedApp.textViews["editor"].firstMatch
    }

    private var preview: XCUIElement {
        launchedApp.webViews.firstMatch
    }

    /// Types `text` into the empty editor and waits until the preview shows
    /// `element`.
    private func type(_ text: String, thenWaitFor element: XCUIElement) {
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no editor")
        editor.click()
        editor.typeText(text)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "preview did not show \(element)")
    }

    // MARK: - Tests

    func testEditorAndPreviewShareTheWindowEqually() {
        type("# Halves", thenWaitFor: preview.staticTexts["Halves"])
        let editorFrame = editor.frame
        let previewFrame = preview.frame
        XCTAssertLessThanOrEqual(editorFrame.maxX, previewFrame.minX + 2, "editor is not left")
        XCTAssertEqual(editorFrame.width, previewFrame.width, accuracy: 20)
    }

    func testTypingUpdatesThePreview() {
        type("# Preview Title\n\nSome *text*.", thenWaitFor: preview.staticTexts["Preview Title"])
        editor.typeText("\n\n## Second")
        XCTAssertTrue(preview.staticTexts["Second"].waitForExistence(timeout: 10))
    }

    func testTextStaysExactlyAsTyped() {
        let text = "\"quotes\" -- 'single' (c) teh ..."
        type(text, thenWaitFor: preview.staticTexts.firstMatch)
        XCTAssertEqual(editor.value as? String, text)
    }

    func testUndoAndRedoTyping() {
        type("abc", thenWaitFor: preview.staticTexts["abc"])
        launchedApp.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "")
        launchedApp.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, "abc")
    }

    /// The notice shown after a click on a link.
    private var notice: XCUIElement {
        launchedApp.descendants(matching: .any)["linkNotice"].firstMatch
    }

    /// Replaces the editor's text with the clipboard and returns it. Pasting
    /// shows what a click copied without reading the clipboard directly.
    private func pastedClipboard() -> String? {
        editor.click()
        launchedApp.typeKey("a", modifierFlags: .command)
        launchedApp.typeKey("v", modifierFlags: .command)
        return editor.value as? String
    }

    func testWebLinkIsCopiedNotOpened() {
        let link = preview.links["Example"]
        type("[Example](https://example.com/page)", thenWaitFor: link)

        link.click()
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no notice")
        XCTAssertTrue(notice.label.contains("example.com"), "notice: \(notice.label)")
        XCTAssertFalse(launchedApp.sheets.firstMatch.exists, "a dialog appeared")
        XCTAssertEqual(launchedApp.state, .runningForeground, "another app came to the front")
        XCTAssertEqual(pastedClipboard(), "https://example.com/page")
    }

    func testEmailLinkCopiesOnlyTheAddress() {
        let link = preview.links["Mail"]
        type("[Mail](mailto:someone@example.com?subject=Hi)", thenWaitFor: link)

        link.click()
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no notice")
        XCTAssertEqual(pastedClipboard(), "someone@example.com")
    }

    func testRelativeLinkCopiesNothing() {
        let link = preview.links["Other"]
        type("[Other](other.md)", thenWaitFor: link)
        // Put known text on the clipboard first.
        launchedApp.typeKey("a", modifierFlags: .command)
        launchedApp.typeKey("c", modifierFlags: .command)

        link.click()
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no notice")
        XCTAssertTrue(notice.label.contains("not supported yet"), "notice: \(notice.label)")
        XCTAssertEqual(pastedClipboard(), "[Other](other.md)", "the clipboard changed")
    }

    func testContextMenuOffersOnlySafeItems() throws {
        let link = preview.links["Context"]
        type("[Context](https://example.com/)", thenWaitFor: link)
        link.rightClick()
        XCTAssertTrue(
            launchedApp.menuItems["WKMenuItemIdentifierCopyLink"].waitForExistence(timeout: 10),
            "no context menu with Copy Link")

        // One snapshot of the whole tree instead of a query per item (the
        // menu bar alone has dozens of items).
        func menus(in element: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
            (element.elementType == .menu ? [element] : []) + element.children.flatMap(menus)
        }
        let contextMenu = try XCTUnwrap(
            menus(in: try launchedApp.snapshot()).first { menu in
                menu.children.contains { $0.identifier == "WKMenuItemIdentifierCopyLink" }
            })
        let items = contextMenu.children
            .filter { $0.elementType == .menuItem && !($0.identifier.isEmpty && $0.title.isEmpty) }
            .map { "\($0.identifier)|\($0.title)" }
        launchedApp.typeKey(.escape, modifierFlags: [])

        let allowedIdentifiers = [
            "WKMenuItemIdentifierCopy|", "WKMenuItemIdentifierCopyLink|",
            "WKMenuItemIdentifierLookUp|",
        ]
        let unexpected = items.filter { item in
            !allowedIdentifiers.contains { item.hasPrefix($0) }
        }
        XCTAssertTrue(unexpected.isEmpty, "unexpected menu items: \(unexpected) of \(items)")
    }

    func testClickingATaskCheckboxEditsTheText() {
        let checkbox = preview.checkBoxes["Task"].firstMatch
        // Wait until the preview shows the whole text: a click on an older
        // page is ignored on purpose (its task index may be outdated).
        type("- [ ] Buy milk\n- [x] Done", thenWaitFor: preview.checkBoxes.element(boundBy: 1))

        checkbox.click()
        XCTAssertTrue(
            waitUntil { self.editor.value as? String == "- [x] Buy milk\n- [x] Done" },
            "checkbox did not check the task: \(editor.value ?? "")")

        // The preview shows the new state, and the click can be undone.
        XCTAssertTrue(waitUntil { checkbox.value as? Int == 1 }, "preview not updated")
        checkbox.click()
        XCTAssertTrue(
            waitUntil { self.editor.value as? String == "- [ ] Buy milk\n- [x] Done" },
            "checkbox did not uncheck the task")
        launchedApp.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil { self.editor.value as? String == "- [x] Buy milk\n- [x] Done" },
            "undo did not restore the task: \(editor.value ?? "")")
    }

    func testZoomChangesEditorAndPreview() {
        let heading = preview.staticTexts["Zoom"].firstMatch
        type("# Zoom", thenWaitFor: heading)
        // The zoom level is kept across launches: start at the normal size.
        // (A launch argument would pin the value for the whole run.)
        launchedApp.typeKey("0", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let normal = heading.frame.height

        launchedApp.typeKey("+", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil { heading.frame.height > normal * 1.05 }, "preview did not zoom in")
        launchedApp.typeKey("-", modifierFlags: .command)
        launchedApp.typeKey("-", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil { heading.frame.height < normal * 0.95 }, "preview did not zoom out")
        launchedApp.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil { abs(heading.frame.height - normal) < 1 }, "zoom was not reset")
        XCTAssertEqual(editor.value as? String, "# Zoom", "zooming changed the text")
    }

    func testPreviewExplainsDocumentsItCannotRender() {
        // Nested deeper than the renderer's limit of 1 000 levels.
        let tooDeep = String(repeating: ">", count: 1_001) + "x"
        let notice = launchedApp.descendants(matching: .any)["previewError"]
        type(tooDeep, thenWaitFor: notice)
        XCTAssertEqual(editor.value as? String, tooDeep, "editor must keep the text")

        // Once the document can be rendered again, the notice disappears.
        launchedApp.typeKey("a", modifierFlags: .command)
        editor.typeText("Fixed")
        XCTAssertTrue(preview.staticTexts["Fixed"].waitForExistence(timeout: 10), "not rendered")
        XCTAssertTrue(waitUntil { !notice.exists }, "the notice stayed")
    }

    func testTabKeyInsertsATabCharacter() {
        type("a\tb", thenWaitFor: preview.staticTexts.firstMatch)
        XCTAssertEqual(editor.value as? String, "a\tb")
    }
}
