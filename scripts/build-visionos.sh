#!/bin/bash
# Build sm64coopdx for the visionOS DEVICE (arm64, signed).
#
# The device sibling of build-vision-sim.sh. Same vendor tree, same overlay,
# same Metal backend — only the sysroot, the dep slices and the signing differ.
#
# Produces build-visionos/Release-xros/sm64coopdx.app
#
# Prereqs, all asserted below rather than assumed:
#   - vendor/                     scripts/bootstrap.sh
#   - lib/SDL2-source             scripts/fetch-sdl2.sh
#   - work/xros-deps/device/lib   scripts/build-deps-xros.sh   <- DEVICE, not sim
#   - build/us_pc assets          (cd vendor/sm64coopdx && ./build_ios.sh desktop)
#     ~10 min; the CMake build consumes its generated .inc.c/anim/sound output.
#     NOTE: this is a HOST asset build, not a ROM extraction — the ROM is a
#     RUNTIME input on all targets (M-3), so no ROM is needed to build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/sm64coopdx"
BUILD="$ROOT/build-visionos"
DEPS="$ROOT/work/xros-deps/device"
TEAM="${SM64_IOS_TEAM:-57G8J46Z2T}"
# CFBundleShortVersionString. Must equal the git tag and GitHub release string, or
# SideStore never offers the update (it string-compares this against the source JSON).
MARKETING_VERSION="${SM64_MARKETING_VERSION:-1.1.1}"

[[ -d "$VENDOR/.git" ]] || "$ROOT/scripts/bootstrap.sh"
[[ -d "$VENDOR/lib/SDL2-source/.git" ]] || "$ROOT/scripts/fetch-sdl2.sh"
[[ -f "$DEPS/lib/libcoopnet.a" ]] || {
    echo "FATAL: xrOS DEVICE dep slices missing — run scripts/build-deps-xros.sh" >&2
    exit 1
}
# Assert the heavy host assets AND the GAME_DATA_DIRS (lang/dynos/palettes) that
# CMake copies into the bundle — CMake's if(EXISTS) SILENTLY skips a missing one,
# which shipped an IPA with no lang/ (the LANGUAGE-menu device bug). Self-heals a
# wiped build/us_pc/lang; FATALs loudly on anything it cannot reconstruct.
"$ROOT/scripts/assert-game-data.sh" "$VENDOR"

# The dep slices are the #1 device/sim confusion risk: they are the ONE input
# that differs by path only, and lipo reports arm64 for both (M-11). Assert the
# Mach-O platform of a real member before spending 10 minutes on a build that
# would fail at link (or worse, at runtime). 11 = XROS.
for L in libcoopnet libjuice liblua53; do
    TMPD=$(mktemp -d)
    ( cd "$TMPD" && ar -x "$DEPS/lib/$L.a" 2>/dev/null )
    OBJ=$(find "$TMPD" -name '*.o' | head -1)
    DPLAT=$(otool -l "$OBJ" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
    rm -rf "$TMPD"
    [[ "$DPLAT" == "11" ]] || {
        echo "FATAL: $DEPS/lib/$L.a reports platform=$DPLAT, expected 11 (XROS)." >&2
        echo "       Is work/xros-deps/device/ actually the SIMULATOR slices (12)?" >&2
        exit 1
    }
done

"$ROOT/scripts/apply-overlay.sh"

# CMAKE_SYSTEM_NAME=visionOS is left ALONE all the way down (no flip back to
# "iOS") — see build-vision-sim.sh and overlay 0005's docstring (D-011).
#
# STRIP_INSTALLED_PRODUCT=NO is the load-bearing one here (VISION-PRO-GUIDE
# 1.4 #1): `xcodebuild archive` strips the installed product, and a stripped
# binary only misbehaves in ARCHIVED/OTA builds — every cable install stays
# green, so it hides until the first real OTA. In THIS port the symptom is not
# the guide's dlsym one (there is no dlsym(RTLD_DEFAULT) in the tree — the only
# dlsym calls are miniaudio's Windows WASAPI/DSound/WinMM paths): it is that our
# crash handler symbolicates via backtrace_symbols_fd (D-014/D-015), and
# _shell_crash_handler is a LOCAL symbol. Strip it and every crash report from
# the headset — the one device we cannot attach a debugger to — degrades to bare
# hex addresses. The publish script asserts the symbol survived the archive.
#
# SM64_DEVELOPMENT_TEAM, NOT CMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM: the vendor
# CMakeLists sets DEVELOPMENT_TEAM as a TARGET property (hardcoded ""), and
# Xcode target settings beat the project-level settings that CMAKE_XCODE_ATTRIBUTE_*
# writes. The cache attribute lands in the pbxproj and is then silently overridden
# -> "Signing for 'sm64coopdx' requires a development team" (M-27, overlay 0005).
# CMAKE_PROJECT_sm64coopdx_INCLUDE: the Phase 2 stereo-3D build wiring (Swift
# @main + CompositorServices), passed by path like the plist/assets. Every legal
# CMakeLists.txt anchor after add_executable() is owned by an existing overlay
# hunk, so overlay 0011 deliberately has NO CMakeLists.txt hunk at all.
# See app/vision3d/vision3d.cmake for the full reasoning.
cmake --no-warn-unused-cli -S "$VENDOR" -B "$BUILD" -GXcode \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT=xros \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 \
    -DCMAKE_XCODE_ATTRIBUTE_XROS_DEPLOYMENT_TARGET=2.0 \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY=7 \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    -DSDL_OPENGLES=OFF -DSDL_OPENGL=OFF \
    "-DSM64_DEVELOPMENT_TEAM=$TEAM" \
    "-DIOS_MARKETING_VERSION=$MARKETING_VERSION" \
    "-DSM64_XROS_DEPS_PREFIX=$DEPS" \
    "-DSM64_VISIONOS_PLIST=$ROOT/app/ios/Info-visionos.plist" \
    "-DSM64_VISIONOS_ASSETS=$ROOT/app/ios/Assets-visionos.xcassets" \
    "-DCMAKE_PROJECT_sm64coopdx_INCLUDE=$ROOT/app/vision3d/vision3d.cmake" \
    "-DSM64_SDL2_VISIONOS_PATCH=$ROOT/overlay/assets/sdl2-visionos-compat.patch"

cmake --build "$BUILD" --config Release --target sm64coopdx --parallel 12 \
    -- -allowProvisioningUpdates

APP="$BUILD/Release-xros/sm64coopdx.app"
[[ -d "$APP" ]] || { echo "FATAL: expected app at $APP" >&2; exit 1; }
BIN="$APP/sm64coopdx"

# ---- Assert the PRODUCT, not the flags ----
# lipo reports only the arch (arm64) and would happily pass an iOS or a
# SIMULATOR binary — the exact bug class these asserts exist for (M-11/M-15).
PLAT=$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
[[ "$PLAT" == "11" ]] || {
    echo "FATAL: built binary reports platform=$PLAT, expected 11 (XROS)." >&2
    echo "       12 = XROS_SIMULATOR (wrong sysroot), 2 = iOS." >&2
    exit 1
}

ARCH=$(lipo -info "$BIN" | sed 's/.*: //')
[[ "$ARCH" == "arm64" ]] || { echo "FATAL: arch is '$ARCH', expected arm64" >&2; exit 1; }

# NOTE ON THE FORM OF THESE ASSERTS: they all use `grep -c` + a count test, never
# `grep -q`. Under `set -o pipefail`, `grep -q` exits at the FIRST match, the
# producer (nm/otool) is killed by SIGPIPE, and the pipeline reports 141 — so
# `producer | grep -q X` FAILS PRECISELY WHEN X IS FOUND. That inverts every
# assert here: the OpenGL check would fail-open (a genuinely GL-linked binary
# would SIGPIPE otool, the `if` would read false, and the assert would pass), and
# the symbol check would fail-closed on a perfectly good binary. Both were
# observed on this script (M-29). `grep -c` consumes all input, so no SIGPIPE.
LDLIBS=$(otool -L "$BIN")

# GL is not merely unused on visionOS — every entry point is API-unavailable
# (M-1/M-15). A linked OpenGLES would mean overlay 0005's gating regressed.
NGL=$(printf '%s\n' "$LDLIBS" | grep -ci "OpenGL" || true)
[[ "$NGL" -eq 0 ]] || {
    echo "FATAL: binary links OpenGL — visionOS must be Metal-only (M-1)" >&2
    printf '%s\n' "$LDLIBS" | grep -i "OpenGL" >&2
    exit 1
}
NMETAL=$(printf '%s\n' "$LDLIBS" | grep -ci "Metal.framework" || true)
[[ "$NMETAL" -ge 1 ]] || { echo "FATAL: binary does not link Metal" >&2; exit 1; }

# The crash handler's symbolication dependency (see STRIP note above). This is a
# LOCAL symbol ('t', not 'T'), so `nm -gU` — which lists only external defined
# symbols — CANNOT see it and would happily pass a binary whose crash reports
# have degraded to bare hex. Assert against the full symbol table instead.
NSYM=$(nm "$BIN" 2>/dev/null | wc -l | tr -d ' ')
NCRASH=$(nm "$BIN" 2>/dev/null | grep -c "_shell_crash_handler" || true)
[[ "$NCRASH" -ge 1 ]] || {
    echo "FATAL: _shell_crash_handler missing ($NSYM symbols) — binary looks stripped;" >&2
    echo "       device crash reports would be unsymbolicated (VISION-PRO-GUIDE 1.4)" >&2
    exit 1
}

codesign -dv "$APP" 2>&1 | sed -n '1,4p'
echo "platform=11 (XROS) arch=$ARCH  metal=yes  opengl=no  symbols=$NSYM  crash-sym=ok"
echo "built (visionOS device): $APP"
