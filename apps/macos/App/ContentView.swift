import MarkdownEditorKit
import SwiftUI

/// Placeholder editor for the app skeleton. Replaced by the plain-text editor
/// and the sanitized preview in a later step.
struct ContentView: View {
    @Binding var document: MarkdownDocument

    var body: some View {
        TextEditor(text: $document.text)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .accessibilityIdentifier("editor")
            .frame(minWidth: 600, minHeight: 400)
    }
}
