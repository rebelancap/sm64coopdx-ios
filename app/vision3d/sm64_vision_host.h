#ifndef SM64_VISION_HOST_H
#define SM64_VISION_HOST_H

#include "sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#import <UIKit/UIKit.h>

// Defaults, in ONE place so the settings table, the reset button and the
// engine-apply path can never disagree about what "default" means.
//
// The stereo numbers are SM64-specific and reasoned from the world scale, not
// copied from vkQuake: Mario is ~160 units tall and ~1.5 m, so 1 unit ~= 1 cm.
//   sep  9.0 units — a modest hyper-stereo (1.4x a 6.5 cm human IPD). The panel
//        is a window into a MINIATURE world, so slight hyper-stereo reads as more
//        dimensional; 6.5 (a literal IPD) put the action near-flat (M-49 device
//        feedback: "Stereo Depth didn't seem to do anything"). Gives real volume
//        and two-sided slider travel (range 0..18 = 0..200%). RETUNED from 6.5
//        (P3 item 3); slider MAX raised 13->18 in comfort batch 3 per device
//        feedback that 144% "wasn't really pushing the boundaries."
//   conv 1524 units ~= 15.24 m ~= 50 ft — the zero-parallax plane. RETUNED from
//        800 (~26 ft): device feedback was that 50 ft feels best (comfort batch 2
//        item 6). This is the MANUAL fallback; convAuto (below) is on by default
//        and DERIVES the convergence from the panel size, landing on ~50 ft at the
//        default panel. Exposed as "Focus Distance" with an "Auto" toggle.
//   convAuto 1 (on) — auto-derive convergence from the panel's angular size
//        (sm64_3d_auto_convergence) so the background disparity holds a fixed
//        comfortable ANGLE as the panel is reshaped/moved (the user's "adjust to
//        screen size" insight). Turn it off to use the manual Focus Distance.
//   hud  0 — comfort batch 2 item 5: the HUD Depth effect only reached the ortho
//        HUD (health + Mario head), NOT the Lakitu dialog boxes (a separate draw
//        path), so it did not fix the dialog-foreground complaint. Defaulted to 0
//        (flush on panel = original behaviour) and the slider was REMOVED.
// All are the DEFAULT, not a truth: the user's eyes are the final judge, which
// is exactly why they are live-draggable sliders (and Reset returns to these).
#define SM64_DEF_DIST     3.6f
#define SM64_DEF_HALFW    2.75f
#define SM64_DEF_HALFH    1.547f  // 16:9 against halfW — the default panel shape
#define SM64_DEF_POSH     0.0f
#define SM64_DEF_SEP      27.0f  // 100% on the depth slider. Rescale 2026-07-23: default 18->27, slider max 36->54. The % readout is v/SM64_DEF_SEP*100, so the new default (27) reads 100% and the new max (54) reads 200% — the slider LOOKS unchanged but every % is 1.5x the old separation, and the top of the range is 1.5x deeper than before (user: "it doesn't go high enough").
#define SM64_DEF_CONV     1524.0f // ~50 ft; manual fallback when convAuto is off
#define SM64_DEF_CONVAUTO 1.0f    // 1 = auto-derive convergence from panel size
#define SM64_DEF_HUD      0.0f    // flush on panel (HUD Depth slider removed)
#define SM64_DEF_DIM      0.8f
#define SM64_DEF_UNITS    1.0f    // 0 = metres, 1 = feet

// Boots the SDL/coopdx engine under the SwiftUI app entry and owns the 2D<->3D
// transition sequencing. Hosted in the SwiftUI WindowGroup (see SM64VisionApp.swift).
@interface SM64HostViewController : UIViewController
@end

// The settings table, hosted in a SwiftUI .sheet. A UIKit modal presented
// directly works in 2D but silently FAILS over an open ImmersiveSpace, which is
// why this is handed to SwiftUI rather than presented here (guide §2.7).
UIViewController *SM64_MakeSettingsNav(void);

// Reset all 3D panel/stereo settings to defaults. Bridged so the SwiftUI sheet
// header's Reset button (moved next to Done) can drive the live UIKit table —
// it clears the persisted values, re-applies, and reloads the visible sliders.
// No-op if the settings sheet is not currently open.
void SM64_ResetVision3D(void);

#endif // SM64_VISION_3D
#endif // SM64_VISION_HOST_H
