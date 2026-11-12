# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Rust core crate `markdown-editor-core` with `render_html`, converting
  CommonMark and GitHub Flavored Markdown (tables, task lists,
  strikethrough, autolinks) to sanitized HTML.
- Test suite: unit, snapshot, property-based, security payload and
  resource-limit tests; fuzz target `render_html`.
- CI on macOS and Linux: formatting, lints, tests, coverage threshold,
  dependency audit, short fuzzing run, PR title check. Nightly fuzzing and
  mutation testing. Dependabot with update cooldown.
- Project documentation: README, security policy, contribution guide.
- macOS app skeleton (macOS 26+, Apple Silicon): SwiftUI document app that
  opens, edits and saves `.md` and `.markdown` files. The Xcode project is
  generated from `apps/macos/project.yml` with XcodeGen.
- Swift package `MarkdownEditorKit` with the document model and unit tests
  (Swift Testing); UI test that creates and edits a document.
- CI job building, verifying and testing the macOS app; Swift sources are
  checked with `swift-format`.
- `scripts/verify-macos-app.sh` checks the built app's signature, hardened
  runtime, architecture, entitlements and linked libraries.

### Fixed

- CI fuzzing jobs build for the glibc Linux target explicitly; the
  prebuilt `cargo-fuzz` binary otherwise defaulted to musl, which is
  incompatible with the sanitizers.

### Security

- Raw HTML in documents is escaped instead of rendered.
- Allowlist sanitization of all generated HTML; links restricted to `http`,
  `https`, `mailto` and relative targets.
- Remote, absolute and scheme-based image sources are removed, so documents
  cannot trigger network requests or read arbitrary local files.
- Inputs larger than 10 MiB or nested deeper than 1000 levels are rejected,
  preventing a quadratic slowdown in HTML sanitization (denial of service).
- The macOS app runs in the App Sandbox with access only to user-selected
  files and no network access, uses the hardened runtime, links no
  third-party dynamic libraries, and release builds do not allow debugger
  attachment. CI fails if any of these properties change.
- Documents with invalid UTF-8 are rejected instead of being altered, and a
  byte order mark is preserved, so saving never changes untouched content.
