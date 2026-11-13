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
}
