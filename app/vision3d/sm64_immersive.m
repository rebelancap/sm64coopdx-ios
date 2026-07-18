// sm64_immersive.m — visionOS stereoscopic "3D screen in the room".
//
// visionOS cannot show real-time stereo in a normal 2D window: stereo goes
// through CompositorServices, which vends per-eye Metal drawable slices and the
// ARKit head pose each frame. This file owns that render loop.
//
// Architecture (ported from the PROVEN vkQuake-ios implementation,
// ios/shell-visionos/VKQImmersive.m; adapted to sm64coopdx's Metal backend):
//
//   1. The engine renders the COMPLETE frame twice per host frame — left then
//      right, same game time, only the projection differs (pc_main.c) — into two
//      offscreen MTLTextures (gfx_metal.mm). Because our backend is native Metal
//      (D-010), those textures are already MTLTextures: no MoltenVK bridge like
//      vkQuake, no ANGLE/EGL aliasing like q2repro. This is the one place our
//      port is genuinely easier than every reference.
//   2. This loop copies each finished eye into a persistent MIPMAPPED texture on
//      THIS Metal queue (so copy and sample are coherent inside one command
//      buffer), then draws a world-locked quad per eye slice: left slice samples
//      the left render, right slice the right => true stereoscopic depth on a
//      head-stable panel. The head pose only PLACES the screen; it never drives
//      the game camera (controller-turn without head-turn is nauseating).
//
// Hard-won loop shape — do NOT "simplify" (guide §2.3/§2.8; each of these
// wedged an engine before the sequence was right):
//   - frame pacing (cp_frame_predict_timing + cp_time_wait_until) AND a
//     per-frame ARKit device anchor: a frame presented without EITHER is
//     silently never displayed. This is the "renders but nothing shows" bug.
//   - the drawable's depth MUST be cleared/written: the compositor reprojects on
//     depth and rejects frames it cannot reproject.
//   - the command queue MUST come from the DRAWABLE's device, not
//     MTLCreateSystemDefaultDevice.
//   - cp_view_get_tangents TRAPS on visionOS 2.0 (__BUG_IN_CLIENT__) — FOV comes
//     from cp_drawable_compute_projection instead.
//   - this thread has no runloop autorelease pool; drain per-frame ObjC garbage.

#import "sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <time.h>

volatile int sm64_3d_imm_stop = 0;
volatile int sm64_3d_imm_running = 0;
static int sm64_imm_frame_count = 0;

// --- fidelity numbers published for the bridge `fidelity` verb (batch 3 item 2)
// Same contract as gfx_metal.mm's gSm64GpuMs: the compositor loop WRITES these
// (once the panel is placed) and the port-8791 bridge READS them from its own
// thread — never the main thread. 0 until 3D is entered and a first sample lands.
// External linkage on purpose (sm64_vision_shell.m extern-declares them).
volatile int   gSm64FidDrawableW = 0, gSm64FidDrawableH = 0; // per-eye compositor viewport px
volatile int   gSm64FidEyeW = 0, gSm64FidEyeH = 0;           // engine eye-texture px
volatile float gSm64FidFovH = 0.0f, gSm64FidFovV = 0.0f;     // per-eye FOV, degrees
volatile float gSm64FidFootW = 0.0f, gSm64FidFootH = 0.0f;   // panel footprint in the drawable, px
volatile float gSm64FidSSH = 0.0f, gSm64FidSSV = 0.0f;       // supersample ratio (eye_tex / footprint)

// --- eye-pair latching state + judder instrument (batch 3 item 1b, Fable P2-a).
// Declared here (above sm64_cadence_sample) so the cadence heartbeat can fold the
// fresh/reuse counts into its line. sm64_pairReuse climbing means the compositor
// woke to find NO fresh pair from the engine — the exact judder signal P1-c wants
// (with a true 1:1 phase-lock it stays ~0; a beat/de-rate makes it climb).
static uint32_t sm64_lastCopiedGen = 0; // last pair generation the loop copied
static uint64_t sm64_pairFresh = 0;     // compositor frames that copied a NEW pair
static uint64_t sm64_pairReuse = 0;     // compositor frames that REUSED (engine behind)

// --- world-lock math ---------------------------------------------------------

static simd_float4x4 sm64_translate(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(x, y, z, 1.0f);
    return m;
}

static simd_float4x4 sm64_scale(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = x;
    m.columns[1].y = y;
    m.columns[2].z = z;
    return m;
}

// Panel placement: captured from the head pose ONCE, after tracking converges,
// then world-locked. Recomputed from the FROZEN head each frame so that live
// tuning of distance/size/height actually moves the panel while dragging.
//
// Defaults are 16:9 (2.75 / 1.547 = 1.778) ON PURPOSE: the engine renders the
// eye textures at the measured 3840x2160 drawable (M-21), and a 4:3 render on a
// 16:9 panel is the guide's "stretched/soft" trap (§2.5). Matching here means
// the aspect is correct by construction before the user touches anything.
static float sm64_screenDist = 3.6f;    // metres from the captured head position
static float sm64_screenHalfW = 2.75f;  // half-width, metres
static float sm64_screenHalfH = 1.547f; // half-height, metres (16:9 against halfW)
static float sm64_screenHeight = 0.0f;  // POSITION: metres above eye level

void sm64_3d_set_panel(float dist, float halfW, float halfH) {
    if (dist >= 1.0f && dist <= 8.0f) { sm64_screenDist = dist; }
    // Comfort batch 2 item 2: ranges WIDENED (was 0.6-4.0 / 0.4-3.0) so the panel
    // can genuinely go ultrawide / ultratall. The engine re-renders at this aspect
    // (sm64_3d_get_render_target_size), so the extra travel reshapes the FILLED
    // image, not a letterbox. Keep the settings-table slider ranges in sync.
    if (halfW >= 0.4f && halfW <= 8.0f) { sm64_screenHalfW = halfW; }
    if (halfH >= 0.3f && halfH <= 6.0f) { sm64_screenHalfH = halfH; } // <=0 = unchanged
}

void sm64_3d_set_height(float h) {
    if (h >= -1.5f && h <= 10.0f) { sm64_screenHeight = h; }
}

// Comfort batch 2 item 2 (panel reshape). The engine renders AT the panel's
// aspect (halfW:halfH) so the image FILLS a reshaped panel with no bars and no
// stretch — the letterbox in the panel shader then degenerates to a no-op. The
// 3840 long-edge budget is kept regardless of shape (extreme aspects only REDUCE
// the total pixel count — short_edge = 3840/aspect — so there is no thermal
// downside to ultrawide/ultratall). Both gfx_metal (the offscreen eye texture)
// and gfx_pc (gfx_current_dimensions => FOV + viewport, overlay 0011) size from
// this one function, so FOV, viewport and texture can never disagree. Read only
// on the main thread (game loop + settings sliders both run there), so no lock.
void sm64_3d_get_render_target_size(int *w, int *h) {
    float aspect = (sm64_screenHalfH > 0.01f) ? (sm64_screenHalfW / sm64_screenHalfH)
                                              : (16.0f / 9.0f);
    if (!(aspect > 0.02f && aspect < 50.0f)) { aspect = 16.0f / 9.0f; }
    const int budget = 3840; // long-edge fidelity budget (M-21)
    int rw, rh;
    if (aspect >= 1.0f) { rw = budget; rh = (int)lroundf((float)budget / aspect); }
    else                { rh = budget; rw = (int)lroundf((float)budget * aspect); }
    if (rw < 32) { rw = 32; }
    if (rh < 32) { rh = 32; }
    if (w) { *w = rw; }
    if (h) { *h = rh; }
}

// Comfort batch 2 item 6 (Focus Distance "Auto"). Convergence is the zero-parallax
// distance in world units; the BACKGROUND (infinity) NDC disparity is a*s/C, and
// the eye sees it scaled by the panel's angular size. To keep that angular
// disparity — the dominant comfort metric — constant as the panel is reshaped or
// moved, C must scale with the panel's angular width. Calibrated so the DEFAULT
// panel (halfW 2.75 m at 3.6 m => ~74.7 deg wide) yields ~1524 units = 50 ft, the
// value the user preferred by hand. A bigger/closer panel => wider angle => larger
// C (more of the scene sits behind the glass), which is the calm direction.
float sm64_3d_auto_convergence(void) {
    float dist = (sm64_screenDist > 0.1f) ? sm64_screenDist : 3.6f;
    float angW = 2.0f * atanf(sm64_screenHalfW / dist); // radians
    float C = 1168.0f * angW;                           // k s.t. default => ~1524 (50 ft)
    if (C < 200.0f)  { C = 200.0f; }
    if (C > 3000.0f) { C = 3000.0f; }
    return C;
}

static bool sm64_haveScreenAnchor = false;
static simd_float4x4 sm64_frozenHead;

void sm64_3d_recenter(void) {
    sm64_haveScreenAnchor = false; // next tracked frame re-captures the head pose
}

// Surroundings dimming: a per-eye fullscreen black layer at this alpha, drawn
// UNDER the panel. 0 = full passthrough, 1 = pitch-black "void". This is the
// practical in-app replacement for the Crown immersion dial, which would need
// progressive-style portal rendering — and merely ALLOWING .progressive aborts
// cp_drawable_encode_present (guide §2.8), so it is not on the table.
static float sm64_dimLevel = 0.0f;

void sm64_3d_set_dim(float dim) {
    dim = (dim < 0.0f) ? 0.0f : (dim > 1.0f) ? 1.0f : dim;
    // Perceptual curve: a LINEAR slider "doesn't really get dark until 80%"
    // (guide §2.7 — measured on a human, not derived). Keep the 0-100% control
    // scale but map through 1-(1-d)^2.2 so darkness arrives early.
    sm64_dimLevel = 1.0f - powf(1.0f - dim, 2.2f);
}

static simd_float4x4 sm64_make_screen_anchor(simd_float4x4 originFromDevice) {
    simd_float3 headPos = originFromDevice.columns[3].xyz;
    simd_float3 fwd = -originFromDevice.columns[2].xyz; // gaze forward
    fwd.y = 0.0f;                                       // level (no pitch/roll)
    float len = simd_length(fwd);
    fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;

    simd_float3 pos = headPos + fwd * sm64_screenDist;
    pos.y += sm64_screenHeight;
    // Face the head; 'right' stays horizontal (no roll) and never degenerates.
    simd_float3 normal = simd_normalize(headPos - pos);
    simd_float3 up = simd_make_float3(0, 1, 0);
    simd_float3 right = simd_normalize(simd_cross(up, normal));
    up = simd_cross(normal, right);

    simd_float4x4 m;
    m.columns[0] = simd_make_float4(right, 0.0f);
    m.columns[1] = simd_make_float4(up, 0.0f);
    m.columns[2] = simd_make_float4(normal, 0.0f);
    m.columns[3] = simd_make_float4(pos, 1.0f);
    return m;
}

// Persistent MIPMAPPED copies of the engine's per-eye textures.
static id<MTLTexture> sm64_eyeCopy[2];

// --- fidelity report (guide §3: measure the ratio, do not estimate) ----------
//
// Measures the ACTUAL supersample ratio rather than guessing it: the per-eye
// compositor viewport + FOV give the panel's real screen-space footprint;
// game texture / footprint = supersample. This is how vkQuake KNEW it was at
// 2.2-2.7x (optimally maxed) instead of believing it.
//
// Batch 3 item 2 makes it REMOTELY READABLE, three ways: (1) publish the numbers
// into gSm64Fid* volatiles every call, so the bridge `fidelity` verb answers with
// no main-thread touch; (2) append a UTC-stamped SM64_FIDELITY line to
// vision-perf.log periodically (like SM64_CADENCE), served by the `perf` verb and
// surviving OTA read-back; (3) keep the one-time full human report in Documents.
// Called every frame once the panel is placed — the ratio changes live as the
// user reshapes the panel, so a fresh value must always be available.
static bool sm64_fidelityLogged = false;

static void sm64_sample_fidelity(cp_drawable_t drawable, id<MTLTexture> gameTex) {
    if (gameTex == nil) { return; }
    cp_view_t view = cp_drawable_get_view(drawable, 0);
    MTLViewport vp = cp_view_texture_map_get_viewport(cp_view_get_view_texture_map(view));
    // FOV from the projection matrix. cp_view_get_tangents is deprecated AND
    // TRAPS on visionOS 2.0. m00 = 2/(l+r), m11 = 2/(t+b), so 1/m00 is the mean
    // horizontal tangent — 2*atan of it is the FOV (exact for a symmetric
    // frustum, <1% off for the Vision Pro's slight cant, which is plenty here).
    simd_float4x4 proj = matrix_identity_float4x4;
    if (__builtin_available(visionOS 2.0, *)) {
        proj = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, 0);
    }
    double m00 = fabs(proj.columns[0].x), m11 = fabs(proj.columns[1].y);
    double fovH = (m00 > 1e-6) ? 2.0 * atan(1.0 / m00) : 0.0;
    double fovV = (m11 > 1e-6) ? 2.0 * atan(1.0 / m11) : 0.0;
    if (vp.width < 1 || vp.height < 1 || fovH < 1e-4 || fovV < 1e-4) { return; }
    double pxPerRadH = vp.width / fovH, pxPerRadV = vp.height / fovV;
    double panAngH = 2.0 * atan(sm64_screenHalfW / sm64_screenDist);
    double panAngV = 2.0 * atan(sm64_screenHalfH / sm64_screenDist);
    double footH = panAngH * pxPerRadH, footV = panAngV * pxPerRadV;
    double ssH = footH > 1 ? gameTex.width / footH : 0.0;
    double ssV = footV > 1 ? gameTex.height / footV : 0.0;

    // (1) Publish for the bridge — every call, so it tracks live panel reshapes.
    gSm64FidDrawableW = (int)vp.width;      gSm64FidDrawableH = (int)vp.height;
    gSm64FidEyeW = (int)gameTex.width;      gSm64FidEyeH = (int)gameTex.height;
    gSm64FidFovH = (float)(fovH * 180.0 / M_PI);
    gSm64FidFovV = (float)(fovV * 180.0 / M_PI);
    gSm64FidFootW = (float)footH;           gSm64FidFootH = (float)footV;
    gSm64FidSSH = (float)ssH;               gSm64FidSSV = (float)ssV;

    // (3) The full human-readable report to Documents, written ONCE.
    if (!sm64_fidelityLogged) {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *report = [NSString stringWithFormat:
            @"sm64coopdx Vision Pro fidelity report\n"
             "=====================================\n"
             "Compositor drawable (per eye): %.0f x %.0f px  (%.1f MP)\n"
             "Per-eye FOV: %.1f deg H x %.1f deg V   (%.1f px/deg H)\n"
             "\n"
             "Game render target (per eye): %lu x %lu px  (%.1f MP)\n"
             "Panel angular size: %.1f deg H x %.1f deg V\n"
             "Panel footprint in drawable: %.0f x %.0f px\n"
             "\n"
             "SUPERSAMPLE RATIO: %.2fx H, %.2fx V   (%s)\n"
             "  >1.0 = supersampling (rendering MORE pixels than the panel shows,\n"
             "         then downfiltering — crisp). <1.0 = upscaling (soft).\n"
             "  ~2x is the sweet spot; past that is wasted GPU and heat.\n"
             "\n"
             "Note: the drawable above is the system-vended render target, NOT the\n"
             "physical ~3660x3200/eye micro-OLED panel — the compositor lens-warps\n"
             "the drawable onto the panel for every app on the system.\n",
            (double)vp.width, (double)vp.height, vp.width * vp.height / 1e6,
            fovH * 180.0 / M_PI, fovV * 180.0 / M_PI, pxPerRadH * M_PI / 180.0,
            (unsigned long)gameTex.width, (unsigned long)gameTex.height,
            gameTex.width * gameTex.height / 1e6,
            panAngH * 180.0 / M_PI, panAngV * 180.0 / M_PI, footH, footV,
            ssH, ssV, (ssH >= 1.0 && ssV >= 1.0) ? "supersampling" : "UNDERSAMPLING"];
        [report writeToFile:[docs stringByAppendingPathComponent:@"vp3d-fidelity.log"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[sm64vp] fidelity: drawable %.0fx%.0f/eye, game %lux%lu, supersample %.2fx/%.2fx",
              (double)vp.width, (double)vp.height, (unsigned long)gameTex.width,
              (unsigned long)gameTex.height, ssH, ssV);
        sm64_fidelityLogged = true;
    }

    // (2) Periodic heartbeat into vision-perf.log (~every 300 samples, matching
    // SM64_CADENCE's rate) so the `perf` verb serves the live ratio and any drift
    // (panel reshape, a fidelity leak) is visible over the bridge.
    static int sincePublish = 0;
    if (++sincePublish >= 300) {
        sincePublish = 0;
        char stamp[32];
        time_t t = time(NULL);
        struct tm g;
        gmtime_r(&t, &g);
        strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%SZ", &g);
        NSString *docs = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (docs) {
            NSString *path = [docs stringByAppendingPathComponent:@"vision-perf.log"];
            FILE *f = fopen(path.fileSystemRepresentation, "a");
            if (f) {
                fprintf(f, "SM64_FIDELITY %s drawable=%.0fx%.0f/eye eye_tex=%lux%lu "
                           "fov=%.1fx%.1f footprint=%.0fx%.0f supersample=%.2fx/%.2fx\n",
                        stamp, (double)vp.width, (double)vp.height,
                        (unsigned long)gameTex.width, (unsigned long)gameTex.height,
                        fovH * 180.0 / M_PI, fovV * 180.0 / M_PI, footH, footV, ssH, ssV);
                fclose(f);
            }
        }
    }
}

// --- the panel quad + dim layer ----------------------------------------------
static id<MTLRenderPipelineState> sm64_pipeline;
static id<MTLRenderPipelineState> sm64_dimPipeline;
static id<MTLDepthStencilState> sm64_depthState;
static id<MTLDepthStencilState> sm64_dimDepthState;

// srgbDecode: our engine writes display-encoded (sRGB) values into a UNORM
// texture. If the drawable expects LINEAR input (an _srgb or float format), the
// shader must linearize or the compositor re-encodes an already-encoded image —
// which reads as washed out / low contrast, i.e. "not crisp". Applied
// CONDITIONALLY: if the source were already _srgb, Metal would decode on sample
// and doing it again would double-darken.
static NSString *const kSM64QuadShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     // c = the local quad coord in [-1,1]^2. The fragment shader aspect-fits the
     // texture into it, so the vertex stage passes the raw coord (not a fixed UV).
     "struct VOut { float4 pos [[position]]; float2 c; };\n"
     "vertex VOut sm64_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
     "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
     "  o.c = p[vid];\n"
     "  return o;\n"
     "}\n"
     "fragment float4 sm64_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                        constant float& srgbDecode [[buffer(0)]],\n"
     "                        constant float2& fitScale [[buffer(1)]]) {\n"
     // ASPECT-FIT / LETTERBOX (guide §2.5). The eye texture is 16:9 but the panel
     // width/height come from INDEPENDENT sliders, so mapping the full texture to
     // the full quad stretches Mario on any non-16:9 panel. Instead map the image
     // into the centred sub-rectangle that preserves its aspect (fitScale = the
     // fraction of the panel it covers per axis; one component is 1, the other
     // <1) and paint the surrounding bars opaque black — never distort.
     "  float2 ic = in.c / fitScale;\n"
     "  if (fabs(ic.x) > 1.0 || fabs(ic.y) > 1.0) { return float4(0.0, 0.0, 0.0, 1.0); }\n"
     "  float2 uv = float2(ic.x*0.5+0.5, 0.5-ic.y*0.5);\n"
     // Trilinear + 16x anisotropic. The game texture is minified onto the
     // panel's ~1400px footprint, so mip_filter::linear kills far-surface
     // shimmer (the real crispness lever above 1:1) and anisotropy sharpens
     // grazing views. Requires mipmaps on the sampled texture — generated below.
     "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
     "  float4 c = tex.sample(s, uv);\n"
     "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
     "  return float4(c.rgb, 1.0);\n"
     "}\n"
     // Surroundings dimming: a clip-space fullscreen layer, black at the given
     // alpha, drawn under the panel (blended over passthrough).
     "vertex float4 sm64_dim_vs(uint vid [[vertex_id]]) {\n"
     "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
     "  return float4(p[vid], 0.9999, 1.0);\n"
     "}\n"
     "fragment float4 sm64_dim_fs(constant float& dim [[buffer(0)]]) {\n"
     "  return float4(0.0, 0.0, 0.0, dim);\n"
     "}\n";

static void sm64_build_pipeline(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt) {
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSM64QuadShader options:nil error:&err];
    if (!lib) {
        NSLog(@"[sm64vp] imm: shader compile FAILED: %@", err.localizedDescription);
        return;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"sm64_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"sm64_fs"];
    pd.colorAttachments[0].pixelFormat = colorFmt;
    pd.depthAttachmentPixelFormat = depthFmt;
    sm64_pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!sm64_pipeline) {
        NSLog(@"[sm64vp] imm: pipeline FAILED: %@", err.localizedDescription);
        return;
    }
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways; // only the quad is drawn
    dd.depthWriteEnabled = YES; // real depth so the compositor reprojects the panel
    sm64_depthState = [dev newDepthStencilStateWithDescriptor:dd];

    MTLRenderPipelineDescriptor *dp = [MTLRenderPipelineDescriptor new];
    dp.vertexFunction = [lib newFunctionWithName:@"sm64_dim_vs"];
    dp.fragmentFunction = [lib newFunctionWithName:@"sm64_dim_fs"];
    dp.colorAttachments[0].pixelFormat = colorFmt;
    dp.colorAttachments[0].blendingEnabled = YES;
    dp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    dp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    dp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    dp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    dp.depthAttachmentPixelFormat = depthFmt;
    sm64_dimPipeline = [dev newRenderPipelineStateWithDescriptor:dp error:&err];
    if (!sm64_dimPipeline) {
        NSLog(@"[sm64vp] imm: dim pipeline FAILED: %@", err.localizedDescription);
    }
    MTLDepthStencilDescriptor *dd2 = [MTLDepthStencilDescriptor new];
    dd2.depthCompareFunction = MTLCompareFunctionAlways;
    dd2.depthWriteEnabled = YES; // deep depth: the compositor reprojects it far away
    sm64_dimDepthState = [dev newDepthStencilStateWithDescriptor:dd2];

    NSLog(@"[sm64vp] imm: quad pipeline built (colorFmt=%lu depthFmt=%lu)",
          (unsigned long)colorFmt, (unsigned long)depthFmt);
}

// Milestone-1 diagnostic: clear the drawable to an opaque colour instead of
// transparent, so "the space opened and the loop is presenting" is provable by
// EYE on a simulator screenshot before any game pixels exist. Off by default —
// an opaque clear would otherwise paint over the passthrough room.
static bool sm64_debug_clear(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("SM64_VP3D_CLEAR");
        cached = (e && *e && *e != '0') ? 1 : 0;
    }
    return cached == 1;
}

// --- compositor cadence measurement (Fable STEREO-3D-FIDELITY §P1-c) ----------
//
// P1-c is the SMOOTHNESS fix, and Fable's instruction is MEASURE FIRST: the
// engine sleep-paces to a number (overlay 0012, MANUAL@panel-rate) while the
// immersive compositor runs on its OWN clock (90 typical; 96/100 for flicker
// compensation; up to 120 on M5). Two unsynchronised clocks at nominally the
// same rate beat against each other — a periodic hitch. This does NOT implement
// the pacing fix (that waits on the user's real device numbers); it only
// MEASURES the compositor's true cadence so we know what it actually grants us.
//
// The delta between successive frames' cp_frame_timing optimal_input_time IS the
// compositor's frame period. We keep a rolling window and publish median / p95 /
// min / max (ms) + implied Hz. Read live over the port-8791 console bridge:
//   - `logtail N` catches the periodic `[sm64vp] cadence:` NSLog line;
//   - `perf` tails Documents/vision-perf.log, where we append a UTC-stamped
//     `SM64_CADENCE` line beside the probe's SM64_PERF lines (M-48: stamped,
//     append-only). Cheap (a subtraction + a periodic sort); 3D-only by
//     construction (this loop only runs in the immersive space).
static int sm64_cmp_float(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}

#define SM64_CADENCE_WIN 300
static void sm64_cadence_sample(double optInSec) {
    static double last = 0.0;
    static float ring[SM64_CADENCE_WIN];
    static int count = 0, head = 0, sincePublish = 0;

    if (last > 0.0 && optInSec > last) {
        float dms = (float)((optInSec - last) * 1000.0);
        if (dms > 0.05f && dms < 1000.0f) { // ignore pauses / first-frame garbage
            ring[head] = dms;
            head = (head + 1) % SM64_CADENCE_WIN;
            if (count < SM64_CADENCE_WIN) { count++; }
        }
    }
    last = optInSec;

    // Publish ~1-2 s of samples at a time (60 frames ≈ 0.5-1 s at 60-120 Hz).
    if (count >= 20 && ++sincePublish >= 60) {
        sincePublish = 0;
        float tmp[SM64_CADENCE_WIN];
        memcpy(tmp, ring, (size_t)count * sizeof(float));
        qsort(tmp, (size_t)count, sizeof(float), sm64_cmp_float);
        float med = tmp[count / 2];
        float p95 = tmp[(int)(count * 0.95f)];
        float mn = tmp[0], mx = tmp[count - 1];
        float hz = (med > 0.001f) ? (1000.0f / med) : 0.0f;

        // Batch 3 item 1b: fold in the pair fresh/reuse counts. With the
        // compositor-driven pace (0012) + pair latching truly engaged, EVERY
        // compositor frame samples a fresh pair -> reuse stays ~flat. reuse
        // climbing fast = the engine is NOT feeding a fresh pair each compositor
        // frame (a beat, a de-rate, or a spike) — the on-device proof of the lock.
        NSLog(@"[sm64vp] cadence: period med=%.3fms p95=%.3f min=%.3f max=%.3f "
               "-> %.1f Hz (n=%d) pairs fresh=%llu reuse=%llu [engine phase-locks "
               "to this via sm64_3d_wait_for_compositor_frame; reuse~flat = 1:1 lock]",
              med, p95, mn, mx, hz, count,
              (unsigned long long)sm64_pairFresh, (unsigned long long)sm64_pairReuse);

        // UTC-stamped line into vision-perf.log so the bridge's `perf` verb serves
        // it and it survives OTA read-back (M-48). Open/close per write (a
        // swipe-kill is SIGKILL — never hold the fd across the process's life).
        char stamp[32];
        time_t t = time(NULL);
        struct tm g;
        gmtime_r(&t, &g);
        strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%SZ", &g);
        NSString *docs = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (docs) {
            NSString *path = [docs stringByAppendingPathComponent:@"vision-perf.log"];
            FILE *f = fopen(path.fileSystemRepresentation, "a");
            if (f) {
                fprintf(f, "SM64_CADENCE %s compositor_period med=%.3fms p95=%.3f "
                           "min=%.3f max=%.3f -> %.1f Hz (n=%d) pairs_fresh=%llu "
                           "pairs_reuse=%llu\n",
                        stamp, med, p95, mn, mx, hz, count,
                        (unsigned long long)sm64_pairFresh,
                        (unsigned long long)sm64_pairReuse);
                fclose(f);
            }
        }
    }
}

// --- compositor-driven pacing (Fable §P1-c — THE smoothness fix) -------------
//
// M-51, live off the user's M5 headset: the immersive compositor runs a
// rock-steady 90 Hz (period med=p95=min=max=11.111ms, ZERO jitter) while gpu_ms
// is 3.6 per eye against an 11.111ms budget — 3x headroom. So the engine is NOT
// GPU-bound; the "not buttery while moving" report is a PACING problem: the
// engine sleep-paces (overlay 0012, MANUAL@measured) to its OWN 90 Hz clock, and
// two unsynchronised 90 Hz clocks beat -> a periodic hitch on motion.
//
// Fix: pace the engine off the compositor loop itself. The loop signals here
// right after cp_time_wait_until(optimal_input_time); in 3D the engine's
// produce_interpolation_frames_and_delay() WAITS on this instead of sleeping, so
// it is phase-locked 1:1 to whatever the compositor actually grants (90/96/100/
// 120 — no measured constant to go stale). Every compositor frame then samples a
// fresh eye pair. Lower latency too: the engine starts rendering aligned to the
// compositor's input time.
//
// A pthread cond/mutex, NOT a counting dispatch_semaphore: the pending state is a
// FLAG (capped at 1), so a stalled engine can never accumulate a backlog to
// burst-render on recovery (the task's "cap at 1 pending signal"). The wait has a
// ~50 ms timeout -> false, so if the loop is not running (entry transition, or
// exited) the engine transparently reverts to 0012's sleep limiter — the non-3D /
// fallback path is entirely unchanged.
static pthread_mutex_t sm64_pace_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  sm64_pace_cond = PTHREAD_COND_INITIALIZER;
static int sm64_pace_pending = 0;
static uint64_t sm64_pace_signals = 0; // diagnostics only

static void sm64_pace_signal(void) {
    pthread_mutex_lock(&sm64_pace_mtx);
    sm64_pace_pending = 1;          // FLAG, capped at 1 — never a backlog
    sm64_pace_signals++;
    pthread_cond_signal(&sm64_pace_cond);
    pthread_mutex_unlock(&sm64_pace_mtx);
}

bool sm64_3d_wait_for_compositor_frame(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += 50L * 1000L * 1000L;  // 50 ms timeout
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&sm64_pace_mtx);
    int rc = 0;
    while (!sm64_pace_pending && rc == 0) {
        rc = pthread_cond_timedwait(&sm64_pace_cond, &sm64_pace_mtx, &ts);
    }
    bool got = sm64_pace_pending;
    sm64_pace_pending = 0;               // consume — next wait blocks for the next frame
    pthread_mutex_unlock(&sm64_pace_mtx);
    return got;
}

void sm64_3d_immersive_run(void *layer_renderer_ptr) {
    // __bridge, not a transfer: SM64VisionApp.swift hands this over with
    // Unmanaged.passUnretained(...).toOpaque(), so SwiftUI still owns the layer
    // renderer and ARC must not take a reference to something it will tear down.
    // (cp_layer_renderer_t is an ObjC pointer type, so under ARC this cast is
    // required — it compiled silently while these files were still MRC, M-40.)
    cp_layer_renderer_t layer_renderer = (__bridge cp_layer_renderer_t)layer_renderer_ptr;
    sm64_3d_imm_stop = 0;
    sm64_3d_imm_running = 1;
    int notifyEnded = 0; // only a system/Crown dismissal reconciles via Ended

    id<MTLCommandQueue> queue = nil;
    sm64_imm_frame_count = 0;
    sm64_haveScreenAnchor = false; // re-center the screen each time 3D is entered
    sm64_eyeCopy[0] = sm64_eyeCopy[1] = nil;
    // Batch 3 item 1b: latch the CURRENT pair generation so the loop waits for a
    // pair rendered THIS session (the counter is monotonic across sessions).
    // First copy then happens when the engine completes its first L+R pair.
    sm64_lastCopiedGen = sm64_metal_get_3d_pair_gen();
    sm64_pairFresh = sm64_pairReuse = 0;

    // ARKit world tracking for the head pose. The compositor reprojects each
    // frame with the device anchor — a frame WITHOUT one may never display.
    ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
    ar_session_t arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
    ar_session_run(arSession, providers);

    NSLog(@"[sm64vp] imm: render loop started (ARKit world tracking running)");

    int running = 1;
    while (running) {
        if (sm64_3d_imm_stop) {
            NSLog(@"[sm64vp] imm: stop requested, exiting cleanly (frames=%d)", sm64_imm_frame_count);
            running = 0;
            continue;
        }
        switch (cp_layer_renderer_get_state(layer_renderer)) {
            case cp_layer_renderer_state_paused:
                cp_layer_renderer_wait_until_running(layer_renderer);
                continue;
            case cp_layer_renderer_state_invalidated:
                NSLog(@"[sm64vp] imm: layer invalidated, exiting loop (frames=%d)", sm64_imm_frame_count);
                notifyEnded = 1; // Crown dismiss: reconcile shell + SwiftUI state
                running = 0;
                continue;
            case cp_layer_renderer_state_running:
            default:
                break;
        }

        // This render thread has no runloop pool; drain per-frame ObjC garbage.
        @autoreleasepool {
            cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
            if (frame == NULL) { continue; }

            cp_frame_timing_t timing = cp_frame_predict_timing(frame);
            cp_frame_start_update(frame);
            cp_frame_end_update(frame);
            // Measure the compositor's true cadence from the optimal_input_time
            // deltas BEFORE waiting on it (Fable §P1-c "measure first").
            cp_time_t optIn = cp_frame_timing_get_optimal_input_time(timing);
            sm64_cadence_sample(cp_time_to_cf_time_interval(optIn));
            // PACING — without this the loop free-runs and presented frames are
            // not displayed. One of the two "renders but nothing shows" bugs.
            cp_time_wait_until(optIn);

            // P1-c (comfort batch 2): release the engine's next paced frame NOW,
            // aligned to the compositor's optimal input time. The engine renders
            // a fresh eye pair that a subsequent compositor frame samples ->
            // phase-locked 1:1, no beat. Signalled every compositor frame; the
            // flag is capped so a stalled engine never burst-renders a backlog.
            sm64_pace_signal();

            cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            // Singular query_drawable: available since 1.0 (the plural form is
            // 26.0-only). vkQuake's shipped loop pairs the singular API with
            // end_submission on a NULL drawable and that is the proven path.
            cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
            if (drawable == NULL) {
                cp_frame_end_submission(frame);
                continue;
            }

            if (queue == nil) {
                // The queue MUST come from the DRAWABLE's own device. A queue
                // from MTLCreateSystemDefaultDevice aborts on the first frame.
                id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
                queue = [t0.device newCommandQueue];
                sm64_build_pipeline(t0.device, t0.pixelFormat,
                                    cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
                NSLog(@"[sm64vp] imm: drawable %lux%lu views=%zu colorFmt=%lu",
                      (unsigned long)t0.width, (unsigned long)t0.height,
                      cp_drawable_get_view_count(drawable), (unsigned long)t0.pixelFormat);
            }

            // Head pose at THIS frame's presentation time -> reprojection.
            CFTimeInterval presTime = cp_time_to_cf_time_interval(
                cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
            ar_device_anchor_t anchor = ar_device_anchor_create();
            ar_device_anchor_query_status_t anchorStatus =
                ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
            cp_drawable_set_device_anchor(drawable, anchor);

            // Anchor the screen ONCE tracking has CONVERGED. ARKit's first
            // frames return success with a near-identity pose, which would put
            // the panel on the floor (guide §2.5) — hence the frame gate, not
            // just the status check.
            if (!sm64_haveScreenAnchor &&
                anchorStatus == ar_device_anchor_query_status_success &&
                sm64_imm_frame_count > 30) {
                sm64_frozenHead = ar_device_anchor_get_origin_from_anchor_transform(anchor);
                sm64_haveScreenAnchor = true;
                NSLog(@"[sm64vp] imm: screen anchored at head (%.2f,%.2f,%.2f)",
                      sm64_frozenHead.columns[3].x, sm64_frozenHead.columns[3].y,
                      sm64_frozenHead.columns[3].z);
            }

            id<MTLCommandBuffer> command_buffer = [queue commandBuffer];

            // Copy BOTH per-eye engine textures into this loop's mipmapped
            // sampling copies — but ONLY when a COMPLETE new pair has landed
            // (batch 3 item 1b, Fable P2-a). The engine renders L then R
            // sequentially, so copying "whatever is latest" every wake could grab
            // L from frame N and R from frame N-1: a per-eye time-skew that fights
            // fusion and reads as micro-judder. The pair generation advances once,
            // after the RIGHT eye's end_frame, so gating the copy on it makes the
            // two eyes an ATOMIC pair. When the compositor outpaces the engine the
            // gen has not advanced: reuse the persistent mipmapped copies (they
            // already persist across frames) and skip the redundant blit+mipgen.
            id<MTLTexture> monoTex = nil; // any live source (aspect + fallback)
            uint32_t curGen = sm64_metal_get_3d_pair_gen();
            if (curGen != sm64_lastCopiedGen) {
                sm64_lastCopiedGen = curGen;
                sm64_pairFresh++;
                for (int e = 0; e < 2; e++) {
                    id<MTLTexture> src = (__bridge id<MTLTexture>)sm64_metal_get_3d_eye_texture(e + 1);
                    if (!src) { continue; } // never rendered => contents UNDEFINED
                    if (src.device != queue.device) {
                        // Cross-device blit would fail. One GPU on visionOS, so this
                        // is a can't-happen — logged rather than assumed.
                        static bool warned = false;
                        if (!warned) {
                            NSLog(@"[sm64vp] imm: eye %d texture is on a DIFFERENT device — skipping", e + 1);
                            warned = true;
                        }
                        continue;
                    }
                    monoTex = src;
                    if (sm64_eyeCopy[e] == nil || sm64_eyeCopy[e].width != src.width ||
                        sm64_eyeCopy[e].height != src.height ||
                        sm64_eyeCopy[e].pixelFormat != src.pixelFormat) {
                        // MIPMAPPED copy: the panel minifies this onto its footprint,
                        // so a mip chain (regenerated each frame) removes aliasing.
                        // renderTarget usage is required by generateMipmaps.
                        MTLTextureDescriptor *td =
                            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                               width:src.width
                                                                              height:src.height
                                                                           mipmapped:YES];
                        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                        td.storageMode = MTLStorageModePrivate;
                        sm64_eyeCopy[e] = [src.device newTextureWithDescriptor:td];
                    }
                    id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
                    [blit copyFromTexture:src toTexture:sm64_eyeCopy[e]]; // fills mip 0
                    if (sm64_eyeCopy[e].mipmapLevelCount > 1) {
                        [blit generateMipmapsForTexture:sm64_eyeCopy[e]]; // fills mips 1..N
                    }
                    [blit endEncoding];
                }
            } else {
                // No fresh pair since our last copy — the compositor woke faster
                // than the engine produced. Reuse the persistent copies; count it
                // as the judder instrument P1-c needs (folded into SM64_CADENCE).
                sm64_pairReuse++;
            }
            // Aspect/format/fidelity/fallback all read a live source. When we
            // reused (no fresh src this wake), fall back to the persistent copy,
            // which is the same pixel format and dimensions as the engine texture.
            if (!monoTex) { monoTex = sm64_eyeCopy[0] ? sm64_eyeCopy[0] : sm64_eyeCopy[1]; }

            id<MTLTexture> color = cp_drawable_get_color_texture(drawable, 0);
            id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, 0);
            size_t views = cp_drawable_get_view_count(drawable);

            simd_float4x4 placement = sm64_haveScreenAnchor
                ? sm64_make_screen_anchor(sm64_frozenHead)
                : sm64_translate(0.0f, 0.0f, -sm64_screenDist);
            simd_float4x4 model = simd_mul(placement, sm64_scale(sm64_screenHalfW, sm64_screenHalfH, 1.0f));
            simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(anchor);

            // Measure the real supersample ratio after the panel is placed —
            // every frame now, so the bridge `fidelity` verb always has a fresh
            // value and live panel reshapes are reflected (batch 3 item 2).
            if (sm64_haveScreenAnchor && sm64_imm_frame_count > 60) {
                sm64_sample_fidelity(drawable, monoTex);
            }

            // Conditional gamma (see the shader comment).
            float srgbDecode = 0.0f;
            if (monoTex) {
                MTLPixelFormat sf = monoTex.pixelFormat, df = color.pixelFormat;
                BOOL srcEncoded = (sf == MTLPixelFormatBGRA8Unorm || sf == MTLPixelFormatRGBA8Unorm);
                BOOL dstLinear = (df == MTLPixelFormatBGRA8Unorm_sRGB ||
                                  df == MTLPixelFormatRGBA8Unorm_sRGB ||
                                  df == MTLPixelFormatRGBA16Float);
                srgbDecode = (srcEncoded && dstLinear) ? 1.0f : 0.0f;
            }

            const bool debugClear = sm64_debug_clear();

            for (size_t v = 0; v < views; v++) {
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = color;
                pass.colorAttachments[0].slice = v; // this eye's array slice
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = debugClear
                    ? MTLClearColorMake(0.06, 0.10, 0.32, 1.0)  // M0 proof colour
                    : MTLClearColorMake(0.0, 0.0, 0.0, 0.0);    // transparent = passthrough
                if (depth) {
                    // The compositor reprojects on depth and REJECTS a frame
                    // whose depth it cannot read. Clearing + writing is mandatory.
                    pass.depthAttachment.texture = depth;
                    pass.depthAttachment.slice = v;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = 1.0;
                }
                // This eye's own image if ready, else the live one (mono
                // fallback): the second eye is UNDEFINED garbage until first
                // rendered, so it is never sampled before that.
                id<MTLTexture> tex = (v < 2 && sm64_eyeCopy[v]) ? sm64_eyeCopy[v] : monoTex;

                // Sim verification harness (P1-a / P1-b). The visionOS SIMULATOR
                // is MONO (views==1) and always samples the LEFT eye, so stereo
                // disparity is invisible on screen. SM64_VP3D_SHOWEYE=R|L forces
                // the panel to sample a CHOSEN eye copy, so a LEFT run and a RIGHT
                // run can be screenshotted and diffed to prove the disparity
                // causally (skybox shifts like far geometry but MORE; HUD/dialog
                // shifts the opposite way = crossed). Env-gated + read once =>
                // absent means no effect at all on a shipped build.
                {
                    static int showEye = -2; // -2 unread, -1 default, 0/1 forced
                    if (showEye == -2) {
                        const char *se = getenv("SM64_VP3D_SHOWEYE");
                        showEye = (se && (*se == 'R' || *se == 'r' || *se == '2')) ? 1
                                : (se && (*se == 'L' || *se == 'l' || *se == '1')) ? 0
                                : -1;
                    }
                    if (showEye >= 0 && sm64_eyeCopy[showEye]) { tex = sm64_eyeCopy[showEye]; }
                }

                id<MTLRenderCommandEncoder> enc =
                    [command_buffer renderCommandEncoderWithDescriptor:pass];
                float dimNow = sm64_dimLevel;
                if (dimNow > 0.003f && sm64_dimPipeline) {
                    [enc setRenderPipelineState:sm64_dimPipeline];
                    [enc setDepthStencilState:sm64_dimDepthState];
                    [enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                if (tex && sm64_pipeline) {
                    cp_view_t view = cp_drawable_get_view(drawable, v);
                    simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                    simd_float4x4 eyeFromOrigin = simd_inverse(simd_mul(originFromDevice, deviceFromEye));
                    simd_float4x4 proj = matrix_identity_float4x4;
                    if (__builtin_available(visionOS 2.0, *)) {
                        proj = cp_drawable_compute_projection(
                            drawable, cp_axis_direction_convention_right_up_back, v);
                    }
                    simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, model));

                    // Aspect-fit the eye texture onto the panel (see the shader's
                    // letterbox note). The texture's true aspect is read from the
                    // sampled texture itself — robust even if the drawable is not
                    // 16:9 — and the panel aspect is halfW/halfH, both live, so
                    // dragging the size sliders re-letterboxes and never stretches.
                    float texAspect = (tex.height > 0)
                        ? (float)tex.width / (float)tex.height : (16.0f / 9.0f);
                    float panelAspect = (sm64_screenHalfH > 0.0f)
                        ? sm64_screenHalfW / sm64_screenHalfH : texAspect;
                    simd_float2 fitScale = (panelAspect > texAspect)
                        ? simd_make_float2(texAspect / panelAspect, 1.0f)  // pillarbox (bars L/R)
                        : simd_make_float2(1.0f, panelAspect / texAspect); // letterbox (bars T/B)

                    [enc setRenderPipelineState:sm64_pipeline];
                    [enc setDepthStencilState:sm64_depthState];
                    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                    [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
                    [enc setFragmentBytes:&fitScale length:sizeof(fitScale) atIndex:1];
                    [enc setFragmentTexture:tex atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
                [enc endEncoding];
            }

            cp_drawable_encode_present(drawable, command_buffer);
            [command_buffer commit];

            sm64_imm_frame_count++;
            if (sm64_imm_frame_count == 3 || (sm64_imm_frame_count % 600) == 0) {
                NSLog(@"[sm64vp] imm: frame %d — engine %lux%lu rendFrames=%d eyeL=%d eyeR=%d "
                       "anchor=%d srgbDecode=%.0f",
                      sm64_imm_frame_count, (unsigned long)(monoTex ? monoTex.width : 0),
                      (unsigned long)(monoTex ? monoTex.height : 0), sm64_metal_get_3d_frames(),
                      (int)(sm64_eyeCopy[0] != nil), (int)(sm64_eyeCopy[1] != nil),
                      (int)sm64_haveScreenAnchor, srgbDecode);
            }

            cp_frame_end_submission(frame);
        } // @autoreleasepool
    }

    sm64_eyeCopy[0] = sm64_eyeCopy[1] = nil;
    if (notifyEnded) { sm64_3d_immersive_ended(); } // Crown/system dismissal only
    sm64_3d_imm_running = 0; // signal the shell LAST, after cleanup
}

#endif // SM64_VISION_3D
