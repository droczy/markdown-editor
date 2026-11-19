import XCTest

/// The zoom level of editor and preview is kept after quitting and launching
/// the app again.
///
/// Uses the app's stored settings, because a launch argument would pin the
/// zoom level for the whole run. The test ends at the normal size.
@MainActor
final class ZoomPersistenceTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZoomPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    private var app = XCUIApplication?.none

    override func setUp() async throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Launches `app` without restored windows, first-launch window or link
    /// explanation.
    private func launch(_ app: XCUIApplication) {
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-privacyInfoShown", "YES",
            "-linkCopyHintShown", "YES",
        ]
        app.launch()
        // Dismiss the open panel DocumentGroup may show at launch.
        app.typeKey(.escape, modifierFlags: [])
    }

    func testZoomIsKeptAfterQuitAndRelaunch() throws {
        let url = directory.appendingPathComponent("zoom.md")
        try Data("# Zoom\n".utf8).write(to: url)
        let app = try XCTUnwrap(app, "setUp did not create the app")
        let heading = app.webViews.firstMatch.staticTexts["Zoom"].firstMatch
        let actualSize = app.menuBars.menuItems["Actual Size"]

        launch(app)
        openInAppUnderTest(url, app: app)
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "preview did not show the file")
        app.typeKey("0", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let normal = heading.frame.height
        // Two steps: about 26 % larger.
        app.typeKey("+", modifierFlags: .command)
        app.typeKey("+", modifierFlags: .command)
        XCTAssertTrue(waitUntil { heading.frame.height > normal * 1.2 }, "did not zoom in")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let zoomed = heading.frame.height

        // Quit the way the user does; the file is unchanged, so nothing asks.
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "the app did not quit")

        launch(app)
        openInAppUnderTest(url, app: app)
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "preview did not show the file")
        XCTAssertTrue(
            waitUntil { abs(heading.frame.height - zoomed) < 1 },
            "zoom not kept: \(heading.frame.height), expected \(zoomed) (normal \(normal))")
        XCTAssertTrue(actualSize.isEnabled, "Actual Size is disabled, so the zoom was reset")

        // Leave the normal size behind for later runs and other tests.
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(waitUntil { abs(heading.frame.height - normal) < 1 }, "zoom was not reset")
    }
}
