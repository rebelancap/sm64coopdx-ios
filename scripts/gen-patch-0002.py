#!/usr/bin/env python3
"""Overlay patch 0002: the Metal engine seam — gfx_sdl.c (window manager)
and pc_main.c (backend selection).

gfx_sdl.c is GL-coupled but only shallowly: GL attributes, the OPENGL
window flag, context create/delete, the swap, and one direct glGetIntegerv
in get_max_msaa. Each is forked on gfx_metal_requested() so GL and Metal
are A/B-able from ONE binary (SM64_RAPI=metal) — which is what made the
desktop pixel oracle (D-003) possible and retired D-002's silent-garbage-
geometry risk (M-13).

pc_main.c's switch is deliberately NOT widened with a new GAPI_* enum:
configGraphicsBackend is persisted in sm64config.txt and read back by
djui_panel_display's selectionbox, so a new enum value would need a
boot-time migration — the exact value-keyed-enum trap the charter flags.
An env var keeps it out of the config file entirely.

SECOND CONCERN, same seam: SM64_NO_OPENGL — compiling GL out entirely
where it does not exist. This lives here rather than in its own patch
because it edits the same two functions ENABLE_METAL_BACKEND does
(get_max_msaa, select_graphics_backend); a separate patch would have to
hunk inside this one's context, which the charter forbids (D6).

Why it is needed at all — a MEASURED extension of M-1. M-1 established
that EAGLContext is unavailable on visionOS. The wall is much wider than
that: EVERY GL entry point is marked unavailable in the xrOS SDK.

    XROS26.5.sdk/.../OpenGLES.framework/Headers/ES2/gl.h:545
    error: 'glGetIntegerv' is unavailable: not available on visionOS

So gfx_sdl.c's glGetIntegerv in get_max_msaa is a HARD COMPILE BREAK on
xros even though patch 0002's USE_METAL() early-return means it can never
be reached at runtime. Runtime gating is not enough; the call sites have
to be compiled out. Three GL touch points in gfx_sdl.c
(the header include, get_max_msaa, gfx_sdl_check_opengl_compatibility)
plus pc_main.c's gfx_opengl_api references.

Everything is gated on ENABLE_METAL_BACKEND / SM64_NO_OPENGL, so this is
a no-op for every build that defines neither (Linux/Windows/the stock iOS
target). Only the visionOS target defines SM64_NO_OPENGL (overlay 0005).
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"


def replace_once(text, old, new, tag):
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}: {old[:70]!r}"
    return text.replace(old, new)


def unified(rel, orig, new):
    with tempfile.TemporaryDirectory() as td:
        a = pathlib.Path(td) / "a"; a.write_text(orig)
        b = pathlib.Path(td) / "b"; b.write_text(new)
        r = subprocess.run(["diff", "-u", "--label", f"a/{rel}", "--label", f"b/{rel}",
                            str(a), str(b)], capture_output=True, text=True)
    assert r.returncode == 1, f"[{rel}] no diff produced"
    return r.stdout


# ---------------------------------------------------------------- gfx_sdl.c
REL_SDL = "src/pc/gfx/gfx_sdl.c"
orig_sdl = (VENDOR / REL_SDL).read_text()
t = orig_sdl

# GL touch point 1/3: the header include. Every GL entry point is
# API-unavailable in the xrOS SDK, so this cannot be included there.
t = replace_once(t, """#if FOR_WINDOWS
#define GLEW_STATIC
#include <GL/glew.h>

#define GL_GLEXT_PROTOTYPES 1
#include <SDL2/SDL_opengl.h>
#else
#define GL_GLEXT_PROTOTYPES 1

#ifdef OSX_BUILD
#include <SDL2/SDL_opengl.h>
#else
#include <SDL2/SDL_opengles2.h>
#endif

#endif // End of OS-Specific GL defines""", """#ifndef SM64_NO_OPENGL
#if FOR_WINDOWS
#define GLEW_STATIC
#include <GL/glew.h>

#define GL_GLEXT_PROTOTYPES 1
#include <SDL2/SDL_opengl.h>
#else
#define GL_GLEXT_PROTOTYPES 1

#ifdef OSX_BUILD
#include <SDL2/SDL_opengl.h>
#else
#include <SDL2/SDL_opengles2.h>
#endif

#endif // End of OS-Specific GL defines
#endif // SM64_NO_OPENGL""", "sdl-gl-includes")

t = replace_once(t, """#include "pc/rom_checker.h"

#ifndef GL_MAX_SAMPLES""", """#include "pc/rom_checker.h"

// Metal backend (visionOS has no OpenGL at all — see gfx_metal.mm). This window
// manager is GL-coupled but only shallowly: GL attributes, the OPENGL window
// flag, context create/delete/make-current, the swap, and one direct
// glGetIntegerv in get_max_msaa. Each of those is forked below on
// gfx_metal_requested() so GL and Metal are A/B-able from one binary.
#ifdef ENABLE_METAL_BACKEND
#include <SDL2/SDL_metal.h>
#include "gfx_metal.h"
#include "pc/platform.h"
#define USE_METAL() gfx_metal_requested()
#else
#define USE_METAL() false
#endif

// SDL_GL_GetDrawableSize() is meaningless on a non-GL window.
static void gfx_sdl_drawable_size(SDL_Window *w, int *dw, int *dh) {
#ifdef ENABLE_METAL_BACKEND
    if (USE_METAL()) { SDL_Metal_GetDrawableSize(w, dw, dh); return; }
#endif
    SDL_GL_GetDrawableSize(w, dw, dh);
}

#ifndef GL_MAX_SAMPLES""", "sdl-includes")

t = replace_once(t, """static inline void gfx_sdl_set_vsync(const bool enabled) {
    SDL_GL_SetSwapInterval(enabled);
}""", """static inline void gfx_sdl_set_vsync(const bool enabled) {
    // CAMetalLayer presents are display-synced by default; there is no
    // SDL_GL_SetSwapInterval equivalent to call on the Metal path.
    if (USE_METAL()) { return; }
    SDL_GL_SetSwapInterval(enabled);
}""", "sdl-vsync")

t = replace_once(t, """    if (configWindow.msaa > 0) {
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1);
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, configWindow.msaa);
    } else {
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 0);
    }

    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
""", """    if (!USE_METAL()) {
    if (configWindow.msaa > 0) {
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1);
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, configWindow.msaa);
    } else {
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 0);
    }

    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    }
""", "sdl-gl-attrs")

t = replace_once(t, """    SDL_Window *probe = SDL_CreateWindow("", 0, 0, 64, 64, SDL_WINDOW_HIDDEN | SDL_WINDOW_ALLOW_HIGHDPI);
    if (probe) {
        int pdw = 64, pdh = 64, pww = 64, pwh = 64;
        SDL_GL_GetDrawableSize(probe, &pdw, &pdh);""", """    SDL_Window *probe = SDL_CreateWindow("", 0, 0, 64, 64,
        (USE_METAL() ? SDL_WINDOW_METAL : 0) | SDL_WINDOW_HIDDEN | SDL_WINDOW_ALLOW_HIGHDPI);
    if (probe) {
        int pdw = 64, pdh = 64, pww = 64, pwh = 64;
        gfx_sdl_drawable_size(probe, &pdw, &pdh);""", "sdl-probe")

t = replace_once(t, """    Uint32 windowFlags = SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE;""",
                 """    Uint32 windowFlags = (USE_METAL() ? SDL_WINDOW_METAL : SDL_WINDOW_OPENGL)
                       | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE;""", "sdl-window-flags")

t = replace_once(t, """    ctx = SDL_GL_CreateContext(wnd);

    // Record actual HiDPI state — drives rendering decisions for this window's lifetime.
    // Toggling the config takes effect only on restart.
    {
        int dw = 0, dh = 0, ww = 0, wh = 0;
        SDL_GL_GetDrawableSize(wnd, &dw, &dh);""", """#ifdef ENABLE_METAL_BACKEND
    if (USE_METAL()) {
        // Creates the SDL_MetalView and grabs its CAMetalLayer; the backend
        // owns everything past this point (no context to make current).
        if (!gfx_metal_setup_layer(wnd)) { sys_fatal("could not set up Metal layer"); }
    } else
#endif
    ctx = SDL_GL_CreateContext(wnd);

    // Record actual HiDPI state — drives rendering decisions for this window's lifetime.
    // Toggling the config takes effect only on restart.
    {
        int dw = 0, dh = 0, ww = 0, wh = 0;
        gfx_sdl_drawable_size(wnd, &dw, &dh);""", "sdl-ctx-create")

t = replace_once(t, """    int w, h;
    if (sHidpiActive) {
        SDL_GL_GetDrawableSize(wnd, &w, &h);""", """    int w, h;
    if (sHidpiActive) {
        gfx_sdl_drawable_size(wnd, &w, &h);""", "sdl-get-dimensions")

t = replace_once(t, """    int dw = 1, dh = 1, ww = 1, wh = 1;
    if (wnd && sHidpiActive) {
        SDL_GL_GetDrawableSize(wnd, &dw, &dh);""", """    int dw = 1, dh = 1, ww = 1, wh = 1;
    if (wnd && sHidpiActive) {
        gfx_sdl_drawable_size(wnd, &dw, &dh);""", "sdl-hidpi-scale")

t = replace_once(t, """static void gfx_sdl_swap_buffers_begin(void) {
    SDL_GL_SwapWindow(wnd);
}""", """static void gfx_sdl_swap_buffers_begin(void) {
    // The Metal backend presents its CAMetalDrawable in gfx_metal_end_frame(),
    // so there is no swap to perform here.
    if (USE_METAL()) { return; }
    SDL_GL_SwapWindow(wnd);
}""", "sdl-swap")

t = replace_once(t, """static int gfx_sdl_get_max_msaa(void) {
    int maxSamples = 0;
    glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);""", """static int gfx_sdl_get_max_msaa(void) {
    int maxSamples = 0;
#ifdef ENABLE_METAL_BACKEND
    // glGetIntegerv from the window manager cannot survive on a Metal window;
    // Metal answers the same question via supportsTextureSampleCount.
    if (USE_METAL()) { return gfx_metal_get_max_msaa(); }
#endif
#ifndef SM64_NO_OPENGL
    glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);""", "sdl-max-msaa")

# GL touch point 2/3: close the SM64_NO_OPENGL guard around the GL body of
# get_max_msaa. Separate replace so each anchor stays small and unique.
t = replace_once(t, """    glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);
    if (maxSamples > 16) { maxSamples = 16; }
    return maxSamples;""", """    glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);
    if (maxSamples > 16) { maxSamples = 16; }
#endif
    return maxSamples;""", "sdl-max-msaa-close")

# GL touch point 3/3: gfx_sdl_check_opengl_compatibility() probes a real GL
# context and calls gfx_opengl_check_compatibility(), which lives in
# gfx_opengl.c — a file the visionOS target does not compile at all. Only
# pc_main.c's _WIN32 branch ever calls this, so returning false on xros is
# dead-code-honest: it keeps the symbol (gfx_sdl.h declares it) without
# pretending a GL context can be created.
t = replace_once(t, """bool gfx_sdl_check_opengl_compatibility(void) {
    if (!(SDL_WasInit(SDL_INIT_VIDEO) & SDL_INIT_VIDEO)) {""", """bool gfx_sdl_check_opengl_compatibility(void) {
#ifdef SM64_NO_OPENGL
    // No GL backend is compiled in on this platform (every GL entry point is
    // API-unavailable in the xrOS SDK), so there is nothing to be compatible
    // with. Only pc_main.c's _WIN32 branch calls this.
    return false;
#else
    if (!(SDL_WasInit(SDL_INIT_VIDEO) & SDL_INIT_VIDEO)) {""", "sdl-check-compat")

t = replace_once(t, """    SDL_GL_DeleteContext(ctx);
    SDL_DestroyWindow(window);

    return validVersion;
}""", """    SDL_GL_DeleteContext(ctx);
    SDL_DestroyWindow(window);

    return validVersion;
#endif // SM64_NO_OPENGL
}""", "sdl-check-compat-close")

t = replace_once(t, """static void gfx_sdl_shutdown(void) {
    if (SDL_WasInit(0)) {
        if (ctx) { SDL_GL_DeleteContext(ctx); ctx = NULL; }""", """static void gfx_sdl_shutdown(void) {
    if (SDL_WasInit(0)) {
#ifdef ENABLE_METAL_BACKEND
        if (USE_METAL()) { gfx_metal_shutdown_layer(); }
#endif
        if (ctx) { SDL_GL_DeleteContext(ctx); ctx = NULL; }""", "sdl-shutdown")

diff_sdl = unified(REL_SDL, orig_sdl, t)

# ---------------------------------------------------------------- pc_main.c
REL_MAIN = "src/pc/pc_main.c"
orig_main = (VENDOR / REL_MAIN).read_text()
m = orig_main

m = replace_once(m, """#include "pc/mods/mods.h"

#include "debug_context.h\"""", """#include "pc/mods/mods.h"

#if defined(SM64_NO_OPENGL) && !defined(ENABLE_METAL_BACKEND)
#error "SM64_NO_OPENGL requires ENABLE_METAL_BACKEND — Metal is the only renderer left."
#endif

#ifdef ENABLE_METAL_BACKEND
#include "pc/gfx/gfx_metal.h"
#endif

#include "debug_context.h\"""", "main-include")

m = replace_once(m, """#if defined(_WIN32)
    if (configGraphicsBackend == GAPI_GL && !gfx_sdl_check_opengl_compatibility()) {""", """#ifdef ENABLE_METAL_BACKEND
    // A/B switch for the Metal backend (SM64_RAPI=metal). Deliberately NOT a
    // new GAPI_* enum value: configGraphicsBackend is persisted in
    // sm64config.txt and read back by djui_panel_display's selectionbox, so
    // widening the enum would need a boot-time migration for existing configs.
    // An env var keeps the spike out of the config file entirely.
    if (gfx_metal_requested()) {
        gWindowApi = &gfx_sdl;
        gRenderApi = &gfx_metal_api;
        gAudioApi  = &audio_sdl;
        printf("Graphics backend: Metal (SM64_RAPI=metal)\\n");
        goto backend_selected;
    }
#endif

#ifdef SM64_NO_OPENGL
    // visionOS: there is no GL backend compiled into this binary at all — every
    // GL entry point is API-unavailable in the xrOS SDK (M-1, extended), so
    // gfx_opengl.c is not built. Metal is the only renderer, so ignore
    // configGraphicsBackend rather than honouring a persisted GAPI_GL that
    // cannot be satisfied. Deliberately NOT routed through gfx_metal_requested():
    // that env var is the desktop A/B switch, and Metal here is not optional.
    //
    // The whole GL selection below is #else'd out rather than skipped with a
    // goto: &gfx_opengl_api would still be COMPILED, and gfx_opengl.c is absent
    // from this target, so it would fail at LINK with an undefined symbol.
    gWindowApi = &gfx_sdl;
    gRenderApi = &gfx_metal_api;
    gAudioApi  = &audio_sdl;
#else

#if defined(_WIN32)
    if (configGraphicsBackend == GAPI_GL && !gfx_sdl_check_opengl_compatibility()) {""", "main-switch")

m = replace_once(m, """    if (!gAudioApi->init()) {
        gAudioApi = &audio_null;
    }""", """#endif // SM64_NO_OPENGL

#ifdef ENABLE_METAL_BACKEND
backend_selected:;
#endif

    if (!gAudioApi->init()) {
        gAudioApi = &audio_null;
    }""", "main-label")

diff_main = unified(REL_MAIN, orig_main, m)

out = ROOT / "overlay/patches/0002-metal-engine-seam.patch"
out.write_text(__doc__ + "\n" + diff_sdl + diff_main)
print(f"wrote {out}")
