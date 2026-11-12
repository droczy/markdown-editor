import Foundation
import Testing
import UniformTypeIdentifiers

@testable import MarkdownEditorKit

@Suite("MarkdownDocument")
struct MarkdownDocumentTests {
    @Test("New documents are empty")
    func newDocumentIsEmpty() {
        #expect(MarkdownDocument().text.isEmpty)
    }

    @Test(
        "Text survives a save/load round trip unchanged",
        arguments: ["", "# Title\n\nText", "Grüße 🌍 日本語", "line\r\nwindows", "\u{FEFF}bom"]
    )
    func roundTrip(text: String) throws {
        let loaded = try MarkdownDocument(data: MarkdownDocument(text: text).data())
        #expect(loaded.text == text)
    }

    @Test("Invalid UTF-8 is rejected instead of being altered")
    func invalidUTF8IsRejected() {
        let invalid = Data([0x61, 0xFF, 0xFE, 0x62])
        #expect(throws: CocoaError.self) {
            try MarkdownDocument(data: invalid)
        }
    }

    @Test("Markdown type is recognised for .md and .markdown")
    func markdownTypeMatchesExtensions() throws {
        let declaredType = UTType.markdownText.identifier
        for fileExtension in ["md", "markdown"] {
            let type = try #require(UTType(filenameExtension: fileExtension))
            #expect(type.identifier == declaredType || type.conforms(to: .markdownText))
        }
    }
}
