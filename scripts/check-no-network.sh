#!/usr/bin/env bash
# Fails if the macOS app's own code could connect to the network or hand
# URLs or files to other apps.
#
# The App Sandbox allows outgoing connections only because WebKit requires
# it (see docs/security/threat-model.md, I1). This check makes sure the app
# itself never uses that permission: its Swift code must not contain
# networking or URL loading APIs. Links are never opened (a click copies
# the address), so nothing may hand URLs to other apps either. Networking
# crates in the Rust core are banned in deny.toml. Tests are not checked:
# they run a local server and open files on purpose.
#
# Usage: scripts/check-no-network.sh [--self-test] [directory ...]
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Extended regular expressions and why each is forbidden.
patterns=(
    '\bURLSession'                          # HTTP and WebSocket client
    '\bNSURLConnection\b'                   # legacy HTTP client
    '\bURLRequest\b'                        # requests for URL loading APIs
    '^[[:space:]]*import[[:space:]]+(Network|CFNetwork)\b'
    '\bNW(Connection|Listener|Browser|PathMonitor|Endpoint)\b'
    '\bCF(Stream|Socket|Host|Network)'      # Core Foundation networking
    '\b(getaddrinfo|gethostbyname|socket|connect)[[:space:]]*\('
    'contentsOf:'                           # Data/String(contentsOf:) also fetch remote URLs
    '\.(load|loadFileURL|loadFileRequest|loadSimulatedRequest)\('  # web view loads other than loadHTMLString
    '\bopenURL\b'                           # SwiftUI action that opens URLs
    '\bLink[[:space:]]*\('                  # SwiftUI view that opens URLs
    '\bNSWorkspace\b'                       # hands URLs and files to other apps
    '\bLSOpen'                              # Launch Services, the same below AppKit
)

check() {
    local found=0 pattern matches
    for pattern in "${patterns[@]}"; do
        if matches="$(grep -rnE --include='*.swift' -- "$pattern" "$@")"; then
            echo "Forbidden API, networking or opening URLs ($pattern):" >&2
            echo "$matches" >&2
            found=1
        fi
    done
    return "$found"
}

self_test() {
    local dir
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' RETURN
    echo 'let page = "safe"' > "$dir/Clean.swift"
    check "$dir" > /dev/null 2>&1 || { echo "self-test: clean code was rejected" >&2; return 1; }
    local snippet
    for snippet in \
        'let s = URLSession.shared' \
        'import Network' \
        'let d = try Data(contentsOf: url)' \
        'webView.load(request)' \
        'NSWorkspace.shared.open(url)' \
        'LSOpenCFURLRef(url, nil)' \
        'Link("x", destination: url)'; do
        echo "$snippet" > "$dir/Bad.swift"
        if check "$dir" > /dev/null 2>&1; then
            echo "self-test: not detected: $snippet" >&2
            return 1
        fi
    done
    echo "self-test passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit
fi

if [[ $# -eq 0 ]]; then
    set -- "$repo_root/apps/macos/App" "$repo_root/apps/macos/Packages/MarkdownEditorKit/Sources"
fi
if check "$@"; then
    echo "ok: no networking APIs in the app's code"
else
    exit 1
fi
