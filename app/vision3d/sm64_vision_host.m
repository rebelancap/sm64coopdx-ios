// sm64_vision_host.m — boots the SDL/coopdx engine under the SwiftUI app entry
// (visionOS only) and owns the 2D<->3D transition sequencing.
//
// Why a SwiftUI entry at all: an ImmersiveSpace (stereoscopic rendering) can
// ONLY be declared by a SwiftUI App. SDL2's own UIApplicationMain wrapper is
// therefore bypassed on visionOS (engine built with SM64_SWIFT_MAIN): this VC
// calls the engine's renamed main once the SwiftUI window scene is live.
//
// THE STRUCTURAL FACT THAT SHAPES THIS WHOLE FILE (docs/frame-map.md:111):
// coopdx's main() NEVER RETURNS — pc_main.c ends in `while (true) {
// gWindowApi->main_loop(produce_one_frame); }`. vkQuake's iOS build converted
// its main into a CADisplayLink callback and returned (its overlay 0002), so
// `vkq_engine_main` returns and UIKit's run loop proceeds. We have NO such
// conversion, so sm64_engine_main() below never comes back and this thread —
// the MAIN thread — is inside the game loop forever.
//
// The survivability of that used to be ARGUED here — that SDL2's
// UIKit_PumpEvents runs CFRunLoopRunInMode on the main thread every frame and so
// drains the main dispatch queue. That argument is now UNDER TEST rather than
// asserted (SM64_MainQueueProbe below), because the first runtime test found
// AUTOENTER never firing from a dispatch_after. Read M-38 for the verdict; do
// not re-add a confident claim here without a measurement behind it.
//
// What is NOT in doubt:
//   - dispatch_sync onto main from another thread: DEADLOCK (D-016).
//   - "run code after sm64_engine_main returns": IMPOSSIBLE — it never returns.
//     Post-boot work therefore lives in sm64_3d_frame_poll(), which the game
//     loop calls ON the main thread, so it needs no queue at all.

#import "sm64_vision_host.h"

#ifdef SM64_VISION_3D

#import <Foundation/Foundation.h>

// SDL2 (statically linked; the shell has no SDL header search path — plain C decl).
extern void SDL_SetMainReady(void);

// pc_main.c, renamed by overlay 0011 under SM64_SWIFT_MAIN.
extern int sm64_engine_main(int argc, char *argv[]);

// SM64VisionApp.swift (@_cdecl).
extern void SM64_SetImmersiveMode(bool on);

static BOOL sm64_booted = NO;
static int sm64_3d_on = 0;
static void SM64_SetCurtain(bool show);
static void SM64_AdoptSDLWindowIntoScene(void);
static void SM64_TrackSDLWindowToScene(void);

// Parked-window state (guide §2.7 / vkQuake vkq_pre3d_w/h). The FULL scene size
// captured in sm64_3d_enter BEFORE the shrink, so exit can restore it. Stored off
// a file-scope static (not fragile SwiftUI @State) and guarded so a re-entrant
// enter, or the per-frame scene-tracking, can never overwrite it with a card
// size — the guide's "sibling window stayed tiny because it captured after
// openSpace" trap.
static CGSize sm64_pre3d_scene_size = { 0.0, 0.0 };
// True while the window is (or is about to be) parked small: makes the per-frame
// SM64_TrackSDLWindowToScene follow the shrunk card without it becoming a new
// "full size" to capture.
static BOOL sm64_window_parked = NO;

// ---------------------------------------------------------------------------
// Settings storage (NSUserDefaults). Deliberately NOT coopdx's configfile: these
// are shell/panel settings with no engine cvar behind them, and configfile is
// owned by the engine's save-on-resign path (D-014). Keys are namespaced.
// ---------------------------------------------------------------------------
#define SM64_KEYPREFIX @"sm64vp3d."

float sm64_3d_setting_f(const char *key, float def) {
    NSString *k = [SM64_KEYPREFIX stringByAppendingString:[NSString stringWithUTF8String:key]];
    id v = [NSUserDefaults.standardUserDefaults objectForKey:k];
    return v ? [v floatValue] : def;
}

void sm64_3d_setting_set_f(const char *key, float val) {
    NSString *k = [SM64_KEYPREFIX stringByAppendingString:[NSString stringWithUTF8String:key]];
    [NSUserDefaults.standardUserDefaults setFloat:val forKey:k];
}

void sm64_3d_apply_settings(void) {
    // Panel geometry FIRST — auto convergence (below) reads the live panel size.
    sm64_3d_set_panel(sm64_3d_setting_f("dist", SM64_DEF_DIST),
                      sm64_3d_setting_f("halfW", SM64_DEF_HALFW),
                      sm64_3d_setting_f("halfH", SM64_DEF_HALFH));
    sm64_3d_set_height(sm64_3d_setting_f("posH", SM64_DEF_POSH));
    // Item 6: Focus Distance is auto-derived from the panel size when "Auto" is
    // on (default), else the manual slider value. Because the panel is applied
    // just above, dragging Screen Width/Distance with Auto on re-derives the
    // convergence live. hud is always 0 now (item 5 — slider removed).
    float conv = (sm64_3d_setting_f("convAuto", SM64_DEF_CONVAUTO) > 0.5f)
                     ? sm64_3d_auto_convergence()
                     : sm64_3d_setting_f("conv", SM64_DEF_CONV);
    sm64_gfx_set_3d_params(sm64_3d_setting_f("sep", SM64_DEF_SEP),
                           conv,
                           sm64_3d_setting_f("hud", SM64_DEF_HUD));
    sm64_3d_set_dim(sm64_3d_setting_f("dim", SM64_DEF_DIM));
}

// ---------------------------------------------------------------------------
// SDL window <-> window scene.
//
// SDL2 2.32.10 has no scene support at all: it creates its UIWindow and calls
// makeKeyAndVisible, never assigning .windowScene. Under the legacy
// (Phase 1, no UIApplicationSceneManifest) lifecycle that displayed fine. The
// moment Phase 2 adds the manifest — which openImmersiveSpace REQUIRES — UIKit
// switches to the scene lifecycle and a scene-less UIWindow is never shown.
// Adopting it here is what keeps the Phase-1 2D window from regressing to black.
//
// Note this is the SDL2 counterpart of SDL3's UIKit_GetActiveWindowScene, and
// it is why the guide's "stale SDL scene delegate" trap does NOT apply to us:
// SDL2 has no scene delegate to go stale.
// ---------------------------------------------------------------------------
static void SM64_AdoptSDLWindowIntoScene(void) {
    UIView *view = (__bridge UIView *)sm64_metal_get_sdl_uiview();
    UIWindow *win = view.window;
    if (!win) { return; }
    if (win.windowScene != nil) { return; } // already adopted

    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) { continue; }
        if (s.activationState != UISceneActivationStateForegroundActive) { continue; }
        win.windowScene = (UIWindowScene *)s;
        NSLog(@"[sm64vp] adopted SDL UIWindow into window scene %@", s.session.persistentIdentifier);
        return;
    }
}

// ---------------------------------------------------------------------------
// Keep the 2D window tracking user resizes (device bug fix, 2026-07-16).
//
// After adoption the SDL UIWindow is a SECONDARY window in the scene — the
// SwiftUI WindowGroup owns the primary one. When the user resizes the visionOS
// window the scene's coordinateSpace resizes, but UIKit does NOT relayout an
// adopted secondary window, so SDL_uikitwindow's own layoutSubviews scene-bounds
// glue (overlay/assets/sdl2-visionos-compat.patch) never FIRES. The window — and
// the metalview drawable derived from it (the metalview is the SDL rootVC's root
// view, so it fills the window) — stays frozen at its 1920x1080 creation size:
// expanding the window shows black margins, shrinking crops the game.
//
// Fix: drive the glue ourselves. The game loop calls sm64_3d_frame_poll() every
// frame ON the main thread, so match the window frame to the live scene bounds
// here. That resizes the rootVC metalview, which re-runs its DEBOUNCED
// updateDrawableSize (the resize-storm jetsam guard is preserved — it lives in
// the SDL patch, untouched), and fires SDL's viewDidLayoutSubviews so the engine
// picks up the new render size. This is the SDL2 counterpart to the geometry
// tracking SDL3 gets from being scene-aware; SDL2 predates scenes entirely.
static void SM64_TrackSDLWindowToScene(void) {
    UIView *view = (__bridge UIView *)sm64_metal_get_sdl_uiview();
    UIWindow *win = view.window;
    UIWindowScene *scene = win.windowScene;
    if (!scene) { return; } // not adopted yet, or scene torn down mid-transition
    CGRect b = scene.coordinateSpace.bounds;
    if (b.size.width > 0 && b.size.height > 0 && !CGRectEqualToRect(win.frame, b)) {
        NSLog(@"[sm64vp] window resize: frame %@ -> scene bounds %@",
              NSStringFromCGRect(win.frame), NSStringFromCGRect(b));
        win.frame = b;
    }
}

// ---------------------------------------------------------------------------
// MAIN-QUEUE LIVENESS PROBE — the experiment behind D-024.
//
// D-024 claims the SwiftUI graft survives coopdx's never-returning main()
// because SDL2's UIKit_PumpEvents runs CFRunLoopRunInMode on the main thread
// every frame, draining the main dispatch queue. EVERYTHING depends on that:
// openImmersiveSpace is an async main-actor Task, SM64_SetImmersiveMode is a
// DispatchQueue.main.async, and the ornament button's action has to get in
// somehow. If the main queue is dead, the whole design is dead.
//
// So it is measured, not argued. This re-arms itself every 0.5 s on the main
// queue; sm64_3d_frame_poll() (which runs on the main thread from inside the
// game loop, and therefore ALWAYS runs) reports the count. A count that stays
// at 0 while frames climb is the disproof; a climbing count is the proof.
// ---------------------------------------------------------------------------
static volatile int sm64_mainq_ticks = 0;

static void SM64_MainQueueProbe(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sm64_mainq_ticks++;
        SM64_MainQueueProbe(); // re-arm
    });
}

// ---------------------------------------------------------------------------
// Per-frame main-thread hook, called from gfx_run() (gfx_pc.c).
//
// This exists because of the structural fact in this file's header: the game
// loop OWNS the main thread and never returns to the run loop. That cuts both
// ways — it is why dispatch_after is unreliable here, but it also means this
// hook IS the main thread, so it can touch UIKit directly with no dispatch at
// all. Work that must happen "after boot" belongs here, not on a queue.
// ---------------------------------------------------------------------------
void sm64_3d_frame_poll(void) {
    static uint64_t frames = 0;
    static bool adopted = false;
    static bool autoentered = false;
    static double autoenter_at = -1.0;
    frames++;

    // Adopt SDL's scene-less UIWindow (D-025). Retried until it takes: SDL's
    // window does not exist for the first frames, and the scene may not be
    // foreground-active yet. Cheap and idempotent once adopted.
    if (!adopted && (frames % 30) == 0) {
        SM64_AdoptSDLWindowIntoScene();
        UIView *v = (__bridge UIView *)sm64_metal_get_sdl_uiview();
        adopted = (v.window.windowScene != nil);
    }

    // Once adopted, keep the 2D window glued to the live scene bounds so it
    // tracks user resizes (see SM64_TrackSDLWindowToScene). Every frame: the
    // frame-equality guard makes it a no-op unless the scene actually changed.
    if (adopted) { SM64_TrackSDLWindowToScene(); }

    // Simulator harness: drive a MID-SESSION scene resize to prove the 2D window
    // and its drawable track a change that happens AFTER startup — the exact BUG
    // 2 user scenario. `idb ui` cannot drag the sim's window handle, so
    // requestGeometryUpdate is the reliable headless channel (the SM64_VP3D_*
    // env pattern). Env-gated; absent => this does nothing, so it cannot affect a
    // shipped build. SM64_TrackSDLWindowToScene (above) does the actual tracking;
    // this only changes the scene geometry so there is something to track.
    {
        const char *rt = getenv("SM64_VP2D_RESIZETEST");
        if (rt && *rt && adopted) {
            static int rt_stage = 0;
            UIView *rv = (__bridge UIView *)sm64_metal_get_sdl_uiview();
            UIWindowScene *rscene = rv.window.windowScene;
            void (^reqSize)(CGFloat, CGFloat) = ^(CGFloat w, CGFloat h) {
                if (@available(visionOS 1.0, *)) {
                    UIWindowSceneGeometryPreferencesVision *p =
                        [[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:CGSizeMake(w, h)];
                    NSLog(@"[sm64vp] RESIZETEST requesting scene geometry %.0fx%.0f", w, h);
                    [rscene requestGeometryUpdateWithPreferences:p errorHandler:^(NSError *e) {
                        NSLog(@"[sm64vp] RESIZETEST geometry error: %@", e);
                    }];
                }
            };
            if (rscene) {
                if (rt_stage == 0 && frames > 300) { rt_stage = 1; reqSize(1000.0, 1500.0); } // tall
                if (rt_stage == 1 && frames > 600) { rt_stage = 2; reqSize(1900.0, 700.0);  } // wide
            }
        }
    }

    // Report the main-queue verdict once there is enough evidence to be worth
    // reading (~2 s of frames).
    if (frames == 240) {
        NSLog(@"[sm64vp] MAIN-QUEUE PROBE: %d ticks after %llu frames "
               "(0 => the main dispatch queue is NOT drained by SDL's pump)",
              sm64_mainq_ticks, (unsigned long long)frames);
    }

    // Harness: open the settings sheet N seconds after entering 3D. The gear is
    // a SwiftUI ornament button needing a gaze-pinch, and idb ui tap is dead on
    // this simulator — so without this the sheet is unverifiable, and an
    // unverifiable control is an unverified one.
    {
        static bool settings_opened = false;
        const char *s = getenv("SM64_VP3D_AUTOSETTINGS");
        if (s && *s && !settings_opened && autoentered && (frames % 600) == 0) {
            settings_opened = true;
            extern void SM64_OpenSettingsSheet(void);
            NSLog(@"[sm64vp] AUTOSETTINGS: opening the sheet");
            SM64_OpenSettingsSheet();
        }
    }

    // Auto-enter, driven off the engine's own frame clock rather than a
    // dispatch timer, so the harness does not depend on the very mechanism it
    // is meant to test.
    const char *e = getenv("SM64_VP3D_AUTOENTER");
    if (e && *e && !autoentered) {
        double now = (double)frames / 120.0; // approx; only a coarse delay is needed
        if (autoenter_at < 0.0) { autoenter_at = atof(e); if (autoenter_at <= 0.0) { autoenter_at = 8.0; } }
        if (now >= autoenter_at) {
            autoentered = true;
            NSLog(@"[sm64vp] AUTOENTER firing from the frame hook (mainq ticks=%d)", sm64_mainq_ticks);
            sm64_3d_enter(true);
        }
    }

    // Harness: auto-EXIT N seconds after entering, so the parked-window RESTORE
    // path is verifiable headlessly (the Exit ornament needs a gaze-pinch, which
    // idb ui cannot drive on this simulator). Env-gated; absent => no effect.
    {
        static bool autoexited = false;
        static double autoexit_at = -1.0;
        const char *xe = getenv("SM64_VP3D_AUTOEXIT");
        if (xe && *xe && autoentered && !autoexited) {
            double now = (double)frames / 120.0;
            if (autoexit_at < 0.0) {
                autoexit_at = autoenter_at + atof(xe);
                if (atof(xe) <= 0.0) { autoexit_at = autoenter_at + 12.0; }
            }
            if (now >= autoexit_at) {
                autoexited = true;
                NSLog(@"[sm64vp] AUTOEXIT firing from the frame hook");
                sm64_3d_enter(false);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Simulator harness: env-driven auto-enter.
//
// The 3D button lives in a SwiftUI ornament, which needs a gaze-pinch — and
// `idb ui tap` is dead on the current simulator, so there is no way to press it
// headlessly. An env var is the reliable channel that remains (`simctl launch`
// argv famously does NOT reach the engine, but SIMCTL_CHILD_* env does), and it
// is the same trick q2repro used (Q2_XR_AUTOENTER). Verification that cannot be
// driven is verification that does not happen.
//
// SM64_VP3D_AUTOENTER=<seconds>: enter 3D that long after boot (the delay lets
// the engine reach a real frame first). Absent => this does nothing at all, so
// it cannot affect a shipped build's behaviour.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// "Playing in 3D" curtain over the parked 2D window.
//
// In 3D the engine stops rendering to the window's drawable, so the 2D window
// freezes on its last frame — a confusing duplicate floating in front of the
// panel. Cover it; the window (and its ornament) stays interactive.
// ---------------------------------------------------------------------------
static UIView *sm64_curtain;

static void SM64_SetCurtain(bool show) {
    if (show) {
        if (sm64_curtain) { return; }
        UIView *view = (__bridge UIView *)sm64_metal_get_sdl_uiview();
        UIWindow *win = view.window;
        if (!win) { return; }
        sm64_curtain = [[UIView alloc] initWithFrame:win.bounds];
        sm64_curtain.backgroundColor = UIColor.blackColor;
        sm64_curtain.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UILabel *l = [UILabel new];
        l.text = @"Playing in 3D";
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
        l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [sm64_curtain addSubview:l];
        [NSLayoutConstraint activateConstraints:@[
            [l.centerXAnchor constraintEqualToAnchor:sm64_curtain.centerXAnchor],
            [l.centerYAnchor constraintEqualToAnchor:sm64_curtain.centerYAnchor],
            [l.widthAnchor constraintLessThanOrEqualToAnchor:sm64_curtain.widthAnchor multiplier:0.8],
        ]];
        [win addSubview:sm64_curtain];
    } else {
        [sm64_curtain removeFromSuperview];
        sm64_curtain = nil;
    }
}

// ---------------------------------------------------------------------------
// 2D <-> 3D transitions. ORDER IS LOAD-BEARING (guide §2.7).
// ---------------------------------------------------------------------------

void sm64_3d_enter(bool on) {
    if (!sm64_booted) {
        NSLog(@"[sm64vp] Enter3D(%d) ignored pre-boot", on);
        return;
    }
    if (on == (bool)sm64_3d_on) { return; }

    if (on) {
        // Capture the FULL scene size to restore on exit, BEFORE anything shrinks
        // it (the shrink happens later, from sm64_3d_park_window, once the space
        // is up). Guard against capturing an already-small card (guide §2.7: a
        // sibling window "stayed tiny" because it captured after openSpace). The
        // scene is still full-size here — entering MIXED immersion does not resize
        // the 2D window.
        {
            UIView *view = (__bridge UIView *)sm64_metal_get_sdl_uiview();
            UIWindowScene *scene = view.window.windowScene;
            if (scene) {
                CGSize sz = scene.coordinateSpace.bounds.size;
                if (sz.width > 600.0 && sm64_pre3d_scene_size.width == 0.0) {
                    sm64_pre3d_scene_size = sz;
                    NSLog(@"[sm64vp] parked-window: captured pre-3D scene size %.0fx%.0f",
                          sz.width, sz.height);
                }
            }
        }
        // Push the saved panel/stereo settings BEFORE the first stereo frame,
        // or the first frames render with defaults and snap.
        sm64_3d_apply_settings();
        sm64_3d_on = 1;
        // OFFSCREEN FIRST, THEN open the space. The engine must stop touching
        // the window's drawable BEFORE the window is hidden behind the immersive
        // space — a hidden window's nextDrawable never returns. Doing this in
        // the other order is a hang, not a glitch.
        sm64_metal_set_3d_mode(1);
        SM64_SetCurtain(true);
        SM64_SetImmersiveMode(true); // sm64_3d_park_window fires after it opens
        NSLog(@"[sm64vp] 3D entry committed");
    } else {
        // Stop the immersive render thread and WAIT for it before the space is
        // torn down: it must never touch a layerRenderer SwiftUI is tearing down.
        sm64_3d_imm_stop = 1;
        for (int i = 0; i < 200 && sm64_3d_imm_running; i++) { usleep(10 * 1000); } // <= 2 s
        NSLog(@"[sm64vp] Enter3D(0): render thread stopped=%d", !sm64_3d_imm_running);
        sm64_3d_on = 0;
        SM64_SetImmersiveMode(false); // sm64_3d_exit_finalize runs after the dismiss
    }
}

// Shrink the parked 2D window to a small card during 3D (guide §2.7 / vkQuake
// VKQ_3DSmallWindow). In 3D the window only exists as the control surface — the
// curtain + the ornament — so it should get out of the way. Called from SwiftUI
// AFTER openImmersiveSpace resolves, i.e. once the space has finished opening:
// a window resize ANIMATION concurrent with the entry animation conflicts
// (vkQuake VKQHostViewController.m:63), so this is deliberately NOT done inside
// sm64_3d_enter.
//
// visionOS offers no API to MOVE a window, so we only resize it. We shrink via
// SCENE geometry (requestGeometryUpdateWithPreferences), NOT the SDL window
// directly: SM64_TrackSDLWindowToScene glues the SDL window to the scene bounds
// every frame, so shrinking the scene makes the SDL window (and its curtain)
// follow the card automatically — the compatibility the charter calls out. The
// long-edge push in the SDL compat patch keeps the eye-texture drawable at its
// ~3840 budget regardless of the small card (scale = 3840/longEdge), so panel
// fidelity is NOT lost while parked.
void sm64_3d_park_window(void) {
    if (!sm64_3d_on) { return; }             // exited before the space finished opening
    UIView *view = (__bridge UIView *)sm64_metal_get_sdl_uiview();
    UIWindowScene *scene = view.window.windowScene;
    if (!scene) { return; }

    // Card sized to the panel aspect (width x height sliders) so the parked card
    // looks like a small copy of the 3D screen. ~480 pt wide (vkQuake's card).
    float halfW = sm64_3d_setting_f("halfW", SM64_DEF_HALFW);
    float halfH = sm64_3d_setting_f("halfH", SM64_DEF_HALFH);
    float aspect = (halfH > 0.01f) ? (halfW / halfH) : (16.0f / 9.0f);
    CGFloat cardW = 480.0;
    CGFloat cardH = round(cardW / aspect);

    sm64_window_parked = YES;
    if (@available(visionOS 1.0, *)) {
        UIWindowSceneGeometryPreferencesVision *p =
            [[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:CGSizeMake(cardW, cardH)];
        NSLog(@"[sm64vp] parked-window: shrinking scene to card %.0fx%.0f", cardW, cardH);
        [scene requestGeometryUpdateWithPreferences:p errorHandler:^(NSError *e) {
            NSLog(@"[sm64vp] parked-window: shrink geometry error: %@", e);
        }];
    }
}

// Runs on the main thread after SwiftUI's dismissImmersiveSpace completes.
// Under MIXED immersion the 2D window never deactivates, so a scene-activate
// trigger would never fire — this is the authoritative back-to-2D path.
void sm64_3d_exit_finalize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Restore the parked window to its captured full size FIRST, and keep the
        // curtain up until the resize has settled (a frozen small game frame
        // expanding mid-restore would be visible). Then drop the curtain and hand
        // rendering back to the window drawable. Order matches vkQuake
        // VKQ_Exit3DFinalize (restore window -> settle -> curtain off -> mode off).
        if (sm64_pre3d_scene_size.width > 0.0) {
            UIView *view = (__bridge UIView *)sm64_metal_get_sdl_uiview();
            UIWindowScene *scene = view.window.windowScene;
            if (scene && @available(visionOS 1.0, *)) {
                UIWindowSceneGeometryPreferencesVision *p =
                    [[UIWindowSceneGeometryPreferencesVision alloc]
                        initWithSize:sm64_pre3d_scene_size];
                NSLog(@"[sm64vp] parked-window: restoring scene to %.0fx%.0f",
                      sm64_pre3d_scene_size.width, sm64_pre3d_scene_size.height);
                [scene requestGeometryUpdateWithPreferences:p errorHandler:^(NSError *e) {
                    NSLog(@"[sm64vp] parked-window: restore geometry error: %@", e);
                }];
            }
            sm64_pre3d_scene_size = CGSizeZero;
        }
        sm64_window_parked = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SM64_SetCurtain(false);
            if (sm64_metal_get_3d_mode()) {
                sm64_metal_set_3d_mode(0); // back to the window drawable
                NSLog(@"[sm64vp] 3D exit finalized — window rendering resumes");
            }
        });
    });
}

// Crown/system dismissal: the loop saw the layer invalidated and already exited.
void sm64_3d_immersive_ended(void) {
    NSLog(@"[sm64vp] immersive ended by system (Crown)");
    dispatch_async(dispatch_get_main_queue(), ^{
        sm64_3d_on = 0;
        SM64_SetImmersiveMode(false); // sync SwiftUI (no-op if already closed)
        sm64_3d_exit_finalize();
    });
}

// ---------------------------------------------------------------------------
// Engine bootstrap
// ---------------------------------------------------------------------------

@implementation SM64HostViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    // Resilience: if the user closes the parked window during 3D, the app loses
    // its only regular scene — audio dies and there is no Exit control left.
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (!sm64_3d_on || ![n.object isKindOfClass:UIWindowScene.class]) { return; }
            NSLog(@"[sm64vp] window closed during 3D — requesting it back");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIApplication.sharedApplication requestSceneSessionActivation:nil
                                                                  userActivity:nil
                                                                       options:nil
                                                                  errorHandler:^(NSError *e) {
                    NSLog(@"[sm64vp] reopen failed: %@", e);
                }];
            });
        }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (sm64_booted) { return; }
    sm64_booted = YES;
    // One runloop hop so the window scene is fully active before SDL_CreateWindow
    // goes looking for it — but via a RUN LOOP TIMER, not dispatch_async(main).
    //
    // THIS IS THE LOAD-BEARING LINE OF THE WHOLE GRAFT, and it was measured, not
    // reasoned (M-38). The main dispatch queue is SERIAL. Booting the engine from
    // inside a dispatch_async(main) block means that block never returns, so the
    // main queue can never drain another block for the life of the process —
    // libdispatch will not re-enter a serial queue that is already executing. It
    // is not that SDL's pump fails to service the queue; it is that WE were
    // holding it. Measured: 0 main-queue ticks in 240 frames, and every
    // SwiftUI-side effect (openImmersiveSpace, @Published, the ornament) silently
    // did nothing.
    //
    // performSelector:afterDelay: schedules a CFRunLoopTimer instead. The run
    // loop calls us directly, the main QUEUE is never entered, and so SDL's
    // per-frame CFRunLoopRunInMode is free to drain it. Same one-hop delay, same
    // thread — completely different consequence.
    [self performSelector:@selector(sm64BootEngine) withObject:nil afterDelay:0.0];
}

- (void)sm64BootEngine {
    NSLog(@"[sm64vp] SwiftUI shell: booting engine (sm64_engine_main)");
    // Armed BEFORE the call: sm64_engine_main never returns, so this is the only
    // chance to arm anything. It now measures a queue we are no longer holding.
    SM64_MainQueueProbe();
    SDL_SetMainReady();
    static char arg0[] = "sm64coopdx";
    static char *argv[] = { arg0, NULL };
    sm64_engine_main(1, argv); // DOES NOT RETURN
}

@end

#endif // SM64_VISION_3D
