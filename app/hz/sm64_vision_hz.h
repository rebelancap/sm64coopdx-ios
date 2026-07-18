#ifndef SM64_VISION_HZ_H
#define SM64_VISION_HZ_H

// visionOS panel refresh-rate MEASUREMENT, and the framerate policy that rides
// on it (overlay 0010).
//
// WHY THIS EXISTS. Every other way this port could learn the panel rate is a
// guess or a hard compile break:
//
//   - `[UIScreen mainScreen].maximumFramesPerSecond` — the iOS answer, and the
//     one pc_main.c's TARGET_IOS branch was written for. UIScreen does not
//     exist on visionOS (API_UNAVAILABLE); that is what overlay 0004 had to
//     route around in the first place.
//   - `SDL_GetCurrentDisplayMode()` — what 0004 routed to. But visionOS has no
//     UIScreen for SDL either, so our own SDL compat patch SYNTHESIZES the
//     display and HARDCODES `mode.refresh_rate = 120`
//     (SDL_uikitmodes.m, "M5 Vision Pro panel max"). Asking SDL therefore just
//     reads our own guess back. It is wrong on an M2-generation Vision Pro
//     (90 Hz panel) BY CONSTRUCTION, and no amount of asking makes it right.
//   - `sysctlbyname("hw.machine")` -> RealityDevice14,1 => 90 — a model-string
//     table. Brittle in the one direction that matters: hardware that does not
//     exist yet is not in the table, so a future headset falls to the default
//     FOREVER and nobody finds out. Explicitly rejected.
//
// So: measure. A CADisplayLink's callback period, once the system has clamped
// our requested frame-rate range to what the panel can actually do, IS the
// panel rate. It is a reading rather than a claim, it costs nothing, and it is
// correct on hardware that did not exist when this was written — which is the
// entire point.
//
// WHY OUR OWN DISPLAY LINK, AND NOT SDL's. The SDL visionOS compat patch does
// set `preferredFrameRateRange = CAFrameRateRangeMake(80, 120, ...)` on a
// CADisplayLink — but SDL only ever CREATES that link from
// `SDL_iPhoneSetAnimationCallback()`, and coopdx never calls it (it owns its
// own `while (true)` main loop — see docs/frame-map.md). Grep the tree: there
// is no caller. SDL's display link therefore never starts in this app and has
// no period to read. Ours does.
//
// THREADING. The sampler runs on its own NSThread with its own run loop, and
// deliberately not on the main run loop: coopdx's main thread never returns to
// UIKit (`pc_main.c: while (true) { gWindowApi->main_loop(...) }`), so a
// main-run-loop display link would only be serviced incidentally, deep inside
// SDL's event pump, and we would be measuring OUR OWN pump rate rather than the
// panel's. Its own thread means the reading is independent of what the game is
// doing. Nothing on that thread touches engine state; it publishes one volatile
// unsigned int and stops.

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

// Gated from TargetConditionals rather than a -D build flag, for the same
// reason as the perf probe (D-013) and the diagnosis shell (D-017): a build-flag
// gate can be silently forgotten, and that must never be why a frame-rate fix is
// missing from the build we shipped to a headset. The whole file compiles to
// nothing off visionOS, so the iOS target and the desktop oracle are untouched.
#if defined(TARGET_OS_VISION) && TARGET_OS_VISION
#define SM64_VISION_HZ 1
#endif

#ifdef SM64_VISION_HZ

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// The measured panel rate in Hz. Pure accessor over a volatile — safe to call
// from any thread, costs a load, never blocks. Returns SM64_VISION_HZ_FALLBACK
// (90 — the M2-generation panel, i.e. the CONSERVATIVE choice: guessing low
// wastes headroom, guessing high asks for frames the panel cannot show) until
// the measurement settles, and the measured value forever after.
//
// Named to match Sm64Ios_VisionLongEdge() (src/pc/platform_ios.m, overlay 0004)
// because it is the same kind of thing: a volatile the app publishes and the
// engine reads.
unsigned int Sm64Ios_VisionPanelHz(void);

// False while Sm64Ios_VisionPanelHz() is still returning the fallback.
bool sm64_vision_hz_settled(void);

// The engine's per-frame entry point, called from pc_main.c's
// get_display_refresh_rate(). Does three idempotent things and returns the
// current best estimate:
//   1. starts the sampler on the first call (which is the first RENDERED frame,
//      i.e. the first moment UIKit is guaranteed up);
//   2. applies the one-shot visionOS framerate policy once the measurement
//      settles (see sm64_vision_hz.m — this is where MANUAL@panel-rate is set,
//      and where an existing config is migrated exactly once);
//   3. returns Sm64Ios_VisionPanelHz().
//
// It is a getter with side effects, which is worth flagging rather than hiding.
// The reason is that this is the ONLY per-frame hook available on visionOS that
// sits in pristine ground: coopdx's frame loop is not extensible without editing
// inside another overlay patch's hunk (charter D6), and the policy cannot run at
// configfile_load() time because the measurement needs SDL, the window and the
// compositor to exist first. Both side effects are single-bool-check cheap after
// they have run once.
unsigned int sm64_vision_hz_poll(void);

#ifdef __cplusplus
}
#endif

#endif // SM64_VISION_HZ
#endif // SM64_VISION_HZ_H
