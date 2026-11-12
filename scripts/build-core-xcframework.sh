#!/usr/bin/env bash
# Builds the Rust core for the macOS app:
#   1. compiles markdown-editor-ffi as a static library (Apple Silicon),
#   2. generates the Swift bindings with UniFFI,
#   3. packages library + C headers as an XCFramework.
# Output (not committed): apps/macos/Packages/MarkdownEditorKit/Generated/
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
target="aarch64-apple-darwin"
profile="${PROFILE:-release}"
out="$repo_root/apps/macos/Packages/MarkdownEditorKit/Generated"
crate_lib="libmarkdown_editor_ffi.a"

cd "$repo_root"
export MACOSX_DEPLOYMENT_TARGET=26.0

echo "==> Building Rust static library ($profile, $target)"
cargo build --locked -p markdown-editor-ffi --target "$target" --profile "$profile"
lib_path="target/$target/$profile/$crate_lib"

echo "==> Generating Swift bindings"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cargo run --locked -q -p uniffi-bindgen -- generate --library "$lib_path" \
    --language swift --out-dir "$staging/bindings"

mkdir -p "$staging/headers"
cp "$staging/bindings/"*FFI.h "$staging/headers/"
# SwiftPM/Xcode expect the module map inside the XCFramework headers to be
# named module.modulemap.
cp "$staging/bindings/"*FFI.modulemap "$staging/headers/module.modulemap"

echo "==> Packaging XCFramework"
rm -rf "$out"
mkdir -p "$out/Swift"
xcodebuild -create-xcframework -library "$lib_path" -headers "$staging/headers" \
    -output "$out/MarkdownEditorCoreFFI.xcframework" > /dev/null
cp "$staging/bindings/"*.swift "$out/Swift/"

echo "==> Done: $out"
ls -1 "$out" "$out/Swift"
