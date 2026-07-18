//
//  sm64_vision_hz.m — measure the Vision Pro panel's real refresh rate, and
//                     default this platform's frame limiter to it.
//
//  Read sm64_vision_hz.h first: it carries the WHY (in short: every other way to
//  learn the panel rate on visionOS is a guess — UIScreen does not exist, SDL's
//  display mode is a number WE hardcoded, and a hw.machine table is wrong on
//  hardware that does not exist yet).
//
//  This file is the source of truth; overlay 0010 only packages it into
//  src/pc/ (D-010, the same arrangement as app/gfx, app/probe and app/shell).
//

#include "sm64_vision_hz.h"

#ifdef SM64_VISION_HZ

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "configfile.h"

#pragma mark - Tunables

// The M2-generation Vision Pro panel. Used ONLY until the measurement settles,
// and chosen as the CONSERVATIVE end of the two shipping panels on purpose:
// reporting 90 on a 120 Hz panel costs headroom we then recover a few frames
// later, whereas reporting 120 on a 90 Hz panel asks the frame limiter for
// frames the display cannot show. It is a fallback, not a guess we ship — if it
// is ever the value the game runs on, the measurement FAILED and the log below
// says so in as many words.
#define SM64_VISION_HZ_FALLBACK   90u

// The user's cap. "limit at 120" — and 120 is also the fastest panel Apple has
// shipped, so this only bites if a future headset goes higher, in which case
// running the game at 120 on a faster panel is the right conservative default
// anyway (the user can raise it in Display -> Frame Limit).
#define SM64_VISION_HZ_CAP        120u

// Sampling. The first callbacks after a display link starts are not
// representative (the link is still ramping, and the very first
// targetTimestamp-timestamp can be a synthetic value), so warm up before
// counting. 48 samples is ~0.4 s at 120 Hz / ~0.53 s at 90 Hz — long enough to
// be stable, short enough that the policy lands well inside the intro sequence.
#define SM64_VISION_HZ_WARMUP     12
#define SM64_VISION_HZ_SAMPLES    48

// Anything outside this is not a display and must never be latched.
#define SM64_VISION_HZ_MIN        24.0
#define SM64_VISION_HZ_MAX        360.0

// Bump when the policy below changes meaning. Persisted as
// `vision_framerate_rev` in sm64config.txt; see sm64_vision_hz_apply_policy().
#define SM64_VISION_FRAMERATE_REV 1u

#pragma mark - Published state

// The one thing this file publishes. 0 == not yet measured; any other value is
// a settled measurement and never changes again.
//
// volatile + plain unsigned int, matching gSm64IosVisionLongEdge (overlay 0004)
// and gSm64DrawableW/H (overlay 0001): the sampler thread writes it exactly
// once, the render thread reads it, and a single aligned 32-bit store is atomic
// on arm64. Charter ground rule 5's pattern — "cache values from a
// [non-game-thread] poll into volatiles and read those" — is the same shape.
static volatile unsigned int gSm64IosVisionPanelHz = 0;

unsigned int Sm64Ios_VisionPanelHz(void) {
    unsigned int hz = gSm64IosVisionPanelHz;
    return hz ? hz : SM64_VISION_HZ_FALLBACK;
}

bool sm64_vision_hz_settled(void) {
    return gSm64IosVisionPanelHz != 0;
}

#pragma mark - Snapping a measurement to a panel rate

static int hz_cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// Snap a raw measurement onto a real panel rate — but ONLY if it is already
// within 4% of one.
//
// The tolerance is the whole design. A bare nearest-of-{60,90,96,120} snap would
// reproduce, in a different coat, exactly the brittleness that makes a
// hw.machine table unacceptable: a 144 Hz panel that does not exist yet would be
// silently reported as 120 forever. Instead, a reading that matches a known rate
// is cleaned up (so 119.88 becomes 120 rather than a scruffy 119), and a reading
// that matches NOTHING known is trusted and used as-is, because it is a
// measurement and we are not in a position to know better than the display.
static unsigned int hz_snap(double raw) {
    static const double known[] = { 60.0, 90.0, 96.0, 120.0 };
    for (size_t i = 0; i < sizeof(known) / sizeof(known[0]); i++) {
        if (fabs(raw - known[i]) <= known[i] * 0.04) {
            return (unsigned int)known[i];
        }
    }
    long r = lround(raw);
    if (r < 1) { r = 1; }
    return (unsigned int)r;
}

#pragma mark - The sampler

@interface SM64PanelHzSampler : NSObject
@end

@implementation SM64PanelHzSampler {
    double _samples[SM64_VISION_HZ_SAMPLES];
    int _count;
    int _warmup;
    int _rejected;
}

- (void)tick:(CADisplayLink *)link {
    // targetTimestamp - timestamp, NOT the delta between successive timestamps.
    //
    // This is the one load-bearing choice in the measurement. A successive-
    // timestamp delta measures how often OUR CALLBACK RAN, which is only the
    // panel rate if we never miss one — and a missed callback silently doubles
    // the delta, i.e. halves the answer. targetTimestamp - timestamp is the
    // display link's own statement of when the next frame is due relative to
    // this one; it is the DISPLAY's number, not ours. (The dedicated run loop
    // this runs on makes missed callbacks unlikely anyway. Both defences,
    // because a frame-rate default that is wrong by exactly 2x is precisely the
    // bug that looks plausible enough to ship.)
    double dt = link.targetTimestamp - link.timestamp;

    if (_warmup < SM64_VISION_HZ_WARMUP) {
        _warmup++;
        return;
    }

    double hz = dt > 0.0 ? 1.0 / dt : 0.0;
    if (!(hz >= SM64_VISION_HZ_MIN && hz <= SM64_VISION_HZ_MAX)) {
        // A hitch, a stall, or a nonsense reading. Drop it rather than let it
        // into the sample set; if EVERY reading is nonsense we simply never
        // settle, and never settling is a safe outcome (the game keeps the
        // engine's own AUTO behaviour and the log says why).
        _rejected++;
        return;
    }

    if (_count < SM64_VISION_HZ_SAMPLES) {
        _samples[_count++] = hz;
    }
    if (_count < SM64_VISION_HZ_SAMPLES) {
        return;
    }

    // MEDIAN, not mean: one scheduling hitch inside the window drags a mean
    // several Hz off and there is no averaging it back out. The median of 48
    // samples is unmoved by a handful of outliers.
    double sorted[SM64_VISION_HZ_SAMPLES];
    memcpy(sorted, _samples, sizeof(sorted));
    qsort(sorted, SM64_VISION_HZ_SAMPLES, sizeof(double), hz_cmp_double);
    double median = 0.5 * (sorted[SM64_VISION_HZ_SAMPLES / 2 - 1] +
                           sorted[SM64_VISION_HZ_SAMPLES / 2]);

    unsigned int snapped = hz_snap(median);

    // Publish first: this is the store the render thread is waiting on, and it
    // is what ends this thread's run loop.
    gSm64IosVisionPanelHz = snapped;

    // The raw median is printed to THREE DECIMALS on purpose, and it is the
    // whole evidentiary value of this line. A hardcoded rate prints as exactly
    // 120.000; a measurement prints as 119.881 with a min/max spread around it.
    // That difference is how a reader tells "we measured the panel" from "we
    // read our own guess back" — which is the precise failure this patch exists
    // to fix, and it would otherwise be invisible in a log that just said 120.
    printf("[hz] panel MEASURED: %u Hz (median %.3f Hz over %d CADisplayLink samples, "
           "min %.3f max %.3f, %d rejected) [requested range 80-120]\n",
           snapped, median, SM64_VISION_HZ_SAMPLES,
           sorted[0], sorted[SM64_VISION_HZ_SAMPLES - 1], _rejected);
    fflush(stdout);

    // Invalidate LAST, and touch nothing afterwards. The link holds the only
    // strong reference to this object (ARC is entitled to have released the
    // local in hz_sampler_thread() after its last use), so invalidating drops
    // our retain count to zero — every ivar read above, including _rejected,
    // must happen before this line. Stopping matters: a display link left
    // running burns a wakeup per frame, forever, for an answer we already have.
    [link invalidate];
}

@end

static void *hz_sampler_thread(void *arg) {
    (void)arg;
    @autoreleasepool {
        SM64PanelHzSampler *sampler = [[SM64PanelHzSampler alloc] init];

        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:sampler
                                                          selector:@selector(tick:)];
        if (link == nil) {
            printf("[hz] FAILED: CADisplayLink could not be created — panel rate NOT measured; "
                   "staying on the engine's own refresh-rate handling\n");
            fflush(stdout);
            return NULL;
        }

        // Ask for the fastest the panel will give us, and let the SYSTEM clamp
        // it — that clamp is the measurement. The same range the SDL compat
        // patch requests for its (never-started) link: minimum 80 so the system
        // does not power-throttle us down to a slow-but-legal rate and hand us a
        // reading that describes ITS power policy rather than the panel.
        link.preferredFrameRateRange = CAFrameRateRangeMake(80.0f, 120.0f, 120.0f);

        NSRunLoop *rl = [NSRunLoop currentRunLoop];
        [link addToRunLoop:rl forMode:NSRunLoopCommonModes];

        // Our own run loop, on our own thread. NOT the main run loop: coopdx's
        // main thread sits in `while (true) { gWindowApi->main_loop(...) }`
        // (pc_main.c) and only services the run loop incidentally, deep inside
        // SDL's event pump — so a main-run-loop link would measure our pump
        // rate, not the panel's.
        //
        // Bounded rather than `[rl run]` forever: this thread exists to answer
        // one question, and it must not outlive the answer. It ends when the
        // measurement settles, or after ~10 s if the link never fires at all
        // (in which case Sm64Ios_VisionPanelHz() keeps returning the fallback
        // and the framerate policy correctly declines to run).
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (gSm64IosVisionPanelHz == 0 && [deadline timeIntervalSinceNow] > 0) {
            @autoreleasepool {
                [rl runMode:NSDefaultRunLoopMode
                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }

        if (gSm64IosVisionPanelHz == 0) {
            [link invalidate];
            printf("[hz] FAILED: no usable CADisplayLink samples in 10 s — panel rate NOT "
                   "measured. Frame limiter keeps the engine's AUTO behaviour and the "
                   "visionOS framerate default is NOT applied (deliberately: a default "
                   "derived from a failed measurement is worse than no default).\n");
            fflush(stdout);
        }
    }
    return NULL;
}

#pragma mark - The visionOS framerate policy (default + one-shot migration)

// Runs at most once per process, and at most once per CONFIG, ever.
//
// WHAT IT DOES. Sets Display -> Framerate Mode = MANUAL and Display -> Frame
// Limit = the measured panel rate (capped at 120).
//
// WHY IT IS NOT JUST A DEFAULT IN configfile.c. Two independent reasons, and
// both of them would have made a `= RRM_MANUAL` one-liner useless:
//
//   1. `framerate_mode` and `frame_limit` are PERSISTED in sm64config.txt.
//      Changing a C default only ever affects a config file that does not exist
//      yet. Every user who has already launched this build has both keys on
//      disk, configfile_load() overwrites the new defaults with the old values,
//      and the change appears to do nothing at all. That is why this is a
//      MIGRATION and not a default, and why the regression test seeds a legacy
//      config instead of testing a fresh install (a fresh install cannot catch
//      this class of bug — charter, "Post-guide traps").
//   2. The right value is not knowable at configfile_load() time. It is
//      MEASURED, and the measurement needs SDL, a window and the compositor —
//      all of which come up after configfile_load(). So the policy has to wait
//      for a reading, which is what sm64_vision_hz_poll() arranges.
//
// WHY IT IS SAFE TO REWRITE A USER'S SETTING AT ALL — which, in general, it is
// NOT ("never delete user data" is a charter ground rule). The narrow
// justification: the visionOS build is DAYS old, ships to nobody but this
// user's headset, and has never presented a panel-rate-aware frame limit to
// deliberately tune. So there is no considered choice here to destroy — only the
// desktop default (60) that the user is asking us to stop shipping. That
// justification expires the moment it runs, which is exactly what the rev marker
// enforces: it is persisted alongside the settings, so the SECOND launch — and
// every launch after, and any launch where the user has since chosen AUTO on
// purpose — takes the early-out below and touches nothing.
static void sm64_vision_hz_apply_policy(void) {
    unsigned int hz = Sm64Ios_VisionPanelHz();

    if (configVisionFramerateRev >= SM64_VISION_FRAMERATE_REV) {
        // Already applied to THIS config, in some previous launch. Whatever
        // framerate_mode/frame_limit say now is the user's business, including
        // "back to AUTO". Do not touch them. Ever.
        printf("[hz] framerate policy: already applied (vision_framerate_rev=%u) — "
               "leaving framerate_mode=%u frame_limit=%u exactly as the user has them "
               "(measured panel %u Hz)\n",
               configVisionFramerateRev, (unsigned int)configFramerateMode,
               configFrameLimit, hz);
        fflush(stdout);
        return;
    }

    unsigned int limit = hz > SM64_VISION_HZ_CAP ? SM64_VISION_HZ_CAP : hz;
    // configfile.c clamps frame_limit to [30, 3000] on load; stay inside it so a
    // pathological measurement can never write a value the engine will bounce.
    if (limit < 30) { limit = 30; }

    unsigned int wasMode  = (unsigned int)configFramerateMode;
    unsigned int wasLimit = configFrameLimit;

    configFramerateMode = RRM_MANUAL;
    configFrameLimit = limit;
    configVisionFramerateRev = SM64_VISION_FRAMERATE_REV;

    // PERSIST IMMEDIATELY. This line is the whole difference between a
    // once-per-config migration and one that re-fires on every launch forever.
    //
    // The first cut set the three globals above and left saving to whatever
    // wrote the config later — in practice the resign-active path. The sim
    // regression caught it (MEASUREMENTS M-35): run 2 re-applied the migration
    // with a byte-identical log line, because `vision_framerate_rev` never
    // reached disk. The early-out above reads the PERSISTED rev, so an unsaved
    // rev makes the "runs once" promise in the message below a lie — and worse,
    // a user who deliberately picks AUTO gets silently clobbered on next launch,
    // which is precisely the thing the marker exists to prevent.
    //
    // It must not depend on the resign path: that path is UNVERIFIED on visionOS
    // (QUESTIONS Q-009 — nothing has ever confirmed the notification fires at
    // swipe-kill), and a swipe-kill is SIGKILL. A migration whose durability
    // rests on an unproven lifecycle event is fragile by construction.
    //
    // gGameInited is not checked here, unlike pc_main.c:594's save: this runs
    // after configfile_load() and the file is already on disk, so there is no
    // half-initialized config to flatten.
    configfile_save(configfile_name());

    printf("[hz] framerate policy APPLIED (rev %u): framerate_mode %u -> %u (MANUAL), "
           "frame_limit %u -> %u, from a MEASURED panel rate of %u Hz (cap %u). "
           "Saved to %s. This runs once per config; the user can change it back in "
           "Display -> Framerate Mode and it will never be overwritten again.\n",
           SM64_VISION_FRAMERATE_REV, wasMode, (unsigned int)RRM_MANUAL,
           wasLimit, limit, hz, SM64_VISION_HZ_CAP, configfile_name());
    fflush(stdout);
}

#pragma mark - Engine entry point

unsigned int sm64_vision_hz_poll(void) {
    static bool started = false;
    static bool policyDone = false;

    if (!started) {
        started = true;
        // Started lazily from the first RENDERED frame rather than from a
        // constructor: a CADisplayLink created before UIApplication exists has
        // no display to attach to. The first call to this function is from
        // produce_interpolation_frames_and_delay(), which is after gfx_init(),
        // which is after SDL has a window — the earliest moment the question is
        // answerable.
        pthread_t th;
        if (pthread_create(&th, NULL, hz_sampler_thread, NULL) == 0) {
            pthread_detach(th);
            printf("[hz] panel-rate sampler started (fallback %u Hz until it settles)\n",
                   SM64_VISION_HZ_FALLBACK);
        } else {
            printf("[hz] FAILED to start panel-rate sampler thread — using fallback %u Hz\n",
                   SM64_VISION_HZ_FALLBACK);
        }
        fflush(stdout);
    }

    if (!policyDone && sm64_vision_hz_settled()) {
        // Runs on the render thread (this function's only caller is
        // pc_main.c's get_display_refresh_rate()), which is also the only thread
        // that reads configFramerateMode/configFrameLimit for pacing — so the
        // policy's writes are never racing the reads they affect.
        policyDone = true;
        sm64_vision_hz_apply_policy();
    }

    return Sm64Ios_VisionPanelHz();
}

#endif // SM64_VISION_HZ
