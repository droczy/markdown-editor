# Security checklist

Every full review assesses each item as *pass*, *fail* or *not applicable*,
with evidence (see the [process](README.md)). Items are grouped by the
chapters of [OWASP ASVS 5.0](https://owasp.org/www-project-application-security-verification-standard/),
adapted to an offline desktop application. Groups marked *project-specific*
cover areas ASVS does not address.

ASVS chapters that do not apply to an offline single-user app are left out:
authentication, session management, authorization, tokens, OAuth, APIs,
network communication and WebRTC. If such a feature is added, the review
adds the matching chapter.

IDs are stable. New items get new IDs, and removed items keep their ID
retired.

## Encoding and sanitization

| ID | Requirement |
| --- | --- |
| ENC-1 | Raw HTML in documents is escaped and shown as text, never rendered. |
| ENC-2 | All generated HTML passes the allowlist sanitizer. The allowlist contains only the elements and attributes the renderer produces. |
| ENC-3 | Links allow only `http`, `https`, `mailto` and relative targets. Images allow only relative paths without scheme, host or absolute path. |
| ENC-4 | The output never contains anything that runs script or loads content on its own: script, style, frames, objects, forms, SVG, MathML, `on*`, `style` and `srcset` attributes. |
| ENC-5 | The sanitizer is tested with an attack corpus, an independent invariant checker, property tests and fuzzing. |
| ENC-6 | Transformations before the sanitizer never change its output, as shown by a property test. |

## Validation and resource limits

| ID | Requirement |
| --- | --- |
| VAL-1 | Every input path checks its size limit before expensive work. |
| VAL-2 | Memory and time are bounded independently of input size, not only by it. Each limit has a test with a worst-case input. |
| VAL-3 | No recursion depends on attacker-controlled nesting. This is tested on a 512 KiB stack. |
| VAL-4 | Invalid input is rejected with an error instead of being altered. |

## File handling

| ID | Requirement |
| --- | --- |
| FILE-1 | Files are accessed only through user-selected access in the sandbox and written atomically. |
| FILE-2 | Saving preserves untouched content byte for byte. |
| FILE-3 | External changes are never overwritten silently, and read-only files are not modified. |
| FILE-4 | Paths taken from document content are resolved and confined to the document's folder, including symbolic links and `..`, before anything is loaded. |
| FILE-5 | Document content never causes a file to be opened, executed or written. |

## Web frontend (preview)

| ID | Requirement |
| --- | --- |
| WEB-1 | JavaScript is disabled in the preview. |
| WEB-2 | A strict Content Security Policy blocks every source the preview does not need. |
| WEB-3 | The preview never navigates. Link clicks are intercepted and opened externally only for allowed schemes and after confirmation. |
| WEB-4 | The preview loads nothing from the network. This is tested with a document that references remote resources. |
| WEB-5 | The preview has no file access beyond the resources it needs. |

## Secure coding and architecture

| ID | Requirement |
| --- | --- |
| CODE-1 | Rust code forbids `unsafe`. Code at the FFI boundary is generated, not handwritten. |
| CODE-2 | A panic in the core does not crash the app. |
| CODE-3 | Errors across the FFI boundary are typed and exhaustive. |
| CODE-4 | Every dependency is justified, locked and from crates.io, has an allowed license and no known advisory, and is at least 14 days old (security fixes excepted). |
| CODE-5 | Lints run with warnings as errors: clippy (pedantic) for Rust, swift-format (strict) and strict concurrency for Swift. |

## Configuration (platform)

| ID | Requirement |
| --- | --- |
| CFG-1 | The app runs in the App Sandbox with exactly the documented entitlements: user-selected files, read and write, and nothing else. |
| CFG-2 | The hardened runtime is enabled, and release builds do not allow debugger attachment. |
| CFG-3 | The app loads no third-party dynamic libraries. |
| CFG-4 | CI verifies CFG-1 to CFG-3 on every change. |

## Data protection and privacy

| ID | Requirement |
| --- | --- |
| DATA-1 | The app makes no network connections and collects no telemetry. |
| DATA-2 | Document content is never logged. |
| DATA-3 | How autosave and document versions retain content is documented. |

## Error handling

| ID | Requirement |
| --- | --- |
| ERR-1 | Errors are shown with a reason and a suggested fix, without internal details, and never crash the app. |

## Supply chain and CI (project-specific)

| ID | Requirement |
| --- | --- |
| CI-1 | Workflows use least-privilege tokens, have no secrets in pull requests from forks and use no `pull_request_target`. |
| CI-2 | Untrusted values such as PR titles and branch names are never interpolated into scripts. |
| CI-3 | Actions are pinned to full commit SHAs, and repository settings enforce this. |
| CI-4 | Every CI job has a timeout. |
| CI-5 | Toolchains and CI tools use pinned versions. |
| CI-6 | Every CI job is a required check. `main` requires signed commits and linear history, forbids force pushes, and these rules also apply to administrators. |
| CI-7 | Secret scanning with push protection, Dependabot alerts and security updates, CodeQL and private vulnerability reporting are enabled. |
| CI-8 | Maintainer accounts use two-factor authentication. |

## Releases (project-specific)

| ID | Requirement |
| --- | --- |
| REL-1 | Release artifacts are built by CI from a tagged, signed commit, and their SHA-256 checksums are published. |
| REL-2 | Release notes contain a security section and known issues. |
