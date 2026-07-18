#!/usr/bin/env python3
"""Overlay patch 0007: the visionOS perf / drawable probe.

WHAT IT ADDS
  - src/pc/sm64_vision_probe.{h,m} (new files, packaged from app/probe/ per
    D-010 — the source of truth is app/probe/, NOT this patch).
  - CMakeLists.txt: the .m into IOS_OBJC_FILES, visionOS-only.
  - pc_main.c: three small hooks (an include, a per-rendered-frame sample, a
    per-sim-tick sample).

WHY (charter): "Ship the SAME instrumentation from day one: wall/eng
percentiles + sim-rate + thermal probe, PLUS true GPU time (command-buffer
GPUEndTime-GPUStartTime -> volatile read by the probe/bridge). eng_ms INCLUDES
present blocking - it cannot distinguish GPU saturation from pacing waits;
gpu_ms is the number that decides optimization direction. Wire it before the
first perf conversation, not after."

It also pays a specific, named debt. QUESTIONS Q-008: "Real drawable /
gpu_ms instrumentation still owed. M-16/M-17's arithmetic INFERS ~3840x2160
from the long-edge push. The 1.667x prediction-vs-observation match is strong
evidence the model is right, but it is not a measurement of the drawable
itself." gfx_metal.mm (overlay 0001) now publishes the acquired drawable
texture's real dimensions; this probe reports them.

THE FRAME MAP THIS INSTRUMENTS (why the hooks are where they are).
coopdx runs sim and render at DIFFERENT rates, so "frame" is ambiguous and
hooking the wrong one would silently report the wrong thing:

    produce_one_frame()                        <- one SIM tick (FRAMERATE=30)
      network_update / game_loop_one_iteration / smlua_update
      produce_interpolation_frames_and_delay()
        do { ... gfx_display_frame(); ... }    <- one RENDERED frame, N per tick

So the wall/eng/gpu percentiles hook the INNER loop (rendered frames, which is
what "fps" and "gpu_ms" mean), and sim_tps hooks produce_one_frame. Hooking
produce_one_frame for both would have reported ~30fps on a 90Hz display and
looked like a catastrophic perf bug that does not exist.

eng_ms deliberately spans gfx_start_frame..gfx_display_frame and EXCLUDES the
precise_delay_f64() pacing sleep that follows it in the same loop iteration;
wall_ms (present-to-present) includes it. wall_ms >> eng_ms therefore means the
frame limiter is sleeping (healthy); wall_ms ~= eng_ms means we are blocked in
render/present, and gpu_ms is what then says whether that is the GPU or pacing.

D6 (patches must not edit inside each other's hunks) — checked, not hoped:
  - CMakeLists IOS_OBJC_FILES is pristine line 200; overlay 0005's nearest
    hunks are 187-192 and 214-230. Clean gap.
  - pc_main.c hooks are at ~321/~357/~447; overlay 0002's pc_main hunks are at
    54, 238-243 and 267-272. Nowhere near.
  - The include is added at produce_interpolation_frames_and_delay rather than
    with the other includes at the top of pc_main.c precisely BECAUSE overlay
    0002 owns the include block (its @@ -54,6 @@ hunk). Mid-file include, on
    purpose, for a reason that is a rule rather than a preference.

GATING: the probe compiles to nothing off visionOS. sm64_vision_probe.h derives
SM64_VISION_PROBE from TargetConditionals (TARGET_OS_VISION is 1 only on xros —
measured, M-9), so the header is safe to include unconditionally and the desktop
oracle + iOS target are unaffected. The .m is added to IOS_OBJC_FILES only under
SM64_VISIONOS, so the iOS target's source list is bit-for-bit unchanged; the
desktop Makefile never globs src/pc/*.m (it lists .mm explicitly, Makefile:498)
so it cannot pick the file up either.
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
APP = ROOT / "app/probe"

diffs = []


def diff_new_file(text, rel):
    """/dev/null hunk for a repo-owned new file (D-010 / overlay 0001 pattern)."""
    r = subprocess.run(["git", "-C", str(VENDOR), "ls-files", "--error-unmatch", rel],
                       capture_output=True)
    assert r.returncode != 0, f"[{rel}] already tracked upstream — 0007 must not clobber it"
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
    """Match-count-asserted replace (charter ground rule 1), plus an
    already-applied guard.

    The guard is not decoration. Every anchor below has its OLD text as a
    PREFIX of its NEW text (we insert around the anchor rather than rewrite
    it), so `text.count(old) == 1` stays true even AFTER the patch is applied
    — the count assert alone would happily pass on a patched tree and emit a
    double-applied patch. The charter's workflow (reverse the patch out, then
    regenerate) prevents that by convention; this makes it a failure instead of
    a convention, because a silently doubled hunk is exactly the kind of thing
    that is invisible until it miscompiles.
    """
    assert sentinel not in text, (
        f"[{tag}] already applied (found sentinel {sentinel!r}) — "
        f"`patch -p1 -R` overlay 0007 out of vendor before regenerating")
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}"
    return text.replace(old, new)


# ---------------------------------------------------------------------------
# 1. The probe itself — packaged from app/probe/ (source of truth), not authored
#    here. D-010: a new file has no pristine anchor to assert against, so keeping
#    the real file real is what keeps the generator honest.
# ---------------------------------------------------------------------------
for src_name, rel in [("sm64_vision_probe.h", "src/pc/sm64_vision_probe.h"),
                      ("sm64_vision_probe.m", "src/pc/sm64_vision_probe.m")]:
    src = APP / src_name
    assert src.is_file(), f"missing source of truth: {src}"
    text = src.read_text()
    assert text, f"empty source: {src}"
    diffs.append(diff_new_file(text, rel))

# ---------------------------------------------------------------------------
# 2. CMakeLists.txt — the .m into the ObjC source list, visionOS-only.
# ---------------------------------------------------------------------------
REL_CMAKE = "CMakeLists.txt"
orig_cmake = (VENDOR / REL_CMAKE).read_text()

OLD_CMAKE = """set(IOS_OBJC_FILES
    ${GAME_ROOT}/src/pc/platform_ios.m
)
"""
NEW_CMAKE = """set(IOS_OBJC_FILES
    ${GAME_ROOT}/src/pc/platform_ios.m
)

# visionOS perf / drawable probe (overlay 0007). Appended rather than added to
# the list above so the iOS target's source list stays bit-for-bit identical —
# the same principle overlay 0005 applies to the renderer defines and the plist.
# The file's own body is additionally gated on TARGET_OS_VISION, so this is a
# belt-and-braces gate, not the only one.
if(SM64_VISIONOS)
    list(APPEND IOS_OBJC_FILES ${GAME_ROOT}/src/pc/sm64_vision_probe.m)
endif()
"""
t_cmake = replace_once(orig_cmake, OLD_CMAKE, NEW_CMAKE, "cmake-objc-list",
                       "sm64_vision_probe.m")
diffs.append(diff_edit(orig_cmake, t_cmake, REL_CMAKE))

# ---------------------------------------------------------------------------
# 3. pc_main.c — the three hooks.
# ---------------------------------------------------------------------------
REL_MAIN = "src/pc/pc_main.c"
orig_main = (VENDOR / REL_MAIN).read_text()

# 3a. The include. Deliberately here and not in the top include block: overlay
#     0002 owns that block (@@ -54,6 @@) and D6 forbids editing inside it.
OLD_INC = """void produce_interpolation_frames_and_delay(void) {
    u32 refreshRate = get_target_refresh_rate();
"""
NEW_INC = """// Included HERE rather than with the includes at the top of this file on
// purpose: overlay 0002 owns that include block, and the charter's D6 forbids
// one overlay patch editing inside another's hunk. The header compiles to
// nothing off visionOS (it derives SM64_VISION_PROBE from TargetConditionals),
// so this is safe on the desktop oracle and the iOS target alike.
#include "sm64_vision_probe.h"

void produce_interpolation_frames_and_delay(void) {
    u32 refreshRate = get_target_refresh_rate();
"""
t_main = replace_once(orig_main, OLD_INC, NEW_INC, "probe-include",
                      '#include "sm64_vision_probe.h"')

# 3b. Per RENDERED frame. This is the inner interpolation loop — N of these run
#     per sim tick, and this is what "fps" and "gpu_ms" actually refer to.
OLD_FRAME = """        gfx_start_frame();
        if (!gSkipInterpolationTitleScreen) { patch_interpolations(delta); }
        send_display_list(gGfxSPTask);
        gfx_end_frame_render();
        gfx_display_frame();
"""
NEW_FRAME = """#ifdef SM64_VISION_PROBE
        // eng_ms spans render+present and EXCLUDES the precise_delay_f64()
        // pacing sleep further down this same loop iteration. wall_ms (measured
        // present-to-present inside the probe) includes it. That difference is
        // the whole point: wall >> eng means the frame limiter is sleeping and
        // we have headroom; wall ~= eng means we are blocked inside
        // render/present, and only gpu_ms can then say whether that is the GPU
        // or the compositor pacing us.
        f64 probeEngStart = clock_elapsed_f64();
#endif
        gfx_start_frame();
        if (!gSkipInterpolationTitleScreen) { patch_interpolations(delta); }
        send_display_list(gGfxSPTask);
        gfx_end_frame_render();
        gfx_display_frame();
#ifdef SM64_VISION_PROBE
        sm64_vision_probe_on_frame((clock_elapsed_f64() - probeEngStart) * 1000.0);
#endif
"""
t_main = replace_once(t_main, OLD_FRAME, NEW_FRAME, "probe-frame",
                      "sm64_vision_probe_on_frame")

# 3c. Per SIM tick. Also drives the periodic report: produce_one_frame keeps
#     running even if rendering stalls, so a stall still gets reported (as a
#     very low fps) rather than silently suppressing the report that would have
#     revealed it.
OLD_TICK = """void produce_one_frame(void) {
    CTX_EXTENT(CTX_NETWORK, network_update);
"""
NEW_TICK = """void produce_one_frame(void) {
#ifdef SM64_VISION_PROBE
    // One sim tick (FRAMERATE=30), NOT one rendered frame — the interpolation
    // loop inside produce_interpolation_frames_and_delay draws N frames per
    // tick. Conflating the two would report ~30fps on a 90Hz display.
    sm64_vision_probe_on_tick();
#endif
    CTX_EXTENT(CTX_NETWORK, network_update);
"""
t_main = replace_once(t_main, OLD_TICK, NEW_TICK, "probe-tick",
                      "sm64_vision_probe_on_tick")

diffs.append(diff_edit(orig_main, t_main, REL_MAIN))

out = ROOT / "overlay/patches/0007-visionos-perf-probe.patch"
out.write_text(__doc__ + "\n" + "".join(diffs))
print(f"wrote {out} ({sum(len(d.splitlines()) for d in diffs)} diff lines)")
