#ifndef SM64_VISION_SHELL_H
#define SM64_VISION_SHELL_H

// visionOS remote-diagnosis floor (charter ground rules 5 and 6).
//
// The user is remote: the device is on the tailnet, delivery is OTA-only, and
// nobody is standing in front of the headset with Xcode attached. Everything
// here exists so that a failure on that device produces EVIDENCE instead of a
// shrug:
//
//   - crash handler        -> Documents/crash.txt (TIMESTAMP entries; a
//                             secondary crash can never erase the primary)
//   - stdout/stderr tee    -> Documents/logs/sm64-<boot>.log (coopdx logs via
//                             printf and has NO file logging of its own, so a
//                             SpringBoard launch is otherwise mute)
//   - TCP console bridge   -> ping/thermal/logtail/crashlog/drawable/input
//   - Documents readme     -> an EMPTY Documents dir HIDES the app in Files,
//                             which would make the ROM undroppable (Q-002)
//   - config save on resign-> swipe-kill is SIGKILL; the desktop write-on-quit
//                             (pc_main.c game_deinit) never runs
//
// Gated from TargetConditionals rather than a -D flag, for the same reason as
// the perf probe (D-013) and the Lua os.execute stub (D-009): a build-flag gate
// can be silently forgotten, and that must never be why the diagnosis floor is
// missing from a build we shipped to a device.

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_VISION) && TARGET_OS_VISION
#define SM64_VISION_SHELL 1
#endif

#ifdef SM64_VISION_SHELL

#ifdef __cplusplus
extern "C" {
#endif

// Called from pc_main.c's main(), immediately after configfile_load().
//
// That placement is deliberate and load-bearing for exactly one of the five
// jobs: the resign-active handler saves the config, and saving before
// configfile_load() would write DEFAULTS over the user's real settings. Hooking
// after the load means the observer can never be registered while the in-memory
// config is still defaults. (The handler additionally re-checks gGameInited,
// mirroring pc_main.c:543 — belt and braces, because "never delete user data"
// is a charter rule and this is the only code path that can violate it.)
//
// The crash handler and the log tee do NOT wait for this — they install from a
// constructor, before main(), so that a crash in coopdx's ~12,100 rom_assets
// constructors is still caught.
void sm64_vision_shell_init(void);

#ifdef __cplusplus
}
#endif

#endif // SM64_VISION_SHELL
#endif // SM64_VISION_SHELL_H
