#!/usr/bin/env bash
# Checks a release tag and prepares the files of the release.
#
#   scripts/prepare-release.sh check <tag>
#       Checks that <tag> is a release tag (vX.Y.Z or vX.Y.Z-beta.N) whose
#       version matches MARKETING_VERSION in apps/macos/project.yml, and that
#       CHANGELOG.md has a section for it and docs/release-notes/<tag>.md
#       exists with both placeholders and a "## Known issues" section (see
#       docs/releasing.md).
#
#   scripts/prepare-release.sh package <tag> <app> <out-dir>
#       Runs the checks, then writes to <out-dir> (macOS, needs
#       cargo-cyclonedx):
#         MarkdownEditor-<version>-macos-arm64.zip  the app
#         markdown-editor-<version>.cdx.json        SBOM of the Rust crates
#         SHA256SUMS                                checksums of both
#         release-notes.md                          text of the GitHub release
#
#   scripts/prepare-release.sh --self-test
#       Tests the checks and the release notes in a temporary directory.
#
# The repository root can be overridden with RELEASE_ROOT (for the self-test).
set -euo pipefail

root="${RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Prints the version of a release tag (without "v"); fails for anything
# else. Numbers follow Semantic Versioning (no leading zeros).
version_of() {
    local number='(0|[1-9][0-9]*)'
    [[ "$1" =~ ^v($number\.$number\.$number(-beta\.[1-9][0-9]*)?)$ ]] ||
        fail "not a release tag (vX.Y.Z or vX.Y.Z-beta.N): $1"
    echo "${BASH_REMATCH[1]}"
}

# Prints the body of the CHANGELOG section for <version>, without its
# heading, up to the next section or the link definitions at the end.
changelog_section() {
    awk -v heading="## [$1] - " '
        index($0, heading) == 1 { found = 1; next }
        found && (/^## / || /^\[.+\]: /) { exit }
        found { print }
    ' "$root/CHANGELOG.md"
}

check() {
    local tag="$1" version base app_version notes marker
    version="$(version_of "$tag")"
    base="${version%%-*}"
    app_version="$(awk '$1 == "MARKETING_VERSION:" { print $2; exit }' "$root/apps/macos/project.yml")"
    [[ "$app_version" == "$base" ]] ||
        fail "MARKETING_VERSION in apps/macos/project.yml is '$app_version', expected '$base'"
    grep -qE "^## \[${version//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\$" "$root/CHANGELOG.md" ||
        fail "CHANGELOG.md has no section '## [$version] - YYYY-MM-DD'"
    [[ -n "$(changelog_section "$version" | tr -d '[:space:]')" ]] ||
        fail "the CHANGELOG section for $version is empty"
    notes="$root/docs/release-notes/$tag.md"
    [[ -f "$notes" ]] || fail "missing release notes: docs/release-notes/$tag.md"
    for marker in '<!-- changes -->' '<!-- checksums -->' '## Known issues'; do
        [[ "$(grep -cxF -- "$marker" "$notes")" == 1 ]] ||
            fail "docs/release-notes/$tag.md must contain the line '$marker' exactly once"
    done
}

# Writes the release notes: the notes file with the CHANGELOG section and
# the checksums in place of the two placeholders.
write_notes() {
    local tag="$1" checksums="$2" zip="$3" out="$4" version repository changes block
    version="$(version_of "$tag")"
    repository="$(awk -F'"' '/^repository = / { sub("https://github.com/", "", $2); print $2; exit }' \
        "$root/Cargo.toml")"
    changes="$(mktemp)"
    block="$(mktemp)"
    {
        echo "## Changes"
        changelog_section "$version"
    } > "$changes"
    {
        echo "## Checksums"
        echo
        echo "SHA-256 (also in \`SHA256SUMS\`):"
        echo
        echo '```'
        cat "$checksums"
        echo '```'
        echo
        echo "## Verifying the download"
        echo
        echo "The files were built by the release workflow of this repository from the"
        echo "tagged commit. GitHub signed a record of how they were built (build"
        echo "provenance) and which Rust crates the app contains (SBOM). To check them with"
        echo "the [GitHub CLI](https://cli.github.com):"
        echo
        echo '```sh'
        echo "shasum -a 256 -c SHA256SUMS"
        echo "gh attestation verify $zip --repo $repository"
        echo "gh attestation verify $zip --repo $repository \\"
        echo "  --predicate-type https://cyclonedx.org/bom"
        echo '```'
    } > "$block"
    awk -v changes="$changes" -v block="$block" '
        $0 == "<!-- changes -->" { while ((getline line < changes) > 0) print line; next }
        $0 == "<!-- checksums -->" { while ((getline line < block) > 0) print line; next }
        { print }
    ' "$root/docs/release-notes/$tag.md" > "$out"
    rm -f "$changes" "$block"
}

package() {
    local tag="$1" app="$2" out="$3" version zip sbom generated member
    check "$tag"
    version="$(version_of "$tag")"
    [[ -d "$app" ]] || fail "no app at $app"
    mkdir -p "$out"
    zip="MarkdownEditor-$version-macos-arm64.zip"
    sbom="markdown-editor-$version.cdx.json"

    # ditto keeps the code signature and extended attributes intact.
    ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$zip"

    # SBOM of the crate linked into the app (markdown-editor-ffi) for the
    # app's target. cargo-cyclonedx writes a file next to every workspace
    # member; only the one of the FFI crate is kept.
    generated="release-sbom-$$"
    (cd "$root" && cargo cyclonedx --manifest-path crates/ffi/Cargo.toml --format json \
        --spec-version 1.5 --target aarch64-apple-darwin --no-build-deps \
        --override-filename "$generated" -q)
    mv "$root/crates/ffi/$generated.json" "$out/$sbom"
    for member in "$root"/crates/* "$root"/tools/*; do
        rm -f "$member/$generated.json"
    done

    (cd "$out" && shasum -a 256 "$zip" "$sbom" > SHA256SUMS)
    write_notes "$tag" "$out/SHA256SUMS" "$zip" "$out/release-notes.md"
    echo "ok: release files for $tag in $out"
    ls -l "$out"
}

self_test() {
    local dir
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' RETURN
    mkdir -p "$dir/apps/macos" "$dir/docs/release-notes"
    echo 'repository = "https://github.com/example/editor"' > "$dir/Cargo.toml"
    printf 'settings:\n  base:\n    MARKETING_VERSION: 1.2.0\n' > "$dir/apps/macos/project.yml"
    cat > "$dir/CHANGELOG.md" << 'EOF'
# Changelog

## [Unreleased]

## [1.2.0-beta.2] - 2026-11-20

### Fixed

- Second beta.

## [1.2.0-beta.1] - 2026-11-17

### Added

- First beta.

[1.2.0-beta.1]: https://example.com/v1.2.0-beta.1
EOF
    printf '## Overview\n\nText.\n\n<!-- changes -->\n\n## Known issues\n\nNone.\n\n<!-- checksums -->\n' \
        > "$dir/docs/release-notes/v1.2.0-beta.1.md"
    cp "$dir/docs/release-notes/v1.2.0-beta.1.md" "$dir/docs/release-notes/v1.2.0-beta.2.md"
    # A CHANGELOG section and notes with placeholders, but no known issues.
    printf '## [1.2.0-beta.4] - 2026-11-30\n\n- Fourth beta.\n' >> "$dir/CHANGELOG.md"
    printf '<!-- changes -->\n<!-- checksums -->\n' > "$dir/docs/release-notes/v1.2.0-beta.4.md"
    echo "## Overview" > "$dir/docs/release-notes/v1.2.0.md"

    local tag
    for tag in v1.2.0-beta.1 v1.2.0-beta.2; do
        RELEASE_ROOT="$dir" "$BASH" "$0" check "$tag" > /dev/null ||
            { echo "self-test: valid tag rejected: $tag" >&2; return 1; }
    done
    # Malformed tags, a version other than the app's, a missing CHANGELOG
    # section, notes without placeholders and notes without known issues
    # are all rejected.
    for tag in 1.2.0 v1.2 v1.2.0-rc.1 v1.2.0-beta.0 v01.2.0 'v1.2.0-beta.1 x' v1.3.0 v1.2.0-beta.3 \
        v1.2.0 v1.2.0-beta.4; do
        if RELEASE_ROOT="$dir" "$BASH" "$0" check "$tag" > /dev/null 2>&1; then
            echo "self-test: invalid tag accepted: $tag" >&2
            return 1
        fi
    done

    # The notes get exactly the CHANGELOG section of their version.
    printf 'abc  MarkdownEditor-1.2.0-beta.1-macos-arm64.zip\n' > "$dir/SHA256SUMS"
    (root="$dir" && write_notes v1.2.0-beta.1 "$dir/SHA256SUMS" \
        MarkdownEditor-1.2.0-beta.1-macos-arm64.zip "$dir/notes.md")
    local expected=(
        '## Changes' '### Added' '- First beta.' '## Known issues' '## Checksums'
        'abc  MarkdownEditor-1.2.0-beta.1-macos-arm64.zip'
        'gh attestation verify MarkdownEditor-1.2.0-beta.1-macos-arm64.zip --repo example/editor'
    )
    local line
    for line in "${expected[@]}"; do
        grep -qxF -- "$line" "$dir/notes.md" ||
            { echo "self-test: notes lack: $line" >&2; cat "$dir/notes.md" >&2; return 1; }
    done
    for line in '- Second beta.' '<!-- changes -->' '<!-- checksums -->' '## [Unreleased]' \
        '[1.2.0-beta.1]: https://example.com/v1.2.0-beta.1'; do
        if grep -qxF -- "$line" "$dir/notes.md"; then
            echo "self-test: notes contain: $line" >&2
            return 1
        fi
    done
    echo "self-test passed"
}

case "${1:-}" in
    check)
        [[ $# -eq 2 ]] || fail "usage: $0 check <tag>"
        check "$2"
        echo "ok: $2 matches the app version, CHANGELOG.md and its release notes"
        ;;
    package)
        [[ $# -eq 4 ]] || fail "usage: $0 package <tag> <app> <out-dir>"
        package "$2" "$3" "$4"
        ;;
    --self-test)
        self_test
        ;;
    *)
        fail "usage: $0 check <tag> | package <tag> <app> <out-dir> | --self-test"
        ;;
esac
