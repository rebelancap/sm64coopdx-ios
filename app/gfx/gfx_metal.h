#ifndef GFX_METAL_H
#define GFX_METAL_H

#include <stdbool.h>

struct GfxRenderingAPI;

#ifdef __cplusplus
extern "C" {
#endif

// The rendering API vtable consumed by gfx_pc.c (see gfx_rendering_api.h).
extern struct GfxRenderingAPI gfx_metal_api;

// A/B switch: returns true when SM64_RAPI=metal is set in the environment.
// Read by BOTH pc_main.c (to pick the render API) and gfx_sdl.c (to build a
// Metal window instead of a GL one). Cached after the first call.
bool gfx_metal_requested(void);

// Called by gfx_sdl.c right after SDL_CreateWindow(..., SDL_WINDOW_METAL).
// Creates the SDL_MetalView + grabs its CAMetalLayer. Returns false on failure.
bool gfx_metal_setup_layer(void *sdl_window);
void gfx_metal_shutdown_layer(void);

// Metal's answer to glGetIntegerv(GL_MAX_SAMPLES) — gfx_sdl.c's get_max_msaa()
// calls straight into GL, which has to be virtualized for the Metal path.
int gfx_metal_get_max_msaa(void);

#ifdef __cplusplus
}
#endif

#endif
