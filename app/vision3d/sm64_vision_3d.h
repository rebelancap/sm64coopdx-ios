#ifndef SM64_VISION_3D_H
#define SM64_VISION_3D_H

// visionOS stereoscopic "3D screen in the room" (Phase 2).
//
// The whole contract between four parties lives in this one header:
//
//   engine   gfx_pc.c   — per-eye projection (off-axis convergence)
//            gfx_metal.mm — renders each eye into an offscreen MTLTexture
//   loop     sm64_immersive.m — the CompositorServices render loop (own thread)
//   shell    sm64_vision_host.m — enter/exit sequencing, panel settings storage
//   Swift    SM64VisionApp.swift — @main, ImmersiveSpace, ornament, settings sheet
//
// Gated from TargetConditionals rather than a -D flag, for the same reason as
// the perf probe (D-013) and the diagnosis shell (D-014): a build-flag gate can
// be silently forgotten, and that must never be why 3D is missing from a build
// we shipped to a device.

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

// <stdbool.h> is not optional here. This header is compiled in three dialects:
// ObjC++ (gfx_metal.mm — `bool` is a keyword), C (gfx_pc.c, pc_main.c), and as
// the Swift BRIDGING HEADER's precompiled header, which is plain ObjC. That last
// one is the strict reader:
//     error: failed to emit precompiled header ... for bridging header
//     error: unknown type name 'bool'
// The ObjC++ translation unit compiles happily either way, so this is invisible
// until Swift touches the header.
#include <stdbool.h>

#if defined(TARGET_OS_VISION) && TARGET_OS_VISION
#define SM64_VISION_3D 1
#endif

#ifdef SM64_VISION_3D

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Engine side — implemented in gfx_metal.mm (the render target) and gfx_pc.c
// (the matrices). Everything here is plain C state read by the render thread.
// ---------------------------------------------------------------------------

// Eye identifiers. 0 = mono/off is NOT a valid eye to render in 3D — it is the
// "no stereo adjustment" state the desktop/iOS builds are permanently in.
#define SM64_EYE_OFF   0
#define SM64_EYE_LEFT  1
#define SM64_EYE_RIGHT 2

// Background-layer markers (P1-a — the "disorienting clouds" fix). SM64's skybox
// (clouds baked in) is drawn under an ORTHO projection, so the ortho-not-offset
// gate would give it ZERO disparity — it would sit ON the panel, stereoscopically
// IN FRONT of the mountains painted behind it. init_skybox_display_list()
// (skybox.c) brackets the skybox's ortho draw with a gDPNoOpTag pair carrying
// these sentinels; gfx_pc.c's G_NOOP case flips a "background layer" flag so the
// ortho branch of gfx_stereo_projection() gives the skybox far-plane (infinity)
// disparity instead. Distinctive values so a plain gDPNoOp (tag 0), or any other
// tag, never matches.
#define SM64_GFX_TAG_BG_BEGIN 0x534B5942u  // 'SKYB' — background layer begin
#define SM64_GFX_TAG_BG_END   0x534B5945u  // 'SKYE' — background layer end

// 3D mode: while ON, gfx_metal renders into the offscreen per-eye textures and
// NEVER acquires or presents the window's drawable. That is load-bearing, not an
// optimisation: the 2D window is hidden behind the immersive space and its
// nextDrawable would stall (guide §2.7).
void sm64_metal_set_3d_mode(int on);
int  sm64_metal_get_3d_mode(void);

// Which eye the NEXT gfx_start_frame() renders. Set between eyes by the engine
// frame pump (pc_main.c). ONE source of truth, owned by gfx_pc.c (the matrix
// owner) and read by gfx_metal.mm (which picks the render target from it) — the
// two must never be able to disagree about which eye is in flight.
void sm64_gfx_set_3d_eye(int eye);

// The eye textures. Returns NULL until that eye has actually been rendered at
// least once since entering 3D — an un-rendered MTLTexture holds UNDEFINED
// garbage, and sampling it is the guide's "second eye is garbage" trap.
// Return type is void* so this header stays pure C; the loop __bridge-casts it.
void *sm64_metal_get_3d_eye_texture(int eye);

// Live extent of the eye textures (0,0 while none exist). Reported in settings.
void sm64_metal_get_3d_render_size(int *w, int *h);

// Liveness counters for the loop's diagnostics (NOT for gating).
int sm64_metal_get_3d_frames(void);

// Comfort batch 3 item 1b (Fable P2-a): the PAIR generation, advanced once after
// the right eye's end_frame (a complete L+R pair is ready). The immersive loop
// copies both eye textures only when this has advanced since its last copy —
// eliminating the mid-pair inter-eye time-skew and skipping redundant blit+mipgen
// when the compositor outpaces the engine. Also a judder instrument: a compositor
// frame that finds this UNCHANGED is one the engine did not feed a fresh pair.
unsigned int sm64_metal_get_3d_pair_gen(void);

// The UIView SDL renders into. Used by the shell to adopt SDL's scene-less
// UIWindow into the SwiftUI window scene (SDL2 predates scenes) and to host the
// 3D curtain. void* so this header stays pure C.
void *sm64_metal_get_sdl_uiview(void);

// ---------------------------------------------------------------------------
// Stereo matrices — implemented in gfx_pc.c.
//
// separation: eye distance in SM64 world units (~1 unit = 1 cm; Mario is ~160).
// convergence: the ZERO-PARALLAX distance in world units. Objects at exactly
//   this distance land ON the panel plane; nearer pops out, farther recedes.
//   This is the single biggest comfort lever — the guide's "crosshair distance".
//   Quake calls it that because it is literally where the aimpoint sits; SM64
//   has no crosshair, so the UI calls it "Focus Distance" (same quantity).
// hud_depth: how far in FRONT of the panel the ORTHO UI layer (HUD stars/coins/
//   lives, DJUI menus, co-op nametags) floats, as a fraction of the background's
//   infinity disparity (P1-b). Comfort batch 2: the DEFAULT is now 0 (flush on
//   the panel = original behaviour) and the "HUD Depth" slider was REMOVED — the
//   effect only reached the ortho HUD (health + Mario head), NOT the Lakitu
//   dialog boxes (a separate draw path), so it did not solve the dialog-
//   foreground complaint and only added a knob. The plumbing stays but is fed 0.
// ---------------------------------------------------------------------------
void sm64_gfx_set_3d_params(float separation, float convergence, float hud_depth);

// ---------------------------------------------------------------------------
// Panel + loop — implemented in sm64_immersive.m.
// ---------------------------------------------------------------------------

// Panel geometry, metres. halfH <= 0 leaves the height unchanged.
void sm64_3d_set_panel(float dist, float halfW, float halfH);
// Panel POSITION height, metres relative to eye level (signed).
void sm64_3d_set_height(float h);

// Comfort batch 2 item 2 (panel reshape): the eye-texture / engine render size
// at the PANEL's aspect (halfW:halfH), 3840 long-edge budget regardless of
// shape. gfx_metal sizes the eye texture AND gfx_pc sizes gfx_current_dimensions
// (FOV + viewport) from THIS one function, so the image FILLS a reshaped panel
// with no letterbox and the two can never disagree. Read on the main thread only.
void sm64_3d_get_render_target_size(int *w, int *h);

// Comfort batch 2 item 6 (Focus Distance "Auto"): derive the convergence (world
// units) from the panel's angular size so the background disparity holds a fixed
// comfortable ANGLE as the panel is reshaped/moved — the user's "adjust to screen
// size" insight. Calibrated so the default panel yields ~50 ft. Used by
// sm64_3d_apply_settings when the "convAuto" toggle is on; the manual slider wins
// when it is off.
float sm64_3d_auto_convergence(void);

// Comfort batch 2 item 1 (compositor-driven pacing, Fable P1-c). In 3D the engine
// blocks here instead of sleep-pacing: the immersive loop signals once per
// compositor frame (right after cp_time_wait_until), phase-locking the engine 1:1
// to the true 90/96/100/120 cadence so two ~90 Hz clocks stop beating. Returns
// true if a fresh compositor frame arrived, false on a ~50 ms timeout (loop not
// running) so the caller falls back to overlay 0012's sleep limiter. Called from
// pc_main.c's produce_interpolation_frames_and_delay().
bool sm64_3d_wait_for_compositor_frame(void);
// Surroundings dimming, 0..1 on the UI scale. Mapped through a perceptual curve
// internally (linear "doesn't get dark until 80%" — guide §2.7).
void sm64_3d_set_dim(float dim);
// Re-anchor the panel to the CURRENT head pose ("Recenter Screen").
void sm64_3d_recenter(void);

// The render loop. Called on a DEDICATED thread from the CompositorLayer closure
// — never the main thread, which would freeze the engine (guide §2.3).
// Declared void* so SM64VisionApp.swift can hand over the layer renderer.
void sm64_3d_immersive_run(void *layer_renderer);

// Loop handshake. The shell sets stop and WAITS for running to clear before the
// space is dismissed, or the loop touches a layerRenderer SwiftUI is tearing
// down (guide §2.7).
extern volatile int sm64_3d_imm_stop;
extern volatile int sm64_3d_imm_running;

// ---------------------------------------------------------------------------
// Shell — implemented in sm64_vision_host.m.
// ---------------------------------------------------------------------------

// The 2D<->3D transition. Order is load-bearing; see sm64_vision_host.m.
void sm64_3d_enter(bool on);
// Shrink the parked 2D window to a small card, called from SwiftUI AFTER the
// immersive space has finished opening (never during the open animation — a
// resize concurrent with entry conflicts; vkQuake VKQHostViewController.m:63).
// The full pre-3D scene size is captured in sm64_3d_enter, before this shrinks.
void sm64_3d_park_window(void);
// Runs after SwiftUI's dismissImmersiveSpace completes.
void sm64_3d_exit_finalize(void);
// The loop saw the layer invalidated (Crown / system dismissal) and already exited.
void sm64_3d_immersive_ended(void);
// Push the persisted settings into the panel/stereo state. Also called live from
// the settings sliders while dragging.
void sm64_3d_apply_settings(void);

// Per-frame hook, called from gfx_run() (gfx_pc.c). Runs ON THE MAIN THREAD —
// the game loop owns it — so it can touch UIKit with no dispatch at all. This is
// where "after boot" work lives, because coopdx's main() never returns and the
// main dispatch queue is therefore not a reliable channel (see D-024 / M-38).
void sm64_3d_frame_poll(void);

// Settings storage (NSUserDefaults-backed; shared with the settings table).
float sm64_3d_setting_f(const char *key, float def);
void  sm64_3d_setting_set_f(const char *key, float val);

#ifdef __cplusplus
}
#endif

#endif // SM64_VISION_3D
#endif // SM64_VISION_3D_H
