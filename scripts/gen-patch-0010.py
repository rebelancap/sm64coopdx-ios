#!/usr/bin/env python3
"""Overlay patch 0010: MEASURE the visionOS panel refresh rate, and default this
platform's frame limiter to it.

THE USER'S REPORT: "let's change the default FPS in display to MANUAL and limit
at 120. Auto don't push it to 120, but remained at 60. Can you do
programmatically, if m2 Vision Pro, then 90, if m5, then 120. Or if there's
another way to read max refresh rate."

There IS another way to read the max refresh rate, and it is the only one on this
platform that is a reading rather than a claim. See app/hz/sm64_vision_hz.h for
the full why; the short version is that all three alternatives are broken:

  - UIScreen.maximumFramesPerSecond          — does not exist on visionOS.
  - SDL_GetCurrentDisplayMode().refresh_rate — visionOS has no UIScreen for SDL
    either, so OUR OWN compat patch synthesizes the display and HARDCODES
    `mode.refresh_rate = 120` ("M5 Vision Pro panel max"). Asking SDL reads our
    own guess back; it is wrong on an M2 (90 Hz) by construction.
  - hw.machine -> RealityDevice14,1 => 90    — the thing the user offered, and
    the thing to refuse. A model table is wrong in the one direction that
    matters: hardware that does not exist yet is not in it, so a future headset
    silently falls to a default forever.

So: a CADisplayLink, its preferredFrameRateRange clamped by the system to what
the panel can actually do, sampled and taken as a median. A measurement, correct
on hardware that did not exist when this was written.

WHAT IT ADDS
  - src/pc/sm64_vision_hz.{h,m}  new files, packaged from app/hz/ per D-010 —
    the source of truth is app/hz/, NOT this patch.
  - CMakeLists.txt              the .m into the target, visionOS-only.
  - pc_main.c                   get_display_refresh_rate(): a visionOS branch
                                that returns the MEASURED rate, uncached.
  - configfile.{c,h}            the `vision_framerate_rev` marker that makes the
                                framerate migration run exactly once.

THE STATIC-CACHE TRAP, WHICH IS WHY pc_main.c HAD TO BE TOUCHED AT ALL.
get_display_refresh_rate() (pc_main.c:212) caches its answer in a function-local
static, computed on the FIRST call — and the first call happens on the first
rendered frame, ~0.5 s before the panel measurement settles. Left alone, it would
latch the pre-measurement fallback FOREVER and the entire fix would do nothing
while appearing to work. The visionOS branch therefore does not cache: the module
publishes a settled value exactly once and the accessor is a volatile read, so
"cache it here" buys a load and costs correctness.

WHY platform_ios_get_refresh_rate() IS LEFT ALONE, stated plainly because the
task asked for it to be changed. Its visionOS body sits ENTIRELY inside overlay
0004's hunk 4 (`@@ -81,7 +114,20 @@`). Editing it from here is the exact thing
charter D6 forbids — "patches must not edit inside each other's hunks" — and
would break 0004's reverse probe, which is what apply-overlay.sh uses to decide a
patch is already applied ("neither applied nor appliable"). The alternatives were
(a) revise 0004 in place, while a second agent is working the same tree, or
(b) route the engine past it. (b) is what this patch does: pc_main.c's
get_display_refresh_rate() is platform_ios_get_refresh_rate()'s ONLY caller, and
the visionOS branch added here preempts it, so on visionOS that function is now
unreachable. It stays correct on iOS, which is its remaining job. This is
recorded in DECISIONS.md rather than left for someone to rediscover.

D6 — checked against the live patched tree, not hoped:
  - pc_main.c: get_display_refresh_rate() is at live lines 212-236. Overlay
    0002's nearest pc_main hunk begins at live 246 (its leading context is
    246-248, `return;` / `}` / blank inside select_graphics_backend); 0007's are
    at 318+; 0008's at 594+. This hunk's trailing context is 237-239, six lines
    clear of the nearest.
  - CMakeLists.txt: 0008 holds the EOF slot (M-26 — an at-EOF hunk stops being
    reversible once anything is appended after it), so this patch must NOT
    append. The live free ranges (pristine-vs-final diff) are ..., 277-282,
    298-303, ... — this patch inserts at 299, inside 298-303, whose neighbours
    are 0007's hunk (ending 297) and 0005's (starting 304). It modifies nothing
    either of them treats as context; it only shifts their line numbers, which
    patch(1) resolves as an offset (--fuzz=0 forbids fuzz, not offsets).
  - configfile.{c,h}: no overlay patch touches either file. Free ground.

THE PERSISTED-CVAR TRAP, AND WHY THE FIX IS A MIGRATION AND NOT A DEFAULT.
`framerate_mode` and `frame_limit` are persisted in sm64config.txt
(configfile.c:308-309), so changing the C defaults at configfile.c:107-108 would
only ever affect a config file that does not exist yet. The user already has both
keys on disk; configfile_load() would put 0/60 straight back and the fix would
look unapplied. Hence `vision_framerate_rev`: one persisted marker that makes the
policy run exactly once per config, so a user who later chooses AUTO on purpose
is never clobbered. It also removes the need for a separate "default" — a fresh
config has rev=0 for the same reason a legacy config does, and gets the same
treatment. One mechanism, both cases.
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
APP = ROOT / "app/hz"

diffs = []


def diff_new_file(text, rel):
    """/dev/null hunk for a repo-owned new file (D-010 / overlay 0001 pattern)."""
    r = subprocess.run(["git", "-C", str(VENDOR), "ls-files", "--error-unmatch", rel],
                       capture_output=True)
    assert r.returncode != 0, f"[{rel}] already tracked upstream — 0010 must not clobber it"
    with tempfile.TemporaryDirectory() as td:
        empty = pathlib.Path(td) / "empty"
        empty.write_text("")
        new = pathlib.Path(td) / "new"
        new.write_text(text)
        r = subprocess.run(
            ["diff", "-uN", "--label", "/dev/null", "--label", f"b/{rel}",
             str(empty), str(new)], capture_output=True, text=True)
    assert r.returncode == 1, f"[{rel}] no diff produced"
    return r.stdout


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
    """Match-count-asserted replace (charter ground rule 1) + already-applied guard.

    The count assert alone is not enough for anchors whose OLD text is a PREFIX
    of their NEW text (we insert around the anchor rather than rewrite it): on an
    already-patched tree `count(old) == 1` is still true and the generator would
    happily emit a doubled hunk, which is invisible until it miscompiles. The
    sentinel turns the charter's reverse-then-regenerate workflow from a
    convention into an enforced failure.
    """
    assert sentinel not in text, (
        f"[{tag}] already applied (found sentinel {sentinel!r}) — "
        f"`patch -p1 -R` overlay 0010 out of vendor before regenerating")
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}"
    return text.replace(old, new)


# ---------------------------------------------------------------------------
# 1. The measurement module — packaged from app/hz/ (source of truth), not
#    authored here. D-010: a new file has no pristine anchor to assert against,
#    so keeping the real file real is what keeps the generator honest.
# ---------------------------------------------------------------------------
for src_name, rel in [("sm64_vision_hz.h", "src/pc/sm64_vision_hz.h"),
                      ("sm64_vision_hz.m", "src/pc/sm64_vision_hz.m")]:
    src = APP / src_name
    assert src.is_file(), f"missing source of truth: {src}"
    text = src.read_text()
    assert text, f"empty source: {src}"
    diffs.append(diff_new_file(text, rel))

# ---------------------------------------------------------------------------
# 2. CMakeLists.txt — the .m into the target, visionOS-only.
#
#    Anchored on the miniaudio ObjC comment, which is pristine and sits in the
#    298-303 gap between overlay 0007's hunk (ends 297) and 0005's (starts 304).
#    NOT appended at EOF: 0008 owns that slot and an at-EOF hunk stops being
#    reversible once anything follows it (M-26).
#
#    target_sources() rather than list(APPEND IOS_OBJC_FILES ...) because
#    IOS_OBJC_FILES was consumed by add_executable() on the line above — a
#    list(APPEND) here would be silently ignored and the file would never
#    compile, with no error to show for it.
# ---------------------------------------------------------------------------
REL_CMAKE = "CMakeLists.txt"
orig_cmake = (VENDOR / REL_CMAKE).read_text()

OLD_CMAKE = """# Files that include miniaudio.h need ObjC on iOS (AVFoundation headers).
"""
NEW_CMAKE = """# ---- visionOS panel refresh-rate measurement (overlay 0010) ----
# Measures the real panel rate from a CADisplayLink and defaults the frame
# limiter to it. visionOS has no UIScreen, and the SDL display mode our own
# compat patch synthesizes carries a HARDCODED 120 — so the panel rate is not
# readable on this platform, only measurable. See src/pc/sm64_vision_hz.h.
#
# Guarded on SM64_VISIONOS so the iOS target's source list stays bit-for-bit
# identical; the file's own body is additionally gated on TARGET_OS_VISION via
# TargetConditionals, so a forgotten build flag can never be why it is missing.
if(SM64_VISIONOS)
    target_sources(sm64coopdx PRIVATE ${GAME_ROOT}/src/pc/sm64_vision_hz.m)
endif()

# Files that include miniaudio.h need ObjC on iOS (AVFoundation headers).
"""
t_cmake = replace_once(orig_cmake, OLD_CMAKE, NEW_CMAKE, "cmake-hz-source",
                       "sm64_vision_hz.m")
diffs.append(diff_edit(orig_cmake, t_cmake, REL_CMAKE))

# ---------------------------------------------------------------------------
# 3. pc_main.c — get_display_refresh_rate() gets a visionOS branch.
#
#    THE STATIC CACHE IS THE POINT. Both existing branches memoize into a
#    function-local static on first call. The first call is on the first rendered
#    frame — ~0.5 s BEFORE the panel measurement settles — so a memoized visionOS
#    branch would latch the fallback forever and the fix would silently do
#    nothing. The new branch deliberately does not cache.
#
#    The whole function is replaced rather than edited around, because the
#    #ifdef ladder has to be re-ordered: SM64_VISION_HZ must be tested BEFORE
#    TARGET_IOS (which is also defined on visionOS — it is how this file reaches
#    platform_ios.m at all).
# ---------------------------------------------------------------------------
REL_MAIN = "src/pc/pc_main.c"
orig_main = (VENDOR / REL_MAIN).read_text()

OLD_RATE = """static u32 get_display_refresh_rate(void) {
#ifdef TARGET_IOS
    // On iOS, UIScreen.maximumFramesPerSecond reliably reports ProMotion rates (120Hz)
    // while SDL_GetCurrentDisplayMode may report only 60Hz
    static u32 refreshRate = 0;
    if (!refreshRate) {
        refreshRate = platform_ios_get_refresh_rate();
        if (refreshRate == 0) { refreshRate = 60; }
    }
    return refreshRate;
#elif defined(HAVE_SDL2)
"""
NEW_RATE = """// Included HERE rather than with the includes at the top of this file, for the
// same reason overlay 0007's and 0008's includes are displaced: overlay 0002 owns
// that block and the charter's D6 forbids one overlay patch editing inside
// another's hunk. The header compiles to nothing off visionOS (it derives
// SM64_VISION_HZ from TargetConditionals), so the desktop oracle and the iOS
// target are untouched.
#include "sm64_vision_hz.h"

static u32 get_display_refresh_rate(void) {
#ifdef SM64_VISION_HZ
    // visionOS: the panel rate is MEASURED (src/pc/sm64_vision_hz.m), because on
    // this platform it cannot be read. UIScreen does not exist, and the SDL
    // display mode below would return the 120 our own SDL compat patch hardcoded
    // into a synthesized display — i.e. our guess, not the panel. That guess is
    // wrong on an M2-generation headset (90 Hz) by construction.
    //
    // This branch MUST come before TARGET_IOS: TARGET_IOS is also defined on
    // visionOS (it is how this file reaches platform_ios.m at all), so an
    // #elif here would be dead code.
    //
    // AND IT MUST NOT MEMOIZE, unlike the two branches below. Their static is
    // computed on the FIRST call, which is the first rendered frame — roughly
    // half a second before the measurement settles. A static here would latch
    // the pre-measurement fallback for the life of the process and the measured
    // value would never once be used: the fix would be present, compiled, logged
    // and completely inert. sm64_vision_hz_poll() is a volatile read plus two
    // already-done bool checks, so there is nothing to memoize anyway.
    return sm64_vision_hz_poll();
#elif defined(TARGET_IOS)
    // On iOS, UIScreen.maximumFramesPerSecond reliably reports ProMotion rates (120Hz)
    // while SDL_GetCurrentDisplayMode may report only 60Hz
    static u32 refreshRate = 0;
    if (!refreshRate) {
        refreshRate = platform_ios_get_refresh_rate();
        if (refreshRate == 0) { refreshRate = 60; }
    }
    return refreshRate;
#elif defined(HAVE_SDL2)
"""
t_main = replace_once(orig_main, OLD_RATE, NEW_RATE, "pc_main-refresh-rate",
                      "sm64_vision_hz_poll")
diffs.append(diff_edit(orig_main, t_main, REL_MAIN))

# ---------------------------------------------------------------------------
# 4. configfile.h — the marker's extern, gated so iOS/desktop never see it.
# ---------------------------------------------------------------------------
REL_CFG_H = "src/pc/configfile.h"
orig_cfg_h = (VENDOR / REL_CFG_H).read_text()

OLD_CFG_H_INC = """#include <stdbool.h>
#include <PR/ultratypes.h>
#include "game/player_palette.h"
"""
NEW_CFG_H_INC = """#include <stdbool.h>
#include <PR/ultratypes.h>
#include "game/player_palette.h"
// Defines SM64_VISION_HZ on visionOS and nothing anywhere else (overlay 0010).
#include "sm64_vision_hz.h"
"""
t_cfg_h = replace_once(orig_cfg_h, OLD_CFG_H_INC, NEW_CFG_H_INC, "configfile.h-include",
                       '#include "sm64_vision_hz.h"')

OLD_CFG_H_DECL = """extern enum RefreshRateMode configFramerateMode;
extern unsigned int configFrameLimit;
"""
NEW_CFG_H_DECL = """extern enum RefreshRateMode configFramerateMode;
extern unsigned int configFrameLimit;
#ifdef SM64_VISION_HZ
// Which revision of the visionOS framerate policy has been applied to THIS
// config (overlay 0010). Persisted as `vision_framerate_rev`. 0 means "never" —
// which is true of a config file that predates the policy AND of one that does
// not exist yet, so the same marker covers the migration and the default with
// one mechanism. Once it is written, the user's framerate_mode/frame_limit are
// theirs and are never rewritten again. See src/pc/sm64_vision_hz.m.
extern unsigned int configVisionFramerateRev;
#endif
"""
t_cfg_h = replace_once(t_cfg_h, OLD_CFG_H_DECL, NEW_CFG_H_DECL, "configfile.h-decl",
                       "configVisionFramerateRev")
diffs.append(diff_edit(orig_cfg_h, t_cfg_h, REL_CFG_H))

# ---------------------------------------------------------------------------
# 5. configfile.c — the marker's definition and its options[] entry.
#
#    Both gated on SM64_VISION_HZ: an ungated options[] entry would add
#    `vision_framerate_rev` to every iOS and desktop sm64config.txt, and this
#    change is required to leave the iOS target bit-for-bit unaffected.
#
#    NOTE the defaults on the two lines above the first anchor are deliberately
#    NOT changed. RRM_AUTO/60 stay the defaults, because the correct visionOS
#    value is not knowable here — it is measured, ~0.5 s into the first frame —
#    and because a default cannot fix a PERSISTED setting anyway. The policy in
#    sm64_vision_hz.m sets both, once, for fresh and existing configs alike.
# ---------------------------------------------------------------------------
REL_CFG_C = "src/pc/configfile.c"
orig_cfg_c = (VENDOR / REL_CFG_C).read_text()

OLD_CFG_C_DEF = """enum RefreshRateMode configFramerateMode          = RRM_AUTO;
unsigned int configFrameLimit                     = 60;
"""
NEW_CFG_C_DEF = """enum RefreshRateMode configFramerateMode          = RRM_AUTO;
unsigned int configFrameLimit                     = 60;
#ifdef SM64_VISION_HZ
// Deliberately NOT a changed default for the two lines above. The visionOS
// answer is MEASURED a fraction of a second into the first frame, so it cannot
// be written here; and a default could not fix these two settings anyway,
// because they are PERSISTED — configfile_load() would put the old values
// straight back. src/pc/sm64_vision_hz.m sets both once, gated on this marker.
unsigned int configVisionFramerateRev             = 0;
#endif
"""
t_cfg_c = replace_once(orig_cfg_c, OLD_CFG_C_DEF, NEW_CFG_C_DEF, "configfile.c-def",
                       "configVisionFramerateRev")

OLD_CFG_C_OPT = """    {.name = "framerate_mode",                 .type = CONFIG_TYPE_UINT, .uintValue = &configFramerateMode},
    {.name = "frame_limit",                    .type = CONFIG_TYPE_UINT, .uintValue = &configFrameLimit},
"""
NEW_CFG_C_OPT = """    {.name = "framerate_mode",                 .type = CONFIG_TYPE_UINT, .uintValue = &configFramerateMode},
    {.name = "frame_limit",                    .type = CONFIG_TYPE_UINT, .uintValue = &configFrameLimit},
#ifdef SM64_VISION_HZ
    {.name = "vision_framerate_rev",           .type = CONFIG_TYPE_UINT, .uintValue = &configVisionFramerateRev},
#endif
"""
t_cfg_c = replace_once(t_cfg_c, OLD_CFG_C_OPT, NEW_CFG_C_OPT, "configfile.c-option",
                       "vision_framerate_rev")
diffs.append(diff_edit(orig_cfg_c, t_cfg_c, REL_CFG_C))

out = ROOT / "overlay/patches/0010-visionos-panel-hz.patch"
out.write_text(__doc__ + "\n" + "".join(diffs))
print(f"wrote {out} ({sum(len(d.splitlines()) for d in diffs)} diff lines)")
