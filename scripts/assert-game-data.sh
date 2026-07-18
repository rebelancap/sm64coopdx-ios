#!/bin/bash
# assert-game-data.sh VENDOR_DIR
#
# Guarantee the game-data dirs that CMake's GAME_DATA_DIRS copies into the app
# bundle are PRESENT and NON-EMPTY before configure — and make a missing one a
# LOUD failure instead of a silent one.
#
# WHY THIS EXISTS (shipped device bug, 2026-07-16). CMakeLists.txt copies lang,
# dynos and palettes into Resources/ inside `foreach(DATA_DIR ...) if(EXISTS
# ${DATA_DIR}) ...`. The `if(EXISTS)` SILENTLY SKIPS a missing dir — no warning,
# no error — so an absent build/us_pc/lang shipped an IPA with dynos/ and
# palettes/ at the bundle root but NO lang/, and the device LANGUAGE menu failed
# with "Failed to load language folder".
#
# It goes missing because the Makefile WIPES build/us_pc/{lang,palettes} at every
# parse (Makefile:584/594) and only the desktop EXE target restores lang
# (Makefile:1175 copies the checked-in source lang/ dir). So lang disappears
# whenever any later `make` parse runs without building the exe — nondeterministic
# and invisible until the bundle reaches a device.
#
# The old prereq gate keyed only on build/us_pc/assets/mario_anim_data.c, which
# can exist while lang does not (exactly the state that shipped). This asserts the
# ACTUAL GAME_DATA_DIRS instead, and self-heals lang (a plain copy of the
# checked-in source, identical to the Makefile rule) so the wipe race cannot ship
# a bundle with no LANGUAGE folder.
set -euo pipefail

VENDOR="${1:?usage: assert-game-data.sh <vendor-dir>}"

nonempty() { [[ -d "$1" ]] && [[ -n "$(ls -A "$1" 2>/dev/null)" ]]; }

# Heavy generated assets (textures / anim / sound) genuinely need the full
# desktop build; there is no cheap way to reconstruct them here.
[[ -f "$VENDOR/build/us_pc/assets/mario_anim_data.c" ]] || {
    echo "FATAL: host assets missing — run: (cd vendor/sm64coopdx && ./build_ios.sh desktop)" >&2
    exit 1
}

# lang: build/us_pc/lang is a plain copy of the checked-in source lang/ dir
# (Makefile:1175-1176). Regenerate it here so a Makefile parse that wiped it
# cannot silently ship a bundle with no LANGUAGE folder.
if ! nonempty "$VENDOR/build/us_pc/lang"; then
    if nonempty "$VENDOR/lang"; then
        echo "game-data: build/us_pc/lang missing — regenerating from source lang/"
        rm -rf "$VENDOR/build/us_pc/lang"
        cp -R "$VENDOR/lang" "$VENDOR/build/us_pc/lang"
    fi
fi

# Final LOUD assertion. These three are exactly CMake's GAME_DATA_DIRS
# (build/us_pc/lang, build/us_pc/dynos, ${GAME_ROOT}/palettes). If any is still
# missing the bundle would ship without it — the silent-skip that caused the bug.
fail=0
for d in "build/us_pc/lang" "build/us_pc/dynos" "palettes"; do
    if ! nonempty "$VENDOR/$d"; then
        echo "FATAL: game-data dir '$d' is missing or empty under $VENDOR" >&2
        echo "       CMake's GAME_DATA_DIRS if(EXISTS) would SILENTLY skip it and the" >&2
        echo "       app bundle would ship without it (the lang/ device bug)." >&2
        echo "       Run: (cd vendor/sm64coopdx && ./build_ios.sh desktop)" >&2
        fail=1
    fi
done
[[ $fail -eq 0 ]] || exit 1

LANGN=$(ls -A "$VENDOR/build/us_pc/lang" | grep -c '\.ini$' || true)
echo "game-data: lang ($LANGN .ini) / dynos / palettes present + non-empty"
