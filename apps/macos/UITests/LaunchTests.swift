import XCTest

/// Smoke tests for the app skeleton: the app launches and a new document can
/// be created and edited.
final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testNewDocumentCanBeEdited() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // Skip the first-launch privacy window and the one-time explanation
        // of copied links.
        app.launchArguments += ["-privacyInfoShown", "YES", "-linkCopyHintShown", "YES"]
        app.launch()

        // DocumentGroup may show an open panel at launch; dismiss it and
        // create a new document explicitly.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("n", modifierFlags: .command)

        let editor = app.textViews["editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("# Hello")
        XCTAssertEqual(editor.value as? String, "# Hello")
    }

    @MainActor
    func testWindowsHaveNoTabs() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-privacyInfoShown", "YES", "-linkCopyHintShown", "YES"]
        app.launch()
        defer { app.terminate() }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textViews["editor"].firstMatch.waitForExistence(timeout: 10))

        for title in ["Show Tab Bar", "Show All Tabs", "Merge All Windows"] {
            XCTAssertFalse(app.menuBars.menuItems[title].exists, "menu still offers \(title)")
        }
    }
}
