#!/bin/bash
# Phase 1 guest: Debian arm64 + Waydroid (LineageOS 20, arm64, no Google apps).
#
# Why Waydroid rather than AOSP: source.android.com states plainly that "Android
# OS development on macOS isn't supported as of June 22, 2021", and requires a
# 64-bit Linux host with 400 GB of disk and 64 GB of RAM. Building AOSP on this
# machine is not a long path, it is a closed one.
#
# Waydroid also fits the product better than a raw Android image would. Its
# multi-window mode renders each Android app as its own chrome-free surface, and
# `waydroid app install` / `waydroid app launch <pkg>` is exactly the APK
# lifecycle Husk needs -- the same illusion, already solved, one layer down.
#
# The VANILLA system image carries no Google apps, so the brief's
# no-Play-Services constraint holds by construction rather than by us stripping
# anything out (and with it the redistribution problem disappears).
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HUSK_ROOT/guests/phase1"
mkdir -p "$OUT"
cd "$OUT"

DEBIAN_BASE="https://cloud.debian.org/images/cloud/trixie/latest"
DEBIAN_IMAGE="debian-13-generic-arm64.qcow2"
DEBIAN_URL="$DEBIAN_BASE/$DEBIAN_IMAGE"
WAYDROID_BASE="https://downloads.sourceforge.net/project/waydroid/images"
WD_SYSTEM="lineage-20.0-20260403-VANILLA-waydroid_arm64-system.zip"
WD_VENDOR="lineage-20.0-20260403-MAINLINE-waydroid_arm64-vendor.zip"
# SHA-256 from the official Waydroid OTA JSON for these exact artifacts; the
# upstream Waydroid updater verifies that its OTA `id` field is SHA-256.
WD_SYSTEM_SHA256="c4b45fad36bee7c0db8a1d9315a5be0035520c53d3d005a807735ae9b7ee79cf"
WD_VENDOR_SHA256="1e6d33d464277ea3964e4658001c8882f21325616d6bcc66d473bc9ee1e246c7"

get() {
    local url="$1" file="$2"
    if [ -s "$file" ]; then echo "[skip] $file"; return 0; fi
    echo "[get ] $file"
    curl --proto '=https' --proto-redir '=https' -fL --retry 3 --retry-delay 5 \
        -o "$file.part" "$url"
    mv "$file.part" "$file"
}
verify_sha256() {
    local file="$1" expected="$2" actual
    if ! [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "error: invalid pinned SHA-256 for $file" >&2
        return 1
    fi
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "error: SHA-256 mismatch for $file; refusing this image" >&2
        return 1
    fi
}
verify_debian_sha512() {
    local file="$1" sums="SHA512SUMS" expected actual
    echo "[sha ] checking Debian's published SHA512SUMS"
    curl --proto '=https' --proto-redir '=https' -fL --retry 3 --retry-delay 5 \
        -o "$sums.part" "$DEBIAN_BASE/SHA512SUMS"
    mv "$sums.part" "$sums"
    expected="$(awk -v image="$DEBIAN_IMAGE" '$2 == image || $2 == "*" image { print $1 }' "$sums")"
    if ! [[ "$expected" =~ ^[[:xdigit:]]{128}$ ]]; then
        echo "error: Debian SHA512SUMS has no unique valid entry for $DEBIAN_IMAGE" >&2
        return 1
    fi
    actual="$(shasum -a 512 "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "error: Debian image SHA-512 mismatch; refusing $file" >&2
        return 1
    fi
}

# generic, not nocloud: the nocloud variant ships WITHOUT cloud-init (it just
# auto-logs-in root on the console), whereas provisioning Waydroid unattended
# needs cloud-init's NoCloud datasource driven from a seed ISO.
get "$DEBIAN_URL" "$DEBIAN_IMAGE"
if ! verify_debian_sha512 "$DEBIAN_IMAGE"; then
    rm -f -- "$DEBIAN_IMAGE"
    echo "[get ] retrying Debian image once after checksum failure"
    get "$DEBIAN_URL" "$DEBIAN_IMAGE"
    verify_debian_sha512 "$DEBIAN_IMAGE"
fi
get "$WAYDROID_BASE/system/lineage/waydroid_arm64/$WD_SYSTEM" waydroid-system.zip
get "$WAYDROID_BASE/vendor/waydroid_arm64/$WD_VENDOR"        waydroid-vendor.zip
verify_sha256 waydroid-system.zip "$WD_SYSTEM_SHA256"
verify_sha256 waydroid-vendor.zip "$WD_VENDOR_SHA256"

# Hashes authenticate the exact upstream archives before any extraction. ZIP
# structural validation remains a separate corruption/format check.
unzip -tq waydroid-system.zip >/dev/null
unzip -tq waydroid-vendor.zip >/dev/null

echo "--- guests/phase1 ---"
ls -lh "$OUT" | grep -v '^total' | awk '{print "  "$5"\t"$9}'
