#!/bin/bash
# Vendor SDL2 into vendor/sm64coopdx/lib/SDL2-source at a pinned release.
#
# WHY THIS SCRIPT EXISTS: the fork gitignores lib/SDL2-source (.gitignore:101)
# and ships no submodule, so its build is NOT reproducible from a fresh clone.
# We pin SDL2 ourselves. See DECISIONS.md D-005.
#
# VERSION CHOICE (D-006): SDL2 2.32.10. Evidence that this is the right base —
# the fork's patches/sdl2-ios-gamepad-fix.patch declares pre-image blobs
# 0a96c68 (SDL_uikitevents.m) and dee4b19 (SDL_uikitviewcontroller.m), which are
# byte-identical to the pre-image blobs in Shipwright's
# sdl2-visionos-compat.patch against SDL2 2.32.10. One common base => the iOS
# gamepad fix and the visionOS compat patch compose on the same tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDL_DIR="$ROOT/vendor/sm64coopdx/lib/SDL2-source"
SDL_TAG="release-2.32.10"

if [[ -d "$SDL_DIR/.git" ]]; then
    git -C "$SDL_DIR" fetch --depth 1 origin "$SDL_TAG"
else
    mkdir -p "$(dirname "$SDL_DIR")"
    git clone --depth 1 --branch "$SDL_TAG" https://github.com/libsdl-org/SDL.git "$SDL_DIR"
fi
git -C "$SDL_DIR" checkout -q --force "$SDL_TAG" 2>/dev/null || true
git -C "$SDL_DIR" clean -qfd

# Anchor on ^#define: the SDL_VERSION() macro body below re-mentions these
# tokens and would clobber the captures.
V=$(awk '/^#define SDL_MAJOR_VERSION/{a=$3} /^#define SDL_MINOR_VERSION/{b=$3} /^#define SDL_PATCHLEVEL/{c=$3} END{print a"."b"."c}' \
    "$SDL_DIR/include/SDL_version.h")
[[ "$V" == "2.32.10" ]] || { echo "FATAL: expected SDL 2.32.10, got $V" >&2; exit 1; }

# Assert the patch base is what we think it is, so a silent upstream retag can
# never quietly shift the tree under our patches.
H=$(git -C "$SDL_DIR" hash-object src/video/uikit/SDL_uikitevents.m)
[[ "$H" == 0a96c682* ]] || {
    echo "FATAL: SDL_uikitevents.m blob $H != expected 0a96c682* (patch base drifted)" >&2
    exit 1
}

echo "sdl2: $SDL_TAG ($V) at $SDL_DIR"
