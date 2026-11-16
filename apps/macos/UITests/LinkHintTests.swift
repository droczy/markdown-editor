import XCTest

/// The first copied link explains once that the editor never opens links.
@MainActor
final class LinkHintTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testExplainsOnceThatLinksAreCopied() {
        let app = XCUIApplication()
        // Behave as if no link had been clicked before.
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES", "-privacyInfoShown", "YES",
            "-linkCopyHintShown", "NO",
        ]
        app.launch()
        defer { app.terminate() }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("n", modifierFlags: .command)

        let editor = app.textViews["editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("[Example](https://example.com/)")
        let link = app.webViews.firstMatch.links["Example"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))

        link.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no explanation")
        XCTAssertTrue(
            sheet.staticTexts["Links are copied, not opened"].exists, "wrong explanation")
        sheet.buttons["OK"].click()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sheet)
        wait(for: [closed], timeout: 10)

        // The second click only shows the short notice.
        link.click()
        let notice = app.descendants(matching: .any)["linkNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no notice")
        XCTAssertFalse(app.sheets.firstMatch.exists, "explained a second time")
    }
}
