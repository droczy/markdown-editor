import MarkdownEditorKit
import SwiftUI

/// Content of a document window.
struct ContentView: View {
    @ObservedObject var document: MarkdownDocument

    var body: some View {
        DocumentEditorView(text: $document.text)
    }
}
