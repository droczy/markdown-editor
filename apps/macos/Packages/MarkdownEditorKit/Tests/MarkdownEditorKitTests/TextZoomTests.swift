import AppKit
import Testing

@testable import MarkdownEditorKit

@Suite("Text zoom")
struct TextZoomTests {
    @Test("Zooming steps through the levels and stops at the ends")
    func steps() throws {
        let step = pow(2, 1.0 / 6)
        #expect(try #require(TextZoom.larger(than: 1)) == step)
        #expect(try #require(TextZoom.smaller(than: 1)) == 1 / step)
        #expect(TextZoom.levels.contains(1))
        #expect(TextZoom.levels.contains(2))
        #expect(TextZoom.levels.first == 0.5)
        #expect(TextZoom.larger(than: try #require(TextZoom.levels.last)) == nil)
        #expect(TextZoom.smaller(than: 0.5) == nil)
        // Values between levels (e.g. stored by an older version) move to
        // the neighbouring level.
        #expect(TextZoom.larger(than: 1.05) == step)
        #expect(TextZoom.smaller(than: 1.05) == 1)
    }

    @Test("Every step changes the size by the same ratio")
    func evenSteps() {
        let ratios = zip(TextZoom.levels.dropFirst(), TextZoom.levels).map { $0 / $1 }
        for ratio in ratios {
            #expect(abs(ratio - pow(2, 1.0 / 6)) < 1e-9)
        }
    }

    @Test("Invalid stored values are limited to the supported range")
    func clamping() {
        #expect(TextZoom.clamped(1.25) == 1.25)
        #expect(TextZoom.clamped(0.1) == 0.5)
        #expect(TextZoom.clamped(10) == TextZoom.levels.last)
        #expect(TextZoom.clamped(.nan) == 1)
        #expect(TextZoom.clamped(.infinity) == 1)
    }

    @MainActor
    @Test("The editor's font scales with the zoom")
    func editorFont() {
        let textView = MarkdownTextView.makeTextView(text: "text")
        MarkdownTextView.applyFont(to: textView, zoom: 2)
        let size = NSFont.systemFontSize * 2
        #expect(textView.font?.pointSize == size)
        let typed = textView.typingAttributes[.font] as? NSFont
        #expect(typed?.pointSize == size)
        #expect(MarkdownTextView.fontSize(zoom: 1) == NSFont.systemFontSize)
        // Not rounded: the editor scales exactly like the preview.
        #expect(MarkdownTextView.fontSize(zoom: 1.122) == NSFont.systemFontSize * 1.122)
    }
}
