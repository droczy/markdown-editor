# Markdown Editor

A native, security-focused Markdown editor. macOS (Apple Silicon) first, Linux later.

> **Status:** early development. The platform-independent core is in progress;
> there is no app to download yet.

## Goals

- **Native** user interface on every platform (SwiftUI/AppKit on macOS,
  GTK 4/libadwaita on Linux) on top of a shared **Rust** core.
- **Secure by default:** documents are treated as untrusted input, the app
  works completely offline and never loads remote content.
- **Split view:** plain-text editor on the left, live preview on the right.
- CommonMark and GitHub Flavored Markdown; LaTeX math, Mermaid diagrams and
  PDF export are planned.

## Repository layout

| Path | Contents |
|---|---|
| `crates/core` | Rust core: Markdown parsing and sanitized HTML rendering |
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

See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions and
[SECURITY.md](SECURITY.md) for the security model and how to report
vulnerabilities.

## License

[MIT](LICENSE)
