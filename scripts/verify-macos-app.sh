#!/usr/bin/env bash
# Verifies the security properties of a built macOS app bundle.
# Usage: scripts/verify-macos-app.sh path/to/App.app
set -euo pipefail

app="${1:?usage: $0 path/to/App.app}"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"

# Signature is valid.
if codesign --verify --strict --deep "$app" 2>/dev/null; then pass "signature valid"; else fail "invalid signature"; fi

# Hardened runtime is enabled.
signature_info="$(codesign -dv "$app" 2>&1)"
if [[ "$signature_info" =~ flags=[^[:space:]]*runtime ]]; then pass "hardened runtime"; else fail "hardened runtime missing"; fi

# Apple Silicon only.
archs="$(lipo -archs "$executable")"
if [[ "$archs" == "arm64" ]]; then pass "arm64 only"; else fail "unexpected architectures: $archs"; fi

# Entitlements are exactly the expected set: sandbox and user-selected files.
# Anything else (network, debugger attachment, JIT, …) fails the check.
entitlements="$(mktemp)"
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null || true
entitlement() { /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements" 2>/dev/null || true; }
# PlistBuddy prints one "key = value" line per entry, including nested ones,
# so any additional entitlement changes the count.
count="$(/usr/libexec/PlistBuddy -c Print "$entitlements" 2>/dev/null | grep -c ' = ' || true)"
if [[ "$count" == 2 &&
    "$(entitlement com.apple.security.app-sandbox)" == true &&
    "$(entitlement com.apple.security.files.user-selected.read-write)" == true ]]; then
    pass "entitlements exactly sandbox + user-selected files"
else
    fail "unexpected entitlements:"$'\n'"$(/usr/libexec/PlistBuddy -c Print "$entitlements" 2>&1 || true)"
fi

# No third-party dynamic libraries are loaded.
foreign="$(otool -L "$executable" | tail -n +2 | awk '{print $1}' | grep -vE '^(/System/|/usr/lib/)' || true)"
if [[ -z "$foreign" ]]; then pass "only system libraries linked"; else fail "non-system libraries linked: $foreign"; fi

exit "$failures"
