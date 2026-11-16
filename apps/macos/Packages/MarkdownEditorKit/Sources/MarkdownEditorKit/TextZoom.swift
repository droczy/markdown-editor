import SwiftUI

/// The zoom level of editor and preview, shared by all windows and kept
/// across launches.
public enum TextZoom {
    /// User defaults key of the zoom factor.
    public static let storageKey = "textZoom"

    /// The normal size.
    public static let actualSize = 1.0

    /// The zoom steps from 50 % to 283 %: six per doubling, so every step
    /// changes the size by the same ratio (about 12 %) and zooming feels
    /// even across the whole range.
    static let levels: [Double] = (-6...9).map { pow(2, Double($0) / 6) }

    /// The next larger level, or `nil` at the largest.
    public static func larger(than zoom: Double) -> Double? {
        levels.first { $0 > zoom + 0.001 }
    }

    /// The next smaller level, or `nil` at the smallest.
    public static func smaller(than zoom: Double) -> Double? {
        levels.last { $0 < zoom - 0.001 }
    }

    /// `zoom` limited to the supported range (stored values may be invalid).
    static func clamped(_ zoom: Double) -> Double {
        guard zoom.isFinite, let smallest = levels.first, let largest = levels.last else {
            return actualSize
        }
        return min(max(zoom, smallest), largest)
    }
}

/// "Zoom In" (⌘+), "Zoom Out" (⌘−) and "Actual Size" (⌘0) in the View menu.
public struct TextZoomCommands: Commands {
    @AppStorage(TextZoom.storageKey) private var zoom = TextZoom.actualSize

    /// Creates the zoom commands.
    public init() {}

    /// The menu items.
    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Actual Size") { zoom = TextZoom.actualSize }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom == TextZoom.actualSize)
            Button("Zoom In") {
                if let larger = TextZoom.larger(than: zoom) { zoom = larger }
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(TextZoom.larger(than: zoom) == nil)
            Button("Zoom Out") {
                if let smaller = TextZoom.smaller(than: zoom) { zoom = smaller }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(TextZoom.smaller(than: zoom) == nil)
            Divider()
        }
    }
}
