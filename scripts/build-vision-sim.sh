#!/bin/bash
# Build sm64coopdx for the visionOS SIMULATOR (arm64).
#
# Phase 1 of the Vision Pro port. Same vendor tree as the iOS build, plus the
# overlay: the Metal backend (D-002, patches 0001-0003), the platform_ios
# visionOS shims (0004), and the visionOS CMake target (0005).
#
# Produces build-vision-sim/Release-xrsimulator/sm64coopdx.app
#
# Prereqs, all asserted below rather than assumed:
#   - vendor/                    scripts/bootstrap.sh
#   - lib/SDL2-source            scripts/fetch-sdl2.sh
#   - work/xros-deps/sim/lib     scripts/build-deps-xros.sh
#   - build/us_pc assets         (cd vendor/sm64coopdx && ./build_ios.sh desktop)
#     ~10 min; the CMake build consumes its generated .inc.c/anim/sound output.
#     NOTE: this is a HOST asset build, not a ROM extraction — the ROM is a
#     RUNTIME input on all targets (M-3), so no ROM is needed to build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/sm64coopdx"
BUILD="$ROOT/build-vision-sim"
DEPS="$ROOT/work/xros-deps/sim"

[[ -d "$VENDOR/.git" ]] || "$ROOT/scripts/bootstrap.sh"
[[ -d "$VENDOR/lib/SDL2-source/.git" ]] || "$ROOT/scripts/fetch-sdl2.sh"
[[ -f "$DEPS/lib/libcoopnet.a" ]] || {
    echo "FATAL: xrOS simulator dep slices missing — run scripts/build-deps-xros.sh" >&2
    exit 1
}
# Assert the heavy host assets AND the GAME_DATA_DIRS (lang/dynos/palettes) that
# CMake copies into the bundle — CMake's if(EXISTS) SILENTLY skips a missing one,
# which shipped an IPA with no lang/ (the LANGUAGE-menu device bug). Self-heals a
# wiped build/us_pc/lang; FATALs loudly on anything it cannot reconstruct.
"$ROOT/scripts/assert-game-data.sh" "$VENDOR"

"$ROOT/scripts/apply-overlay.sh"

# CMAKE_SYSTEM_NAME=visionOS is left ALONE all the way down (no flip back to
# "iOS"): this tree dispatches on its own TARGET_IOS define, and SDL2 2.32.10
# self-detects visionOS from CMAKE_SYSTEM_NAME (cmake/sdlplatform.cmake ->
# set(VISIONOS TRUE)). See overlay 0005's docstring.
#
# SDL_OPENGLES/SDL_OPENGL OFF: GLES does not exist on visionOS (M-1) — every GL
# entry point in the xrOS SDK is marked unavailable. We render through Metal.
# CMAKE_PROJECT_sm64coopdx_INCLUDE: the Phase 2 stereo-3D build wiring (Swift
# @main + CompositorServices), passed by path like the plist/assets. Every legal
# CMakeLists.txt anchor after add_executable() is owned by an existing overlay
# hunk, so overlay 0011 deliberately has NO CMakeLists.txt hunk at all.
# See app/vision3d/vision3d.cmake for the full reasoning.
cmake --no-warn-unused-cli -S "$VENDOR" -B "$BUILD" -GXcode \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT=xrsimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 \
    -DCMAKE_XCODE_ATTRIBUTE_XROS_DEPLOYMENT_TARGET=2.0 \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    -DSDL_OPENGLES=OFF -DSDL_OPENGL=OFF \
    "-DSM64_XROS_DEPS_PREFIX=$DEPS" \
    "-DSM64_VISIONOS_PLIST=$ROOT/app/ios/Info-visionos.plist" \
    "-DSM64_VISIONOS_ASSETS=$ROOT/app/ios/Assets-visionos.xcassets" \
    "-DCMAKE_PROJECT_sm64coopdx_INCLUDE=$ROOT/app/vision3d/vision3d.cmake" \
    "-DSM64_SDL2_VISIONOS_PATCH=$ROOT/overlay/assets/sdl2-visionos-compat.patch"

cmake --build "$BUILD" --config Release --target sm64coopdx --parallel 12

APP="$BUILD/Release-xrsimulator/sm64coopdx.app"
[[ -d "$APP" ]] || { echo "FATAL: expected app at $APP" >&2; exit 1; }

# Assert the Mach-O platform rather than trusting the SDK flags: lipo reports
# only the arch (arm64) and would happily pass an iOS binary — the exact bug
# class the dep-slice asserts guard (M-11). 12 = XROS_SIMULATOR.
PLAT=$(otool -l "$APP/sm64coopdx" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
[[ "$PLAT" == "12" ]] || {
    echo "FATAL: built binary reports platform=$PLAT, expected 12 (XROS_SIMULATOR)" >&2
    exit 1
}

lipo -info "$APP/sm64coopdx"
echo "built (visionOS simulator): $APP"
