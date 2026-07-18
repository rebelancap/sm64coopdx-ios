#!/usr/bin/env python3
"""Overlay patch 0012: keep the engine's frame limiter alive in 3D.

THE BUG (DECISIONS D-028, MEASUREMENTS M-39). Entering the immersive space
takes the engine from `fps=119.5, wall_ms p50=8.32` to `wall_ms p50=0.81` and
~850 host frames/s — roughly **1695 eye-renders per second**, feeding a
compositor that samples at 60-90 Hz. The engine free-runs.

MECHANISM. In 2D the engine is paced by `[mtl_layer nextDrawable]` blocking on
the display link, and `produce_interpolation_frames_and_delay()` explicitly opts
OUT of its own limiter on the strength of that:

    if (configWindow.vsync && displayRefreshRate <= refreshRate) {
        shouldDelay = false;          // "vsync will pace us"
        refreshRate = displayRefreshRate;
    }

In 3D we deliberately never acquire the window drawable — that is load-bearing,
not an optimisation: the 2D window is hidden behind the immersive space and its
`nextDrawable` would stall forever (guide §2.7). So **the pacing that
`shouldDelay = false` was relying on does not exist**, and nothing else caps the
loop.

THE FIX. One condition: do not opt out of the limiter when there is no drawable
to do the pacing. `shouldDelay` then stays true and the loop paces to
`refreshRate` = `get_target_refresh_rate()` — which overlay 0010 has already made
MANUAL@(measured panel rate). Note the `refreshRate = displayRefreshRate`
assignment is skipped along with it, which is correct and not incidental: in 3D
the *panel* rate is what matters, and that is what `get_target_refresh_rate()`
already returns.

WHY THIS IS NOT COSMETIC. On an M-series Mac it is invisible (`gpu_ms p50 =
0.03`). On the headset it is 2x the GPU work (both eyes) at ~10x the needed rate:
that is heat and battery, and the charter's entire 90 Hz budget argument assumes
the engine is paced. No device performance or thermal number from the 3D path
means anything until this lands.

WHY IT IS A NEW PATCH AND NOT A 0007/0010/0011 REVISION (charter D6). The
`shouldDelay` SET site (pc_main.c:386-389) is owned by no patch:
  - 0007 (perf probe) touches `shouldDelay` only as trailing CONTEXT at the USE
    site (`if (shouldDelay) {`) further down the interpolation loop — a different
    hunk, ~15 lines away.
  - 0010 touches `get_display_refresh_rate()` (~line 212), a different function.
  - 0011 adds the include at :146 that puts the accessor in scope here.
So this hunk lands in virgin territory and needs no reverse-out of anything.
D-028 guessed 0010 owned this region; it does not.

The condition is gated on SM64_VISION_3D (0011's own gate, already established at
pc_main.c:147), so every non-visionOS target — desktop, iOS — compiles and
behaves byte-identically.

COMFORT BATCH 2 item 1 (Fable P1-c) adds a SECOND hunk: the loop now paces off
the COMPOSITOR instead of the sleep clock. M-51 read the user's M5 live —
gpu_ms=3.6/eye against an 11.111ms budget (3x headroom) with a rock-steady 90 Hz
compositor — so the "not buttery while moving" report is a PACING beat (the
engine's own 90 Hz limiter vs the compositor's 90 Hz), not a perf problem. The
new hunk, after `f64 delay = ...`, blocks on the immersive loop's
per-compositor-frame signal (sm64_3d_wait_for_compositor_frame) and zeroes the
delay when a fresh frame arrives — phase-locked 1:1 to the true granted cadence
(90/96/100/120, no measured constant). A ~50 ms timeout falls back to the sleep
limiter above (loop not running). It sits BELOW overlay 0007's probe hunk (which
ends at `if (shouldDelay) {`), sharing no line with it (charter D6). The signal
side lives in the repo-owned sm64_immersive.m (overlay 0011). Device cadence is
the only real proof it removed the beat — the sim compositor is 60 Hz.
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
REL = "src/pc/pc_main.c"
orig = (VENDOR / REL).read_text()


def replace_once(text, old, new, tag):
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}: {old[:70]!r}"
    return text.replace(old, new)


t = orig

t = replace_once(t, """    bool shouldDelay = configFramerateMode != RRM_UNLIMITED;
    if (configWindow.vsync && displayRefreshRate <= refreshRate) {
        shouldDelay = false;
        refreshRate = displayRefreshRate;
    }""",
"""    bool shouldDelay = configFramerateMode != RRM_UNLIMITED;
    bool vsyncPaces = configWindow.vsync;
#ifdef SM64_VISION_3D
    // D-028/M-39: in 3D there is NO drawable to pace us. gfx_metal never
    // acquires or presents the window's drawable while 3D mode is on (that is
    // load-bearing — the hidden window's nextDrawable would stall, guide §2.7),
    // so the vsync this block is about to trust does not exist. Opting out of
    // the limiter here let the engine free-run at ~850 host fps / 1695
    // eye-renders per second into a compositor sampling at 60-90 Hz: invisible
    // on a Mac, but 2x the GPU work at ~10x the needed rate on the headset,
    // i.e. heat and battery for nothing.
    //
    // Keeping shouldDelay true paces the loop to refreshRate =
    // get_target_refresh_rate(), which overlay 0010 has already made
    // MANUAL@(measured panel rate) — the right target in 3D.
    if (sm64_metal_get_3d_mode()) { vsyncPaces = false; }
#endif
    if (vsyncPaces && displayRefreshRate <= refreshRate) {
        shouldDelay = false;
        refreshRate = displayRefreshRate;
    }""", "frame-limiter-3d")

# --- Comfort batch 2 item 1: compositor-driven pacing (Fable P1-c) -----------
# The set-site hunk above keeps shouldDelay TRUE in 3D so the loop paces itself.
# This second hunk changes HOW it paces: instead of sleeping to a measured number
# (MANUAL@panel-rate) — which beats against the compositor's own steady clock
# (M-51: two 90 Hz clocks -> periodic motion hitch, gpu_ms=3.6/eye so NOT perf) —
# it blocks on the immersive loop's per-compositor-frame signal, phase-locking the
# engine 1:1 to whatever the compositor actually grants (90/96/100/120). On a
# ~50 ms timeout the wait returns false, the computed delay is kept, and the loop
# falls through to precise_delay_f64 — i.e. 0012's original sleep limiter — so a
# loop that is not running (entry/exit transition) is transparently handled.
#
# Injected AFTER `f64 delay = ...`, deliberately BELOW overlay 0007's probe hunk
# (which ends at `if (shouldDelay) {` — its trailing context), so this hunk shares
# no line with 0007 (charter D6). sm64_metal_get_3d_mode / _wait_for_compositor_
# frame are in scope via the sm64_vision_3d.h include overlay 0011 adds at :146.
t = replace_once(t, """            f64 delay = (expectedTime - elapsedTime);
            if (delay > 0.0) {
                precise_delay_f64(delay);
            }""",
"""            f64 delay = (expectedTime - elapsedTime);
#ifdef SM64_VISION_3D
            // Comfort batch 2 item 1 (Fable P1-c). M-51: gpu_ms=3.6/eye (3x
            // headroom) yet motion is "not buttery" — the engine sleep-paces to
            // its own 90 Hz clock while the compositor runs a separate steady 90
            // Hz, and two unsynchronised clocks beat into a periodic hitch. Block
            // on the immersive loop's per-compositor-frame signal instead,
            // phase-locking the engine 1:1 to the true granted cadence (90/96/
            // 100/120). false = ~50 ms timeout (loop not running) -> keep the
            // computed delay and fall through to the sleep limiter unchanged.
            if (sm64_metal_get_3d_mode() && sm64_3d_wait_for_compositor_frame()) {
                delay = 0.0;
            }
#endif
            if (delay > 0.0) {
                precise_delay_f64(delay);
            }""", "compositor-pace-3d")

with tempfile.TemporaryDirectory() as td:
    a = pathlib.Path(td) / "a"; a.write_text(orig)
    b = pathlib.Path(td) / "b"; b.write_text(t)
    r = subprocess.run(["diff", "-u", "--label", f"a/{REL}", "--label", f"b/{REL}",
                        str(a), str(b)], capture_output=True, text=True)
assert r.returncode == 1, f"[{REL}] no diff produced"

out = ROOT / "overlay/patches/0012-visionos-3d-frame-limiter.patch"
out.write_text(__doc__ + "\n" + r.stdout)
print(f"wrote {out}")
