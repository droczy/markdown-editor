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
        /// The document's syntax tree would have more than
        /// ``MarkdownRenderer/maxNodes`` nodes.
        case tooManyNodes(limit: UInt64)
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
            case .tooManyNodes(let limit):
                return "The document is too complex for the preview "
                    + "(more than \(limit.formatted()) elements)."
            case .internalError(let message):
                return "The preview could not be rendered: \(message)"
            }
        }
    }

    /// Largest document size in bytes that can be rendered.
    public static let maxInputBytes: UInt64 = MarkdownEditorCore.maxInputBytes()

    /// Deepest nesting of Markdown elements that can be rendered.
    public static let maxNestingDepth: UInt64 = MarkdownEditorCore.maxNestingDepth()

    /// Largest syntax tree, in nodes, that can be rendered.
    public static let maxNodes: UInt64 = MarkdownEditorCore.maxNodes()

    /// Base URL the preview page must be loaded with. Relative links resolve
    /// against it, which tells them apart from links to websites.
    public static let pageBaseURL: URL = {
        guard let url = URL(string: pageBaseUrl()) else {
            preconditionFailure("the core's page base URL is not a valid URL")
        }
        return url
    }()

    /// Content Security Policy of the preview page.
    public static let pageContentSecurityPolicy: String =
        MarkdownEditorCore
        .pageContentSecurityPolicy()

    /// Stylesheet embedded in the preview page.
    static let pageStylesheet: String = MarkdownEditorCore.pageStylesheet()

    /// Base64-encoded SHA-256 hash of ``pageStylesheet`` (as in the policy).
    static let pageStylesheetHash: String = MarkdownEditorCore.pageStylesheetHash()

    /// Renders `markdown` off the calling actor, so that large documents
    /// never block the user interface.
    @concurrent
    public static func render(_ markdown: String) async throws(Failure) -> String {
        try renderSynchronously(markdown)
    }

    /// Renders `markdown` to a complete HTML page for the preview, off the
    /// calling actor. The page carries a strict Content Security Policy and
    /// must be loaded with ``pageBaseURL``. With a `taskToken` (letters,
    /// digits and hyphens, e.g. a UUID), task checkboxes become links that
    /// the preview hands over as ``PreviewLinkAction/toggleTask(token:index:)``.
    @concurrent
    public static func renderPage(_ markdown: String, taskToken: String? = nil)
        async throws(Failure) -> String
    {
        try convertingErrors {
            try MarkdownEditorCore.renderPage(markdown: markdown, taskToken: taskToken)
        }
    }

    /// An edit that checks or unchecks one task: replace the single byte at
    /// `utf8Offset` with `replacement`.
    public struct TaskEdit: Equatable, Sendable {
        /// Offset of the character between the brackets, in UTF-8 bytes.
        public let utf8Offset: Int
        /// `"x"` to check, `" "` to uncheck.
        public let replacement: String
    }

    /// The edit that checks or unchecks the task with `index` (in document
    /// order) in `markdown`, or `nil` if there is no such task.
    public static func taskEdit(in markdown: String, index: Int) -> TaskEdit? {
        guard index >= 0,
            let toggle = MarkdownEditorCore.toggleTask(markdown: markdown, index: UInt64(index)),
            let offset = Int(exactly: toggle.offset)
        else { return nil }
        return TaskEdit(utf8Offset: offset, replacement: toggle.replacement)
    }

    /// Renders `markdown` on the current thread.
    public static func renderSynchronously(_ markdown: String) throws(Failure) -> String {
        try convertingErrors { try renderHtml(markdown: markdown) }
    }

    private static func convertingErrors(_ body: () throws -> String) throws(Failure) -> String {
        do {
            return try body()
        } catch let error as RenderError {
            switch error {
            case .InputTooLarge(let size, let limit):
                throw .inputTooLarge(size: size, limit: limit)
            case .NestingTooDeep(let depth, let limit):
                throw .nestingTooDeep(depth: depth, limit: limit)
            case .TooManyNodes(let limit):
                throw .tooManyNodes(limit: limit)
            }
        } catch {
            throw .internalError(error.localizedDescription)
        }
    }
}
