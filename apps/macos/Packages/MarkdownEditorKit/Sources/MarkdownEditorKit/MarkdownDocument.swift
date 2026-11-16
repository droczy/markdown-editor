import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

extension UTType {
    /// Markdown files (`.md`, `.markdown`). Declared as an imported type in
    /// the app's Info.plist.
    public static let markdownText = UTType(importedAs: "net.daringfireball.markdown")
}

/// A Markdown document: UTF-8 text on disk, a `String` in memory.
///
/// Saving is handled by the system document architecture: it writes
/// atomically (to a temporary file that then replaces the original), autosaves
/// in place and keeps versions. The bytes of the file are preserved exactly:
/// line endings, a missing final newline and a byte order mark survive a
/// load/save round trip unchanged.
///
/// A reference type, so that the editor's own undo registrations are the only
/// ones: they mark the document as edited, and one ⌘Z undoes one typing
/// step. (With a value type, SwiftUI registers an extra undo step for every
/// keystroke and keeps a full copy of the text for each.)
@MainActor
public final class MarkdownDocument: ReferenceFileDocument {
    /// Types the app can open: Markdown and any other plain text.
    public nonisolated static let readableContentTypes: [UTType] = [.markdownText, .plainText]

    /// Types the app can save. New documents are Markdown; opened plain-text
    /// files keep their type (a `.txt` file is not renamed to `.md`).
    public nonisolated static let writableContentTypes: [UTType] = [.markdownText, .plainText]

    /// Largest file that can be opened (50 MiB). Larger files are rejected
    /// before they are decoded, so they cannot make the app unresponsive.
    public nonisolated static let maxFileBytes = 50 * 1024 * 1024

    /// Announces changes to SwiftUI (`ObservableObject`). Combine's
    /// publisher is thread-safe; it is only sent from the main actor.
    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    /// The document's Markdown source. Changed by the editor; changes are
    /// registered for undo by the editor, not here.
    public var text: String {
        willSet { objectWillChange.send() }
        didSet {
            let text = text
            textForSaving.withLock { $0 = text }
        }
    }

    /// The latest text for ``snapshot(contentType:)``, which the document
    /// system calls on a background thread while saving. Copying a `String`
    /// only copies a reference, so keeping it up to date costs nothing.
    private nonisolated let textForSaving: OSAllocatedUnfairLock<String>

    /// Creates a document with the given Markdown source.
    public nonisolated init(text: String = "") {
        self.text = text
        textForSaving = OSAllocatedUnfairLock(initialState: text)
    }

    /// Reads a document from disk. Called by the document system.
    public nonisolated convenience init(configuration: ReadConfiguration) throws {
        let file = configuration.file
        // Check the size reported by the file system first, so oversized
        // files are rejected without decoding them.
        if let size = (file.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber)?.intValue,
            size > Self.maxFileBytes
        {
            throw DocumentError.fileTooLarge(size: size, limit: Self.maxFileBytes)
        }
        guard let data = file.regularFileContents else {
            throw DocumentError.notARegularFile
        }
        try self.init(data: data)
    }

    /// Decodes UTF-8 data. Invalid UTF-8 is rejected instead of being
    /// silently replaced, so that saving can never corrupt a file. A byte
    /// order mark is kept (`String(data:encoding:)` would drop it and thereby
    /// change the file on the next save).
    public nonisolated convenience init(data: Data) throws(DocumentError) {
        guard data.count <= Self.maxFileBytes else {
            throw .fileTooLarge(size: data.count, limit: Self.maxFileBytes)
        }
        guard let text = String(validating: data, as: UTF8.self) else {
            throw .notUTF8
        }
        self.init(text: text)
    }

    /// The contents to save. Called by the document system, also on
    /// background threads (autosave).
    public nonisolated func snapshot(contentType: UTType) throws -> Data {
        Data(textForSaving.withLock { $0 }.utf8)
    }

    /// Serializes a snapshot for saving. Called by the document system.
    public nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws
        -> FileWrapper
    {
        FileWrapper(regularFileWithContents: snapshot)
    }

    /// The UTF-8 encoded file contents.
    public func data() -> Data {
        Data(text.utf8)
    }
}

/// Reasons why a file cannot be opened. The descriptions are shown to the
/// user by the system's error alert.
public enum DocumentError: Error, Equatable, Sendable, LocalizedError {
    /// The file is larger than ``MarkdownDocument/maxFileBytes``.
    case fileTooLarge(size: Int, limit: Int)
    /// The file is not valid UTF-8 text.
    case notUTF8
    /// The item is not a regular file (e.g. a folder or package).
    case notARegularFile

    /// What went wrong.
    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size, let limit):
            let format = ByteCountFormatter()
            return "The file is too large to open "
                + "(\(format.string(fromByteCount: Int64(size))), "
                + "limit \(format.string(fromByteCount: Int64(limit))))."
        case .notUTF8:
            return "The file is not valid UTF-8 text."
        case .notARegularFile:
            return "The item is not a regular file."
        }
    }

    /// Shown by the system's "could not be opened" alert after its own
    /// message, so the actual reason is visible at a glance.
    public var failureReason: String? {
        errorDescription
    }

    /// How the user can resolve the problem.
    public var recoverySuggestion: String? {
        switch self {
        case .fileTooLarge:
            return "Split the document into smaller files."
        case .notUTF8:
            return "Convert the file to UTF-8 in another application and open it again. "
                + "The file has not been changed."
        case .notARegularFile:
            return "Choose a Markdown or plain-text file."
        }
    }
}
