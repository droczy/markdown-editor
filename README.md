# Markdown Editor

A native, security-focused Markdown editor. macOS (Apple Silicon) first, Linux later.

> **Status:** early development. The Rust core renders Markdown safely; the
> macOS app is a skeleton. There is no release to download yet.

## Goals

- **Native** user interface on every platform (SwiftUI/AppKit on macOS,
  GTK 4/libadwaita on Linux) on top of a shared **Rust** core.
- **Secure by default:** documents are treated as untrusted input, the app
  works completely offline and never loads remote content.
- **Split view:** plain-text editor on the left, live preview on the right.
- CommonMark and GitHub Flavored Markdown; LaTeX math, Mermaid diagrams and
  PDF export are planned.

## Saving and document versions

The macOS app saves like other document-based Mac apps: changes are saved
automatically to the original file, and macOS keeps earlier versions of the
document (*File > Revert To > Browse All Versions*). macOS stores these
versions outside the document, so text deleted from a document can remain
in an earlier version. An option to turn off or delete versions is planned.

## Repository layout

| Path | Contents |
|---|---|
| `crates/core` | Rust core: Markdown parsing and sanitized HTML rendering |
| `crates/ffi` | Bridge from the core to the platform apps (UniFFI) |
| `tools/uniffi-bindgen` | Build-time tool generating the Swift bindings |
| `apps/macos` | macOS app (SwiftUI/AppKit); Xcode project defined in `project.yml` |
| `apps/macos/Packages/MarkdownEditorKit` | Testable Swift logic of the macOS app |
| `scripts` | Helper scripts, e.g. verification of the built app's security properties |
| `fuzz` | Fuzz targets (requires nightly Rust and `cargo-fuzz`) |
| `.github` | CI workflows and Dependabot configuration |

## Building and testing

Requires the Rust toolchain pinned in `rust-toolchain.toml` (installed
automatically by `rustup`).

```sh
cargo test --workspace            # all tests
cargo clippy --workspace --all-targets
cargo deny check                  # advisories, licenses, sources
cargo llvm-cov --workspace        # coverage
cd fuzz && cargo +nightly fuzz run render_html corpus/render_html seeds/render_html
```

### macOS app

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
2.46.0. The minimum supported system is macOS 26 on Apple Silicon.

```sh
scripts/build-core-xcframework.sh # Rust core + Swift bindings (run first)
cd apps/macos
xcodegen generate                 # creates MarkdownEditor.xcodeproj
xcodebuild build -project MarkdownEditor.xcodeproj -scheme MarkdownEditor \
  -configuration Release -derivedDataPath build
xcodebuild test -project MarkdownEditor.xcodeproj -scheme MarkdownEditor \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build
(cd Packages/MarkdownEditorKit && swift test)
../../scripts/verify-macos-app.sh build/Build/Products/Release/MarkdownEditor.app
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions and
[SECURITY.md](SECURITY.md) for the security model and how to report
vulnerabilities.

## License

[MIT](LICENSE)
