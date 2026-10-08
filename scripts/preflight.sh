#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fail before fetching/building anything if this machine cannot produce the iOS app.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: Husk's iOS app requires macOS, Xcode, and the Apple iOS SDK." >&2
    echo "       On Linux, run ./tests/run.sh for the portable regression suite." >&2
    exit 2
fi

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' was not found on PATH." >&2
        return 1
    fi
}

missing=0
for tool in xcodebuild xcrun xcodegen meson ninja pkg-config python3 git make \
            curl bunzip2 qemu-img rustc cargo rustup patch plutil codesign; do
    require_tool "$tool" || missing=1
done
[ "$missing" -eq 0 ] || exit 2

if ! xcode-select -p >/dev/null 2>&1; then
    echo "error: select a full Xcode installation with xcode-select before building." >&2
    exit 2
fi
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "error: the iPhoneOS SDK is unavailable; install/select Xcode with iOS support." >&2
    exit 2
fi
if ! rustup target list --installed | grep -qx 'aarch64-apple-ios'; then
    echo "error: missing Rust target aarch64-apple-ios; run: rustup target add aarch64-apple-ios" >&2
    exit 2
fi

xcodebuild -version
printf 'iPhoneOS SDK: %s\n' "$(xcrun --sdk iphoneos --show-sdk-version)"
printf 'preflight passed; existing build products are preserved\n'
