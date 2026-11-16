import XCTest

/// The privacy information appears once at the first launch and can be
/// opened again from the Help menu.
@MainActor
final class PrivacyInfoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testShownAtFirstLaunchAndFromHelpMenu() {
        let app = XCUIApplication()
        // Behave as if the app had never been launched before.
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES", "-privacyInfoShown", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Privacy and Permissions"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "not shown at first launch")
        for text in ["Files you open or save", "Outgoing network connections"] {
            let predicate = NSPredicate(
                format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
            XCTAssertTrue(
                window.staticTexts.matching(predicate).firstMatch.exists, "missing: \(text)")
        }
        window.buttons["OK"].click()
        let closed = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: window)
        wait(for: [closed], timeout: 10)

        app.menuBars.menuBarItems["Help"].click()
        app.menuBars.menuItems["Privacy and Permissions…"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 10), "not shown from the Help menu")
    }
}
