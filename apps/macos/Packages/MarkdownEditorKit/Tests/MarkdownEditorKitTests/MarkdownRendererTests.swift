import Foundation
import Testing

@testable import MarkdownEditorKit

/// Tests across the Swift/Rust boundary. Rendering details are covered by the
/// Rust test suite; these tests verify that values and errors cross the
/// boundary intact.
@Suite("MarkdownRenderer")
struct MarkdownRendererTests {
    @Test("Renders Markdown to HTML")
    func rendersMarkdown() async throws {
        let html = try await MarkdownRenderer.render("# Hello *world*")
        #expect(html == "<h1>Hello <em>world</em></h1>\n")
    }

    @Test(
        "Text survives the boundary unchanged",
        arguments: ["Grüße", "🌍👨‍👩‍👧", "日本語", "مرحبا", "e\u{301}"]
    )
    func unicodeRoundTrip(text: String) throws {
        let html = try MarkdownRenderer.renderSynchronously(text)
        #expect(html == "<p>\(text)</p>\n")
    }

    @Test("NUL characters are replaced as required by CommonMark")
    func nulIsReplaced() throws {
        #expect(try MarkdownRenderer.renderSynchronously("a\u{0}b") == "<p>a\u{FFFD}b</p>\n")
    }

    @Test(
        "Attack payloads produce safe HTML",
        arguments: [
            "<script>alert(1)</script>",
            "[x](javascript:alert(1))",
            "![x](https://evil.example/t.png)",
            "<img src=x onerror=alert(1)>",
        ]
    )
    func payloadsAreNeutralized(payload: String) throws {
        let html = try MarkdownRenderer.renderSynchronously(payload).lowercased()
        // Escaped payloads may appear as visible text (`&lt;script&gt;`);
        // only real tags and attributes are dangerous.
        #expect(!html.contains("<script"))
        #expect(!html.contains("href=\"javascript:"))
        #expect(html.firstMatch(of: /<[^>]*\son[a-z]+=/) == nil)
        #expect(!html.contains("src=\"https://"))
    }

    @Test("Too large input is reported as a typed error")
    func inputTooLarge() {
        let limit = MarkdownRenderer.maxInputBytes
        let markdown = String(repeating: "a", count: Int(limit) + 1)
        #expect(throws: MarkdownRenderer.Failure.inputTooLarge(size: limit + 1, limit: limit)) {
            try MarkdownRenderer.renderSynchronously(markdown)
        }
    }

    @Test("Too deep nesting is reported as a typed error")
    func nestingTooDeep() {
        let markdown = String(repeating: ">", count: 2_000) + "x"
        do {
            _ = try MarkdownRenderer.renderSynchronously(markdown)
            Issue.record("expected an error")
        } catch {
            guard case .nestingTooDeep(_, let limit) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(limit == MarkdownRenderer.maxNestingDepth)
        }
    }

    @Test("Too complex documents are reported as a typed error")
    func tooManyNodes() {
        // Short rows are filled up to the header width.
        let table =
            String(repeating: "|a", count: 500) + "|\n" + String(repeating: "|-", count: 500)
            + "|\n" + String(repeating: "x\n", count: 1_000) + "\n"
        let markdown = String(repeating: table, count: 10)
        #expect(throws: MarkdownRenderer.Failure.tooManyNodes(limit: MarkdownRenderer.maxNodes)) {
            try MarkdownRenderer.renderSynchronously(markdown)
        }
    }

    @Test("Errors have readable descriptions")
    func errorDescriptions() {
        let tooDeep = MarkdownRenderer.Failure.nestingTooDeep(depth: 5, limit: 3)
        #expect(
            tooDeep.errorDescription
                == "The document is nested too deeply for the preview (depth 5, limit 3).")
        let tooLarge = MarkdownRenderer.Failure.inputTooLarge(size: 20_000_000, limit: 10_485_760)
        #expect(tooLarge.errorDescription?.contains("too large") == true)
        let tooComplex = MarkdownRenderer.Failure.tooManyNodes(limit: 2_000_000)
        #expect(tooComplex.errorDescription?.hasPrefix("The document is too complex") == true)
        #expect(tooComplex.errorDescription?.contains(2_000_000.formatted()) == true)
    }

    @Test("Concurrent rendering from many tasks is safe and consistent")
    func concurrentRendering() async throws {
        let inputs = (0..<200).map { "# Document \($0)\n\n- item **\($0)**" }
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, input) in inputs.enumerated() {
                group.addTask { (index, try await MarkdownRenderer.render(input)) }
            }
            var results = [Int: String]()
            for try await (index, html) in group {
                results[index] = html
            }
            return results
        }
        for (index, input) in inputs.enumerated() {
            #expect(results[index] == (try MarkdownRenderer.renderSynchronously(input)))
        }
    }

    @Test("Limits are exposed from the core")
    func limits() {
        #expect(MarkdownRenderer.maxInputBytes == 10 * 1024 * 1024)
        #expect(MarkdownRenderer.maxNestingDepth == 1_000)
        #expect(MarkdownRenderer.maxNodes == 2_000_000)
    }
}
