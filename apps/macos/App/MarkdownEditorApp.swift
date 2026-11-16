import AppKit
import MarkdownEditorKit
import SwiftUI

@main
struct MarkdownEditorApp: App {
    /// Whether the privacy information was shown once already.
    @AppStorage(PrivacyInfoView.shownKey) private var privacyInfoShown = false

    init() {
        // No window tabs for now: every document has its own window, and the
        // View menu offers no tab commands. Worth reconsidering together with
        // the folder and file tree.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { file in
            ContentView(document: file.document)
        }
        .commands {
            TextZoomCommands()
            PrivacyInfoCommands()
        }

        // Shown at the first launch; afterwards from the Help menu.
        Window(PrivacyInfoView.title, id: PrivacyInfoView.windowID) {
            PrivacyInfoView()
                .onAppear { privacyInfoShown = true }
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(privacyInfoShown ? .suppressed : .presented)
    }
}
