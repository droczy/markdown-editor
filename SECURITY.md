# Security Policy

Security is the top priority of this project.

## Reporting a vulnerability

Please **do not open a public issue**. Report vulnerabilities privately via
GitHub: *Security → Report a vulnerability* in this repository. You will
receive a response as soon as possible; fixes are released with a security
advisory and a `Security` entry in the [changelog](CHANGELOG.md).

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
- **Offline.** The app requests no network permission and never loads remote
  resources such as images, fonts or scripts.
- **Resource limits.** Inputs above 10 MiB or nested deeper than 1000 levels
  are rejected to prevent denial of service.
- **Memory safety.** The core is written in safe Rust (`unsafe` is forbidden
  by a compiler lint).
- **Verification.** Every change runs unit, snapshot, property-based and
  security tests on macOS and Linux, coverage checks, dependency audits and
  fuzzing; longer fuzzing and mutation testing run nightly.
- **Supply chain.** Dependencies are locked, audited (`cargo-deny`) and
  restricted to crates.io and permissive licenses; GitHub Actions are pinned
  to commit SHAs; new dependency releases are adopted after a cooldown.

Planned platform measures: App Sandbox and Hardened Runtime on macOS, a
JavaScript-free preview with a strict Content Security Policy, and Flatpak
sandboxing on Linux.
