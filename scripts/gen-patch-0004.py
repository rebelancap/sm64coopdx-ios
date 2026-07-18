#!/usr/bin/env python3
"""Overlay patch 0004: make platform_ios.m compile and behave on visionOS.

Measured, not guessed: compiling platform_ios.m against XRSimulator26.5
yields exactly FOUR errors, at the four sites the frame map predicted:

    :24  keyWindow  'keyWindow' is unavailable: not available on visionOS
    :62  keyWindow  (same)
    :84  UIScreen   'UIScreen' is unavailable: not available on visionOS
    :145 keyWindow  (same)

CORRECTION to docs/frame-map.md: it lists keyWindow as
"deprecated/unreliable" on visionOS. It is neither — it is
API_UNAVAILABLE(visionos, watchos) in UIApplication.h:108, i.e. a HARD
COMPILE BREAK exactly like UIScreen. Three of the four breaks are
keyWindow, so this file could never have compiled for xros untouched.
(Everything else in the file is fine — notably UIDocumentPickerViewController
and the whole ROM-picker path compile clean for visionOS.)

Fixes, one per break:
- keyWindow  -> sm64_ios_key_window(), which walks connectedScenes on
  visionOS. The iOS path deliberately KEEPS keyWindow: the shipped iOS
  build has proven it, and this patch should not put the working target at
  risk to tidy a deprecation.
- UIScreen.maximumFramesPerSecond -> SDL_GetCurrentDisplayMode(). The SDL2
  visionOS compat patch (overlay 0007) synthesizes a virtual display
  carrying the real panel rate (it advertises 120), so asking SDL is
  correct-by-construction and keeps working if that advertised rate later
  changes — strictly better than hardcoding a number here that would then
  disagree with the display link.

Also adds Sm64Ios_VisionLongEdge(), the drawable long-edge (render scale)
that overlay 0007's SDL patch calls into. Kept as a volatile global +
accessor so Phase 1 can point a CVar at it without touching SDL again.
STUB FOR NOW: returns a constant 3840 — the render-scale menu is Phase 1
polish, not part of this bring-up.
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
REL = "src/pc/platform_ios.m"
orig = (VENDOR / REL).read_text()


def replace_once(text, old, new, tag):
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}: {old[:70]!r}"
    return text.replace(old, new)


t = orig

# --- the visionOS shims, inserted ahead of the first user ---
t = replace_once(t, """#include "platform.h"
#include "rom_checker.h"

// ---- iOS software keyboard height tracking ----""",
"""#include "platform.h"
#include "rom_checker.h"

#if TARGET_OS_VISION
#include <SDL2/SDL.h>

// keyWindow is API_UNAVAILABLE(visionos) (UIApplication.h:108) — a hard compile
// break, not a deprecation. Walk the connected scenes instead. visionOS-only on
// purpose: the iOS build ships on keyWindow today and this patch has no business
// changing that proven path.
static UIWindow *sm64_ios_key_window(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) { return window; }
        }
        if (windowScene.windows.count > 0) { return windowScene.windows.firstObject; }
    }
    return nil;
}

// Drawable long edge for the SDL metal view (see the visionOS SDL2 compat
// patch, which declares this extern). Volatile global + accessor so a Phase 1
// "Render Scale" CVar can drive it without touching SDL again.
// STUB: constant for now; the menu lever is Phase 1 polish.
volatile float gSm64IosVisionLongEdge = 3840.0f;
float Sm64Ios_VisionLongEdge(void) {
    return gSm64IosVisionLongEdge;
}
#else
static UIWindow *sm64_ios_key_window(void) {
    return [UIApplication sharedApplication].keyWindow;
}
#endif

// ---- iOS software keyboard height tracking ----""", "ios-vision-shims")

# --- break 1: :24, inside keyboardWillShow ---
t = replace_once(t, """    // Convert keyboard frame to the app window's coordinate space
    // This handles iPhone vs iPad, landscape vs portrait, floating keyboards, etc.
    UIWindow *window = [UIApplication sharedApplication].keyWindow;""",
"""    // Convert keyboard frame to the app window's coordinate space
    // This handles iPhone vs iPad, landscape vs portrait, floating keyboards, etc.
    UIWindow *window = sm64_ios_key_window();""", "keywindow-keyboard")

# --- break 2: :62, inside platform_ios_get_safe_area_left ---
t = replace_once(t, """float platform_ios_get_safe_area_left(void) {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;""",
"""float platform_ios_get_safe_area_left(void) {
    UIWindow *window = sm64_ios_key_window();""", "keywindow-safearea")

# --- break 3: :84, UIScreen ---
t = replace_once(t, """unsigned int platform_ios_get_refresh_rate(void) {
    return (unsigned int)[UIScreen mainScreen].maximumFramesPerSecond;
}""",
"""unsigned int platform_ios_get_refresh_rate(void) {
#if TARGET_OS_VISION
    // No UIScreen on visionOS. The SDL2 visionOS compat patch synthesizes a
    // virtual display whose mode carries the panel rate, so ask SDL rather than
    // hardcoding — this stays in agreement with the CADisplayLink range even if
    // the advertised rate changes. pc_main.c maps 0 -> 60, so the fallback here
    // only matters if SDL has no display yet.
    SDL_DisplayMode mode;
    if (SDL_GetCurrentDisplayMode(0, &mode) == 0 && mode.refresh_rate > 0) {
        return (unsigned int)mode.refresh_rate;
    }
    return 90;
#else
    return (unsigned int)[UIScreen mainScreen].maximumFramesPerSecond;
#endif
}""", "uiscreen-refresh")

# --- break 4: :145, picker root view controller ---
t = replace_once(t, """        UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;""",
"""        UIViewController *rootVC = sm64_ios_key_window().rootViewController;""", "keywindow-picker")

with tempfile.TemporaryDirectory() as td:
    a = pathlib.Path(td) / "a"; a.write_text(orig)
    b = pathlib.Path(td) / "b"; b.write_text(t)
    r = subprocess.run(["diff", "-u", "--label", f"a/{REL}", "--label", f"b/{REL}",
                        str(a), str(b)], capture_output=True, text=True)
assert r.returncode == 1, "no diff produced"

out = ROOT / "overlay/patches/0004-platform-ios-visionos.patch"
out.write_text(__doc__ + "\n" + r.stdout)
print(f"wrote {out}")
