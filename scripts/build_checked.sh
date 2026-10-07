#!/bin/bash
# Validate prerequisites before spending hours compiling dependencies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Husk is an iOS app. Build it on macOS with Xcode." >&2
    exit 1
fi
missing=()
for tool in xcodebuild meson ninja pkg-config python3 xcodegen qemu-img cargo rustup; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
    printf 'Missing tools: %s\n' "${missing[*]}" >&2
    exit 1
fi
xcrun --sdk iphoneos --show-sdk-path >/dev/null
rustup target list --installed | grep -qx aarch64-apple-ios || {
    echo "Install the Rust target: rustup target add aarch64-apple-ios" >&2
    exit 1
}
python3 "$ROOT/scripts/test_bundle_security.py"
exec bash "$ROOT/scripts/ci_build.sh" "${1:-$ROOT/build/Husk.ipa}"