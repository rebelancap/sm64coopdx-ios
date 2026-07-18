#!/usr/bin/env python3
"""Overlay patch 0009: the visionOS app icon (.solidimagestack).

WHAT IT ADDS
  - CMakeLists.txt: on visionOS, swap the iOS asset catalog for a repo-owned
    visionOS catalog passed by path (-DSM64_VISIONOS_ASSETS).

WHY. visionOS app icons are LAYERED. A flat PNG in an .appiconset — which is
all the fork ships (platform/ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png,
1024x1024) — renders as a BLANK TILE on visionOS. That blank tile is visible in
artifacts/vision-sim-02.png and is recorded as deferred in M-15 known-open #5
and QUESTIONS Q-008. The fix is an AppIcon.solidimagestack of 1024x1024 layers.

WHY A SEPARATE CATALOG RATHER THAN THE CHARTER'S "SAME-NAME TRICK".
CLAUDE.md says: "Same-name trick works: AppIcon.appiconset +
AppIcon.solidimagestack in one catalog; actool picks per platform." True, and it
is the right call when you own the catalog. We do not: the catalog lives in
VENDOR (platform/ios/Assets.xcassets), so adding the stack there means adding
PNGs to vendor, and the overlay's only tool is `patch -p1`. macOS patch(1)
cannot apply git binary hunks, so PNGs cannot be delivered by a patch at all.
The alternatives were to base64 the layers into a text patch and decode at build
time (ugly, and the generator could not assert against them), or to have a
script stage binaries into vendor outside the overlay (which is exactly the
"upstream stays pristine" rule this repo exists to keep).

So: a repo-owned catalog at app/ios/Assets-visionos.xcassets, passed BY PATH —
the same mechanism overlay 0005 already uses for Info-visionos.plist
(SM64_VISIONOS_PLIST), and the same layout the sibling ports already landed on
(quake3e-ios/ios/Assets-visionos.xcassets, q2repro-ios/app/Assets-visionos.xcassets).
Non-compiled repo-owned files live in app/ and are passed by path — D-010 says
exactly this. It also keeps the iOS target bit-for-bit unaffected by
construction rather than by conditional: iOS never sees this variable.

WHY THE EDIT IS AT EOF AND USES set_target_properties RATHER THAN JUST
REASSIGNING ASSET_CATALOG. The obvious one-liner — making
`set(ASSET_CATALOG ${GAME_ROOT}/platform/ios/Assets.xcassets)` conditional — is
FORBIDDEN here, and it is worth writing down why so nobody "simplifies" it back.
That line (live 295) is TRAILING CONTEXT of overlay 0007's hunk, along with
`add_executable(...)` (live 297). Modifying either leaves 0007 un-reversible:
apply-overlay.sh's `patch -R --fuzz=0` probe would stop matching, and the next
run would die "FATAL: overlay patch 0007 neither applied nor appliable" — the
precise symptom CLAUDE.md warns about. Inserting BETWEEN 295 and 297 fails the
same way (it breaks 0007's trailing context block).

So this patch anchors just above the pristine `# Copy game data files into the
app bundle` block (live 403), which is ~12 lines past 0005's last hunk and has
real context on both sides. That position is still after add_executable() (297)
and after the set_target_properties() that sets RESOURCE (~365-380), which is
what the swap requires.

By that point add_executable() has already consumed ${ASSET_CATALOG} as a source
AND RESOURCE has already been set from it, so a late set(ASSET_CATALOG ...) would
be silently inert. Hence the swap-on-the-target form below: pull SOURCES, drop
the iOS catalog, add ours, re-point RESOURCE.

WHY NOT AT EOF, NEXT TO 0008 — a real mechanism, found by measurement, worth
keeping. The first cut of this patch appended at EOF right after overlay 0008's
EOF block. apply-overlay then went green from pristine (9/9) and FAILED on the
idempotent re-run with "FATAL: overlay patch 0008 neither applied nor appliable".
The cause is not D6 in its usual form — 0009 never touched a line 0008 wrote:

    A hunk generated at EOF has NO TRAILING CONTEXT (there is nothing after it
    to quote). macOS patch(1) anchors such a hunk to the end of the file, so it
    stops being reversible the moment ANYTHING is appended after it.

Isolated to that one variable: with 0009's block present (473 lines) 0008's
reverse probe fails; truncate the file so 0008's block ends it again (442 lines)
and the identical probe passes. The rule that falls out, and that the next patch
in this series needs to know: AT MOST ONE PATCH MAY APPEND AT EOF, and it must
stay last. 0008 holds that slot.
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
CATALOG = ROOT / "app/ios/Assets-visionos.xcassets"

# The catalog is repo-owned and passed by path, but it must EXIST and be a real
# solidimagestack or the patch is wiring up nothing. Assert the shape here so a
# missing/renamed layer is a generator failure rather than a silently blank tile
# on the device — the exact failure this patch exists to fix.
assert CATALOG.is_dir(), f"missing visionOS catalog: {CATALOG} (run scripts/gen-vision-icon.py)"
STACK = CATALOG / "AppIcon.solidimagestack"
assert (STACK / "Contents.json").is_file(), f"missing {STACK}/Contents.json"
for layer in ("Back", "Middle", "Front"):
    d = STACK / f"{layer}.solidimagestacklayer" / "Content.imageset"
    assert d.is_dir(), f"missing layer {layer}: {d}"
    pngs = list(d.glob("*.png"))
    assert len(pngs) == 1, f"[{layer}] expected exactly 1 png, got {len(pngs)}"

diffs = []


def diff_edit(orig, new, rel):
    with tempfile.TemporaryDirectory() as td:
        fa = pathlib.Path(td) / "a"
        fb = pathlib.Path(td) / "b"
        fa.write_text(orig)
        fb.write_text(new)
        r = subprocess.run(["diff", "-u", "--label", f"a/{rel}", "--label", f"b/{rel}",
                            str(fa), str(fb)], capture_output=True, text=True)
    assert r.returncode == 1, f"[{rel}] no diff produced"
    return r.stdout


def replace_once(text, old, new, tag, sentinel):
    """Match-count-asserted replace (charter ground rule 1) + already-applied guard."""
    assert sentinel not in text, (
        f"[{tag}] already applied (found sentinel {sentinel!r}) — "
        f"`patch -p1 -R` overlay 0009 out of vendor before regenerating")
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}"
    return text.replace(old, new)


REL_CMAKE = "CMakeLists.txt"
orig_cmake = (VENDOR / REL_CMAKE).read_text()

# Anchored on the pristine GAME_DATA_DIRS comment: real context on both sides
# (unlike an EOF hunk — see the docstring), clear of 0005's hunks, and late
# enough that add_executable() and the RESOURCE property already exist.
OLD_CMAKE = """# Copy game data files into the app bundle
set(GAME_DATA_DIRS
"""
NEW_CMAKE = """# ---- visionOS app icon (overlay 0009) ----
# visionOS icons are LAYERED (.solidimagestack); the fork's flat AppIcon.png
# renders as a BLANK TILE (M-15 known-open #5, Q-008). SM64_VISIONOS_ASSETS
# points at a repo-owned catalog carrying AppIcon.solidimagestack — passed by
# path exactly like SM64_VISIONOS_PLIST, because the overlay cannot deliver PNGs
# (patch(1) has no binary hunks) and vendor must stay pristine.
#
# The swap is done on the TARGET rather than by reassigning ASSET_CATALOG for
# two independent reasons:
#   1. By this point add_executable() has already consumed ${ASSET_CATALOG} as a
#      source and RESOURCE has already been set from it, so a late set() would
#      be silently inert.
#   2. The set(ASSET_CATALOG ...) line is trailing context of overlay 0007's
#      hunk. Editing it would leave 0007 un-reversible and break apply-overlay
#      on its next run (charter D6).
#
# The iOS target never defines SM64_VISIONOS_ASSETS, so its catalog is untouched.
if(SM64_VISIONOS AND SM64_VISIONOS_ASSETS)
    if(NOT EXISTS ${SM64_VISIONOS_ASSETS})
        message(FATAL_ERROR "SM64_VISIONOS_ASSETS does not exist: ${SM64_VISIONOS_ASSETS}")
    endif()
    get_target_property(_sm64_srcs sm64coopdx SOURCES)
    list(REMOVE_ITEM _sm64_srcs ${ASSET_CATALOG})
    list(APPEND _sm64_srcs ${SM64_VISIONOS_ASSETS})
    set_target_properties(sm64coopdx PROPERTIES
        SOURCES "${_sm64_srcs}"
        RESOURCE "${SM64_VISIONOS_ASSETS}"
    )
    message(STATUS "visionOS asset catalog: ${SM64_VISIONOS_ASSETS}")
endif()

# Copy game data files into the app bundle
set(GAME_DATA_DIRS
"""
t_cmake = replace_once(orig_cmake, OLD_CMAKE, NEW_CMAKE, "cmake-vision-icon",
                       "SM64_VISIONOS_ASSETS")
diffs.append(diff_edit(orig_cmake, t_cmake, REL_CMAKE))

out = ROOT / "overlay/patches/0009-visionos-app-icon.patch"
out.write_text(__doc__ + "\n" + "".join(diffs))
print(f"wrote {out} ({sum(len(d.splitlines()) for d in diffs)} diff lines)")
