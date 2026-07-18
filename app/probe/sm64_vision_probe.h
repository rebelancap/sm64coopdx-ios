#ifndef SM64_VISION_PROBE_H
#define SM64_VISION_PROBE_H

// visionOS performance / drawable instrumentation.
//
// Charter: "wire it before the first perf conversation, not after." This header
// is safe to include unconditionally — on every non-visionOS target it defines
// nothing and compiles to nothing, so the desktop oracle and the iOS build are
// bit-for-bit unaffected.
//
// SM64_VISION_PROBE is derived from TargetConditionals rather than from a
// -D flag on purpose: a build-flag gate can be silently forgotten (D-009 made
// the same call for Lua's os.execute stub), and this must never be the reason a
// perf number is missing.

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_VISION) && TARGET_OS_VISION
#define SM64_VISION_PROBE 1
#endif

#ifdef SM64_VISION_PROBE

#ifdef __cplusplus
extern "C" {
#endif

// One RENDERED frame (one iteration of the interpolation loop, after present).
// engMs = time inside gfx_start_frame..gfx_display_frame. It INCLUDES blocking
// inside present, so it cannot by itself distinguish GPU saturation from pacing
// waits — that is what gpu_ms is for.
void sm64_vision_probe_on_frame(double engMs);

// One SIM tick (one produce_one_frame). Also drives the periodic report, since
// it is guaranteed to run even if rendering stalls.
void sm64_vision_probe_on_tick(void);

// NSProcessInfo thermal state: 0 nominal, 1 fair, 2 serious, 3 critical.
int sm64_vision_probe_thermal_state(void);

#ifdef __cplusplus
}
#endif

#endif // SM64_VISION_PROBE
#endif // SM64_VISION_PROBE_H
