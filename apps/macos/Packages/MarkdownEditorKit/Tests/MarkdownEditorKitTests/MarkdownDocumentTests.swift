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
        "File bytes survive a load/save round trip exactly",
        arguments: [
            "",
            "# Title\n\nText\n",
            "no final newline",
            "windows\r\nline\r\nendings\r\n",
            "old mac\rline endings\r",
            "mixed\nline\r\nendings\r",
            "\u{FEFF}byte order mark\n",
            "Grüße 🌍 日本語 مرحبا e\u{301}\n",
            "trailing spaces   \n\t\n",
            "\n\n\nonly blank lines\n\n\n",
        ]
    )
    func byteExactRoundTrip(text: String) throws {
        let original = Data(text.utf8)
        let saved = try MarkdownDocument(data: original).data()
        #expect(saved == original)
    }

    @Test(
        "Invalid UTF-8 is rejected instead of being altered",
        arguments: [
            Data([0x61, 0xFF, 0xFE, 0x62]),  // invalid bytes
            Data([0xC3]),  // truncated sequence
            Data([0xED, 0xA0, 0x80]),  // UTF-16 surrogate encoded as UTF-8
            Data([0xC0, 0xAF]),  // overlong encoding of "/"
            Data("Grüße".data(using: .isoLatin1) ?? Data()),  // Latin-1 file
            Data([0xFF, 0xFE, 0x61, 0x00]),  // UTF-16 LE with BOM
        ]
    )
    func invalidUTF8IsRejected(data: Data) {
        #expect(throws: DocumentError.notUTF8) {
            try MarkdownDocument(data: data)
        }
    }

    @Test("Files up to the size limit can be opened")
    func fileAtLimitOpens() throws {
        let data = Data(repeating: 0x61, count: MarkdownDocument.maxFileBytes)
        #expect(try MarkdownDocument(data: data).text.utf8.count == MarkdownDocument.maxFileBytes)
    }

    @Test("Files above the size limit are rejected")
    func fileAboveLimitIsRejected() {
        let size = MarkdownDocument.maxFileBytes + 1
        #expect(
            throws: DocumentError.fileTooLarge(size: size, limit: MarkdownDocument.maxFileBytes)
        ) {
            try MarkdownDocument(data: Data(repeating: 0x61, count: size))
        }
    }

    @Test("The size limit is 50 MiB")
    func sizeLimit() {
        #expect(MarkdownDocument.maxFileBytes == 50 * 1024 * 1024)
    }

    @Test("Errors explain the problem and how to resolve it")
    func errorMessages() {
        let errors: [DocumentError] = [
            .fileTooLarge(size: 60_000_000, limit: 52_428_800), .notUTF8, .notARegularFile,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
            #expect(error.failureReason == error.errorDescription)
        }
        #expect(DocumentError.notUTF8.errorDescription?.contains("UTF-8") == true)
        #expect(DocumentError.notUTF8.recoverySuggestion?.contains("not been changed") == true)
    }

    @Test("Markdown and plain text can be opened and saved")
    func contentTypes() {
        #expect(MarkdownDocument.readableContentTypes == [.markdownText, .plainText])
        #expect(MarkdownDocument.writableContentTypes == [.markdownText, .plainText])
    }

    @Test("Markdown type is recognised for .md and .markdown")
    func markdownTypeMatchesExtensions() throws {
        for fileExtension in ["md", "markdown"] {
            let type = try #require(UTType(filenameExtension: fileExtension))
            #expect(type == .markdownText || type.conforms(to: .markdownText))
        }
    }
}
