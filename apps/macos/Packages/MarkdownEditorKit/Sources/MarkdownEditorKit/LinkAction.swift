import Foundation
import MarkdownEditorCore

/// What the preview does when the user clicks a link. Links are never
/// opened: web and email addresses are copied to the clipboard.
public enum PreviewLinkAction: Equatable, Sendable {
    /// Copy `address` (an `http` or `https` link); `host` is shown.
    case copyWebAddress(address: String, host: String)
    /// Copy the email address of a `mailto` link (may be empty).
    case copyEmailAddress(String)
    /// A click on a task checkbox: check or uncheck the task with `index`,
    /// if `token` is the one of the shown page.
    case toggleTask(token: String, index: Int)
    /// A relative link to another file or a heading: not supported yet.
    case unsupported
    /// Any other kind of address: neither opened nor copied.
    case blocked

    /// Decides what to do with a link that the web view resolved to `url`.
    /// The decision is made by the Rust core, so that every platform behaves
    /// the same; the text to copy comes from the core, already checked.
    public init(resolvedURL url: URL) {
        switch MarkdownEditorCore.linkAction(url: url.absoluteString) {
        case .copyWebAddress(let address, let host):
            self = .copyWebAddress(address: address, host: host)
        case .copyEmailAddress(let address):
            self = .copyEmailAddress(address)
        case .toggleTask(let token, let index):
            self = Int(exactly: index).map { .toggleTask(token: token, index: $0) } ?? .blocked
        case .unsupported:
            self = .unsupported
        case .blocked:
            self = .blocked
        }
    }
}
