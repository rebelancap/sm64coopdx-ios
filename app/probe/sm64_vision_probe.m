//
//  sm64_vision_probe.m — visionOS performance / drawable instrumentation
//
//  Why this exists, in the charter's words: "Ship the SAME instrumentation from
//  day one: wall/eng percentiles + sim-rate + thermal probe, PLUS true GPU time.
//  eng_ms INCLUDES present blocking — it cannot distinguish GPU saturation from
//  pacing waits; gpu_ms is the number that decides optimization direction. Wire
//  it before the first perf conversation, not after."
//
//  It also closes a specific, named debt. M-16/M-17 INFERRED the visionOS
//  drawable was ~3840x2160 by reasoning backwards from DJUI's auto-scale
//  arithmetic, and overlay 0006's clamp fix rests on that inference. QUESTIONS
//  Q-008 lists "real drawable instrumentation" as still owed. gfx_metal.mm now
//  publishes the size of the texture the drawable actually hands back, and this
//  probe reports it, so the inference can be confirmed or contradicted by a
//  measurement instead of by arithmetic.
//
//  Two outputs on purpose:
//    - stderr, for a live console attach (simctl launch --console-pty).
//    - Documents/vision-perf.log, because the user is remote and OTA-only. A
//      file in Documents is readable through the Files app with no console
//      plumbing at all, which is the charter's remote-diagnosis floor.
//
//  ---------------------------------------------------------------------------
//  FOUR THINGS THIS FILE GOT WRONG, AND WHY THE FIXES ARE SHAPED AS THEY ARE
//  (M-46 — the "two instruments disagree ~4.5x" investigation).
//
//  1. fps SATURATED, SILENTLY, AT EXACTLY PROBE_CAP/PROBE_REPORT_SEC = 409.6.
//     fps was `s_wall_n / elapsed`, and s_wall_n is the PERCENTILE BUFFER's
//     index, capped at PROBE_CAP. So the moment the engine exceeded ~410 fps
//     the probe stopped counting and reported the cap as if it were a reading.
//     Measured: the pre-0012 free-running 3D engine was doing ~752 host fps and
//     this line said `fps=409.6`. Not "no data" — a plausible, wrong number,
//     which is the worst possible failure for the instrument the charter wants
//     TRUSTED for the first device perf conversation. fps now comes from
//     s_frames, an uncapped counter that exists for no other purpose.
//
//  2. THE PERCENTILES SILENTLY COVERED ONLY PART OF THE WINDOW. The cap is
//     still right for the percentile buffers (a probe must never allocate on
//     the render path), but when it is hit, p50/p95/p99 describe the FIRST
//     PROBE_CAP frames of the window rather than the window. That is why the
//     saturated lines read `wall_ms p50=0.86` (=1163/s) while the true
//     full-window rate was 752/s: the two numbers were measuring different
//     spans and nothing on the line said so. wall_ms now prints `n=<sampled>/
//     <total frames>`, so a truncated percentile base is visible ON THE LINE
//     instead of being a fact about the source code.
//
//  3. "fps" WAS AMBIGUOUS IN 3D, AND THE AMBIGUITY COST A WHOLE INVESTIGATION.
//     In 3D the engine renders BOTH eyes per host frame (D-026), so `fps=90`
//     and "180 eye-renders/s" are the same fact stated twice — but the log line
//     only carried one of them, and the immersive loop only carried the other.
//     Comparing them meant comparing two instruments across two logs, which is
//     exactly how M-43 ended up comparing a post-fix run against a pre-fix one.
//     The line now carries `mode=` and `eye_renders_s=` read from the SAME
//     counter the immersive loop reports, over the SAME window, so the
//     cross-check is arithmetic on one line and needs no second instrument.
//
//  4. THE FILE IS APPEND-ONLY ACROSS RUNS AND HAD NO CLOCK AND NO RUN BOUNDARY.
//     vision-perf.log accumulated 3,189 undelimited lines over ~9 hours and a
//     dozen builds. Reading it, there is no way to tell a line written by the
//     current binary from one written by a binary that has since been fixed —
//     and that is not hypothetical: it is precisely how M-43 read a stale
//     `fps=409.6` as belonging to the run it was looking at. Append-only is
//     still right (D-015's reasoning: never let a later run erase the evidence
//     of an earlier one), but every line now carries a UTC timestamp and every
//     process writes a session banner. A stale line can still be READ; it can
//     no longer be MISTAKEN for a current one.
//  ---------------------------------------------------------------------------
//

#include "sm64_vision_probe.h"

#ifdef SM64_VISION_PROBE

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "pc/platform.h"

// The stereo contract (overlay 0011). Included rather than extern-declared so
// the prototypes cannot drift from the definitions in gfx_metal.mm, which is
// where sm64_metal_get_3d_mode/_frames actually live (overlay 0001). Both this
// header and sm64_vision_probe.h derive their gate from TARGET_OS_VISION, so
// they are on together or off together — the #ifdefs below are belt-and-braces.
#include "pc/vision3d/sm64_vision_3d.h"

// Published by the Metal backend (app/gfx/gfx_metal.mm, overlay 0001).
// gSm64GpuMs is written from Metal's completion handler on a system thread.
extern volatile float gSm64GpuMs;
extern volatile int gSm64DrawableW;
extern volatile int gSm64DrawableH;

// The PERCENTILE buffers' cap — NOT a cap on the frame count (that was the bug;
// see note 1 at the top of this file). Samples past the cap are dropped rather
// than growing the buffer: a probe must never be the reason a frame is late.
// Dropping them costs percentile COVERAGE, which the report now states outright
// as `n=<sampled>/<frames>` rather than leaving for a reader to deduce.
#define PROBE_CAP 4096
#define PROBE_REPORT_SEC 10.0

// Batch 3 item 1c: a wall-time frame this slow has blown even the 90 Hz budget
// (11.11 ms) by ~44%, and at 120 Hz it is a hard miss. M-52 saw wall max=21.99ms
// device-side and the immersive compositor de-rate 120->60 right after — most
// likely the 30 Hz sim tick (network / co-op sync / game logic) landing on one
// render frame. We can't fully fix that from here (it's engine-side), but a
// per-window COUNT of these makes the spike FREQUENCY readable over the bridge
// (the `perf` verb tails SM64_PERF), so it can be correlated with the de-rate.
#define PROBE_SPIKE_MS 16.0

static double s_wall[PROBE_CAP];
static double s_eng[PROBE_CAP];
static double s_gpu[PROBE_CAP];
static int s_wall_n = 0;
static int s_eng_n = 0;
static int s_gpu_n = 0;
// The TRUE rendered-frame count for this window. Deliberately separate from
// s_wall_n and deliberately uncapped: this is the only thing fps may be derived
// from, because it is the only counter with no ceiling to hide behind.
static unsigned long long s_frames = 0;
static unsigned long long s_ticks = 0;
// Wall-time spikes this window (frames slower than PROBE_SPIKE_MS). Counted over
// ALL frames, not just the percentile-sampled ones, so a truncated percentile
// base can never hide a spike (item 1c).
static unsigned long long s_spikes = 0;
static double s_last_frame = 0.0;
static double s_last_report = 0.0;
static unsigned long long s_reports = 0;
// Last value of the engine's cumulative eye-render counter, so the report can
// state eye-renders/s over the same window as everything else on the line.
static int s_last_eye_frames = 0;

// CLOCK_MONOTONIC rather than the engine's clock_elapsed_f64(): the probe must
// measure real elapsed time even if the engine's own timebase is ever rebased.
static double probe_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// Wall-clock UTC, for the line stamp and the session banner. CLOCK_MONOTONIC
// above is the right clock for measuring; this is the right one for saying WHEN
// — and "when" is what tells a reader whether a line is from this run.
static void probe_utc(char *buf, size_t n) {
    time_t t = time(NULL);
    struct tm tmv;
    gmtime_r(&t, &tmv);
    if (strftime(buf, n, "%Y-%m-%dT%H:%M:%SZ", &tmv) == 0) {
        snprintf(buf, n, "????-??-??T??:??:??Z");
    }
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// Caller must have sorted v. Returns 0 for an empty set so a missing metric
// reads as an obvious zero rather than as an out-of-bounds read.
static double pct(const double *v, int n, double p) {
    if (n <= 0) { return 0.0; }
    int idx = (int)(p * (n - 1));
    if (idx < 0) { idx = 0; }
    if (idx >= n) { idx = n - 1; }
    return v[idx];
}

// "3d" only while the engine is actually rendering per-eye. Read at report time
// from the same accessor gfx_pc.c gates the both-eyes path on, so the label
// cannot claim a mode the renderer is not in.
static const char *probe_mode(void) {
#ifdef SM64_VISION_3D
    return sm64_metal_get_3d_mode() ? "3d" : "2d";
#else
    return "2d";
#endif
}

// The engine's cumulative eye-render count — the SAME counter sm64_immersive.m
// prints as rendFrames. Reading it here is the whole point: it puts both
// instruments on one line, over one window, in one file.
static int probe_eye_frames(void) {
#ifdef SM64_VISION_3D
    return sm64_metal_get_3d_frames();
#else
    return 0;
#endif
}

int sm64_vision_probe_thermal_state(void) {
    return (int)[[NSProcessInfo processInfo] thermalState];
}

void sm64_vision_probe_on_frame(double engMs) {
    double now = probe_now();
    // Counted BEFORE the cap check and never capped — fps depends on this and
    // on nothing else.
    s_frames++;
    if (s_last_frame > 0.0) {
        double wall = (now - s_last_frame) * 1000.0;
        // Percentile buffer is capped (a probe must never allocate on the render
        // path); the spike COUNT is not — it is checked on every frame so a
        // truncated percentile window cannot swallow a spike (item 1c).
        if (s_wall_n < PROBE_CAP) { s_wall[s_wall_n++] = wall; }
        if (wall > PROBE_SPIKE_MS) { s_spikes++; }
    }
    s_last_frame = now;

    if (s_eng_n < PROBE_CAP) { s_eng[s_eng_n++] = engMs; }

    // gSm64GpuMs is the LAST completed frame's GPU time, not this frame's — the
    // completion handler necessarily runs after we get here. Over a 10 s window
    // that one-frame lag is irrelevant to a percentile; it is recorded so nobody
    // later reads gpu_ms as being in lockstep with the eng_ms beside it.
    float g = gSm64GpuMs;
    if (g > 0.0f && s_gpu_n < PROBE_CAP) { s_gpu[s_gpu_n++] = (double)g; }
}

// Both sinks, one place. Opened and closed per report (once per 10 s) rather
// than held open: a swipe-kill on visionOS is SIGKILL, so an fd held across the
// process's life would lose whatever sat in its buffer. Cheap at this cadence.
static void probe_emit(const char *line) {
    fprintf(stderr, "%s\n", line);
    fflush(stderr);

    const char *user = sys_user_path();
    if (user && user[0]) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/vision-perf.log", user);
        FILE *f = fopen(path, "a");
        if (f) {
            fprintf(f, "%s\n", line);
            fclose(f);
        }
    }
}

static void probe_report(double elapsed) {
    qsort(s_wall, s_wall_n, sizeof(double), cmp_double);
    qsort(s_eng, s_eng_n, sizeof(double), cmp_double);
    qsort(s_gpu, s_gpu_n, sizeof(double), cmp_double);

    char stamp[32];
    probe_utc(stamp, sizeof(stamp));

    // The session banner. This file is append-only across every run the app has
    // ever made (deliberately — D-015: a later run must not erase an earlier
    // run's evidence), so without a boundary there is nothing separating this
    // build's lines from a build that has since been fixed. M-43 read a stale
    // line as a live one for exactly this reason.
    if (s_reports == 0) {
        char banner[256];
        snprintf(banner, sizeof(banner),
                 "SM64_PERF === session %s pid=%d === "
                 "(this log is APPEND-ONLY across runs — check the stamp on every line)",
                 stamp, (int)getpid());
        probe_emit(banner);
    }

    int eyeNow = probe_eye_frames();
    int eyeDelta = eyeNow - s_last_eye_frames;
    // The counter is monotonic within a process, so a negative delta can only
    // mean a wrap or a reset. Report 0 rather than a negative rate: a nonsense
    // number that LOOKS like a reading is the failure this whole file just got
    // rewritten over.
    if (eyeDelta < 0) { eyeDelta = 0; }
    s_last_eye_frames = eyeNow;

    char line[720];
    snprintf(line, sizeof(line),
             "SM64_PERF %s wall_ms p50=%.2f p95=%.2f p99=%.2f max=%.2f n=%d/%llu | "
             "spikes(>%.0fms)=%llu | "
             "eng_ms p50=%.2f p95=%.2f | gpu_ms p50=%.2f p95=%.2f n=%d | "
             "fps=%.1f sim_tps=%.2f | mode=%s eye_renders_s=%.1f | "
             "drawable=%dx%d | thermal=%d",
             stamp,
             pct(s_wall, s_wall_n, 0.50), pct(s_wall, s_wall_n, 0.95),
             pct(s_wall, s_wall_n, 0.99), s_wall_n > 0 ? s_wall[s_wall_n - 1] : 0.0,
             s_wall_n, s_frames,
             PROBE_SPIKE_MS, s_spikes,
             pct(s_eng, s_eng_n, 0.50), pct(s_eng, s_eng_n, 0.95),
             pct(s_gpu, s_gpu_n, 0.50), pct(s_gpu, s_gpu_n, 0.95), s_gpu_n,
             // fps = RENDERED HOST FRAMES per second: one per iteration of the
             // interpolation loop, which is one complete image of the game. In
             // 3D that same iteration renders the scene TWICE (once per eye —
             // D-026), which is what eye_renders_s reports; expect it to be
             // exactly 2x fps in 3D and 0 in 2D. They are two views of one
             // number, printed together so nobody has to reconcile two logs.
             (double)s_frames / elapsed, (double)s_ticks / elapsed,
             probe_mode(), (double)eyeDelta / elapsed,
             gSm64DrawableW, gSm64DrawableH,
             sm64_vision_probe_thermal_state());

    probe_emit(line);

    s_wall_n = 0;
    s_eng_n = 0;
    s_gpu_n = 0;
    s_frames = 0;
    s_ticks = 0;
    s_spikes = 0;
    s_reports++;
}

void sm64_vision_probe_on_tick(void) {
    s_ticks++;
    double now = probe_now();
    if (s_last_report == 0.0) {
        s_last_report = now;
        // Baseline the eye counter with the window, or the first report would
        // attribute every eye render since process start to a 10 s window.
        s_last_eye_frames = probe_eye_frames();
        return;
    }
    double elapsed = now - s_last_report;
    if (elapsed < PROBE_REPORT_SEC) { return; }

    // Report even with few frames — a report that says fps=0.3 is a FINDING
    // (rendering has stalled), and a probe that suppresses it would hide exactly
    // the condition worth knowing about. Guard only against a divide-by-zero.
    if (elapsed > 0.0) { probe_report(elapsed); }
    s_last_report = now;
}

#endif // SM64_VISION_PROBE
