import SwiftUI

/// Explains which permissions the app has and what it never does. Shown once
/// at the first launch and later from the Help menu, because macOS itself
/// does not ask for these permissions.
public struct PrivacyInfoView: View {
    /// Identifier of the window.
    public static let windowID = "privacy"
    /// User defaults key that records that the window was shown.
    public static let shownKey = "privacyInfoShown"
    /// Title of the window and the Help menu item.
    public static let title = "Privacy and Permissions"

    @Environment(\.dismiss) private var dismiss

    /// Creates the view.
    public init() {}

    /// The explanation and an OK button.
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This app works offline. macOS gives it these permissions:")
                .font(.headline)

            permission(
                "Files you open or save",
                systemImage: "doc.text",
                text: "Read and write access only to the files you choose in an Open or Save "
                    + "dialog or open with the app. It cannot see any of your other files.")

            permission(
                "Outgoing network connections",
                systemImage: "network",
                text: "Required by WebKit, the part of macOS that shows the preview: it does not "
                    + "start without this permission, even though the app loads nothing from "
                    + "the internet. The preview blocks every attempt to load content, and the "
                    + "app's own code contains no networking functions (checked automatically).")

            VStack(alignment: .leading, spacing: 6) {
                Text("What the app never does").font(.headline)
                Text(
                    "Send your documents or any other data anywhere, open links, load images, "
                        + "fonts or scripts from the internet, run scripts from documents, or "
                        + "collect usage statistics.")
                Text(
                    "Links in your documents are never opened: clicking one copies its address, "
                        + "so you can paste it into your browser or email app yourself.")
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func permission(_ title: String, systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Help menu item that opens ``PrivacyInfoView``.
public struct PrivacyInfoCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    /// Creates the command.
    public init() {}

    /// The menu item.
    public var body: some Commands {
        CommandGroup(after: .help) {
            Button(PrivacyInfoView.title + "…") { openWindow(id: PrivacyInfoView.windowID) }
        }
    }
}
