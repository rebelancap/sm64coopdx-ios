# Frame map — sm64coopdx, one page

Where a frame comes from, and the exact seams the visionOS port cuts at.
Line numbers are against vendor pin `cfc54dbb`.

## Startup

```
SDL2main → main()                       src/pc/pc_main.c
  parse_cli_opts
  fs_init(sys_user_path())              :526   iOS => NSDocumentDirectory (Files-visible)
  configfile_load
  rom_assets_load()                     :504   drains the ROM-read queue (below)
  djui_language_init / dynos / mods_init       all read sys_resource_path() = bundle root
  gfx_init(gWindowApi, gRenderApi, TITLE)      :557
  main_rom_handler()                    :567   no valid ROM => render_rom_setup_screen() BLOCKS :569
  main_loop
```

**Assets are a RUNTIME ROM read, not a build step.** `src/pc/rom_assets.h`
macros expand each asset to a zero-filled array + an
`__attribute__((constructor))` that registers a (physical offset, size) read —
~12,100 instantiations across ~1,414 files. `rom_assets_load()` seeks/reads/
byte-swaps them out of the user's ROM. `extract_assets.py` is vestigial
(Makefile only touches it in `distclean:1143`). Sound is baked from checked-in
zlib blobs, then patched from the ROM by `sound/samples_assets.c`.

## The two roots (`src/pc/platform.c`)

| root | iOS/visionOS resolves to | holds |
|---|---|---|
| `sys_resource_path()` :341 | app bundle root (`sys_exe_path_dir()`) | `lang/`, `dynos/`, `palettes/`, bundled `mods/` |
| `sys_user_path()` :299 | `platform_ios_get_user_path()` → `NSDocumentDirectory` | the **ROM**, `sm64config.txt`, saves, user `mods/` |

## Render path

```
game → gfx_pc.c  (the N64 display-list interpreter, RSP/RDP emulation)
         │  builds buf_vbo triangle stream + shader/CC state
         ▼
     struct GfxRenderingAPI          src/pc/gfx/gfx_rendering_api.h  (24 C fn ptrs)
         ├── gfx_opengl.c    USE_GLES on iOS   ← DEAD on visionOS (M-1)
         ├── gfx_direct3d11.cpp  (Windows; C++ backend precedent for the shim)
         ├── gfx_dummy.c
         └── gfx_metal       ← WE WRITE THIS (D-002)
         │
     struct GfxWindowManagerAPI      gfx_sdl.c  (SDL_GL_CreateContext/SwapWindow/...)
```

Backend chosen by a plain switch: `pc_main.c:254` `gRenderApi = &gfx_opengl_api;`
(default `gfx_dummy_renderer_api` at `:113`).

**Two different rates — do not conflate them** (this is where the perf probe hooks,
overlay 0007 / D-013):

```
produce_one_frame()                          pc_main.c:447  <- one SIM tick, FRAMERATE=30
  network_update / game_loop_one_iteration / smlua_update
  produce_interpolation_frames_and_delay()   pc_main.c:321
    do {                                     :345           <- one RENDERED frame,
      gfx_start_frame() ... gfx_display_frame()                N per tick (N = refresh/30)
      precise_delay_f64()                    :369           <- the frame limiter's sleep
    } while (curTime < targetTime && numFramesToDraw > 0);
```

So `fps` and `gpu_ms` mean the **inner** loop; `sim_tps` means the **outer** tick.
Measuring the tick and calling it fps would report ~30 on a 120 Hz panel.

**A THIRD rate exists in 3D, and conflating it with `fps` cost a whole session**
(M-46 / D-030). Each inner-loop iteration renders the scene **twice** in 3D (both
eyes, D-026), so the engine's eye-render counter ticks at **2× fps**. `SM64_PERF`
prints both — `fps=90.0 … mode=3d eye_renders_s=180.0` — and they are one fact
stated twice, not two instruments to reconcile. `eye_renders_s == 2 × fps` in 3D,
`0` in 2D; anything else means a window straddling a mode change. `fps` itself is
now an **uncapped** counter: it previously came from the percentile buffer's index
and silently clamped at `PROBE_CAP/PROBE_REPORT_SEC = 409.6`, reporting the
ceiling as a reading (a free-running engine at 827 fps read `409.6`).
`Documents/vision-perf.log` is **append-only across every run** — always check the
per-line UTC stamp and the session banner before quoting a number from it.

**Phase 2 forks this path in ONE place** (overlay 0011): while 3D mode is on,
`gfx_metal_start_frame()` swaps the drawable's texture for one of two persistent
offscreen per-eye `MTLTexture`s and `end_frame` skips `presentDrawable`.
Everything between — pipelines, encoder, vertex buffers, the entire draw path —
is byte-for-byte the 2D path (they share `gfx_metal_begin_pass()`, factored so
the two cannot drift). Not acquiring the drawable in 3D is load-bearing, not an
optimisation: the 2D window is hidden behind the immersive space and a hidden
window's `nextDrawable` never returns (guide §2.7) — a hang, not a slowdown.

**Facts that make the Metal port tractable:**
- `gfx_pc.c` has **zero** framebuffer references — no render-target indirection
  to implement (LUS's framebuffer machinery is a clean subtraction). *Phase 2's
  eye textures are therefore the FIRST offscreen targets in the tree — there was
  no RT machinery to fight, but equally none to reuse.*
- The `z_is_from_0_to_1` clip convention is already threaded through
  (`gfx_pc.c:1211-1215`), so Metal's 0..1 depth is already supported.
- `gfx_direct3d11.cpp` proves the `extern "C"` struct-of-fn-ptrs C++ backend
  pattern in-tree.

**The risk:** the MSL generator must agree with `buf_vbo`'s vertex layout.
coopdx emits pos/texcoord/fog/**light_map**/inputs (`gfx_opengl.c:266-295`,
producer `gfx_pc.c:1218-1272`). `light_map` has no libultraship counterpart, and
LUS's template emits attributes coopdx never writes. A mismatch is **silent
garbage geometry**, not a compile error.

## Matrices — where Phase 2 injects (this is the good news)

```
gfx_sp_matrix()                         gfx_pc.c:662-709
  G_MTX_PROJECTION → mtxf_copy/mul into rsp.P_matrix        :690-695
  every path ends at:
    mtxf_mul(rsp.MP_matrix, modelview_stack[top], rsp.P_matrix)   :708
gfx_sp_pop_matrix() mirrors it                                    :716
vertices consume rsp.MP_matrix — SSE :788-791, scalar :810-813
```

Patching the projection at `:690-695` (or the two `mtxf_mul` sites `:708`/`:716`)
covers **100%** of geometry.

**The ortho/perspective predicate already exists:** `gfx_pc.c:728` tests
`rsp.P_matrix[3][3] > 0.5f`. That is exactly the gate the guide's
"ortho-not-offset" rule needs — apply the per-eye skew only when that test says
*perspective*, and SM64's ortho HUD (stars/coins/lives) stays at zero disparity,
sitting on the panel plane for free.

Phase 2 shape (guide §2.4), per eye offset `e`, convergence `C`:
```
view:       shift camera ±e/2 along view-space X
projection: proj[2][0] += -proj[0][0] * e / C      # off-axis, one line
```

**DONE — overlay 0011, and the "view" half turned out to need no view matrix.**
gfx_pc has none to shift (the game bakes view*model into the modelview stack), so
the eye offset is FOLDED INTO the projection: vertices compute `v * MV * P`, so
`v * MV * T * P == v * MV * (T*P)`, and `T*P` differs from `P` only in row 3.
Both edits therefore land on one matrix, at the two `mtxf_mul(rsp.MP_matrix, …)`
sites — **not** at the `P_matrix` load, which would compound the skew on a
subsequent `G_MTX_PROJECTION|G_MTX_MUL` and corrupt the ortho predicate (D-026):
```
for (i=0..3) eyeP[3][i] = P[3][i] - e * P[0][i];   # eye offset, folded
eyeP[2][0] += -P[0][0] * e / C;                    # off-axis convergence
```
The row-vector convention was READ out of the vertex loop (`:810-813` computes
`ob[0]*MP[0][0] + … + MP[3][0]`), not assumed — and it matches vkQuake's layout
exactly, so the guide's formulas transfer literally.

**Both-eyes-per-frame lives in `gfx_run()` (`:2102`), not pc_main.c** — overlay
0007's probe hunk encloses pc_main's render block, and editing inside another
patch's hunk breaks the reverse probe (D6). `gfx_run` renders the LEFT eye to
completion, then returns having selected the RIGHT, which the caller's unmodified
`gfx_end_frame_render()` / `gfx_display_frame()` close. **pc_main.c is untouched
for this.** Cheap because `gfx_sdl_start_frame()` is `return true;` and the Metal
path's `swap_buffers_begin/end` + `finish_render` are all no-ops.

**None of this has rendered a pixel** — it compiles, links and is symbol-verified
only (M-36). The host's simulator subsystem is wedged (M-34).

## Threads (the audit surface — charter ground rule 5)

- **main/render** — `main_loop`, owns `gfx_*`. **It never returns to the UIKit
  run loop**: `pc_main.c:708` is `while (true) { gWindowApi->main_loop(...) }` and
  `gfx_sdl_main_loop` just calls the iteration. Main-queue blocks therefore only
  drain incidentally, deep inside SDL's event pump — so nothing off-main may
  schedule work on the main queue and expect it to run promptly (D-016).
- **audio** — SDL2 callback (`AAPI_SDL2`). Guard every engine touch: a
  briefly-null context during init/teardown is the recurring SEGV class.
- **network** — CoopNet/juice. **The novel risk no reference port had.** Same
  audit as the audio thread. When it crashes, `crash.txt`'s `thread=other` +
  backtrace is what will say so (D-014).
- **Lua** — interprets on the main thread (no JIT ⇒ iOS/visionOS-legal).
- **bridge accept/serve** (overlay 0008, visionOS only, launch-gated) — a global
  dispatch queue. Reads only the volatiles `gfx_metal.mm` publishes
  (`gSm64GpuMs`, `gSm64DrawableW/H`) and pushes input via `SDL_PushEvent`
  (thread-safe). Touches no engine state directly.
- **log pump** (overlay 0008, visionOS only) — detached pthread draining the
  stdout/stderr tee pipe. The one thread that could hurt the frame loop: if it
  stalled, `printf` on main would block once the pipe filled. Hence the pipe's
  write ends are `O_NONBLOCK` — printf drops bytes rather than parking a frame
  (D-017).

## visionOS deltas (known before writing code)

| site | problem |
|---|---|
| `CMakeLists.txt:31,255` | `USE_GLES` + `-framework OpenGLES` — dead (M-1). **M-15 widens M-1: it is not just EAGLContext — EVERY GL entry point is `unavailable` in the xrOS SDK (`ES2/gl.h:545` for `glGetIntegerv`), so GL call sites must be COMPILED OUT (`SM64_NO_OPENGL`), not merely runtime-gated.** FIXED by overlay 0002/0005. |
| `platform_ios.m:84` | `[UIScreen mainScreen].maximumFramesPerSecond` — **UIScreen doesn't exist on visionOS**; hard compile break. FIXED by overlay 0004 (asks SDL for the display mode instead). **⚠️ SUPERSEDED by overlay 0010 — 0004's fix asked a MIRROR.** visionOS has no UIScreen for SDL either, so our own `sdl2-visionos-compat.patch` synthesizes the display and **hardcodes** `mode.refresh_rate = 120` (`SDL_uikitmodes.m`, "M5 Vision Pro panel max"): asking SDL read our own guess back, wrong on an M2 (90 Hz) by construction. 0010 MEASURES it from a CADisplayLink instead (D-021) and routes `pc_main.c: get_display_refresh_rate()` straight to `Sm64Ios_VisionPanelHz()`. `platform_ios_get_refresh_rate()` is left untouched (its body is inside 0004's hunk — D6) and is now **unreachable dead code on visionOS**; still live and correct on iOS (D-022). |
| `pc_main.c:212` | `get_display_refresh_rate()` memoizes into a function-local static on FIRST call = the first rendered frame — ~0.5 s *before* 0010's panel measurement settles. A memoized visionOS branch would latch the fallback for the life of the process: present, compiled, logged and **inert**. 0010's branch deliberately does not cache. |
| `configfile.c:107-108` | `framerate_mode`/`frame_limit` (RRM_AUTO / 60) are **PERSISTED**, so changing the C default only reaches a config that doesn't exist yet. 0010 ships a one-shot, marker-gated (`vision_framerate_rev`) migration instead — MANUAL @ measured panel rate, cap 120 (D-023). |
| **vsync ≡ no frame limiting** | `pc_main.c:333-337`: with `configWindow.vsync` (default **1**) and `displayRefreshRate <= refreshRate`, `shouldDelay = false` and `numFramesToDraw` is never decremented — the do-loop just renders until the 1/30 s tick boundary. So **AUTO and MANUAL@(≥ display rate) are behaviourally IDENTICAL** on a default config; the achieved fps is whatever the present path allows. MANUAL only *paces* when the limit is **below** the display rate. Do not read a Framerate-Mode change as a frame-rate change unless vsync is off. |
| `platform_ios.m:24,62,145` | `keyWindow` — ~~deprecated/unreliable~~ **CORRECTED (M-15): `API_UNAVAILABLE(visionos, watchos)` at `UIApplication.h:108` = a HARD COMPILE BREAK**, exactly like UIScreen. 3 of the file's 4 xros breaks. FIXED by overlay 0004 (connectedScenes walk on visionOS; iOS keeps keyWindow). |
| `lib/*/ios/*.a` | Mach-O platform 2 (iOS); need XROS 11 / XROS_SIM 12 (M-5) |
| `lib/SDL2-source` | gitignored & absent; we pin 2.32.10 ourselves (M-6) |
| `CMakeLists.txt:271-275` | `mods/` missing from `GAME_DATA_DIRS` — bundled mods silently absent on iOS today |
| `djui_gfx.c:74` | auto DJUI scale `clamp(…, 0.5, 1.5)` — the formula is really `drawableHeight/960`, so the 1.5 ceiling **saturates at a 1440-high drawable** and the menu shrinks as the visionOS drawable grows to ~2160. Manual options (`:77-81`) also cap at 1.5 ⇒ no user workaround. **FIXED by overlay 0006** (ceiling → 4.0 on visionOS; measured 487→787 px, M-15). |
| **drawable size** | ~~inferred~~ **MEASURED 3840×2160** (M-21, overlay 0007): `gfx_metal_start_frame` logs the acquired drawable's texture size next to what SDL asked for — they agree, so the long-edge push reaches the layer and the guide §1.2 lever is confirmed end-to-end. Desktop control reads 1024×768. Published as `gSm64DrawableW/H` + reported in `SM64_PERF`. |
| `patches/sdl2-ios-gamepad-fix.patch` | every hunk gated `#if TARGET_OS_IOS`, which is **0** on visionOS ⇒ the fix is INERT there (M-9). **RESOLVED — leave it inert (D-012).** It suppresses an *iPadOS* UIPress/UIKeyCommand conversion; visionOS instead converts pad input to **pinch events** (xrOS SDK `GCEventInteraction.h`), and `GCEventInteraction` at its default `receivesEventsInView=NO` makes GameController delivery **exclusive**, killing the conversion at source. Re-gating the patch would break hardware-keyboard input and fix nothing. |
| **gamepad claim** | `GCEventInteraction(GCUIEventTypeGamepad)` attached to the `SDL_Metal_CreateView` UIView in `gfx_metal_setup_layer` — Apple's own prescribed attach point for a Metal game (§ `GCEventInteraction.h`). Verified attaching on the sim; **not** verified with a real pad (none on this Mac) — M-22. |

### The diagnosis floor / data path (overlay 0008-0009, visionOS only — M-25)

| site | what |
|---|---|
| `app/shell/sm64_vision_shell.m` | crash handler → `Documents/crash.txt` (append-only, TIMESTAMP entries, primary never overwritten — D-014/D-015); stdout+stderr tee → `Documents/logs/` (coopdx has NO file logging: `debuglog.h` is printf-to-stdout — D-017); TCP bridge on **8791** (D-016); readme seed + import-perm normalisation; config save on resign. Constructor installs the crash handler + tee **before `main()`**; `sm64_vision_shell_init()` (pc_main.c, right after `configfile_load()`) does the rest — that ordering is what stops a resign from saving DEFAULTS over the user's config. |
| `src/pc/crash_handler.c` | **NOT used, and not usable**: gated `#if defined(_WIN32) \|\| defined(__linux__)`, so no handler is installed on Apple at all. `crash_handler_init()` (`:720`, called from `network.c:125`) survives the gate but installs nothing — it is an obfuscated `gPcDebug` tag hash. A name collision, not a starting point. → D-014. |
| `app/ios/Assets-visionos.xcassets` | `AppIcon.solidimagestack` — the fork's flat PNG gives a BLANK visionOS tile. Passed by path (`SM64_VISIONOS_ASSETS`, overlay 0009) because the overlay cannot deliver PNGs into vendor (patch(1) has no binary hunks). Layers generated by `scripts/gen-vision-icon.py`. → D-018. |

### Info.plist audit (`platform/ios/Info.plist`)

Already correct — inherit, don't re-derive:
- `UIFileSharingEnabled` = true **and** `LSSupportsOpeningDocumentsInPlace` = true.
  The Files-app ROM-drop path (Q-005) is already wired. ~~Phase 1 only needs the
  **Documents readme seed**~~ **DONE** (overlay 0008): an empty Documents dir
  hides the app in Files, which would make the ROM undroppable. Verified
  non-empty at first launch on a fresh container (M-25).

Needs fixing for visionOS — **DONE** in `app/ios/Info-visionos.plist`, selected by
overlay 0005 via `-DSM64_VISIONOS_PLIST` (the iOS plist is untouched):
| key | issue | status |
|---|---|---|
| `LSRequiresIPhoneOS` = true | iOS-only key; wrong for a native xrOS app (device family 7). | **DROPPED** (verified absent in the built app) |
| **`NSLocalNetworkUsageDescription` — ABSENT** | iOS/visionOS 14+ gate local-network access behind this key + user consent. libjuice's ICE gathers host candidates and talks to LAN peers ⇒ **LAN co-op likely fails silently without it** (internet co-op via STUN/relay is unaffected). Relevant because CoopNet is a hard v1 requirement. | **ADDED** (verified present) |
| `UIRequiresFullScreen`, `UISupportedInterfaceOrientations`, `UIStatusBarHidden` | meaningless on visionOS (no orientation, no status bar); harmless but noise | **DROPPED** |
| `CADisableMinimumFrameDurationOnPhone` | iOS ProMotion unlock; inert on visionOS | **DROPPED** (rate comes from the SDL display link: `CAFrameRateRange(80,120,120)`) |
| `UIApplicationSceneManifest` / `UIApplicationSupportsMultipleScenes` | ~~absent~~ **ADDED** with the Phase 2 graft (overlay 0011) — `openImmersiveSpace` fails `.error` before `makeConfiguration` without it (guide §2.2). Verified `true` in the BUILT Info.plist (M-36). **Its side effect is the interesting part:** the manifest switches UIKit from the legacy app-delegate lifecycle to the SCENE lifecycle, and **SDL2 2.32.10 never assigns `.windowScene`** (it predates scenes; the only `windowScene` reference under `src/video/uikit/` is one our own compat patch added). A scene-less `UIWindow` is never displayed — so the key Phase 2 *requires* is the key that would black out Phase 1's window. `sm64_vision_host.m` adopts SDL's window into the active scene (SDL3's `UIKit_GetActiveWindowScene`, reimplemented in the shell — D-025). **Adoption is reasoned, NOT observed** (M-36). |
| **`UIApplicationSupportsIndirectInputEvents` — ABSENT** (found M-15) | SDL logs *"You need UIApplicationSupportsIndirectInputEvents in your Info.plist for mouse support"* at launch on visionOS. Gaze-pinch arrives as an **indirect** input event, so this likely gates menu interaction. | **OPEN** — not needed to render; untested |
