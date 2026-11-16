import Foundation
import MarkdownEditorCore

/// What the preview does when the user clicks a link.
public enum PreviewLinkAction: Equatable, Sendable {
    /// Open in the default browser, after the user confirmed it.
    case openInBrowser(host: String)
    /// Open the default email app, after the user confirmed it.
    case openInEmailApp(recipients: String)
    /// A relative link to another file or a heading: not supported yet.
    case unsupported
    /// Any other kind of address: never opened.
    case blocked

    /// Decides what to do with a link that the web view resolved to `url`.
    /// The decision is made by the Rust core, so that every platform behaves
    /// the same.
    public init(resolvedURL url: URL) {
        switch MarkdownEditorCore.linkAction(url: url.absoluteString) {
        case .openInBrowser(let host):
            self = .openInBrowser(host: host)
        case .openInEmailApp(let recipients):
            self = .openInEmailApp(recipients: recipients)
        case .unsupported:
            self = .unsupported
        case .blocked:
            self = .blocked
        }
    }
}
