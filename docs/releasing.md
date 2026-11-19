# Releasing

Releases are built only by the [release workflow](../.github/workflows/release.yml)
from a signed tag on `main`. Nobody uploads files built elsewhere.

## What a release contains

| File | Contents |
| --- | --- |
| `MarkdownEditor-<version>-macos-arm64.zip` | The macOS app (Apple Silicon), ad-hoc signed |
| `markdown-editor-<version>.cdx.json` | SBOM (CycloneDX 1.5) of the Rust crates in the app |
| `SHA256SUMS` | SHA-256 checksums of both files |

The SBOM is created by `cargo-cyclonedx` for the crate that is linked into
the app (`markdown-editor-ffi`). It lists every crate needed to build it,
including crates used only at compile time (procedural macros). The Swift
code uses no third-party packages.

GitHub signs two attestations with a short-lived Sigstore certificate: the
build provenance of all three files (which workflow built them from which
commit) and the SBOM of the app. The release notes explain how to verify
them.

## Steps

1. **Release pull request** (`chore(release): vX.Y.Z`, also for betas):
   - `CHANGELOG.md`: move the entries of `[Unreleased]` into a new section
     `## [X.Y.Z] - YYYY-MM-DD` (or `X.Y.Z-beta.N`), and leave
     `[Unreleased]` empty.
   - `apps/macos/project.yml`: `MARKETING_VERSION` is `X.Y.Z` (also for
     betas); increase `CURRENT_PROJECT_VERSION` by one for every release.
   - Write `docs/release-notes/vX.Y.Z.md` (see
     [release notes](release-notes/README.md)).
   - Add the full security review of the release to `docs/security/reviews/`.
   - `scripts/prepare-release.sh check vX.Y.Z` must pass.
2. **Merge** the pull request once all checks pass, and wait for the CI run
   on `main`.
3. **Rehearsal (optional):** *Actions → Release → Run workflow* on `main`
   with the planned tag. It runs every check and builds the files, which
   are kept as a workflow artifact for 14 days; nothing is attested or
   published.
4. **Tag** the merge commit with a signed, annotated tag and push it:

   ```sh
   git tag -s vX.Y.Z -m "Markdown Editor vX.Y.Z"
   git push origin vX.Y.Z
   ```

5. **The workflow** checks that the tag is verified by GitHub, that the
   commit is on `main` and passed CI there, and that the version matches
   `project.yml`, the CHANGELOG and the release notes. It then builds and
   verifies the app, packages the files, attests them and creates a
   **draft** release (marked as a pre-release for betas).
6. **Publish** the draft after checking its notes and files. Published
   releases are immutable (repository setting): their files and tag cannot
   be changed, so a mistake is fixed with a new version.

## Permissions of the workflow

| Job | Runs on | Permissions |
| --- | --- | --- |
| Check tag, commit and version | Ubuntu | read the repository and CI results |
| Build, package and attest | macOS | read the repository; sign and store attestations |
| Create draft release | Ubuntu | write the repository (create the draft) |

The build job runs third-party build scripts and therefore cannot write to
the repository. The job that can write runs no build and only uploads the
files that the build job passed on; their digests are checked on download.
