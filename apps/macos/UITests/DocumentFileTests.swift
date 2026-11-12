import XCTest

/// End-to-end tests with real files: what is on disk after opening, editing,
/// saving and closing must be exactly what the user expects.
///
/// Main-actor isolated as a whole: UI automation APIs must run on the main
/// thread (enforced by the XCTest version used in CI).
@MainActor
final class DocumentFileTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DocumentFileTests-\(UUID().uuidString)", isDirectory: true)
    private var app = XCUIApplication?.none

    override func setUp() async throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        self.app = app
        // Start without windows restored from earlier test runs.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        // Dismiss the open panel DocumentGroup may show at launch.
        app.typeKey(.escape, modifierFlags: [])
    }

    override func tearDown() async throws {
        app?.terminate()
        // Restore write permission so read-only fixtures can be deleted.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in files {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: directory.appendingPathComponent(file).path)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// The app launched in `setUp`.
    private var launchedApp: XCUIApplication {
        guard let app else {
            preconditionFailure("setUp did not launch the app")
        }
        return app
    }

    private func fixture(_ name: String, bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func fixture(_ name: String, text: String) throws -> URL {
        try fixture(name, bytes: Data(text.utf8))
    }

    /// Sends `url` to exactly the app under test. `XCUIApplication.open(_:)`
    /// would use the system's default app for the file type, which differs
    /// between machines (e.g. `.txt` opening in another editor).
    private func send(_ url: URL) throws {
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
        launchedApp.activate()
    }

    /// Opens `url` in the app under test and returns its editor.
    private func open(_ url: URL) throws -> XCUIElement {
        try send(url)
        let editor = launchedApp.textViews["editor"].firstMatch
        XCTAssertTrue(
            editor.waitForExistence(timeout: 10),
            "editor did not appear for \(url.lastPathComponent)")
        return editor
    }

    /// Appends `text` at the very end of the document.
    private func append(_ text: String, to editor: XCUIElement) {
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText(text)
    }

    private func contents(of url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Waits until the file at `url` contains `expected`.
    private func waitForContents(of url: URL, toEqual expected: Data, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? Data(contentsOf: url)) == expected { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let actual =
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
            ?? "<unreadable>"
        XCTFail(
            "file content \(actual.debugDescription) != \(String(decoding: expected, as: UTF8.self).debugDescription)"
        )
    }

    /// Returns true if any alert, sheet or dialog shows a text containing `fragment`.
    private func errorIsShown(containing fragment: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(
            format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", fragment, fragment)
        return launchedApp.staticTexts.matching(predicate).firstMatch.waitForExistence(
            timeout: timeout)
    }

    // MARK: - Tests

    @MainActor
    func testEditAndSaveWritesExactlyTheEditedText() throws {
        let url = try fixture("note.md", text: "# Original\n")
        let editor = try open(url)
        XCTAssertEqual(editor.value as? String, "# Original\n")

        append("more", to: editor)
        launchedApp.typeKey("s", modifierFlags: .command)

        waitForContents(of: url, toEqual: Data("# Original\nmore".utf8))
    }

    @MainActor
    func testClosingAutosavesWithoutAsking() throws {
        let url = try fixture("autosave.md", text: "start\n")
        let editor = try open(url)
        append("typed", to: editor)

        launchedApp.typeKey("w", modifierFlags: .command)

        XCTAssertFalse(
            launchedApp.sheets.firstMatch.waitForExistence(timeout: 2), "closing asked to save")
        waitForContents(of: url, toEqual: Data("start\ntyped".utf8))
    }

    @MainActor
    func testWindowsLineEndingsArePreservedWhenEditing() throws {
        let url = try fixture("crlf.md", text: "line one\r\nline two\r\n")
        let editor = try open(url)
        append("three", to: editor)
        launchedApp.typeKey("s", modifierFlags: .command)

        waitForContents(of: url, toEqual: Data("line one\r\nline two\r\nthree".utf8))
    }

    @MainActor
    func testPlainTextFileKeepsItsName() throws {
        let url = try fixture("notes.txt", text: "plain\n")
        let editor = try open(url)
        append("text", to: editor)
        launchedApp.typeKey("s", modifierFlags: .command)

        waitForContents(of: url, toEqual: Data("plain\ntext".utf8))
        // No Markdown copy may appear next to it. Other entries are not
        // checked: atomic saving briefly creates a temporary file in the same
        // folder, which made an exact listing flaky on slower machines.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains("notes.txt"))
        XCTAssertFalse(names.contains { $0.hasSuffix(".md") }, "unexpected Markdown file: \(names)")
    }

    @MainActor
    func testNonUTF8FileIsRejectedAndLeftUnchanged() throws {
        let latin1 = try XCTUnwrap("Grüße".data(using: .isoLatin1))
        let url = try fixture("latin1.md", bytes: latin1)
        try send(url)

        XCTAssertTrue(errorIsShown(containing: "UTF-8"), "no UTF-8 error shown")
        XCTAssertFalse(launchedApp.textViews["editor"].exists)
        XCTAssertEqual(try contents(of: url), latin1)
    }

    @MainActor
    func testTooLargeFileIsRejectedAndLeftUnchanged() throws {
        let bytes = Data(repeating: 0x61, count: 50 * 1024 * 1024 + 1)
        let url = try fixture("huge.md", bytes: bytes)
        try send(url)

        XCTAssertTrue(errorIsShown(containing: "too large"), "no size error shown")
        XCTAssertFalse(launchedApp.textViews["editor"].exists)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, bytes.count)
    }

    @MainActor
    func testExternalChangeIsNotSilentlyOverwritten() throws {
        let url = try fixture("conflict.md", text: "base\n")
        let editor = try open(url)
        append("local", to: editor)

        let external = Data("external edit\n".utf8)
        try external.write(to: url)
        launchedApp.typeKey("s", modifierFlags: .command)

        // Either the system asks how to resolve the conflict, or it keeps the
        // external version; in no case may the external edit be lost silently.
        let asked =
            launchedApp.sheets.firstMatch.waitForExistence(timeout: 5)
            || launchedApp.dialogs.firstMatch.waitForExistence(timeout: 1)
        if !asked {
            XCTAssertEqual(
                try contents(of: url), external, "external edit was overwritten silently")
        }
    }

    @MainActor
    func testExternalChangeIsNotSilentlyOverwrittenOnClose() throws {
        let url = try fixture("conflict-close.md", text: "base\n")
        let editor = try open(url)
        append("local", to: editor)

        let external = Data("external edit\n".utf8)
        try external.write(to: url)
        launchedApp.typeKey("w", modifierFlags: .command)

        let asked =
            launchedApp.sheets.firstMatch.waitForExistence(timeout: 5)
            || launchedApp.dialogs.firstMatch.waitForExistence(timeout: 1)
        if !asked {
            XCTAssertEqual(
                try contents(of: url), external, "external edit was overwritten silently")
        }
    }

    @MainActor
    func testReadOnlyFileIsNotModified() throws {
        let url = try fixture("readonly.md", text: "protected\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let editor = try open(url)
        append("attempt", to: editor)
        launchedApp.typeKey("s", modifierFlags: .command)

        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(try contents(of: url), Data("protected\n".utf8))
    }
}
