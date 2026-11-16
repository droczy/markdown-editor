import AppKit

/// Copies the address of a clicked link instead of opening it, and describes
/// what happened for the notice in the preview.
@MainActor
public enum LinkCopy {
    /// The short notice shown after a click on a link.
    public struct Notice: Equatable, Sendable {
        /// The main line, e.g. "Link copied: example.com".
        public let title: String
        /// The copied text or an explanation, shown smaller (optional).
        public let detail: String?
        /// Whether something was copied (shown with a different symbol).
        public let copied: Bool
    }

    /// User defaults key that records that the one-time explanation was
    /// shown.
    public static let hintShownKey = "linkCopyHintShown"

    /// Whether the explanation was shown in this session (also when the
    /// stored value cannot be changed, e.g. because a launch argument sets
    /// it).
    static var explainedThisSession = false

    /// Handles a click: copies web and email addresses to `pasteboard`
    /// (as plain text) and returns the notice to show. Task checkboxes are
    /// not handled here (`nil`).
    public static func handle(
        _ action: PreviewLinkAction, pasteboard: NSPasteboard = .general
    ) -> Notice? {
        switch action {
        case .copyWebAddress(let address, let host):
            copy(address, to: pasteboard)
            return Notice(title: "Link copied: \(host)", detail: address, copied: true)
        case .copyEmailAddress(let address):
            guard !address.isEmpty else {
                return Notice(
                    title: "This email link contains no address.", detail: nil, copied: false)
            }
            copy(address, to: pasteboard)
            return Notice(title: "Email address copied", detail: address, copied: true)
        case .unsupported:
            return Notice(
                title: "Links to other files or headings are not supported yet.", detail: nil,
                copied: false)
        case .blocked:
            return Notice(
                title: "Link blocked",
                detail: "Only web and email addresses can be copied.", copied: false)
        case .toggleTask:
            return nil
        }
    }

    private static func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Explains once, after the first copied link, that the editor never
    /// opens links. Later clicks only show the short notice.
    public static func explainOnce(
        in window: NSWindow?, defaults: UserDefaults = .standard,
        present: (NSAlert, NSWindow) -> Void = { alert, window in
            alert.beginSheetModal(for: window)
        }
    ) {
        guard !explainedThisSession, !defaults.bool(forKey: hintShownKey), let window else {
            return
        }
        explainedThisSession = true
        defaults.set(true, forKey: hintShownKey)
        present(makeHint(), window)
    }

    /// The one-time explanation.
    static func makeHint() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Links are copied, not opened"
        alert.informativeText =
            "For your safety, this editor never opens links. Clicking a link copies its "
            + "address, so you can paste it into your browser or email app. A short notice "
            + "at the bottom of the preview confirms each copy."
        alert.addButton(withTitle: "OK")
        return alert
    }
}
