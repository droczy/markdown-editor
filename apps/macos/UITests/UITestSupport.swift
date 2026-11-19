import XCTest

/// Helpers shared by the UI tests.
@MainActor
extension XCTestCase {
    /// Opens `url` in exactly the app under test and brings `app` to the
    /// front. `XCUIApplication.open(_:)` would use the system's default app
    /// for the file type, which differs between machines (e.g. `.txt`
    /// opening in another editor).
    func openInAppUnderTest(_ url: URL, app: XCUIApplication) {
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("MarkdownEditor.app")
        let opened = expectation(description: "open \(url.lastPathComponent)")
        NSWorkspace.shared.open(
            [url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        app.activate()
    }

    /// Polls `condition` for up to ten seconds; returns whether it became
    /// true.
    func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
