#!/bin/bash
# Build xrOS (visionOS) slices of the three prebuilt deps the fork ships as
# iOS-only static libs:
#
#   vendor/sm64coopdx/lib/lua/ios/liblua53.a       -> liblua53.a
#   vendor/sm64coopdx/lib/coopnet/ios/libjuice.a   -> libjuice.a
#   vendor/sm64coopdx/lib/coopnet/ios/libcoopnet.a -> libcoopnet.a
#
# WHY THIS SCRIPT EXISTS: those three prebuilts are Mach-O *platform 2 (iOS)*
# (verified: LC_BUILD_VERSION platform 2, minos 15.0, sdk 26.2). An
# arm64-apple-xros binary cannot link them. There is no source in the tree for
# any of them, so we fetch pinned upstreams and build real xrOS slices.
#
# NOT USED, DELIBERATELY: `vtool -set-build-version`. Rewriting an iOS build's
# load command is rejected for this project (DECISIONS: it only works for pure
# C touching no platform frameworks, and its "simulator" output is really
# device code). Everything here is compiled from source against the real
# xros/xrsimulator sysroots.
#
# Outputs:
#   work/xros-deps/device/lib/{liblua53.a,libjuice.a,libcoopnet.a}   platform 11 (XROS)
#   work/xros-deps/sim/lib/{liblua53.a,libjuice.a,libcoopnet.a}      platform 12 (XROS_SIMULATOR)
#
# Every produced archive is asserted member-by-member: LC_BUILD_VERSION
# platform must be 11 (device) / 12 (simulator), and arch must be arm64.
# `lipo -info` only reports ARCH and would happily pass an iOS-platform lib —
# so we read LC_BUILD_VERSION, never lipo, for the platform gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/work/xros-src"
OUT="$ROOT/work/xros-deps"

# ---------------------------------------------------------------- pins -------
# Lua 5.3.5 -- NOT 5.3.6.
#
# The fork's commit 91b8f999 ("Replace Lua 5.3.6 source with prebuilt 5.3.5
# library for iOS") removed a lua-5.3.6 source tree, but the headers the game
# actually compiles against (lib/lua/include, wired in at CMakeLists.txt:73,196)
# are 5.3.5, and the shipped prebuilt reports `$LuaVersion: Lua 5.3.5`.
# Verified: lua-5.3.5/src/lua.h is BYTE-IDENTICAL to lib/lua/include/lua.h.
# Building 5.3.6 against 5.3.5 headers would be a gratuitous mismatch; 5.3.5
# reproduces the shipping iOS configuration exactly.
LUA_VER="5.3.5"
LUA_SHA256="0c2eed3f960446e1a3e4b9a1ca2f3ff893b6ce41942cf54d5dd59ab4b3b058ac"
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VER}.tar.gz"

# libjuice v1.6.2. Confirmed two ways: the mac dylib the fork ships is named
# libjuice.1.6.2.dylib, and coopnet's bundled lib/include/juice/juice.h is
# BYTE-IDENTICAL to libjuice v1.6.2's include/juice/juice.h.
JUICE_URL="https://github.com/paullouisageneau/libjuice.git"
JUICE_TAG="v1.6.2"
JUICE_COMMIT="85efaa9b5e1cb3d4d534fc85d69cc9f7b76a66d7"

# CoopNet upstream VERIFIED as github.com/coop-deluxe/coopnet (master @ 9d9b3dd,
# 2025-11-12). Evidence it matches the shipped prebuilt:
#   - vendor lib/coopnet/include/libcoopnet.h is BYTE-IDENTICAL to this commit's
#     common/libcoopnet.h.
#   - the prebuilt's C++ mangled symbols match this commit's signatures, e.g.
#     __ZN6Client11LobbyCreateE...S6_S6_S6_tS6_S6_ == LobbyCreate(string,string,
#     string,string,uint16_t,string,string).
COOPNET_URL="https://github.com/coop-deluxe/coopnet.git"
COOPNET_COMMIT="9d9b3dd4e87dba2fa3ca542ae32b73f43df32b0e"

XROS_MIN="2.0"

# ------------------------------------------------------------- helpers -------
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Assert every object in an archive is arm64 AND carries the expected
# LC_BUILD_VERSION platform. This is the whole point of the exercise: a wrong
# platform is exactly the bug we are fixing, so it must never slide.
#   1=macOS 2=iOS 3=tvOS 7=iOS-sim 11=XROS 12=XROS_SIMULATOR
verify_lib() {
    local lib="$1" want="$2" label="$3"
    [[ -f "$lib" ]] || { echo "FATAL: $label: $lib was not produced" >&2; exit 1; }

    local tmp; tmp="$(mktemp -d)"
    ( cd "$tmp" && ar -x "$lib" )

    local n=0 bad=0 obj plat arch
    shopt -s nullglob
    for obj in "$tmp"/*.o; do
        n=$((n + 1))
        # otool prints:  cmd LC_BUILD_VERSION / cmdsize / platform N / minos / sdk
        plat="$(otool -l "$obj" | awk '/cmd LC_BUILD_VERSION/{f=1;next} f&&/platform/{print $2;exit}')"
        arch="$(lipo -archs "$obj" 2>/dev/null || echo '?')"
        if [[ "$plat" != "$want" ]]; then
            echo "FATAL: $label: $(basename "$obj"): LC_BUILD_VERSION platform=${plat:-<none>}, expected $want" >&2
            bad=$((bad + 1))
        fi
        if [[ "$arch" != "arm64" ]]; then
            echo "FATAL: $label: $(basename "$obj"): arch=$arch, expected arm64" >&2
            bad=$((bad + 1))
        fi
    done
    shopt -u nullglob
    rm -rf "$tmp"

    [[ $n -gt 0 ]]   || { echo "FATAL: $label: archive has no objects" >&2; exit 1; }
    [[ $bad -eq 0 ]] || { echo "FATAL: $label: $bad bad object(s) -- refusing to ship" >&2; exit 1; }
    echo "  OK  $label: $n/$n objects arm64, LC_BUILD_VERSION platform $want"
}

# ------------------------------------------------------------- fetch ---------
fetch_all() {
    mkdir -p "$SRC"

    say "fetch lua $LUA_VER"
    if [[ ! -f "$SRC/lua-$LUA_VER.tar.gz" ]]; then
        curl -sSL "$LUA_URL" -o "$SRC/lua-$LUA_VER.tar.gz"
    fi
    local got; got="$(shasum -a 256 "$SRC/lua-$LUA_VER.tar.gz" | awk '{print $1}')"
    [[ "$got" == "$LUA_SHA256" ]] || {
        echo "FATAL: lua tarball sha256 $got != pinned $LUA_SHA256" >&2; exit 1; }
    # Always re-extract, then patch. The patch is generated against PRISTINE
    # upstream text (scripts/gen-patch-lua-xros-no-system.py asserts match
    # counts), so it must never be applied to an already-patched tree.
    rm -rf "${SRC:?}/lua-$LUA_VER"
    tar xzf "$SRC/lua-$LUA_VER.tar.gz" -C "$SRC"

    # REQUIRED for xrOS: loslib.c calls system(), which Apple marks
    # __IOS_PROHIBITED on every embedded SDK, so it will not compile:
    #   loslib.c:143:14: error: 'system' is unavailable: not available on visionOS
    # (The fork's shipped iOS prebuilt has no _system symbol either -- same fix,
    # theirs just undocumented.) See overlay/assets/lua-5.3.5-xros-no-system.patch.
    patch -p1 -d "$SRC/lua-$LUA_VER" < "$ROOT/overlay/assets/lua-5.3.5-xros-no-system.patch" \
        || { echo "FATAL: lua os.execute patch failed to apply" >&2; exit 1; }
    grep -q 'LUA_NO_PROCESS_SPAWN' "$SRC/lua-$LUA_VER/src/loslib.c" \
        || { echo "FATAL: lua patch applied but guard missing" >&2; exit 1; }
    # Guard the version the headers imply. If this trips, the pin drifted.
    grep -q '^#define LUA_VERSION_RELEASE\s*"5"' "$SRC/lua-$LUA_VER/src/lua.h" || {
        echo "FATAL: lua source is not 5.3.5" >&2; exit 1; }
    # The game compiles against lib/lua/include -- assert our source matches it,
    # so a header/lib ABI split can never sneak in.
    diff -q "$SRC/lua-$LUA_VER/src/lua.h" \
            "$ROOT/vendor/sm64coopdx/lib/lua/include/lua.h" >/dev/null || {
        echo "FATAL: lua-$LUA_VER/src/lua.h differs from vendor lib/lua/include/lua.h" >&2; exit 1; }

    say "fetch libjuice $JUICE_TAG"
    if [[ ! -d "$SRC/libjuice/.git" ]]; then
        git clone -q "$JUICE_URL" "$SRC/libjuice"
    fi
    git -C "$SRC/libjuice" fetch -q --tags origin
    git -C "$SRC/libjuice" checkout -q --force "$JUICE_COMMIT"
    git -C "$SRC/libjuice" clean -qfd

    say "fetch coopnet"
    if [[ ! -d "$SRC/coopnet/.git" ]]; then
        git clone -q "$COOPNET_URL" "$SRC/coopnet"
    fi
    git -C "$SRC/coopnet" fetch -q origin
    git -C "$SRC/coopnet" checkout -q --force "$COOPNET_COMMIT"
    git -C "$SRC/coopnet" clean -qfd
    # coopnet's public header must stay identical to the one the game includes.
    diff -q "$SRC/coopnet/common/libcoopnet.h" \
            "$ROOT/vendor/sm64coopdx/lib/coopnet/include/libcoopnet.h" >/dev/null || {
        echo "FATAL: coopnet common/libcoopnet.h differs from vendor lib/coopnet/include/libcoopnet.h" >&2
        echo "       -> the pin drifted from what the game expects; re-pin before shipping." >&2
        exit 1; }
    # coopnet vendors juice.h; it must match the libjuice we build against.
    diff -q "$SRC/coopnet/lib/include/juice/juice.h" \
            "$SRC/libjuice/include/juice/juice.h" >/dev/null || {
        echo "FATAL: coopnet's bundled juice.h != libjuice $JUICE_TAG juice.h" >&2; exit 1; }
}

# ------------------------------------------------------------- builds --------
# $1 = variant name (device|sim), $2 = sdk, $3 = -target triple, $4 = platform id

build_lua() {
    local variant="$1" sdk="$2" triple="$3"
    local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local bd="$OUT/$variant/obj/lua"; rm -rf "$bd"; mkdir -p "$bd"

    # liblua53.a == CORE_O + LIB_O from lua's own src/Makefile: every .c except
    # the two mains (lua.c = interpreter, luac.c = bytecode compiler).
    #
    # -DLUA_USE_POSIX only -- NOT LUA_USE_MACOSX. Fingerprinted from the shipped
    # iOS prebuilt: `nm -u liblua53.a` references _popen (=> LUA_USE_POSIX, which
    # enables l_popen in liolib.c) but has NO _dlopen (=> LUA_USE_DLOPEN off).
    # LUA_USE_MACOSX would imply LUA_USE_DLOPEN + LUA_USE_READLINE, neither of
    # which is correct here: xrOS forbids dlopen'ing arbitrary code, and there is
    # no readline. So POSIX-only exactly reproduces the shipping iOS config.
    local f
    for f in "$SRC/lua-$LUA_VER/src"/*.c; do
        case "$(basename "$f")" in lua.c|luac.c) continue ;; esac
        xcrun --sdk "$sdk" clang -target "$triple" -isysroot "$sysroot" \
            -O2 -fPIC -DLUA_USE_POSIX \
            -c "$f" -o "$bd/$(basename "$f" .c).o"
    done

    mkdir -p "$OUT/$variant/lib"
    rm -f "$OUT/$variant/lib/liblua53.a"
    ar rcs "$OUT/$variant/lib/liblua53.a" "$bd"/*.o
}

build_juice() {
    local variant="$1" sdk="$2" triple="$3"
    local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local bd="$OUT/$variant/obj/juice"; rm -rf "$bd"; mkdir -p "$bd"

    # juice_export.h is normally produced by CMake's generate_export_header().
    # We build with plain clang (no CMake visionOS toolchain to fight), so reuse
    # the copy coopnet vendors -- that is precisely the header coopnet's own
    # objects are compiled against, which keeps both sides in agreement.
    # Under -DJUICE_STATIC it collapses to empty JUICE_EXPORT anyway.
    local inc="$bd/include"; mkdir -p "$inc"
    cp "$SRC/coopnet/lib/include/juice/juice_export.h" "$inc/"

    # Source list mirrors LIBJUICE_SOURCES in libjuice's CMakeLists.txt.
    local srcs=(addr agent crc32 const_time conn conn_poll conn_thread conn_mux
                base64 hash hmac ice juice log random server stun timestamp turn udp)
    # USE_NETTLE=0 -> libjuice uses its built-in hash impls (picohash), so there
    # is no external crypto dependency to cross-build. JUICE_STATIC matches how
    # the fork consumes it (CMakeLists links libjuice.a).
    local s
    for s in "${srcs[@]}"; do
        xcrun --sdk "$sdk" clang -target "$triple" -isysroot "$sysroot" \
            -O2 -fPIC -Wall \
            -DJUICE_STATIC -DJUICE_EXPORTS -DUSE_NETTLE=0 \
            -I"$SRC/libjuice/include" -I"$SRC/libjuice/include/juice" \
            -I"$inc" -I"$SRC/libjuice/src" \
            -c "$SRC/libjuice/src/$s.c" -o "$bd/$s.o"
    done

    mkdir -p "$OUT/$variant/lib"
    rm -f "$OUT/$variant/lib/libjuice.a"
    ar rcs "$OUT/$variant/lib/libjuice.a" "$bd"/*.o
}

build_coopnet() {
    local variant="$1" sdk="$2" triple="$3"
    local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local bd="$OUT/$variant/obj/coopnet"; rm -rf "$bd"; mkdir -p "$bd"

    # coopnet's Makefile `lib` target is literally `ar rcs libcoopnet.a $(COMMON_OBJ)`
    # -- an archive of common/*.cpp objects with NO link step. That is why this
    # cross-builds so cleanly: nothing resolves symbols or picks frameworks here.
    # (Confirmed: the shipped iOS prebuilt contains exactly these 9 members.)
    #
    # -DOSX_BUILD=1 IS REQUIRED ON xrOS, and it is a correctness flag, not cosmetics.
    # Connection::Receive() clamps `remaining` to ioctl(FIONREAD) and then calls
    # recv(fd, buf, remaining, MSG_DONTWAIT). On an empty socket that is
    # recv(..., 0, ...), and on Darwin (XNU) a zero-length recv returns 0 with
    # errno 0 -- which Receive() interprets as "connection closed" -> Disconnect().
    # Linux instead returns -1/EAGAIN, which is why upstream hid the guard behind
    # OSX_BUILD. Verified empirically on XNU:
    #     recv(fd, buf, 0, MSG_DONTWAIT) => ret=0 errno=0
    #     recv(fd, buf, 64, MSG_DONTWAIT) => ret=-1 errno=35 (EAGAIN)
    # Client::Update() calls Receive() unconditionally (no read-readiness poll --
    # the select() in client.cpp is write-only, for connect). So WITHOUT this
    # define co-op compiles and links fine, then disconnects almost immediately
    # on device. iOS/xrOS are Darwin, so the guard applies.
    # In common/ the define only touches two sites (utils.cpp:1 -- a mach-o/dyld.h
    # include that __APPLE__ already provides, and connection.cpp:108 -- the guard),
    # so it has no unwanted side effects. The Makefile's other OSX_BUILD effects
    # (dylib naming, -arch, -install_name) live in link rules we never invoke.
    local f
    for f in "$SRC/coopnet/common"/*.cpp; do
        xcrun --sdk "$sdk" clang++ -target "$triple" -isysroot "$sysroot" \
            -O2 -fPIC -std=c++11 -Wall -Wno-unused-function \
            -DJUICE_STATIC -DOSX_BUILD=1 \
            -I"$SRC/coopnet/common" -I"$SRC/coopnet/lib/include" \
            -c "$f" -o "$bd/$(basename "$f" .cpp).o"
    done

    mkdir -p "$OUT/$variant/lib"
    rm -f "$OUT/$variant/lib/libcoopnet.a"
    ar rcs "$OUT/$variant/lib/libcoopnet.a" "$bd"/*.o
}

# --------------------------------------------------------------- main --------
fetch_all

build_variant() {
    local variant="$1" sdk="$2" triple="$3" plat="$4"
    say "build $variant  ($triple, sdk $sdk)"
    build_lua     "$variant" "$sdk" "$triple"
    build_juice   "$variant" "$sdk" "$triple"
    build_coopnet "$variant" "$sdk" "$triple"

    say "verify $variant -- LC_BUILD_VERSION platform must be $plat"
    verify_lib "$OUT/$variant/lib/liblua53.a"   "$plat" "$variant/liblua53.a"
    verify_lib "$OUT/$variant/lib/libjuice.a"   "$plat" "$variant/libjuice.a"
    verify_lib "$OUT/$variant/lib/libcoopnet.a" "$plat" "$variant/libcoopnet.a"
}

build_variant device xros        "arm64-apple-xros${XROS_MIN}"           11
build_variant sim    xrsimulator "arm64-apple-xros${XROS_MIN}-simulator" 12

# Cross-check that coopnet's undefined juice symbols are actually satisfied by
# the libjuice we built. Catches a stale/mismatched pairing that the per-file
# platform assert cannot see.
say "cross-check: coopnet's juice imports resolve against our libjuice"
for variant in device sim; do
    need="$(nm -u "$OUT/$variant/lib/libcoopnet.a" 2>/dev/null | grep -o '_juice_[A-Za-z_]*' | sort -u)"
    have="$(nm -gU "$OUT/$variant/lib/libjuice.a" 2>/dev/null | awk '/ T _juice/{print $3}' | sort -u)"
    missing="$(comm -23 <(echo "$need") <(echo "$have"))"
    if [[ -n "$missing" ]]; then
        echo "FATAL: $variant: libjuice.a does not define: $missing" >&2; exit 1
    fi
    echo "  OK  $variant: all $(echo "$need" | grep -c . ) juice imports resolved"
done

say "done"
echo "device: $OUT/device/lib   (platform 11 XROS)"
echo "sim:    $OUT/sim/lib      (platform 12 XROS_SIMULATOR)"
ls -la "$OUT/device/lib" "$OUT/sim/lib"
