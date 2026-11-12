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

### Security

- Raw HTML in documents is escaped instead of rendered.
- Allowlist sanitization of all generated HTML; links restricted to `http`,
  `https`, `mailto` and relative targets.
- Remote, absolute and scheme-based image sources are removed, so documents
  cannot trigger network requests or read arbitrary local files.
- Inputs larger than 10 MiB or nested deeper than 1000 levels are rejected,
  preventing a quadratic slowdown in HTML sanitization (denial of service).
