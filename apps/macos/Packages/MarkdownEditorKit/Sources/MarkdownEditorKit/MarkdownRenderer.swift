import Foundation
import MarkdownEditorCore

/// Converts untrusted Markdown into sanitized HTML using the Rust core.
///
/// The returned HTML contains no scripts, no event handlers, no remote
/// resources and only links to `http`, `https`, `mailto` or relative targets.
/// It must still be displayed with JavaScript disabled (defence in depth).
public enum MarkdownRenderer {
    /// Reasons why a document cannot be rendered.
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// The document is larger than ``MarkdownRenderer/maxInputBytes``.
        case inputTooLarge(size: UInt64, limit: UInt64)
        /// The document nests elements deeper than
        /// ``MarkdownRenderer/maxNestingDepth``.
        case nestingTooDeep(depth: UInt64, limit: UInt64)
        /// An unexpected error inside the core, e.g. a caught panic. The app
        /// keeps running; the document is not affected.
        case internalError(String)

        /// A short explanation for the user.
        public var errorDescription: String? {
            switch self {
            case .inputTooLarge(let size, let limit):
                let format = ByteCountFormatter()
                return "The document is too large for the preview "
                    + "(\(format.string(fromByteCount: Int64(clamping: size))), "
                    + "limit \(format.string(fromByteCount: Int64(clamping: limit))))."
            case .nestingTooDeep(let depth, let limit):
                return "The document is nested too deeply for the preview "
                    + "(depth \(depth), limit \(limit))."
            case .internalError(let message):
                return "The preview could not be rendered: \(message)"
            }
        }
    }

    /// Largest document size in bytes that can be rendered.
    public static let maxInputBytes: UInt64 = MarkdownEditorCore.maxInputBytes()

    /// Deepest nesting of Markdown elements that can be rendered.
    public static let maxNestingDepth: UInt64 = MarkdownEditorCore.maxNestingDepth()

    /// Renders `markdown` off the calling actor, so that large documents
    /// never block the user interface.
    @concurrent
    public static func render(_ markdown: String) async throws(Failure) -> String {
        try renderSynchronously(markdown)
    }

    /// Renders `markdown` on the current thread.
    public static func renderSynchronously(_ markdown: String) throws(Failure) -> String {
        do {
            return try renderHtml(markdown: markdown)
        } catch let error as RenderError {
            switch error {
            case .InputTooLarge(let size, let limit):
                throw .inputTooLarge(size: size, limit: limit)
            case .NestingTooDeep(let depth, let limit):
                throw .nestingTooDeep(depth: depth, limit: limit)
            }
        } catch {
            throw .internalError(error.localizedDescription)
        }
    }
}
