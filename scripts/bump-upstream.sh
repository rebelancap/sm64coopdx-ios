#!/bin/bash
# Bump the vendored upstream (LeoManrique/sm64coopdx-ios) to a new commit and
# re-apply the overlay — the whole "take an upstream update" drill in one command.
#
#   Usage: scripts/bump-upstream.sh <new-commit-sha> [--sync-mirror]
#
# The overlay is match-count-asserted, so this is safe: a patch whose upstream
# anchor is UNCHANGED re-applies automatically; one whose anchor MOVED makes
# apply-overlay fail LOUD and name the patch. When that happens, regenerate that
# patch against the new pristine text (edit + re-run scripts/gen-patch-NNNN.py per
# the CLAUDE.md revise-a-patch drill), then re-run this script. Always rebuild and
# test on device before cutting a release.
#
# --sync-mirror also refreshes rebelancap/sm64coopdx-ios-base so the clean-machine
# fallback (bootstrap.sh) keeps covering the new pin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$ROOT/scripts/bootstrap.sh"
BASE_MIRROR="https://github.com/rebelancap/sm64coopdx-ios-base.git"
UPSTREAM="https://github.com/LeoManrique/sm64coopdx-ios.git"

NEWPIN="${1:-}"
[[ -n "$NEWPIN" ]] || { echo "usage: $0 <new-commit-sha> [--sync-mirror]" >&2; exit 1; }

OLDPIN=$(grep -oE 'PIN="[0-9a-f]{7,40}"' "$BOOT" | grep -oE '[0-9a-f]{7,40}')
[[ -n "$OLDPIN" ]] || { echo "FATAL: could not find PIN in $BOOT" >&2; exit 1; }
echo "bump: $OLDPIN -> $NEWPIN"

# 1. Rewrite the PIN (single source of truth). Portable (no GNU/BSD sed split).
OLDPIN="$OLDPIN" NEWPIN="$NEWPIN" BOOT="$BOOT" python3 - <<'PY'
import os
p=os.environ["BOOT"]; t=open(p).read()
t=t.replace(os.environ["OLDPIN"], os.environ["NEWPIN"])
open(p,"w").write(t)
PY

# 2. Reset vendor to the new pin (bootstrap fetches + checks out + cleans).
"$BOOT"

# 3. Re-apply the overlay. Fails loud (naming the patch) if a hunk no longer
#    anchors — regenerate that patch, then re-run this script.
"$ROOT/scripts/apply-overlay.sh"

echo "bump: overlay re-applied on $NEWPIN — now rebuild + test before releasing."

# 4. Optional: re-sync the base mirror so the fallback tracks the new pin.
if [[ "${2:-}" == "--sync-mirror" ]]; then
    echo "bump: re-syncing base mirror $BASE_MIRROR ..."
    T=$(mktemp -d)
    git clone --mirror "$UPSTREAM" "$T/m"
    git -C "$T/m" push --mirror "$BASE_MIRROR"
    rm -rf "$T"
    echo "bump: base mirror synced."
fi
