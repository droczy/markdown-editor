# Security Policy

Security is the top priority of this project.

## Reporting a vulnerability

Please **do not open a public issue**. Report vulnerabilities privately via
GitHub: *Security → Report a vulnerability* in this repository. You will
receive a response as soon as possible; fixes are released with a security
advisory and a `Security` entry in the [changelog](CHANGELOG.md).

## Security reviews

Every pull request that touches a security-relevant area contains a short
security review, and every development phase and release ends with a full
review. The process, the [threat model](docs/security/threat-model.md), the
checklist and the published reports are in [docs/security](docs/security/).

## Supported versions

Only the latest release receives security fixes during early development.

## Security model

- **Documents are untrusted.** Opening a file must never execute code,
  access the network or read other files.
- **Two-layer rendering.** The Markdown parser escapes raw HTML and removes
  dangerous link schemes; an allowlist-based HTML sanitizer then removes
  everything except the elements and attributes the parser legitimately
  produces. Links are limited to `http`, `https`, `mailto` and relative
  targets; images only to relative paths.
- **Offline.** The app never loads remote resources such as images, fonts
  or scripts, and never sends data anywhere. The preview blocks every load
  in independent ways (the sanitizer removes remote addresses; a strict
  Content Security Policy and a content blocker each refuse every request)
  and never navigates. Links are never opened: a click copies the address,
  so that opening it is always a deliberate step in another app.
  The App Sandbox allows outgoing connections only because WebKit, which
  shows the preview, requires it. CI ensures that the app's own code uses no
  networking APIs and the core no networking libraries.
- **Resource limits.** Inputs above 10 MiB, nested deeper than 1000 levels
  or expanding to more than 1,000,000 syntax tree nodes are rejected to
  prevent denial of service.
- **Memory safety.** The core is written in safe Rust (`unsafe` is forbidden
  by a compiler lint).
- **Verification.** Every change runs unit, snapshot, property-based and
  security tests on macOS and Linux, coverage checks, dependency audits and
  fuzzing; longer fuzzing and mutation testing run nightly.
- **Supply chain.** Dependencies are locked, audited (`cargo-deny`) and
  restricted to crates.io and permissive licenses; GitHub Actions are pinned
  to commit SHAs; new dependency releases are adopted after a cooldown.
- **Releases.** Built only by the release workflow from a signed tag on
  `main` whose CI passed, with SHA-256 checksums, an SBOM and attestations
  of build provenance and SBOM signed by GitHub. Published releases cannot
  be changed. See [docs/releasing.md](docs/releasing.md).

- **macOS app.** Runs in the App Sandbox with access only to files the user
  opens or saves, plus outgoing connections for WebKit (see above); hardened
  runtime enabled; no third-party dynamic libraries; release builds forbid
  debugger attachment. CI verifies these properties on every change.
- **Preview.** Scripts in the page never run, WebKit's Lockdown Mode is on,
  nothing is stored on disk, the context menu offers only copying and
  looking up, and dropped files are not opened. A click on an `http`,
  `https` or `mailto` link copies its address and shows the real host;
  nothing is handed to another app.
- **Data integrity.** Files are written atomically and preserved byte for
  byte (encoding, line endings, byte order mark). Files that are not valid
  UTF-8 or larger than 50 MiB are refused instead of being altered. External
  changes are never overwritten silently.

Planned: Flatpak sandboxing on Linux.
