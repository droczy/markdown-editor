// swift-tools-version: 6.2
// Platform-specific logic of the macOS app that can be tested without
// launching the app. Linked statically into the app target.

import PackageDescription

let package = Package(
    name: "MarkdownEditorKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MarkdownEditorKit", targets: ["MarkdownEditorKit"])
    ],
    targets: [
        .target(
            name: "MarkdownEditorKit",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "MarkdownEditorKitTests",
            dependencies: ["MarkdownEditorKit"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
