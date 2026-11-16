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
- Bridge between the Rust core and the macOS app: crate `markdown-editor-ffi`
  (UniFFI 0.32.2), `scripts/build-core-xcframework.sh` producing a static
  XCFramework with generated Swift bindings, and the Swift API
  `MarkdownRenderer` that renders off the calling actor and reports typed
  errors.
- Robust document handling in the macOS app: files up to 50 MiB, UTF-8
  only; opened plain-text files keep their type and name; autosave in place
  with versions (system default); clear error messages with a reason and a
  suggested fix when a file cannot be opened. Plain text is offered under
  "Open With" without becoming the default app for `.txt`.
- UI tests with real files: edit and save, autosave on close, Windows line
  endings, plain-text files, invalid UTF-8, oversized files, external
  changes and read-only files.
- `scripts/verify-macos-app.sh` checks the built app's signature, hardened
  runtime, architecture, entitlements and linked libraries.
- Security review process in `docs/security`: short reviews for
  security-relevant pull requests, full reviews per phase and release,
  threat model, checklist based on OWASP ASVS 5.0, report template,
  severity deadlines and disclosure rules. A pull request template asks
  for the short review.
- First full security review (phase 2): report in
  `docs/security/reviews/2026-11-phase-2.md`.
- The README explains autosave and document versions.
- Editor and preview side by side in the macOS app, each taking half of the
  window. The editor (`NSTextView`, TextKit 2, system font) never changes
  text on its own: smart quotes and dashes, text replacement, spelling
  correction, link detection, inline predictions and writing tools are off.
  Undo works per typing step. The preview updates after a short pause in
  typing, renders at most once at a time, keeps its scroll position, follows
  the light or dark appearance and shows a notice, with the last result
  dimmed, when a document is too large or too complex to render.
- Zoom for editor and preview together: View > Zoom In (⌘+), Zoom Out (⌘−)
  and Actual Size (⌘0), in even steps of about 12 % from 50 % to 283 %,
  kept across launches.
- "Privacy and Permissions" window, shown once at the first launch and
  later from the Help menu: which permissions the app has, why, and what it
  never does. macOS does not ask the user for these permissions itself.
- Task list checkboxes in the preview can be clicked to check or uncheck
  the task: exactly the character between the brackets changes in the
  editor, and ⌘Z undoes it. Core function `toggle_task` finds the
  character; `render_page` turns checkboxes into task links when given a
  token.
- Core functions `render_page`, which wraps the sanitized HTML in the
  preview page (Content Security Policy and stylesheet), and `link_action`,
  which decides what a click on a link does after the web engine resolved
  it; both are available to Swift through the FFI crate.
- `scripts/check-no-network.sh` (run in CI) fails if the app's Swift code
  uses networking or URL loading APIs or hands URLs or files to other apps
  (`NSWorkspace`, Launch Services, SwiftUI `openURL` and `Link`).

### Changed

- Window tabs are turned off: every document opens in its own window, and
  the View and Window menus offer no tab commands. To be reconsidered with
  the folder and file tree.
- The GitHub workflows are audited with zizmor 1.31.1 on every pull
  request (new required check "Workflow security (zizmor)"), and the
  locked dependencies are checked against the RustSec advisories every
  night, not only when a pull request runs. CodeQL and nightly runs no
  longer overlap: a newer commit replaces a running analysis, and nightly
  runs wait for each other.
- Code scanning uses an advanced CodeQL setup (`.github/workflows/codeql.yml`)
  that builds the macOS app, so the Swift code is analyzed as well; GitHub's
  default setup could not build it. Actions, Rust and Swift are analyzed
  with the `security-extended` queries on every pull request, on `main` and
  weekly.
- The macOS app's sandbox allows outgoing connections. WebKit requires this
  permission for the preview even though nothing is loaded from the
  network; the app's own code still never connects (see *Security*).
- The document model is a reference type, so that the editor's undo steps
  are the only ones and mark the document as edited.
- CI hardening: every job has a timeout; fuzzing uses a pinned nightly
  toolchain and fails on any input that takes longer than 10 seconds; the
  CI tools cargo-deny, cargo-llvm-cov, cargo-fuzz and cargo-mutants are
  pinned to exact versions. `scripts/verify-macos-app.sh` reads
  entitlements with PlistBuddy instead of Python.
- Release builds unwind on panic instead of aborting, so that UniFFI can
  turn an unexpected panic in the core into a Swift error instead of
  crashing the app.
- `RenderError` of the core is exhaustive, so that new error cases must be
  handled in every consumer at compile time.

### Fixed

- CI fuzzing jobs build for the glibc Linux target explicitly; the
  prebuilt `cargo-fuzz` binary otherwise defaulted to musl, which is
  incompatible with the sanitizers.

### Security

- The preview is locked down in independent layers: a Content Security
  Policy that allows nothing but the preview's own stylesheet, a content
  blocker that refuses every load, a navigation policy that cancels every
  navigation, JavaScript of the page disabled, WebKit's Lockdown Mode,
  website data kept in memory only, no link previews, no dropped files, and
  a context menu without system services. Tests load a page with dozens of
  ways to reach a local server and run scripts: each of the policy and the
  content blocker alone stops all of them.
- Links are never opened. A click on a web link copies its address, a
  click on an email link copies the address only; a short notice at the
  bottom of the preview names the real host (without user name or
  password), and the first copy explains once why links are not opened.
  What is copied comes from the core and is printable ASCII only (no
  spaces, line breaks or invisible characters). Other files, headings and
  blocked addresses (`file:`, `javascript:`, other apps' schemes) only get
  a notice; the scheme is checked after the link was resolved, so relative
  links such as `java%09script:` can never act as a scheme.
- Networking crates (HTTP clients, TLS, async I/O runtimes) are banned in
  `deny.toml`.
- Clicks on task checkboxes are applied only if they carry the random token
  of the page that is shown and the text has not changed since that page
  was rendered. Protocol-relative links (`//host/path`) are removed from
  documents, because in the preview they would lead to its internal
  addresses.
- Rendering time now grows linearly with the input size, also for long
  paragraphs, code blocks, link targets, titles and image descriptions
  full of characters such as `&`, `°` or no-break spaces (denial of
  service). Escaping such text previously took quadratic time: a 1.4 MB
  code block with many `&&` needed about 9 seconds, larger inputs
  minutes. Long runs of such text are now split into separate text nodes
  before sanitization, which does not change the output, and attribute
  values that would be excessively expensive to escape are removed; real
  links, titles and image descriptions stay far below that limit. No
  released version was affected.
- The node limit also bounds the memory of the preview (denial of service,
  SR-2026-005). The preview's web engine needs up to about 2 KB per node,
  so documents of 2 to 3 MB within the earlier limit of 2,000,000 nodes
  made it use up to 3.4 GB of memory, in addition to the app. The limit is
  now 1,000,000 nodes: at most about 1.8 GB for the preview and 0.5 GB for
  the app. Real documents have 50 to 80 nodes per KiB and stay below the
  limit up to the size limit of 10 MiB. No released version was affected.
- Documents whose syntax tree would exceed 1,000,000 nodes are rejected
  (denial of service). Some Markdown constructs expand to far more nodes
  than they have bytes, so small crafted inputs could make rendering
  exhaust memory. Parsing now stops as soon as the limit is reached, which
  bounds memory use and rendering time independently of the input size:
  10 MiB documents previously needed up to 4 GB of memory, the core now
  at most about 0.6 GB. Typical documents up to the size limit, such as
  10 MiB of prose, are not affected. The limit is available to the app as
  `MarkdownRenderer.maxNodes`, and exceeding it is reported as a typed
  error. No released version was affected.
- Updated ammonia from 4.2.4 to 4.2.5, which fixes RUSTSEC-2026-0533
  (GHSA-934p-vp7m-gx3c, mutation XSS by mixing MathML and SVG). Not
  exploitable here: the sanitizer allows no MathML, SVG or raw-text
  elements, and raw HTML is escaped before sanitization. A regression test
  checks that the sanitizer alone removes the published payloads.
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
- The Rust core is linked statically; the app still loads no third-party
  dynamic libraries. The UniFFI binding generator is a separate build-time
  tool and not part of the app.
- Documents with invalid UTF-8 are rejected instead of being altered, and a
  byte order mark is preserved, so saving never changes untouched content.
  Line endings and a missing final newline are preserved as well.
- Files larger than 50 MiB are rejected before they are decoded.
- Changes made to a file by another application are never overwritten
  silently: the system asks how to resolve the conflict.
- Read-only files are not modified.
