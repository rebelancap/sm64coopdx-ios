#!/bin/bash
# Vendor the sm64coopdx iOS fork at a pinned commit. Upstream stays pristine:
# every local change is an overlay patch (overlay/patches/NNNN-*.patch) applied
# by scripts/apply-overlay.sh. Re-running resets vendor to the pin.
#
# BASE = LeoManrique/sm64coopdx-ios, NOT coop-deluxe/sm64coopdx. Upstream
# coopdx has no iOS support whatsoever (verified: zero iOS/xros references in
# its Makefile at 8cd6e597). Leo's fork adds the CMake iOS build, platform/ios,
# src/pc/platform_ios.m, touch controls, and prebuilt iOS coopnet/lua slices.
# See DECISIONS.md D-001.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/sm64coopdx"
REPO="https://github.com/LeoManrique/sm64coopdx-ios.git"
# Fallback mirror. Upstream is one person's fork and our whole build bootstraps
# from it, so an archive/delete would break the clean-machine drill. This is a
# DEDICATED pin-synced mirror of Leo's tree (NOT the overlay repo, which holds no
# vendored coopdx source); keep it fresh with `bump-upstream.sh --sync-mirror`.
# Override with SM64_VENDOR_MIRROR, or set it empty to clone from REPO only.
MIRROR="${SM64_VENDOR_MIRROR:-https://github.com/rebelancap/sm64coopdx-ios-base.git}"
# Pin: 2026-06-04 "Fix angle bracket in iOS Info.plist version string".
PIN="cfc54dbba84525a4ade2286a8a149510fbc268e7"

if [[ ! -d "$VENDOR/.git" ]]; then
    mkdir -p "$(dirname "$VENDOR")"
    git clone --filter=blob:none "$REPO" "$VENDOR" \
        || { [[ -n "$MIRROR" ]] && { echo "warn: upstream unreachable, trying mirror $MIRROR" >&2
                                     git clone --filter=blob:none "$MIRROR" "$VENDOR"; } \
             || { echo "FATAL: cannot clone $REPO (set SM64_VENDOR_MIRROR for a fallback)" >&2; exit 1; }; }
fi

git -C "$VENDOR" fetch --filter=blob:none origin "$PIN" 2>/dev/null || git -C "$VENDOR" fetch origin
git -C "$VENDOR" checkout -q --force "$PIN"
git -C "$VENDOR" clean -qfd -e '/lib/SDL2-source'
git -C "$VENDOR" submodule update --init --recursive

echo "vendor: sm64coopdx-ios pinned at $PIN"
git -C "$VENDOR" log -1 --format='  %h %ci %s'
