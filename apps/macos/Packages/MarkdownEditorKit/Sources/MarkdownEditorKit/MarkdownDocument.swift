import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Markdown files (`.md`, `.markdown`). Declared as an imported type in
    /// the app's Info.plist.
    public static let markdownText = UTType(importedAs: "net.daringfireball.markdown")
}

/// A Markdown document: UTF-8 text on disk, a `String` in memory.
///
/// Saving is handled by the system document architecture, which writes
/// atomically (to a temporary file that then replaces the original).
public struct MarkdownDocument: FileDocument, Sendable {
    /// Types the app can open: Markdown and any other plain text.
    public static let readableContentTypes: [UTType] = [.markdownText, .plainText]
    /// Types the app saves: always Markdown.
    public static let writableContentTypes: [UTType] = [.markdownText]

    /// The document's Markdown source.
    public var text: String

    /// Creates a document with the given Markdown source.
    public init(text: String = "") {
        self.text = text
    }

    /// Reads a document from disk. Called by the document system.
    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: data)
    }

    /// Decodes UTF-8 data. Invalid UTF-8 is rejected instead of being
    /// silently replaced, so that saving can never corrupt a file. A byte
    /// order mark is kept (`String(data:encoding:)` would drop it and thereby
    /// change the file on the next save).
    public init(data: Data) throws {
        guard let text = String(validating: data, as: UTF8.self) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    /// Serializes the document for saving. Called by the document system.
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data())
    }

    /// The UTF-8 encoded file contents.
    public func data() -> Data {
        Data(text.utf8)
    }
}
