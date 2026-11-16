import AppKit

/// Asks the user before a link from the preview leaves the app.
///
/// The dialog shows the full address and, separately, the host it really
/// leads to. The default button (Return) is "Cancel", so a stray key press
/// never opens anything.
@MainActor
public enum LinkConfirmation {
    /// Handles a click on a link that resolved to `url`: asks before opening
    /// web and email links, explains why other links do nothing. Without a
    /// window to attach the dialog to, nothing happens (fail closed).
    public static func handle(
        _ url: URL, in window: NSWindow?,
        open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        guard let window else { return }
        let action = PreviewLinkAction(resolvedURL: url)
        guard let alert = makeAlert(for: action, url: url) else { return }
        let opens: Bool
        switch action {
        case .openInBrowser, .openInEmailApp:
            opens = true
        case .toggleTask, .unsupported, .blocked:
            opens = false
        }
        var escapeMonitor: Any?
        alert.beginSheetModal(for: window) { response in
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
            if opens && response == .alertSecondButtonReturn {
                open(url)
            }
        }
        // NSAlert assigns key equivalents while it presents the sheet, so the
        // keys are set up afterwards: Return clicks the first button (the
        // default button), Escape ends the sheet like that button.
        guard let first = alert.buttons.first else { return }
        alert.window.defaultButtonCell = first.cell as? NSButtonCell
        let sheet = alert.window
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == escapeKeyCode, event.window === sheet else { return event }
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            return nil
        }
    }

    /// Virtual key code of the Escape key.
    private static let escapeKeyCode: UInt16 = 53

    /// The dialog for `action`. For links that may be opened, the first
    /// button is "Cancel" (default) and the second "Open". Task checkboxes
    /// get no dialog (`nil`); the editor handles them.
    static func makeAlert(for action: PreviewLinkAction, url: URL) -> NSAlert? {
        let alert = NSAlert()
        switch action {
        case .toggleTask:
            return nil
        case .openInBrowser(let host):
            alert.messageText = "Open “\(host)” in your browser?"
            alert.informativeText = "The link leads to this address:\n\n\(url.absoluteString)"
            addCancelAndOpenButtons(to: alert)
        case .openInEmailApp(let recipients):
            alert.messageText =
                recipients.isEmpty
                ? "Write an email?" : "Write an email to “\(recipients)”?"
            alert.informativeText =
                "The link opens your email app with this address:\n\n\(url.absoluteString)"
            addCancelAndOpenButtons(to: alert)
        case .unsupported:
            alert.messageText = "Links to other files or headings are not supported yet."
            alert.informativeText = "Only links to websites and email addresses can be opened."
            alert.addButton(withTitle: "OK")
        case .blocked:
            alert.alertStyle = .warning
            alert.messageText = "This link can’t be opened."
            alert.informativeText =
                "For your safety, the app opens only web addresses (http, https) "
                + "and email addresses (mailto)."
            alert.addButton(withTitle: "OK")
        }
        return alert
    }

    /// "Cancel" first, so that Return and Escape both cancel (see
    /// ``handle(_:in:open:)``); "Open" has no key equivalent and must be
    /// clicked.
    private static func addCancelAndOpenButtons(to alert: NSAlert) {
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open").keyEquivalent = ""
    }
}
