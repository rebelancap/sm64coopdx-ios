//
//  gfx_metal.mm — Metal rendering backend for sm64coopdx
//
//  Why this exists: visionOS has no OpenGL (EAGLContext is explicitly marked
//  unavailable in XROS*.sdk OpenGLES.framework/Headers/EAGL.h for BOTH device
//  and simulator), so gfx_opengl.c cannot run there at all. This backend
//  implements the same 24-function GfxRenderingAPI seam (gfx_rendering_api.h)
//  on top of Metal.
//
//  Ported from libultraship's Fast3D Metal backend (src/fast/backends/
//  gfx_metal.cpp), which is a descendant fork of this same gfx_pc lineage.
//  The device/pipeline/texture/encoder structure transfers closely; the
//  shader-generation layer does NOT — LUS drives its MSL through the `prism`
//  template processor over an o2r resource archive, neither of which exists
//  here, and its vertex layout carries attributes (o_masks, o_blend, o_clamp,
//  o_grayscale, o_prim_depth) that coopdx's gfx_pc.c never writes to buf_vbo.
//  The generator below is therefore authored against coopdx's OWN producer
//  (gfx_pc.c:1218-1272) and mirrors gfx_opengl.c:266-312 statement for
//  statement. A mismatch there is silent garbage geometry, not a compile
//  error, so the two orderings are kept adjacent and commented.
//
//  Subtractions vs the LUS donor (all verified absent from coopdx):
//    - Framebuffer machinery: coopdx has zero framebuffers (grep -c framebuffer
//      gfx_pc.c == 0). CopyFramebuffer/ReadFramebufferToCPU/GetPixelDepth + its
//      depth compute kernel / MSAA resolve / readback queue are all dropped.
//      LUS's "framebuffer 0 == the window" concept is kept implicitly: this
//      file owns the CommandBuffer/RenderPassDescriptor/RenderCommandEncoder
//      for the drawable directly.
//    - ImGui: coopdx has no ImGui at all (djui draws through gfx_pc display
//      lists like any other geometry), so all 6 LUS ImGui sites are dropped.
//    - Ship::Context/CVar/spdlog/ResourceManager: replaced by coopdx's
//      configfile globals and fprintf/sys_fatal.
//
//  Language choice: plain Objective-C++ against the native Metal ObjC API
//  rather than LUS's metal-cpp. metal-cpp exists in LUS for cross-platform
//  build reasons that do not apply here, and vendoring it would add a large
//  header-only dependency to a tree that already has an ObjC toolchain on
//  every target that can run Metal. ARC is enabled for this file (-fobjc-arc),
//  which removes the whole retain/release class of bug the donor hand-manages.
//

#ifdef ENABLE_METAL_BACKEND

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <TargetConditionals.h>
#if TARGET_OS_VISION
// The gamepad claim (GCEventInteraction) and the view it attaches to. Gated on
// TARGET_OS_VISION, which is 1 ONLY on xros (measured, M-9: TARGET_OS_IPHONE 1,
// TARGET_OS_IOS 0, TARGET_OS_VISION 1) — so the macOS desktop oracle, which
// compiles this same file, never sees any of it.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
// The stereo 3D contract (SM64_EYE_*, the eye-texture accessors this file
// implements). Same TargetConditionals gate, so it compiles to nothing off
// visionOS.
#include "pc/vision3d/sm64_vision_3d.h"
#endif

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

#ifndef _LANGUAGE_C
#define _LANGUAGE_C
#endif
#include <PR/gbi.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>

// platform.h is not __cplusplus-guarded and gets pulled in transitively by the
// project headers below, which would give sys_fatal() C++ linkage and a mangled
// undefined symbol at link time. Force C linkage by including it first; the
// system headers it wants (stdlib/string/stdbool) are already included above,
// so their guards keep them out of the extern "C" block.
extern "C" {
#include "pc/platform.h"
}

#include "types.h"
#include "pc/configfile.h"
#include "gfx_cc.h"
#include "gfx_rendering_api.h"
#include "gfx_pc.h"
#include "gfx_metal.h"

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// Per-shader-program state. Mirrors gfx_opengl.c's `struct ShaderProgram`.
// Each backend defines its own incomplete-to-gfx_pc `struct ShaderProgram`;
// gfx_direct3d11.cpp establishes this precedent for a C++ backend.
struct ShaderProgram {
    uint64_t hash;
    uint8_t num_inputs;
    bool used_textures[2];
    uint8_t num_floats;
    bool used_noise;
    bool used_lightmap;
    bool world_geometry;
    id<MTLRenderPipelineState> pipeline_state;
};

struct MetalTexture {
    id<MTLTexture> texture;
    id<MTLSamplerState> sampler;
    float size[2];
    bool filter;
};

// Fragment uniforms. Deliberately built from 4-byte scalars ONLY — no float3 /
// packed vectors — so the C layout here and the MSL `struct FragUniforms`
// emitted by the generator below are byte-identical without alignment games.
// SHADER_FLAG_MAX is 8 (gfx_pc.h). Total = 96 bytes, far under the 4KB
// setFragmentBytes limit, so it is re-pushed on every draw instead of tracking
// dirty state the way gfx_opengl.c's per-uniform-location caching does.
struct FragUniforms {
    float uFrameCount;
    int32_t uFilter;
    int32_t uTexFilter0;
    int32_t uTexFilter1;
    float uLightmapR;
    float uLightmapG;
    float uLightmapB;
    float uPad;
    int32_t uShaderFlags[SHADER_FLAG_MAX];
    float uShaderFlagValues[SHADER_FLAG_MAX];
};

// Vertex streaming. gfx_pc.c flushes at most MAX_BUFFERED(256) * 3 verts *
// 26 floats = ~78KB per draw. Metal has no glBufferData equivalent: the GPU may
// still be reading a buffer the CPU wants to refill, so we keep one chain of
// buffers per in-flight frame and gate frames with a semaphore. Chunks grow on
// demand rather than pre-committing a huge fixed pool (LUS pre-allocates
// 3 x 4.9MB unconditionally) — this keeps the footprint honest for visionOS.
#define VBUF_FRAMES 3
#define VBUF_CHUNK  (4 * 1024 * 1024)

struct FrameVertexBuffers {
    std::vector<id<MTLBuffer>> chunks;
    size_t chunk_idx;
    size_t offset;
};

static id<MTLDevice> mtl_device = nil;
static id<MTLCommandQueue> mtl_queue = nil;
static CAMetalLayer *mtl_layer = nil;
static SDL_MetalView mtl_view = nil;
static SDL_Window *mtl_window = nil;

static id<CAMetalDrawable> cur_drawable = nil;
static id<MTLCommandBuffer> cur_cmdbuf = nil;
static id<MTLRenderCommandEncoder> cur_encoder = nil;
static id<MTLTexture> depth_texture = nil;
static id<MTLTexture> dummy_texture = nil;
static id<MTLSamplerState> dummy_sampler = nil;

// [depth_test][depth_mask]
static id<MTLDepthStencilState> depth_states[2][2];

static FrameVertexBuffers vbufs[VBUF_FRAMES];
static int vbuf_frame = 0;
static dispatch_semaphore_t frame_sem = nil;

static struct ShaderProgram shader_program_pool[CC_MAX_SHADERS];
static uint8_t shader_program_pool_size = 0;
static uint8_t shader_program_pool_index = 0;
static struct ShaderProgram *cur_shader = NULL;

static std::vector<MetalTexture> tex_cache;
static int cur_tex_id[2] = { -1, -1 };
static int cur_tile = 0;

static uint32_t frame_count = 0;
static bool frame_valid = false;
// How many times start_frame had to close a frame that end_frame never closed.
// Expected to be small and bounded (screen-to-screen transitions); a number that
// climbs every frame would mean the start/end pairing is genuinely broken.
static uint32_t stale_frame_closes = 0;
static uint32_t rt_width = 0, rt_height = 0;

// ---------------------------------------------------------------------------
// Telemetry published to the perf probe (pc_main.c, overlay 0007)
//
// gSm64GpuMs is written from Metal's completion handler, which runs on a
// SYSTEM thread, and read from the game thread — hence volatile. It is the ONLY
// number that can tell GPU saturation from pacing waits: the probe's eng_ms
// includes blocking inside present, so a saturated GPU and a frame-limiter
// sleeping to hit 60Hz look identical there.
//
// gSm64DrawableW/H are the MEASURED drawable, taken from the acquired
// drawable's texture (the ground truth Metal actually renders into) rather than
// from anything we asked for. Same thread as the reader, but kept volatile for
// uniformity with the bridge contract.
// ---------------------------------------------------------------------------
extern "C" {
volatile float gSm64GpuMs = 0.0f;
volatile int gSm64DrawableW = 0;
volatile int gSm64DrawableH = 0;
}

#if TARGET_OS_VISION
// ---------------------------------------------------------------------------
// visionOS stereoscopic 3D — the offscreen per-eye render targets (Phase 2).
//
// This is the ONLY render-target indirection in the whole tree: gfx_pc.c has
// zero framebuffer references (see this file's header comment), so there is no
// existing RT machinery to fight — but equally none to reuse. The shape is
// deliberately the smallest thing that works: while 3D mode is on, start_frame
// swaps the drawable's texture for one of two persistent eye textures and
// end_frame skips presentDrawable. Everything between them — pipelines,
// encoder, vertex buffers, the whole draw path — is byte-for-byte the 2D path.
//
// Why NOT acquire the drawable in 3D: the 2D window is hidden behind the
// immersive space, and a hidden window's nextDrawable never returns (guide
// §2.7). That is a hang, not a slowdown.
//
// The eye textures are plain RenderTarget|ShaderRead, NOT mipmapped: the
// immersive loop copies each into its OWN mipmapped texture on ITS command
// queue, so that the copy and the sample are coherent within one command
// buffer. Generating mips here (on the engine queue) and sampling there (on the
// compositor queue) would be an unsynchronised cross-queue read. That copy is
// vkQuake's proven shape (VKQImmersive.m) and is not an accident.
// ---------------------------------------------------------------------------
static int stereo_active = 0;
// The eye in flight is owned by gfx_pc.c (the matrix owner) — see the header.
// This file only READS it, to pick the render target that matches the
// projection gfx_pc is about to build. Two independent copies of "which eye" is
// exactly the bug that would put the left image on the right panel slice.
extern "C" int sm64_gfx_3d_eye;
static id<MTLTexture> stereo_eye_tex[2] = { nil, nil };
static id<MTLTexture> stereo_depth_tex = nil;
// Per-eye "has ever been rendered since entering 3D". An eye texture that has
// never been rendered holds UNDEFINED garbage — the guide's explicit trap. The
// accessor below gates on this, so the loop cannot sample it early.
static int stereo_eye_rendered[2] = { 0, 0 };
static uint32_t stereo_frames = 0;
// Comfort batch 3 item 1b (Fable P2-a): a PAIR generation counter, incremented
// ONCE after the RIGHT eye's end_frame — the pair boundary. The immersive loop
// copies both eye textures only when this has ADVANCED since its last copy,
// otherwise it reuses its persistent mipmapped copies. That kills the "L from
// frame N, R from frame N-1" inter-eye time-skew (the loop used to grab whatever
// was latest, mid-pair) AND skips redundant blit+mipgen whenever the compositor
// outpaces the engine. Monotonic; the loop tracks its own last-seen value.
static uint32_t stereo_pair_gen = 0;

static inline int stereo_idx(int eye) { return (eye == SM64_EYE_RIGHT) ? 1 : 0; }

extern "C" void sm64_metal_set_3d_mode(int on) {
    stereo_active = on ? 1 : 0;
    // Re-gate both eyes on EVERY transition: on entry nothing has been rendered
    // yet, and on exit the textures must not be handed out again if 3D is
    // re-entered before the first new frame lands.
    stereo_eye_rendered[0] = stereo_eye_rendered[1] = 0;
    if (!on) { sm64_gfx_set_3d_eye(SM64_EYE_OFF); }
    fprintf(stderr, "gfx_metal: 3D mode -> %d\n", stereo_active);
}

extern "C" int sm64_metal_get_3d_mode(void) { return stereo_active; }

extern "C" void *sm64_metal_get_3d_eye_texture(int eye) {
    const int i = stereo_idx(eye);
    if (!stereo_eye_rendered[i]) { return NULL; } // undefined contents — do not sample
    return (__bridge void *)stereo_eye_tex[i];
}

extern "C" void sm64_metal_get_3d_render_size(int *w, int *h) {
    id<MTLTexture> t = stereo_eye_tex[0];
    if (w) { *w = t ? (int)t.width : 0; }
    if (h) { *h = t ? (int)t.height : 0; }
}

extern "C" int sm64_metal_get_3d_frames(void) { return (int)stereo_frames; }

// The pair generation (batch 3 item 1b). Advances once per COMPLETE eye pair
// (after the right eye). The immersive loop diffs it to decide whether a fresh
// pair is ready — see stereo_pair_gen.
extern "C" uint32_t sm64_metal_get_3d_pair_gen(void) { return stereo_pair_gen; }

// The UIView SDL renders into (SDL_Metal_CreateView's). The shell needs it for
// two jobs it cannot do any other way:
//
//   1. Adopt SDL's UIWindow into the SwiftUI window scene. SDL2 predates scenes
//      entirely (2.32.10 has NO scene-delegate class and never assigns
//      .windowScene — verified by grep, unlike SDL3 which has
//      UIKit_GetActiveWindowScene). Once Info-visionos.plist declares
//      UIApplicationSceneManifest, UIKit switches to the scene lifecycle and a
//      scene-less UIWindow is never displayed. This is the seam that fixes it.
//   2. Host the "Playing in 3D" curtain over the parked window.
//
// SDL_MetalView is already a plain `void *` alias for the UIView (not an ObjC
// pointer type), so this is a straight pass-through — a __bridge cast here is
// actually a compile error ("incompatible types casting 'SDL_MetalView'
// (aka 'void *') to 'void *' with a __bridge cast"). The caller bridges it.
extern "C" void *sm64_metal_get_sdl_uiview(void) { return mtl_view; }
#endif // TARGET_OS_VISION

// Rendering state that Metal keeps on the encoder (and therefore loses every
// frame when a new encoder is made) but that gfx_pc.c only pushes on CHANGE.
// gfx_pc's rendering_state cache will happily not re-send an unchanged viewport
// across a frame boundary, so these are cached and re-applied at encoder
// creation. GL never needed this — its context state is persistent.
static bool cached_viewport_valid = false;
static MTLViewport cached_viewport;
static bool cached_scissor_valid = false;
static MTLScissorRect cached_scissor;
static bool cur_zmode_decal = false;
static bool cur_depth_test = false;
static bool cur_depth_mask = false;

// ---------------------------------------------------------------------------
// A/B switch + layer setup (called from gfx_sdl.c)
// ---------------------------------------------------------------------------

extern "C" bool gfx_metal_requested(void) {
#ifdef SM64_NO_OPENGL
    // visionOS: no GL backend exists in this binary at all, so Metal is not an
    // A/B choice and must not depend on an env var that nobody sets on-device.
    //
    // This is ONE source of truth on purpose. gfx_sdl.c keys USE_METAL() off
    // this to decide between an SDL_WINDOW_METAL window (+ gfx_metal_setup_layer)
    // and an SDL_WINDOW_OPENGL window (+ SDL_GL_CreateContext), while pc_main.c
    // separately forces gRenderApi = &gfx_metal_api under SM64_NO_OPENGL. When
    // this returned the env-var answer, those two disagreed on the visionOS
    // simulator: the renderer was Metal but the window was GL, so the layer was
    // never set up and gfx_metal_api.init() aborted with
    // "gfx_metal: init before layer setup" (observed, artifacts/vision-sim-01.png).
    return true;
#else
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("SM64_RAPI");
        cached = (e && (!strcmp(e, "metal") || !strcmp(e, "Metal") || !strcmp(e, "METAL"))) ? 1 : 0;
    }
    return cached == 1;
#endif
}

#if TARGET_OS_VISION
static void gfx_metal_claim_gamepad(void);
#endif

extern "C" bool gfx_metal_setup_layer(void *sdl_window) {
    mtl_window = (SDL_Window *)sdl_window;
    mtl_view = SDL_Metal_CreateView(mtl_window);
    if (!mtl_view) {
        fprintf(stderr, "gfx_metal: SDL_Metal_CreateView failed: %s\n", SDL_GetError());
        return false;
    }
    mtl_layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(mtl_view);
    if (!mtl_layer) {
        fprintf(stderr, "gfx_metal: SDL_Metal_GetLayer returned NULL\n");
        return false;
    }
    mtl_device = MTLCreateSystemDefaultDevice();
    if (!mtl_device) {
        fprintf(stderr, "gfx_metal: no Metal device\n");
        return false;
    }
    mtl_layer.device = mtl_device;
    mtl_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    mtl_layer.framebufferOnly = YES;

    // The game renders at the window's LOGICAL size (gfx_sdl's sHidpiActive is
    // false unless configWindow.hidpi is set), so on a Retina display the
    // compositor magnifies the result. CAMetalLayer defaults to
    // magnificationFilter = kCAFilterLinear, which softens every edge and makes
    // the whole frame read as blurry next to the GL build; the GL surface gets a
    // point upscale instead. Match GL so the backends are a true A/B and so the
    // 1x path keeps SM64's intended chunky-pixel look.
    //
    // NOTE for visionOS: this is the same axis as the "~3840 drawable" work item
    // — the real fix there is to render AT the native drawable size (set
    // contentsScale to the backing scale and size the drawable in pixels) rather
    // than magnifying a smaller one. That is a gfx_sdl/hidpi change, not a
    // backend change, so it is deliberately out of scope for this spike.
    mtl_layer.magnificationFilter = kCAFilterNearest;

#if TARGET_OS_VISION
    gfx_metal_claim_gamepad();
#endif
    return true;
}

#if TARGET_OS_VISION
// ---------------------------------------------------------------------------
// visionOS gamepad claim — REQUIRED in a 2D window / shared space.
//
// Without this the pad drives the SYSTEM, not the game. From the xrOS 26.5 SDK's
// own GCEventInteraction.h (Apple's words, not folklore):
//
//   "On visionOS, users can interact with your app using a game controller. By
//    default, the system converts game controller actions into pinch events and
//    sends them to the view the user is gazing at, its gesture recognizers, and
//    then up the responder chain.
//
//    If you use the Game Controller framework to handle game controller events
//    for part of your user interface, add an instance of `GCEventInteraction`
//    to the root of that part of your app's view hierarchy. For example, if you
//    are writing a game using Metal, add this interaction to the view that hosts
//    your game's `CAMetalLayer`."
//
// That last sentence is this exact call site: SDL_Metal_CreateView returns the
// UIView hosting our CAMetalLayer, so we attach here rather than hunting for a
// window through UIApplication.connectedScenes. It is also the earliest point at
// which the view exists.
//
// Why claiming is enough, and why we do NOT re-gate the fork's SDL2
// gamepad-suppression patch to cover visionOS (M-9 left this open):
// `receivesEventsInView` defaults to NO, which the same header defines as
// "events of the types specified by handledEventTypes are delivered EXCLUSIVELY
// through the Game Controller framework." So the claim does not merely let
// GCController see the pad — it stops the UIKit conversion at the source. The
// fork's patch is an iPadOS workaround (suppress SDL's UIPress->scancode
// conversion) for a platform where GCEventInteraction was not used; re-gating it
// to visionOS would additionally kill arrow keys from a real Bluetooth keyboard,
// which visionOS supports and which djui menus use. Wrong tool, and the right
// tool is already here.
//
// SDL reads GCController underneath (SDL_mfijoystick.m), so once the events are
// claimed, SDL's controller stack and coopdx's existing 0x1000-based binds
// (VK_BASE_SDL_GAMEPAD, controller_sdl.h:6) work unchanged.
static void gfx_metal_claim_gamepad(void) {
    if (@available(visionOS 2.0, *)) {
        UIView *host = (__bridge UIView *)mtl_view;
        if (!host) {
            fprintf(stderr, "gfx_metal: gamepad claim SKIPPED — no metal view\n");
            return;
        }
        GCEventInteraction *it = [GCEventInteraction new];
        it.handledEventTypes = GCUIEventTypeGamepad;
        [host addInteraction:it];
        // Logged, not assumed: a silent claim is indistinguishable from no claim
        // at all, and "the pad does nothing" is the #1 thing that looks broken
        // first on this platform.
        fprintf(stderr, "gfx_metal: visionOS gamepad claimed via GCEventInteraction "
                        "(handledEventTypes=0x%lx, view=%s)\n",
                (unsigned long)it.handledEventTypes,
                [NSStringFromClass([host class]) UTF8String]);
    } else {
        fprintf(stderr, "gfx_metal: gamepad claim UNAVAILABLE (visionOS < 2.0)\n");
    }
}
#endif

extern "C" void gfx_metal_shutdown_layer(void) {
    if (mtl_view) {
        SDL_Metal_DestroyView(mtl_view);
        mtl_view = nil;
        mtl_layer = nil;
    }
}

// Virtualizes gfx_sdl.c's glGetIntegerv(GL_MAX_SAMPLES) — a direct GL call from
// the window manager, which is the one piece of gfx_sdl.c that cannot survive
// on a Metal window.
//
// RETURNS 1 (= "no MSAA") ON PURPOSE. This backend does not implement MSAA: it
// never sets a pipeline sampleCount and never resolves. Reporting the device's
// real capability here would advertise up to 16x through
// djui_panel_display.c:132-146, and the menu would then offer 2x/4x/8x/16x
// options that do NOTHING — a control that lies. Returning 1 takes the menu's
// own `if (maxMsaa >= 2)` early-out at :133, so the Antialiasing row is simply
// not created. That is upstream's designed path for "this backend has no MSAA",
// not a hack.
//
// WHY NOT JUST IMPLEMENT IT. On visionOS MSAA is close to pointless: the panel
// renders at a ~3840 drawable and is downsampled onto a ~1400 px footprint —
// roughly 2.7x supersampling, which already antialiases better than MSAA would,
// for GPU time we are told to spend elsewhere. Note the guide's §2.6 panel
// fidelity levers, in impact order, are mipmaps+aniso -> gamma -> resolution.
// MSAA is not on the list at all. If a desktop-Metal user ever wants it, that is
// the moment to implement it properly — and then this returns the real number.
extern "C" int gfx_metal_get_max_msaa(void) {
    return 1;
}

// ---------------------------------------------------------------------------
// Shader generation
//
// This is the highest-risk code in the backend. The MSL emitted here must agree
// EXACTLY with the float ordering gfx_pc.c writes into buf_vbo:
//
//   gfx_pc.c:1218  pos.x, pos.y, z, w                     -> 4 floats, always
//   gfx_pc.c:1222  per used texture j: u, v               -> 2 floats each
//   gfx_pc.c:1259  if cm->use_fog:  r, g, b, fog_z        -> 4 floats
//   gfx_pc.c:1269  if cm->light_map: packed rg, packed ba -> 2 floats
//   gfx_pc.c:1275  per input: rgb(a)                      -> 3 or 4 floats
//
// which is exactly gfx_opengl.c:274-296's attribute declaration order. Both the
// MTLVertexDescriptor and the `struct Vertex` below walk that order in lockstep
// with num_floats, so the stride and every offset stay derived from one source.
// ---------------------------------------------------------------------------

static void append_str(char *buf, size_t *len, const char *str) {
    while (*str != '\0') buf[(*len)++] = *str++;
}

static void append_line(char *buf, size_t *len, const char *str) {
    while (*str != '\0') buf[(*len)++] = *str++;
    buf[(*len)++] = '\n';
}

// Same algorithm and same SHADER_* enums as gfx_opengl.c:136-216 (shared
// lineage), retyped for MSL: vecN -> floatN, and the varyings live on the
// stage_in struct so they take an `in.` prefix.
static const char *metal_shader_item_to_str(uint32_t item, bool with_alpha, bool only_alpha, bool inputs_have_alpha, bool hint_single_element) {
    if (!only_alpha) {
        switch (item) {
            case SHADER_0:
                return with_alpha ? "float4(0.0, 0.0, 0.0, 0.0)" : "float3(0.0, 0.0, 0.0)";
            case SHADER_1:
                return with_alpha ? "float4(1.0, 1.0, 1.0, 1.0)" : "float3(1.0, 1.0, 1.0)";
            case SHADER_INPUT_1:
                return with_alpha || !inputs_have_alpha ? "in.vInput1" : "in.vInput1.rgb";
            case SHADER_INPUT_2:
                return with_alpha || !inputs_have_alpha ? "in.vInput2" : "in.vInput2.rgb";
            case SHADER_INPUT_3:
                return with_alpha || !inputs_have_alpha ? "in.vInput3" : "in.vInput3.rgb";
            case SHADER_INPUT_4:
                return with_alpha || !inputs_have_alpha ? "in.vInput4" : "in.vInput4.rgb";
            case SHADER_INPUT_5:
                return with_alpha || !inputs_have_alpha ? "in.vInput5" : "in.vInput5.rgb";
            case SHADER_INPUT_6:
                return with_alpha || !inputs_have_alpha ? "in.vInput6" : "in.vInput6.rgb";
            case SHADER_INPUT_7:
                return with_alpha || !inputs_have_alpha ? "in.vInput7" : "in.vInput7.rgb";
            case SHADER_INPUT_8:
                return with_alpha || !inputs_have_alpha ? "in.vInput8" : "in.vInput8.rgb";
            case SHADER_TEXEL0:
                return with_alpha ? "texVal0" : "texVal0.rgb";
            case SHADER_TEXEL0A:
                return hint_single_element ? "texVal0.a" :
                    (with_alpha ? "float4(texVal0.a, texVal0.a, texVal0.a, texVal0.a)" : "float3(texVal0.a, texVal0.a, texVal0.a)");
            case SHADER_TEXEL1:
                return with_alpha ? "texVal1" : "texVal1.rgb";
            case SHADER_TEXEL1A:
                return hint_single_element ? "texVal1.a" :
                    (with_alpha ? "float4(texVal1.a, texVal1.a, texVal1.a, texVal1.a)" : "float3(texVal1.a, texVal1.a, texVal1.a)");
            case SHADER_COMBINED:
                return with_alpha ? "texel" : "texel.rgb";
            case SHADER_COMBINEDA:
                return hint_single_element ? "texel.a" :
                    (with_alpha ? "float4(texel.a, texel.a, texel.a, texel.a)" : "float3(texel.a, texel.a, texel.a)");
            case SHADER_NOISE:
                return with_alpha ? "float4(noise)" : "float3(noise)";
        }
    } else {
        switch (item) {
            case SHADER_0:
                return "0.0";
            case SHADER_1:
                return "1.0";
            case SHADER_INPUT_1:
                return "in.vInput1.a";
            case SHADER_INPUT_2:
                return "in.vInput2.a";
            case SHADER_INPUT_3:
                return "in.vInput3.a";
            case SHADER_INPUT_4:
                return "in.vInput4.a";
            case SHADER_INPUT_5:
                return "in.vInput5.a";
            case SHADER_INPUT_6:
                return "in.vInput6.a";
            case SHADER_INPUT_7:
                return "in.vInput7.a";
            case SHADER_INPUT_8:
                return "in.vInput8.a";
            case SHADER_TEXEL0:
                return "texVal0.a";
            case SHADER_TEXEL0A:
                return "texVal0.a";
            case SHADER_TEXEL1:
                return "texVal1.a";
            case SHADER_TEXEL1A:
                return "texVal1.a";
            case SHADER_COMBINED:
                return "texel.a";
            case SHADER_COMBINEDA:
                return "texel.a";
            case SHADER_NOISE:
                // GL emits "noise.a" here, which would not compile (noise is a
                // float). Unreachable in practice; emit the scalar so the Metal
                // path cannot be the thing that breaks if it ever is reached.
                return "noise";
        }
    }
    return "unknown";
}

// Structurally identical to gfx_opengl.c:218-243.
static void metal_append_formula(char *buf, size_t *len, uint8_t *cmd, bool do_single, bool do_multiply, bool do_mix, bool with_alpha, bool only_alpha, bool opt_alpha) {
    if (do_single) {
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 3], with_alpha, only_alpha, opt_alpha, false));
    } else if (do_multiply) {
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 0], with_alpha, only_alpha, opt_alpha, false));
        append_str(buf, len, " * ");
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 2], with_alpha, only_alpha, opt_alpha, true));
    } else if (do_mix) {
        append_str(buf, len, "mix(");
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 1], with_alpha, only_alpha, opt_alpha, false));
        append_str(buf, len, ", ");
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 0], with_alpha, only_alpha, opt_alpha, false));
        append_str(buf, len, ", ");
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 2], with_alpha, only_alpha, opt_alpha, true));
        append_str(buf, len, ")");
    } else {
        append_str(buf, len, "(");
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 0], with_alpha, only_alpha, opt_alpha, false));
        append_str(buf, len, " - ");
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 1], with_alpha, only_alpha, opt_alpha, false));
        append_str(buf, len, ") * ");
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 2], with_alpha, only_alpha, opt_alpha, true));
        append_str(buf, len, " + ");
        append_str(buf, len, metal_shader_item_to_str(cmd[only_alpha * 4 + 3], with_alpha, only_alpha, opt_alpha, false));
    }
}

static void add_vtx_attr(MTLVertexDescriptor *vd, int index, int components, size_t offset_floats) {
    MTLVertexFormat fmt;
    switch (components) {
        case 1:  fmt = MTLVertexFormatFloat;  break;
        case 2:  fmt = MTLVertexFormatFloat2; break;
        case 3:  fmt = MTLVertexFormatFloat3; break;
        default: fmt = MTLVertexFormatFloat4; break;
    }
    vd.attributes[index].format = fmt;
    vd.attributes[index].bufferIndex = 0;
    vd.attributes[index].offset = offset_floats * sizeof(float);
}

static void gfx_metal_load_shader(struct ShaderProgram *new_prg);

static struct ShaderProgram *gfx_metal_create_and_load_new_shader(struct ColorCombiner *cc) {
    struct CCFeatures ccf = { 0 };
    gfx_cc_get_features(cc, &ccf);

    bool opt_alpha = cc->cm.use_alpha;
    bool opt_fog = cc->cm.use_fog;
    bool opt_texture_edge = cc->cm.texture_edge;
    bool opt_2cycle = cc->cm.use_2cycle;
    bool opt_light_map = cc->cm.light_map;
    bool world_geometry = cc->cm.world_geometry;
    bool opt_dither = cc->cm.use_dither;

    char buf[32768];
    size_t len = 0;
    size_t num_floats = 4;   // aVtxPos — matches gfx_opengl.c:266
    int attr = 0;
    size_t off = 0;

    MTLVertexDescriptor *vdesc = [MTLVertexDescriptor vertexDescriptor];

    append_line(buf, &len, "#include <metal_stdlib>");
    append_line(buf, &len, "using namespace metal;");

    // Emitted unconditionally so the MSL layout can never drift from the C
    // `struct FragUniforms` based on which features a given combiner uses.
    append_line(buf, &len, "struct FragUniforms {");
    append_line(buf, &len, "    float uFrameCount;");
    append_line(buf, &len, "    int uFilter;");
    append_line(buf, &len, "    int uTexFilter0;");
    append_line(buf, &len, "    int uTexFilter1;");
    append_line(buf, &len, "    float uLightmapR;");
    append_line(buf, &len, "    float uLightmapG;");
    append_line(buf, &len, "    float uLightmapB;");
    append_line(buf, &len, "    float uPad;");
    len += sprintf(buf + len, "    int uShaderFlags[%d];\n", SHADER_FLAG_MAX);
    len += sprintf(buf + len, "    float uShaderFlagValues[%d];\n", SHADER_FLAG_MAX);
    append_line(buf, &len, "};");

    // ---- Vertex input struct + MTLVertexDescriptor, in buf_vbo order --------
    append_line(buf, &len, "struct Vertex {");
    len += sprintf(buf + len, "    float4 aVtxPos [[attribute(%d)]];\n", attr);
    add_vtx_attr(vdesc, attr++, 4, off); off += 4;

    for (int t = 0; t < 2; t++) {
        if (ccf.used_textures[t]) {
            len += sprintf(buf + len, "    float2 aTexCoord%d [[attribute(%d)]];\n", t, attr);
            add_vtx_attr(vdesc, attr++, 2, off); off += 2;
            num_floats += 2;
        }
    }
    if (opt_fog) {
        len += sprintf(buf + len, "    float4 aFog [[attribute(%d)]];\n", attr);
        add_vtx_attr(vdesc, attr++, 4, off); off += 4;
        num_floats += 4;
    }
    if (opt_light_map) {
        // No LUS counterpart — coopdx-only attribute (gfx_pc.c:1269).
        len += sprintf(buf + len, "    float2 aLightMap [[attribute(%d)]];\n", attr);
        add_vtx_attr(vdesc, attr++, 2, off); off += 2;
        num_floats += 2;
    }
    for (int i = 0; i < ccf.num_inputs; i++) {
        len += sprintf(buf + len, "    float%d aInput%d [[attribute(%d)]];\n", opt_alpha ? 4 : 3, i + 1, attr);
        add_vtx_attr(vdesc, attr++, opt_alpha ? 4 : 3, off); off += opt_alpha ? 4 : 3;
        num_floats += opt_alpha ? 4 : 3;
    }
    append_line(buf, &len, "};");

    vdesc.layouts[0].stride = num_floats * sizeof(float);
    vdesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    // `off` walked the same sequence num_floats did; if they ever disagree the
    // vertex descriptor and the shader disagree, which renders as silent
    // garbage rather than an error. Assert instead.
    if (off != num_floats) {
        sys_fatal("gfx_metal: vertex layout desync (off=%zu num_floats=%zu)", off, num_floats);
    }

    // ---- Varyings ----------------------------------------------------------
    append_line(buf, &len, "struct ProjectedVertex {");
    for (int t = 0; t < 2; t++) {
        if (ccf.used_textures[t]) {
            len += sprintf(buf + len, "    float2 vTexCoord%d;\n", t);
        }
    }
    if (opt_fog)      { append_line(buf, &len, "    float4 vFog;"); }
    if (opt_light_map) { append_line(buf, &len, "    float2 vLightMap;"); }
    for (int i = 0; i < ccf.num_inputs; i++) {
        len += sprintf(buf + len, "    float%d vInput%d;\n", opt_alpha ? 4 : 3, i + 1);
    }
    append_line(buf, &len, "    float4 position [[position]];");
    append_line(buf, &len, "};");

    // ---- Vertex shader -----------------------------------------------------
    // gfx_pc.c does all transformation on the CPU and hands us clip space
    // directly, so this is a pure passthrough (gfx_opengl.c:312 is likewise
    // just `gl_Position = aVtxPos`). The 0..1 vs -1..1 depth convention is
    // already handled upstream via z_is_from_0_to_1 (gfx_pc.c:1211-1215).
    append_line(buf, &len, "vertex ProjectedVertex vertexShader(Vertex in [[stage_in]]) {");
    append_line(buf, &len, "    ProjectedVertex out;");
    for (int t = 0; t < 2; t++) {
        if (ccf.used_textures[t]) {
            len += sprintf(buf + len, "    out.vTexCoord%d = in.aTexCoord%d;\n", t, t);
        }
    }
    if (opt_fog)       { append_line(buf, &len, "    out.vFog = in.aFog;"); }
    if (opt_light_map) { append_line(buf, &len, "    out.vLightMap = in.aLightMap;"); }
    for (int i = 0; i < ccf.num_inputs; i++) {
        len += sprintf(buf + len, "    out.vInput%d = in.aInput%d;\n", i + 1, i + 1);
    }
    append_line(buf, &len, "    out.position = in.aVtxPos;");
    append_line(buf, &len, "    return out;");
    append_line(buf, &len, "}");

    // ---- Fragment helpers --------------------------------------------------
    if (ccf.used_textures[0] || ccf.used_textures[1]) {
        // 3-point filtering, original author ArthurCarvalho / mupen64plus.
        // MSL retype of gfx_opengl.c:353-367. NOTE: configFiltering defaults to
        // 2 ("Trilinear") in configfile.c:104, so this is the DEFAULT path, not
        // an exotic one.
        append_line(buf, &len, "#define TEX_OFFSET(tex, smp, texCoord, off, texSize) tex.sample(smp, texCoord - (off) / texSize)");
        append_line(buf, &len, "static float4 filter3point(texture2d<float> tex, sampler smp, float2 texCoord, float2 texSize) {");
        append_line(buf, &len, "    float2 offset = fract(texCoord * texSize - float2(0.5));");
        append_line(buf, &len, "    offset -= step(1.0, offset.x + offset.y);");
        append_line(buf, &len, "    float4 c0 = TEX_OFFSET(tex, smp, texCoord, offset, texSize);");
        append_line(buf, &len, "    float4 c1 = TEX_OFFSET(tex, smp, texCoord, float2(offset.x - sign(offset.x), offset.y), texSize);");
        append_line(buf, &len, "    float4 c2 = TEX_OFFSET(tex, smp, texCoord, float2(offset.x, offset.y - sign(offset.y)), texSize);");
        append_line(buf, &len, "    return c0 + abs(offset.x) * (c1 - c0) + abs(offset.y) * (c2 - c0);");
        append_line(buf, &len, "}");
        append_line(buf, &len, "static float4 sampleTex(texture2d<float> tex, sampler smp, float2 uv, float2 texSize, bool dofilter, int filt) {");
        append_line(buf, &len, "    if (dofilter && filt == 2) {");
        append_line(buf, &len, "        return filter3point(tex, smp, uv, texSize);");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    return tex.sample(smp, uv);");
        append_line(buf, &len, "}");
    }

    if (world_geometry) {
        append_line(buf, &len, "static float dither4x4(float2 position, float brightness) {");
        append_line(buf, &len, "    int x = int(fmod(position.x, 4.0));");
        append_line(buf, &len, "    int y = int(fmod(position.y, 4.0));");
        append_line(buf, &len, "    int index = x + y * 4;");
        append_line(buf, &len, "    float limit = 0.0;");
        append_line(buf, &len, "    if (x < 8) {");
        append_line(buf, &len, "        if (index == 0) limit = 0.0625;");
        append_line(buf, &len, "        if (index == 1) limit = 0.5625;");
        append_line(buf, &len, "        if (index == 2) limit = 0.1875;");
        append_line(buf, &len, "        if (index == 3) limit = 0.6875;");
        append_line(buf, &len, "        if (index == 4) limit = 0.8125;");
        append_line(buf, &len, "        if (index == 5) limit = 0.3125;");
        append_line(buf, &len, "        if (index == 6) limit = 0.9375;");
        append_line(buf, &len, "        if (index == 7) limit = 0.4375;");
        append_line(buf, &len, "        if (index == 8) limit = 0.25;");
        append_line(buf, &len, "        if (index == 9) limit = 0.75;");
        append_line(buf, &len, "        if (index == 10) limit = 0.125;");
        append_line(buf, &len, "        if (index == 11) limit = 0.625;");
        append_line(buf, &len, "        if (index == 12) limit = 1.0;");
        append_line(buf, &len, "        if (index == 13) limit = 0.5;");
        append_line(buf, &len, "        if (index == 14) limit = 0.875;");
        append_line(buf, &len, "        if (index == 15) limit = 0.375;");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    return brightness < limit ? 0.0 : 1.0;");
        append_line(buf, &len, "}");

        append_line(buf, &len, "static float3 rgb2hsv(float3 c) {");
        append_line(buf, &len, "    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);");
        append_line(buf, &len, "    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));");
        append_line(buf, &len, "    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));");
        append_line(buf, &len, "    float d = q.x - min(q.w, q.y);");
        append_line(buf, &len, "    float e = 1.0e-10;");
        append_line(buf, &len, "    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);");
        append_line(buf, &len, "}");
        append_line(buf, &len, "static float3 hsv2rgb(float3 c) {");
        append_line(buf, &len, "    float3 p = abs(fract(c.xxx + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);");
        append_line(buf, &len, "    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);");
        append_line(buf, &len, "}");
    }

    if ((opt_alpha && opt_dither) || ccf.do_noise) {
        append_line(buf, &len, "static float random(float3 value) {");
        append_line(buf, &len, "    float random = dot(sin(value), float3(12.9898, 78.233, 37.719));");
        append_line(buf, &len, "    return fract(sin(random) * 143758.5453);");
        append_line(buf, &len, "}");
    }

    // ---- Fragment shader ---------------------------------------------------
    append_line(buf, &len, "fragment float4 fragmentShader(ProjectedVertex in [[stage_in]],");
    append_line(buf, &len, "                               constant FragUniforms &u [[buffer(0)]]");
    for (int t = 0; t < 2; t++) {
        if (ccf.used_textures[t]) {
            len += sprintf(buf + len, "                               , texture2d<float> uTex%d [[texture(%d)]], sampler uTex%dSmplr [[sampler(%d)]]\n", t, t, t, t);
        }
    }
    append_line(buf, &len, ") {");

    if ((opt_alpha && opt_dither) || ccf.do_noise) {
        // gl_FragCoord -> in.position. NOTE: GL's gl_FragCoord.y counts from the
        // bottom, Metal's [[position]].y from the top. For the noise hash this
        // only reshuffles which pixel gets which value; see the header comment
        // on dither/scanlines where it is a real (if cosmetic) divergence.
        append_line(buf, &len, "    float noise = floor(random(floor(float3(in.position.xy, u.uFrameCount))) + 0.5);");
    }

    // GL reads texture size from a uniform it sets on upload; Metal can ask the
    // texture directly, which removes that uniform-plumbing entirely.
    if (ccf.used_textures[0]) {
        append_line(buf, &len, "    float2 texSize0 = float2(uTex0.get_width(), uTex0.get_height());");
        append_line(buf, &len, "    float4 texVal0 = sampleTex(uTex0, uTex0Smplr, in.vTexCoord0, texSize0, u.uTexFilter0 != 0, u.uFilter);");
    }
    if (ccf.used_textures[1]) {
        append_line(buf, &len, "    float2 texSize1 = float2(uTex1.get_width(), uTex1.get_height());");
        if (opt_light_map) {
            append_line(buf, &len, "    float4 texVal1 = sampleTex(uTex1, uTex1Smplr, in.vLightMap, texSize1, u.uTexFilter1 != 0, u.uFilter);");
            append_line(buf, &len, "    texVal0.rgb *= float3(u.uLightmapR, u.uLightmapG, u.uLightmapB);");
            append_line(buf, &len, "    texVal1.rgb = texVal1.rgb * texVal1.rgb + texVal1.rgb;");
        } else {
            append_line(buf, &len, "    float4 texVal1 = sampleTex(uTex1, uTex1Smplr, in.vTexCoord1, texSize1, u.uTexFilter1 != 0, u.uFilter);");
        }
    }

    append_str(buf, &len, opt_alpha ? "    float4 texel = " : "    float3 texel = ");
    for (int i = 0; i < (opt_2cycle + 1); i++) {
        uint8_t *cmd = &cc->shader_commands[i * 8];
        if (!ccf.color_alpha_same[i] && opt_alpha) {
            append_str(buf, &len, "float4(");
            metal_append_formula(buf, &len, cmd, ccf.do_single[i*2+0], ccf.do_multiply[i*2+0], ccf.do_mix[i*2+0], false, false, true);
            append_str(buf, &len, ", ");
            metal_append_formula(buf, &len, cmd, ccf.do_single[i*2+1], ccf.do_multiply[i*2+1], ccf.do_mix[i*2+1], true, true, true);
            append_str(buf, &len, ")");
        } else {
            metal_append_formula(buf, &len, cmd, ccf.do_single[i*2+0], ccf.do_multiply[i*2+0], ccf.do_mix[i*2+0], opt_alpha, false, opt_alpha);
        }
        append_line(buf, &len, ";");

        if (i == 0 && opt_2cycle) {
            append_str(buf, &len, "    texel = ");
        }
    }

    if (opt_texture_edge && opt_alpha) {
        append_line(buf, &len, "    if (texel.a > 0.3) { texel.a = 1.0; } else { discard_fragment(); }");
    }

    if (world_geometry) {
        append_line(buf, &len, "    if (u.uShaderFlags[0] == 1) {");
        append_line(buf, &len, "        float3 hsv = rgb2hsv(texel.rgb);");
        append_line(buf, &len, "        hsv.x = fract(hsv.x + u.uShaderFlagValues[0]);");
        append_line(buf, &len, "        texel.rgb = hsv2rgb(hsv);");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    if (u.uShaderFlags[1] == 1) {");
        append_line(buf, &len, "        const float3 w = float3(0.2125, 0.7154, 0.0721);");
        append_line(buf, &len, "        float3 intensity = float3(dot(texel.rgb, w));");
        append_line(buf, &len, "        texel.rgb = mix(intensity, texel.rgb, u.uShaderFlagValues[1]);");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    if (u.uShaderFlags[2] == 1) {");
        append_line(buf, &len, "        texel.rgb *= u.uShaderFlagValues[2];");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    if (u.uShaderFlags[3] == 1) {");
        append_line(buf, &len, "        texel.rgb = 0.5 + u.uShaderFlagValues[3] * (texel.rgb - 0.5);");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    if (u.uShaderFlags[4] == 1) {");
        append_line(buf, &len, "        texel.rgb = texel.rgb + (u.uShaderFlagValues[4] - 2.0) * texel.rgb + texel.rgb;");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    if (u.uShaderFlags[5] == 1) {");
        append_line(buf, &len, "        texel.rgb *= dither4x4(in.position.xy, dot(texel.rgb, float3(0.299, 0.587, 0.114)));");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    if (u.uShaderFlags[6] == 1) {");
        append_line(buf, &len, "        float levels = float(int(max(1.0, u.uShaderFlagValues[6])));");
        append_line(buf, &len, "        texel.rgb = floor(texel.rgb * levels) / levels;");
        append_line(buf, &len, "    }");
        append_line(buf, &len, "    if (u.uShaderFlags[7] == 1) {");
        append_line(buf, &len, "        float scan = sin(in.position.y * 1.5) * 0.04;");
        append_line(buf, &len, "        texel.rgb -= scan * u.uShaderFlagValues[7];");
        append_line(buf, &len, "    }");
    }

    if (opt_fog) {
        if (opt_alpha) {
            append_line(buf, &len, "    texel = float4(mix(texel.rgb, in.vFog.rgb, in.vFog.a), texel.a);");
        } else {
            append_line(buf, &len, "    texel = mix(texel, in.vFog.rgb, in.vFog.a);");
        }
    }

    if (opt_alpha && opt_dither) {
        append_line(buf, &len, "    texel.a *= noise;");
    }

    if (opt_alpha) {
        append_line(buf, &len, "    return texel;");
    } else {
        append_line(buf, &len, "    return float4(texel, 1.0);");
    }
    append_line(buf, &len, "}");
    buf[len] = '\0';

    if (len >= sizeof(buf) - 1) {
        sys_fatal("gfx_metal: shader source overflow (%zu bytes)", len);
    }

    if (getenv("SM64_METAL_DUMP_SHADERS")) {
        fprintf(stderr, "==== MSL for cc hash %llu ====\n%s\n", (unsigned long long)cc->hash, buf);
    }

    // ---- Compile + pipeline ------------------------------------------------
    NSError *error = nil;
    id<MTLLibrary> library = [mtl_device newLibraryWithSource:[NSString stringWithUTF8String:buf]
                                                      options:nil
                                                        error:&error];
    if (!library) {
        fprintf(stderr, "gfx_metal: MSL compile failed:\n%s\n", buf);
        sys_fatal("metal shader compilation failed:\n%s",
                  error ? [[error localizedDescription] UTF8String] : "unknown");
    }

    MTLRenderPipelineDescriptor *pdesc = [[MTLRenderPipelineDescriptor alloc] init];
    pdesc.vertexFunction = [library newFunctionWithName:@"vertexShader"];
    pdesc.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
    pdesc.vertexDescriptor = vdesc;
    pdesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pdesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    // gfx_pc.c only ever calls set_use_alpha(cm->use_alpha) (gfx_pc.c:1181) and
    // builds the shader with opt_alpha = cc->cm.use_alpha — the two are always
    // equal, so GL's dynamic glEnable(GL_BLEND) collapses into static pipeline
    // state here and set_use_alpha becomes a no-op. Factors match
    // gfx_opengl.c:845's glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA),
    // which applies to the alpha channel too (LUS diverges here, using
    // Zero/One for alpha; we match coopdx's GL instead).
    if (opt_alpha) {
        pdesc.colorAttachments[0].blendingEnabled = YES;
        pdesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pdesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pdesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pdesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        pdesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pdesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    } else {
        pdesc.colorAttachments[0].blendingEnabled = NO;
    }

    id<MTLRenderPipelineState> pso = [mtl_device newRenderPipelineStateWithDescriptor:pdesc error:&error];
    if (!pso) {
        sys_fatal("metal pipeline creation failed:\n%s",
                  error ? [[error localizedDescription] UTF8String] : "unknown");
    }

    // Ring-buffer pool, identical policy to gfx_opengl.c:598-600.
    struct ShaderProgram *prg = &shader_program_pool[shader_program_pool_index];
    shader_program_pool_index = (shader_program_pool_index + 1) % CC_MAX_SHADERS;
    if (shader_program_pool_size < CC_MAX_SHADERS) { shader_program_pool_size++; }

    prg->hash = cc->hash;
    prg->num_inputs = ccf.num_inputs;
    prg->used_textures[0] = ccf.used_textures[0];
    prg->used_textures[1] = ccf.used_textures[1];
    prg->num_floats = num_floats;
    prg->used_noise = (opt_alpha && opt_dither) || ccf.do_noise;
    prg->used_lightmap = opt_light_map;
    prg->world_geometry = world_geometry;
    prg->pipeline_state = pso;

    gfx_metal_load_shader(prg);
    return prg;
}

static struct ShaderProgram *gfx_metal_lookup_shader(struct ColorCombiner *cc) {
    for (size_t i = 0; i < shader_program_pool_size; i++) {
        if (shader_program_pool[i].hash == cc->hash) {
            return &shader_program_pool[i];
        }
    }
    return NULL;
}

static void gfx_metal_unload_shader(struct ShaderProgram *old_prg) {
    if (old_prg == NULL || old_prg == cur_shader) {
        cur_shader = NULL;
    }
}

static void gfx_metal_load_shader(struct ShaderProgram *new_prg) {
    cur_shader = new_prg;
}

static void gfx_metal_shader_get_info(struct ShaderProgram *prg, uint8_t *num_inputs, bool used_textures[2]) {
    *num_inputs = prg->num_inputs;
    used_textures[0] = prg->used_textures[0];
    used_textures[1] = prg->used_textures[1];
}

// ---------------------------------------------------------------------------
// Textures
// ---------------------------------------------------------------------------

static uint32_t gfx_metal_new_texture(void) {
    MetalTexture t = {};
    t.sampler = dummy_sampler;
    tex_cache.push_back(t);
    return (uint32_t)(tex_cache.size() - 1);
}

static void gfx_metal_select_texture(int tile, uint32_t texture_id) {
    cur_tile = tile;
    cur_tex_id[tile] = (int)texture_id;
}

static void gfx_metal_upload_texture(const uint8_t *rgba32_buf, int width, int height) {
    if (width <= 0 || height <= 0) { return; }
    if (cur_tex_id[cur_tile] < 0) { return; }
    MetalTexture &t = tex_cache[cur_tex_id[cur_tile]];

    if (t.texture == nil || (int)t.texture.width != width || (int)t.texture.height != height) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:width
                                                                                     height:height
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        t.texture = [mtl_device newTextureWithDescriptor:td];
    }
    [t.texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                 mipmapLevel:0
                   withBytes:rgba32_buf
                 bytesPerRow:4 * width];
    t.size[0] = width;
    t.size[1] = height;
}

// Mirrors gfx_opengl.c:729-734 exactly. LUS switches on the exact
// G_TX_MIRROR|G_TX_CLAMP combinations and can yield MirrorClampToEdge; coopdx's
// GL mapping cannot produce that, so we reproduce coopdx's mapping instead of
// the donor's to keep the A/B honest.
static MTLSamplerAddressMode gfx_cm_to_metal(uint32_t val) {
    if (val & G_TX_CLAMP) {
        return MTLSamplerAddressModeClampToEdge;
    }
    return (val & G_TX_MIRROR) ? MTLSamplerAddressModeMirrorRepeat : MTLSamplerAddressModeRepeat;
}

static void gfx_metal_set_sampler_parameters(int tile, bool linear_filter, uint32_t cms, uint32_t cmt) {
    cur_tile = tile;
    if (cur_tex_id[tile] < 0) { return; }
    MetalTexture &t = tex_cache[cur_tex_id[tile]];

    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    // Match gfx_opengl.c:737 — the sampler follows linear_filter alone.
    // (LUS forces Nearest whenever three-point mode is on; coopdx's GL leaves
    // it Linear and lets the shader's filter3point do the work on top.)
    MTLSamplerMinMagFilter f = linear_filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sd.minFilter = f;
    sd.magFilter = f;
    sd.sAddressMode = gfx_cm_to_metal(cms);
    sd.tAddressMode = gfx_cm_to_metal(cmt);
    sd.rAddressMode = MTLSamplerAddressModeRepeat;
    t.sampler = [mtl_device newSamplerStateWithDescriptor:sd];
    t.filter = linear_filter;
}

// ---------------------------------------------------------------------------
// Pipeline state
// ---------------------------------------------------------------------------

static bool gfx_metal_z_is_from_0_to_1(void) {
    return true;   // Metal clip space is 0..1; gfx_pc.c:1215 rescales for us.
}

static void gfx_metal_set_depth_test(bool depth_test) {
    cur_depth_test = depth_test;
}

static void gfx_metal_set_depth_mask(bool z_upd) {
    cur_depth_mask = z_upd;
}

static void gfx_metal_set_zmode_decal(bool zmode_decal) {
    cur_zmode_decal = zmode_decal;
}

static void gfx_metal_set_viewport(int x, int y, int width, int height) {
    // GL measures viewport y from the BOTTOM of the framebuffer; Metal measures
    // originY from the TOP. This flip (and the matching one in set_scissor) is
    // the entire reason no vertical flip is needed anywhere else: both APIs put
    // NDC y=+1 at the top of the viewport.
    cached_viewport.originX = x;
    cached_viewport.originY = (double)rt_height - y - height;
    cached_viewport.width = width;
    cached_viewport.height = height;
    cached_viewport.znear = 0.0;
    cached_viewport.zfar = 1.0;
    cached_viewport_valid = true;
    if (cur_encoder) { [cur_encoder setViewport:cached_viewport]; }
}

static void gfx_metal_set_scissor(int x, int y, int width, int height) {
    int fy = (int)rt_height - y - height;
    int x0 = x < 0 ? 0 : x;
    int y0 = fy < 0 ? 0 : fy;
    int x1 = x + width;
    int y1 = fy + height;
    if (x1 > (int)rt_width)  { x1 = rt_width; }
    if (y1 > (int)rt_height) { y1 = rt_height; }
    if (x0 > (int)rt_width)  { x0 = rt_width; }
    if (y0 > (int)rt_height) { y0 = rt_height; }
    // Metal validation aborts if the scissor leaves the render target, so it is
    // clamped rather than passed through the way glScissor allows.
    cached_scissor.x = x0;
    cached_scissor.y = y0;
    cached_scissor.width  = (x1 > x0) ? (x1 - x0) : 0;
    cached_scissor.height = (y1 > y0) ? (y1 - y0) : 0;
    cached_scissor_valid = true;
    if (cur_encoder) { [cur_encoder setScissorRect:cached_scissor]; }
}

static void gfx_metal_set_use_alpha(bool use_alpha) {
    // No-op: blending is baked into the pipeline state at shader-creation time.
    // See the comment in create_and_load_new_shader — use_alpha is always equal
    // to the bound program's opt_alpha, so nothing dynamic is lost.
    (void)use_alpha;
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

static void gfx_metal_draw_triangles(float buf_vbo[], size_t buf_vbo_len, size_t buf_vbo_num_tris) {
    if (!frame_valid || !cur_encoder || !cur_shader) { return; }

    // Depth. GL applies glDepthFunc(GL_LEQUAL) once at init (gfx_opengl.c:844)
    // and toggles GL_DEPTH_TEST / glDepthMask. Note that in GL, disabling the
    // depth test ALSO disables depth writes, hence write = test && mask.
    [cur_encoder setDepthStencilState:depth_states[cur_depth_test ? 1 : 0][cur_depth_mask ? 1 : 0]];

    // zmode_decal. GL uses glPolygonOffset(-2, -2) (factor, units);
    // Metal's setDepthBias takes (constant, slopeScale, clamp) in depth units.
    // Slope scale maps directly; the constant term does not (GL multiplies
    // `units` by an implementation-defined minimum resolvable depth delta), so
    // this follows LUS's default of slope-scale only.
    [cur_encoder setDepthBias:0.0f slopeScale:(cur_zmode_decal ? -2.0f : 0.0f) clamp:0.0f];

    // Vertex data. Grab space from this frame's chunk chain, growing on demand.
    FrameVertexBuffers &fv = vbufs[vbuf_frame];
    size_t bytes = sizeof(float) * buf_vbo_len;
    if (bytes > VBUF_CHUNK) { return; }   // impossible for MAX_BUFFERED, but do not scribble
    if (fv.chunk_idx < fv.chunks.size() && fv.offset + bytes > VBUF_CHUNK) {
        fv.chunk_idx++;
        fv.offset = 0;
    }
    while (fv.chunk_idx >= fv.chunks.size()) {
        fv.chunks.push_back([mtl_device newBufferWithLength:VBUF_CHUNK options:MTLResourceStorageModeShared]);
    }
    id<MTLBuffer> vb = fv.chunks[fv.chunk_idx];
    memcpy((char *)vb.contents + fv.offset, buf_vbo, bytes);
    [cur_encoder setVertexBuffer:vb offset:fv.offset atIndex:0];
    fv.offset += bytes;

    // Fragment uniforms — everything gfx_opengl.c spreads across 9 uniform
    // locations, pushed as one 96-byte blob per draw.
    FragUniforms u = {};
    u.uFrameCount = (float)frame_count;
    u.uFilter = (int32_t)configFiltering;
    u.uTexFilter0 = (cur_tex_id[0] >= 0 && tex_cache[cur_tex_id[0]].filter) ? 1 : 0;
    u.uTexFilter1 = (cur_tex_id[1] >= 0 && tex_cache[cur_tex_id[1]].filter) ? 1 : 0;
    u.uLightmapR = gVertexColor[0] / 255.0f;
    u.uLightmapG = gVertexColor[1] / 255.0f;
    u.uLightmapB = gVertexColor[2] / 255.0f;
    for (int i = 0; i < SHADER_FLAG_MAX; i++) {
        u.uShaderFlags[i] = gShaderFlags[i];
        u.uShaderFlagValues[i] = gShaderFlagValues[i];
    }
    [cur_encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];

    for (int i = 0; i < 2; i++) {
        if (!cur_shader->used_textures[i]) { continue; }
        id<MTLTexture> tex = dummy_texture;
        id<MTLSamplerState> smp = dummy_sampler;
        if (cur_tex_id[i] >= 0 && tex_cache[cur_tex_id[i]].texture != nil) {
            tex = tex_cache[cur_tex_id[i]].texture;
            if (tex_cache[cur_tex_id[i]].sampler != nil) { smp = tex_cache[cur_tex_id[i]].sampler; }
        }
        [cur_encoder setFragmentTexture:tex atIndex:i];
        [cur_encoder setFragmentSamplerState:smp atIndex:i];
    }

    [cur_encoder setRenderPipelineState:cur_shader->pipeline_state];
    [cur_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:buf_vbo_num_tris * 3];
}

// ---------------------------------------------------------------------------
// Frame lifecycle
// ---------------------------------------------------------------------------

static void gfx_metal_init(void) {
    if (!mtl_device) { sys_fatal("gfx_metal: init before layer setup"); }
    mtl_queue = [mtl_device newCommandQueue];
    frame_sem = dispatch_semaphore_create(VBUF_FRAMES);

    for (int test = 0; test < 2; test++) {
        for (int mask = 0; mask < 2; mask++) {
            MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
            dd.depthCompareFunction = test ? MTLCompareFunctionLessEqual : MTLCompareFunctionAlways;
            dd.depthWriteEnabled = (test && mask) ? YES : NO;
            depth_states[test][mask] = [mtl_device newDepthStencilStateWithDescriptor:dd];
        }
    }

    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterNearest;
    sd.magFilter = MTLSamplerMinMagFilterNearest;
    dummy_sampler = [mtl_device newSamplerStateWithDescriptor:sd];

    // Bound in place of a never-uploaded texture so a combiner that reads an
    // unpopulated tile samples opaque white instead of tripping validation.
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    dummy_texture = [mtl_device newTextureWithDescriptor:td];
    const uint8_t white[4] = { 255, 255, 255, 255 };
    [dummy_texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:white bytesPerRow:4];

    tex_cache.reserve(512);
}

static void gfx_metal_on_resize(void) {
    // Drawable size is re-read from SDL every start_frame, so nothing to do.
}

static void gfx_metal_end_frame(void);
static void gfx_metal_begin_pass(id<MTLTexture> color_tex, id<MTLTexture> depth_tex);

#if TARGET_OS_VISION
// Offscreen per-eye start_frame: the 3D counterpart of the drawable path below.
//
// Deliberately does NOT touch SDL, the CAMetalLayer, or nextDrawable — the 2D
// window is hidden behind the immersive space and acquiring its drawable would
// stall forever (guide §2.7). It also does not take frame_sem: that semaphore
// gates VBUF_FRAMES-deep in-flight reuse of the vertex ring, and it is signalled
// from the completion handler, which the 3D end_frame installs identically.
static void gfx_metal_start_frame_3d(void) {
    const int idx = stereo_idx(sm64_gfx_3d_eye);

    // Comfort batch 2 item 2 (panel reshape / P2-b): size the eye targets from
    // the PANEL's aspect (halfW:halfH at the 3840 long-edge budget), NOT the
    // parked control window's drawable. The engine's render dimensions
    // (gfx_start_frame, overlay 0011) read the SAME source, so FOV, viewport and
    // this texture all agree and the image FILLS a reshaped panel undistorted.
    // Reallocated (below) only when the size changes, at this frame boundary, so
    // there is no mid-frame framebuffer race (the charter black-screen warning).
    // Previously this tracked SDL_Metal_GetDrawableSize, which made the render
    // shape follow the window, not the panel -> the letterbox added bars whenever
    // the user reshaped the panel mid-session.
    int dw = 0, dh = 0;
    sm64_3d_get_render_target_size(&dw, &dh);
    if (dw <= 0 || dh <= 0) { return; }

    if (stereo_eye_tex[idx] == nil ||
        (int)stereo_eye_tex[idx].width != dw || (int)stereo_eye_tex[idx].height != dh) {
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:dw
                                                              height:dh
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        stereo_eye_tex[idx] = [mtl_device newTextureWithDescriptor:td];
        // A REALLOCATED texture is undefined again until re-rendered — re-gate
        // this eye or the loop would sample garbage after a resize.
        stereo_eye_rendered[idx] = 0;
        fprintf(stderr, "gfx_metal: 3D eye %d target %dx%d\n", sm64_gfx_3d_eye, dw, dh);
    }

    id<MTLTexture> color_tex = stereo_eye_tex[idx];
    rt_width = (uint32_t)color_tex.width;
    rt_height = (uint32_t)color_tex.height;

    // Depth is SHARED between the eyes: each eye is rendered to completion
    // before the next begins (pc_main.c renders them back to back), and the pass
    // clears depth on load, so there is nothing to preserve across eyes. One
    // texture instead of two saves 32 MB at 3840x2160.
    if (stereo_depth_tex == nil ||
        stereo_depth_tex.width != color_tex.width || stereo_depth_tex.height != color_tex.height) {
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                               width:color_tex.width
                                                              height:color_tex.height
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        stereo_depth_tex = [mtl_device newTextureWithDescriptor:td];
    }

    dispatch_semaphore_wait(frame_sem, DISPATCH_TIME_FOREVER);
    gfx_metal_begin_pass(color_tex, stereo_depth_tex);
}
#endif // TARGET_OS_VISION

static void gfx_metal_start_frame(void) {
    // Close any frame a previous iteration left open BEFORE touching
    // cur_encoder/cur_cmdbuf below. Assigning over an open encoder lets ARC
    // release it, and releasing a command encoder without endEncoding is a
    // Metal API violation that ABORTS the process — it is not a soft error:
    //
    //   -[_MTLCommandEncoder dealloc]:134: failed assertion
    //   `Command encoder released without endEncoding'
    //
    // Observed on the visionOS simulator (artifacts/vision-sim-02.png); the
    // crashing stack was gfx_metal_start_frame -> ...dealloc -> abort, i.e. the
    // release happened HERE, not at shutdown. gfx_pc.c does not guarantee a
    // start/end pair on every path: gfx_run() (gfx_pc.c:2109) returns BEFORE
    // rapi->start_frame() when the window manager drops a frame, and the
    // loading screen, the ROM-setup screen and the interpolation loop each
    // drive start/end through different call chains. Ending the stale frame is
    // the correct recovery — the alternative is aborting on a frame nobody
    // needed. Counted (not silently swallowed) so the imbalance stays visible.
    if (frame_valid) {
        stale_frame_closes++;
        if (stale_frame_closes == 1) {
            fprintf(stderr, "gfx_metal: closed a stale open frame at frame %llu "
                            "(start_frame without end_frame)\n",
                    (unsigned long long)frame_count);
        }
        gfx_metal_end_frame();
    }

    frame_count++;
    frame_valid = false;

#if TARGET_OS_VISION
    if (stereo_active) { gfx_metal_start_frame_3d(); return; }
#endif

    int dw = 0, dh = 0;
    SDL_Metal_GetDrawableSize(mtl_window, &dw, &dh);
    if (dw <= 0 || dh <= 0) { return; }
    if ((int)mtl_layer.drawableSize.width != dw || (int)mtl_layer.drawableSize.height != dh) {
        mtl_layer.drawableSize = CGSizeMake(dw, dh);
    }

    dispatch_semaphore_wait(frame_sem, DISPATCH_TIME_FOREVER);

    cur_drawable = [mtl_layer nextDrawable];
    if (!cur_drawable) {
        // No drawable (occluded / mid-resize). Release the frame slot we just
        // took, or the semaphore leaks and we deadlock after VBUF_FRAMES misses.
        dispatch_semaphore_signal(frame_sem);
        return;
    }

    // Size everything from the ACQUIRED drawable's texture, never from the
    // cached dw/dh we asked SDL for: during a live resize the layer can hand
    // back a drawable that is still the old size, and a depth attachment whose
    // dimensions disagree with the colour attachment is a Metal validation
    // abort. On visionOS that abort can tear the scene WITHOUT killing the
    // process, which reads as a spontaneous "relaunch to intro" rather than a
    // crash — a documented, already-paid-for trap in this program.
    id<MTLTexture> color_tex = cur_drawable.texture;
    rt_width = (uint32_t)color_tex.width;
    rt_height = (uint32_t)color_tex.height;

    // MEASURE the drawable — do not infer it. M-16/M-17 reasoned the visionOS
    // drawable was ~3840x2160 backwards from DJUI's scale arithmetic and the
    // SDL long-edge push, and the whole 0006 clamp fix rests on that inference.
    // This is the ground truth: the size of the texture Metal actually hands us.
    // Published for the probe, and logged once (plus on every change, which is
    // also how a live-resize reallocation becomes visible).
    gSm64DrawableW = (int)rt_width;
    gSm64DrawableH = (int)rt_height;
    static uint32_t logged_w = 0, logged_h = 0;
    if (rt_width != logged_w || rt_height != logged_h) {
        // dw/dh is what SDL_Metal_GetDrawableSize claimed; rt_* is what the
        // acquired drawable really is. Printing BOTH is the point: if the SDL
        // visionOS compat patch's long-edge push is not taking effect, these
        // disagree, and that disagreement is invisible from either number alone.
        fprintf(stderr, "gfx_metal: DRAWABLE measured %ux%u (SDL reported %dx%d)\n",
                rt_width, rt_height, dw, dh);
        logged_w = rt_width;
        logged_h = rt_height;
    }

    if (depth_texture == nil || depth_texture.width != color_tex.width || depth_texture.height != color_tex.height) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                      width:color_tex.width
                                                                                     height:color_tex.height
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        depth_texture = [mtl_device newTextureWithDescriptor:td];
    }

    gfx_metal_begin_pass(color_tex, depth_texture);
}

// The command buffer + encoder + per-frame state, shared VERBATIM by the 2D
// (drawable) and 3D (offscreen eye) paths. Factored rather than copied so the
// two paths cannot silently drift apart: everything gfx_pc.c depends on being
// re-established at a frame boundary lives here exactly once.
static void gfx_metal_begin_pass(id<MTLTexture> color_tex, id<MTLTexture> depth_tex) {
    // GL's start_frame clears colour+depth with the scissor test disabled
    // (gfx_opengl.c:862-870); a Clear load action is the exact equivalent and
    // is likewise unaffected by the scissor rect.
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = color_tex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.depthAttachment.texture = depth_tex;
    rpd.depthAttachment.loadAction = MTLLoadActionClear;
    rpd.depthAttachment.clearDepth = 1.0;
    rpd.depthAttachment.storeAction = MTLStoreActionDontCare;

    cur_cmdbuf = [mtl_queue commandBuffer];
    cur_encoder = [cur_cmdbuf renderCommandEncoderWithDescriptor:rpd];

    // GL never culls (it never calls glEnable(GL_CULL_FACE)); gfx_pc.c handles
    // backface rejection itself.
    [cur_encoder setCullMode:MTLCullModeNone];
    [cur_encoder setFrontFacingWinding:MTLWindingCounterClockwise];

    // Re-apply state that lives on the encoder. gfx_pc.c will not re-send an
    // unchanged viewport/scissor after a frame boundary, but the encoder is new.
    if (cached_viewport_valid) { [cur_encoder setViewport:cached_viewport]; }
    if (cached_scissor_valid)  { [cur_encoder setScissorRect:cached_scissor]; }

    FrameVertexBuffers &fv = vbufs[vbuf_frame];
    fv.chunk_idx = 0;
    fv.offset = 0;

    frame_valid = true;
}

static void gfx_metal_end_frame(void) {
    // gfx_pc.c calls end_frame even on a dropped frame (gfx_pc.c:2120 runs
    // unconditionally while gfx_run returns early before rapi->start_frame).
    if (!frame_valid) { return; }

    [cur_encoder endEncoding];
#if TARGET_OS_VISION
    // In 3D there is NO drawable to present: the immersive loop samples the eye
    // texture we just rendered and presents the compositor's drawable itself.
    // Presenting here would mean acquiring the hidden window's drawable — the
    // stall this whole path exists to avoid.
    if (stereo_active) {
        const int idx = stereo_idx(sm64_gfx_3d_eye);
        // Publish the eye ONLY now that it has actually been encoded. Ordered
        // before commit deliberately: the loop's blit is issued on its own queue
        // and the worst case is that it copies this frame or the previous one —
        // never uninitialised memory, which is what the gate exists to prevent.
        stereo_eye_rendered[idx] = 1;
        stereo_frames++;
        // Batch 3 item 1b: the RIGHT eye completing marks a fresh, COMPLETE pair
        // (the left eye was rendered to completion earlier this host frame —
        // pc_main.c renders L then R). Advancing the generation here is what lets
        // the immersive loop copy both eyes as one atomic pair, never mid-pair.
        if (idx == 1) { stereo_pair_gen++; }
    } else {
        [cur_cmdbuf presentDrawable:cur_drawable];
    }
#else
    [cur_cmdbuf presentDrawable:cur_drawable];
#endif
    [cur_cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        // TRUE GPU frame time. This is the number that decides optimization
        // direction: the probe's eng_ms includes blocking inside present, so it
        // cannot separate "the GPU is saturated" from "we are sleeping to hit
        // the frame limiter." Sampled from the same command buffer that renders
        // and presents the frame, so it is the whole frame's GPU cost.
        //
        // Sanity-bounded: GPUStartTime/GPUEndTime are 0 on a command buffer the
        // GPU never scheduled, which would otherwise publish a garbage 0 or a
        // huge value into the percentiles.
        double ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
        if (ms > 0.0 && ms < 1000.0) { gSm64GpuMs = (float)ms; }
        dispatch_semaphore_signal(frame_sem);
    }];
    [cur_cmdbuf commit];

    cur_encoder = nil;
    cur_cmdbuf = nil;
    cur_drawable = nil;
    vbuf_frame = (vbuf_frame + 1) % VBUF_FRAMES;
    frame_valid = false;
}

static void gfx_metal_finish_render(void) {
    // Presentation happens in end_frame (as in the LUS donor); gfx_sdl.c's
    // swap_buffers_begin is a no-op on the Metal path.
}

static const char *gfx_metal_get_name(void) {
    return "Metal";
}

static void gfx_metal_shutdown(void) {
    // Same Metal API rule as start_frame: an open encoder must be ended, never
    // just released. Tearing down mid-frame would otherwise abort on the way
    // out — a crash-on-exit that looks like a shutdown bug rather than a
    // renderer one.
    if (frame_valid) { gfx_metal_end_frame(); }
    cur_encoder = nil;
    cur_cmdbuf = nil;
    cur_drawable = nil;
    depth_texture = nil;
#if TARGET_OS_VISION
    // Re-gate BEFORE releasing, so the immersive loop can never be handed a
    // texture that is on its way out (it polls these from its own thread).
    stereo_eye_rendered[0] = stereo_eye_rendered[1] = 0;
    stereo_eye_tex[0] = nil;
    stereo_eye_tex[1] = nil;
    stereo_depth_tex = nil;
#endif
    tex_cache.clear();
    for (int i = 0; i < VBUF_FRAMES; i++) { vbufs[i].chunks.clear(); }
    mtl_queue = nil;
}

extern "C" struct GfxRenderingAPI gfx_metal_api = {
    gfx_metal_z_is_from_0_to_1,
    gfx_metal_unload_shader,
    gfx_metal_load_shader,
    gfx_metal_create_and_load_new_shader,
    gfx_metal_lookup_shader,
    gfx_metal_shader_get_info,
    gfx_metal_new_texture,
    gfx_metal_select_texture,
    gfx_metal_upload_texture,
    gfx_metal_set_sampler_parameters,
    gfx_metal_set_depth_test,
    gfx_metal_set_depth_mask,
    gfx_metal_set_zmode_decal,
    gfx_metal_set_viewport,
    gfx_metal_set_scissor,
    gfx_metal_set_use_alpha,
    gfx_metal_draw_triangles,
    gfx_metal_init,
    gfx_metal_on_resize,
    gfx_metal_start_frame,
    gfx_metal_end_frame,
    gfx_metal_finish_render,
    gfx_metal_get_name,
    gfx_metal_shutdown
};

#endif // ENABLE_METAL_BACKEND
