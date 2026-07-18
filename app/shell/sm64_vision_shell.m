//
//  sm64_vision_shell.m — visionOS remote-diagnosis floor + Files data path
//
//  Charter ground rule 5: "Remote diagnosis floor before device work: crash
//  handler -> Documents/crash.txt (TIMESTAMP entries; do not let a secondary
//  crash overwrite the primary), spdlog file logs, and a launch-gated TCP
//  console bridge (pick a port != 8765-8769; those are taken) with at least:
//  ping, thermal, logtail N, crashlog, drawable, and input injection. NEVER
//  dispatch_sync to the main queue from a bridge handler — the game loop owns
//  the main thread and it deadlocks; cache values from a main-thread poll into
//  volatiles and read those."
//
//  Charter ground rule 6: "Never delete user data. Synchronous config save on
//  resign-active (swipe-kill is SIGKILL). Files-app visibility:
//  UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace + seed a readme
//  into Documents at first launch (an empty Documents dir hides the app in
//  Files)."
//
//  TWO PLACES THIS DEVIATES FROM THE REFERENCE, ON PURPOSE:
//
//  1. "spdlog file logs" is SoH's shape, not coopdx's. coopdx has NO file
//     logging at all — src/pc/debuglog.h is a set of printf() macros straight
//     to stdout, and there is no spdlog anywhere in the tree. On a SpringBoard
//     (OTA) launch stdout goes nowhere, so `logtail` would have had nothing to
//     read and the whole engine log would be invisible on the one device that
//     matters. So this file TEES stdout+stderr into Documents/logs/ instead of
//     inventing a parallel logging system the engine would never call. The tee
//     starts from a constructor, so it captures from process spawn — which also
//     makes its first line a launch beacon (guide 1.6) for free.
//
//  2. Shipwright's crash handler (app/ios/SohIosShell.m:242) opens crash.txt
//     O_TRUNC. That is exactly the behaviour this task forbids: the SECOND
//     crash silently erases the FIRST, and the first is the one that matters
//     (a secondary crash is very often just fallout from the primary). We
//     append instead, and cap the file rather than truncating it, so what
//     survives is always the OLDEST entry. See shell_crash_handler().
//

#include "sm64_vision_shell.h"

#ifdef SM64_VISION_SHELL

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <arpa/inet.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <SDL2/SDL.h>

#include "pc/configfile.h"
#include "pc/platform.h"

// pc_main.c's own guard for "the config in memory is real". Declared here
// rather than by including pc/pc_main.h, which drags in gfx_opengl.h — a header
// this target compiles out entirely (SM64_NO_OPENGL, M-15 trap 3).
extern bool gGameInited;

// Published by the Metal backend (app/gfx/gfx_metal.mm, overlay 0001). These
// exist SPECIFICALLY so a bridge handler can answer `drawable` without touching
// the main thread — see shell_handle_line().
extern volatile float gSm64GpuMs;
extern volatile int gSm64DrawableW;
extern volatile int gSm64DrawableH;

// Published by the immersive loop (app/vision3d/sm64_immersive.m, overlay 0011).
// Same contract as the drawable volatiles above: written on the compositor thread
// once the panel is placed, read HERE so the `fidelity` verb never touches the
// main thread. The supersample ratio (eye texture px / panel footprint px) is the
// guide's §3 crispness number — vkQuake's device optimum was ~2.7x/2.2x.
extern volatile int gSm64FidDrawableW, gSm64FidDrawableH;
extern volatile int gSm64FidEyeW, gSm64FidEyeH;
extern volatile float gSm64FidFovH, gSm64FidFovV;
extern volatile float gSm64FidFootW, gSm64FidFootH;
extern volatile float gSm64FidSSH, gSm64FidSSV;

// The bridge port. 8765-8769 are taken by sibling ports (charter), and a survey
// of the other ports on this machine found 8771/8772 (dhewm3) and 8783
// (q2repro) also in use, plus 8666 for the OTA server. 8791 is clear of all of
// them.
#define SM64_BRIDGE_PORT 8791

// Bounded so a crash LOOP cannot fill the user's storage. Because entries are
// APPENDED, hitting the cap drops the newest entries and keeps the oldest —
// which is the primary crash, i.e. the one worth having.
#define SM64_CRASH_LOG_MAX (256 * 1024)

#pragma mark - Paths

// Both built once, at constructor time, and then treated as read-only. The
// crash handler cannot build them itself: snprintf() and NSString are not
// async-signal-safe, and a crash handler that crashes reports nothing.
static char s_docs[1024];
static char s_crash_path[1200];
static char s_log_path[1200];

static void shell_init_paths(void) {
    const char *home = getenv("HOME");
    snprintf(s_docs, sizeof(s_docs), "%s/Documents", home ? home : "/tmp");
    snprintf(s_crash_path, sizeof(s_crash_path), "%s/crash.txt", s_docs);
}

#pragma mark - Async-signal-safe primitives

// Everything in this section is callable from a signal handler. That rules out
// snprintf, malloc, NSLog, stdio — all of which can take a lock the crashing
// thread may already hold, turning a diagnosable crash into a hang.

static void shell_wr(int fd, const char *s) {
    if (s == NULL) { return; }
    size_t n = strlen(s);
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        if (w <= 0) { return; }
        s += w;
        n -= (size_t)w;
    }
}

// Unsigned -> decimal, zero-padded to `pad`. Returns bytes written to buf.
static int shell_utoa(unsigned long long v, char *buf, int pad) {
    char tmp[24];
    int n = 0;
    do { tmp[n++] = (char)('0' + (v % 10)); v /= 10; } while (v != 0 && n < 20);
    while (n < pad) { tmp[n++] = '0'; }
    for (int i = 0; i < n; i++) { buf[i] = tmp[n - 1 - i]; }
    buf[n] = '\0';
    return n;
}

static void shell_wr_u(int fd, unsigned long long v) {
    char b[24];
    shell_utoa(v, b, 0);
    shell_wr(fd, b);
}

static void shell_wr_hex(int fd, unsigned long long v) {
    static const char *digits = "0123456789abcdef";
    char b[19];
    b[0] = '0'; b[1] = 'x';
    for (int i = 0; i < 16; i++) { b[2 + i] = digits[(v >> ((15 - i) * 4)) & 0xF]; }
    b[18] = '\0';
    shell_wr(fd, b);
}

// Howard Hinnant's civil_from_days: pure integer arithmetic, so unlike
// localtime_r/gmtime_r (which can touch the tz database and take locks) it is
// genuinely safe to call from a signal handler. This is what lets a crash entry
// carry a real TIMESTAMP rather than a bare epoch count.
static void shell_civil_from_days(long long z, int *y, unsigned *m, unsigned *d) {
    z += 719468;
    long long era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned long long doe = (unsigned long long)(z - era * 146097);
    unsigned long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long long yr = (long long)yoe + era * 400;
    unsigned long long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned long long mp = (5 * doy + 2) / 153;
    unsigned long long dy = doy - (153 * mp + 2) / 5 + 1;
    unsigned long long mth = mp < 10 ? mp + 3 : mp - 9;
    *y = (int)(yr + (mth <= 2));
    *m = (unsigned)mth;
    *d = (unsigned)dy;
}

// "2026-07-15T04:12:33Z" into buf (needs >= 21 bytes). UTC on purpose: the
// device's timezone is not knowable from here, and a crash log correlated
// against our own build/test timestamps wants one unambiguous clock.
static void shell_timestamp(char *buf) {
    time_t t = time(NULL); // async-signal-safe
    long long secs = (long long)t;
    long long days = secs / 86400;
    long long rem = secs % 86400;
    if (rem < 0) { rem += 86400; days -= 1; }
    int y; unsigned mo, d;
    shell_civil_from_days(days, &y, &mo, &d);
    char *p = buf;
    p += shell_utoa((unsigned long long)y, p, 4); *p++ = '-';
    p += shell_utoa(mo, p, 2); *p++ = '-';
    p += shell_utoa(d, p, 2); *p++ = 'T';
    p += shell_utoa((unsigned long long)(rem / 3600), p, 2); *p++ = ':';
    p += shell_utoa((unsigned long long)((rem % 3600) / 60), p, 2); *p++ = ':';
    p += shell_utoa((unsigned long long)(rem % 60), p, 2);
    *p++ = 'Z';
    *p = '\0';
}

#pragma mark - Crash handler -> Documents/crash.txt

static volatile sig_atomic_t s_in_handler = 0;

static const char *shell_signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGABRT: return "SIGABRT";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default:      return "SIG?";
    }
}

static void shell_crash_handler(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;

    // Re-entrancy: a crash INSIDE the handler must not restart the handler.
    // Critically it must also not re-open the file — the primary entry is
    // already on disk and fsync'd by the time anything else can run, and the
    // one job of this branch is to not jeopardise it.
    if (s_in_handler) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    s_in_handler = 1;

    // O_APPEND, never O_TRUNC. This is the whole difference from the reference
    // implementation: with O_TRUNC a secondary crash erases the primary, and
    // the primary is the one that explains the failure. Appending means the
    // file accumulates TIMESTAMP-delimited entries in the order they happened.
    int fd = open(s_crash_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        // Cap, rather than truncate. Combined with O_APPEND this keeps the
        // OLDEST entries when the cap is hit, so a crash loop can never push
        // the primary out of the file.
        off_t sz = lseek(fd, 0, SEEK_END);
        if (sz >= 0 && sz < SM64_CRASH_LOG_MAX) {
            char ts[24];
            shell_timestamp(ts);

            shell_wr(fd, "\n==== CRASH ");
            shell_wr(fd, ts);
            shell_wr(fd, " sig=");
            shell_wr_u(fd, (unsigned long long)sig);
            shell_wr(fd, " ");
            shell_wr(fd, shell_signal_name(sig));
            shell_wr(fd, " pid=");
            shell_wr_u(fd, (unsigned long long)getpid());
            // Which thread died matters here more than on the reference ports:
            // the frame map names the NETWORK thread (CoopNet/juice) as the
            // novel risk this port carries and no sibling did, and the audio
            // thread as the recurring SEGV class. "main or not" is the first
            // bit of that question and it is answerable async-signal-safely.
            shell_wr(fd, pthread_main_np() ? " thread=main" : " thread=other");
            if (info != NULL) {
                shell_wr(fd, " fault_addr=");
                shell_wr_hex(fd, (unsigned long long)(uintptr_t)info->si_addr);
                shell_wr(fd, " code=");
                shell_wr_u(fd, (unsigned long long)info->si_code);
            }
            shell_wr(fd, " ====\n");

            void *frames[64];
            int n = backtrace(frames, 64);
            // backtrace_symbols_fd, NOT backtrace_symbols: the latter mallocs,
            // and malloc in a signal handler after a heap corruption deadlocks
            // or re-crashes. This one writes straight to the fd.
            backtrace_symbols_fd(frames, n, fd);
        } else {
            shell_wr(fd, "\n==== CRASH (log capped; primary entries above preserved) ====\n");
        }
        fsync(fd); // swipe-kill is SIGKILL and we are about to re-raise: flush now
        close(fd);
    }

    // Restore and re-raise so the OS still produces its own .ips crash report.
    // Ours is a convenience for the remote case, not a replacement for Apple's.
    signal(sig, SIG_DFL);
    raise(sig);
}

static void shell_install_crash_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = shell_crash_handler;
    sigemptyset(&sa.sa_mask);
    // SA_SIGINFO for si_addr (the faulting address is most of the value of a
    // SIGSEGV report). SA_ONSTACK so a stack-overflow crash — which has no
    // usable stack left — can still run the handler and be reported.
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;

    static const int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
}

#pragma mark - stdout/stderr tee -> Documents/logs/

static int s_orig_stdout = -1;
static int s_log_fd = -1;

static void *shell_log_pump(void *arg) {
    int rfd = (int)(intptr_t)arg;
    char buf[4096];
    for (;;) {
        ssize_t n = read(rfd, buf, sizeof(buf));
        if (n > 0) {
            // Both destinations, best-effort, never blocking on either: losing
            // a log line must never be able to stall the game loop.
            if (s_log_fd >= 0) { (void)!write(s_log_fd, buf, (size_t)n); }
            if (s_orig_stdout >= 0) { (void)!write(s_orig_stdout, buf, (size_t)n); }
        } else if (n == 0) {
            return NULL; // write end closed — cannot happen in practice
        } else if (errno != EINTR) {
            return NULL;
        }
    }
}

// Tee stdout+stderr into Documents/logs/sm64-<timestamp>.log while preserving
// the original fds, so `simctl launch --console-pty` still shows everything.
//
// THE HAZARD, AND WHY THIS IS SHAPED THE WAY IT IS. A pipe whose reader stalls
// blocks the WRITER once the ~64 KB kernel buffer fills — and the writer here
// is the game's main thread calling printf(). A logging facility that can hang
// the render loop is worse than no logging at all. Two defences:
//   1. the pump thread has no path that blocks (it only ever read()s the pipe
//      and write()s two fds, ignoring errors), and
//   2. the write ends are O_NONBLOCK, so if the pump ever did stall, printf
//      drops bytes with EAGAIN instead of parking the frame. Dropped log lines
//      under a pathological burst is a trade we will take every time.
static void shell_start_log_tee(void) {
    char ts[24];
    shell_timestamp(ts);

    char dir[1200];
    snprintf(dir, sizeof(dir), "%s/logs", s_docs);
    mkdir(dir, 0755);
    snprintf(s_log_path, sizeof(s_log_path), "%s/sm64-%s.log", dir, ts);

    s_log_fd = open(s_log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (s_log_fd < 0) { return; }

    int fds[2];
    if (pipe(fds) != 0) { close(s_log_fd); s_log_fd = -1; return; }

    s_orig_stdout = dup(STDOUT_FILENO);

    fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL, 0) | O_NONBLOCK);
    dup2(fds[1], STDOUT_FILENO);
    dup2(fds[1], STDERR_FILENO);
    close(fds[1]);

    pthread_t th;
    if (pthread_create(&th, NULL, shell_log_pump, (void *)(intptr_t)fds[0]) != 0) {
        // Could not start the pump: restore stdout rather than leave the game
        // writing into a pipe nobody drains (which is the hang above).
        if (s_orig_stdout >= 0) { dup2(s_orig_stdout, STDOUT_FILENO); dup2(s_orig_stdout, STDERR_FILENO); }
        close(fds[0]);
        close(s_log_fd);
        s_log_fd = -1;
        return;
    }
    pthread_detach(th);

    // Line-buffered: an unflushed buffer is lost on SIGKILL, and swipe-kill is
    // SIGKILL. The cost is a write() per line, which at coopdx's log volume is
    // nothing.
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

#pragma mark - Documents readme seed + import hygiene

// THIS IS THE ONE THAT GATES THE WHOLE APP BEING USABLE.
//
// The ROM is a RUNTIME input (Q-002/M-3): rom_checker.cpp scans the write path
// for a *.z64, md5-gates it, and render_rom_setup_screen() blocks the game load
// until it finds one. The user's ONLY way to put a ROM there is Files ->
// On My Apple Vision Pro -> SM64CoopDX. And an app whose Documents directory is
// EMPTY does not appear in Files at all. So without this seed the app is
// unwinnable-by-construction: it demands a ROM through the one door it also
// hides. UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace are already
// set (M-19) — necessary, but not sufficient on their own.
static NSString *shell_readme_text(void) {
    return
    @"SM64CoopDX — Apple Vision Pro\n"
    @"=============================\n"
    @"\n"
    @"This folder is the game's data folder. You are looking at it through\n"
    @"Files -> On My Apple Vision Pro -> SM64CoopDX.\n"
    @"\n"
    @"\n"
    @"1. THE GAME NEEDS YOUR OWN SM64 ROM\n"
    @"-----------------------------------\n"
    @"The app ships with NO game data. Until you supply a ROM the game will\n"
    @"sit on the \"ROM setup\" screen and go no further.\n"
    @"\n"
    @"  Drop your ROM file into THIS folder, next to this readme.\n"
    @"\n"
    @"It must be the US (NTSC) release of Super Mario 64, unmodified:\n"
    @"\n"
    @"  name  baserom.us.z64   (any *.z64 filename works — the game scans\n"
    @"                          this folder for one and checks its contents)\n"
    @"  size  8388608 bytes (8 MB exactly)\n"
    @"  md5   20b854b239203baf6c961b850a4a51a2\n"
    @"\n"
    @"The game checks that md5 itself and will REJECT anything else — a EU/JP\n"
    @"ROM, a byte-swapped (.n64/.v64) dump, or a romhack will not be accepted.\n"
    @"If your file is rejected, it is almost always one of those three.\n"
    @"\n"
    @"Nothing is uploaded anywhere. The ROM stays in this folder on-device.\n"
    @"\n"
    @"\n"
    @"2. WHERE THE GAME PUTS THINGS (all in this folder)\n"
    @"--------------------------------------------------\n"
    @"  sm64config.txt        your settings. Saved when you leave the app.\n"
    @"  sm64config-backup.txt previous settings, kept as a safety net.\n"
    @"  save_file.sav         your save data. DO NOT DELETE.\n"
    @"  crash.txt             written ONLY if the game crashes (see below).\n"
    @"  logs/                 a log per launch: sm64-<date>.log\n"
    @"  vision-perf.log       frame timing / thermal samples.\n"
    @"  mods/                 drop Lua mods here.\n"
    @"\n"
    @"\n"
    @"3. IF SOMETHING GOES WRONG\n"
    @"--------------------------\n"
    @"crash.txt is the useful one. It appends a timestamped entry per crash\n"
    @"and never overwrites an earlier one, so the FIRST crash is preserved\n"
    @"even if the game then crashes again. Send that file, plus the newest\n"
    @"file in logs/.\n"
    @"\n"
    @"You can delete crash.txt and anything in logs/ whenever you like; the\n"
    @"game will make new ones. Do not delete save_file.sav or your ROM.\n"
    @"\n"
    @"\n"
    @"4. REMOTE CONSOLE (only if you are asked to turn it on)\n"
    @"------------------------------------------------------\n"
    @"For debugging, the game can listen on TCP port 8791 for a few commands\n"
    @"(ping / thermal / drawable / logtail / crashlog / key). It is OFF unless\n"
    @"you switch it on, and it only ever listens on your local network.\n"
    @"\n"
    @"To turn it on: create an empty file called  console_enabled.txt  in this\n"
    @"folder (Files can do this), then relaunch the game.\n"
    @"To turn it off: delete that file and relaunch.\n"
    @"\n"
    @"\n"
    @"This readme is recreated automatically if you delete it. That is not an\n"
    @"accident: an app with an empty data folder becomes INVISIBLE in Files,\n"
    @"and you would lose the only way to give the game its ROM.\n";
}

static void shell_seed_readme(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = [NSString stringWithUTF8String:s_docs];
    NSString *path = [docs stringByAppendingPathComponent:@"READ ME FIRST.txt"];

    // Recreated whenever absent, not just on a literal first launch: the failure
    // this guards against ("Documents is empty, so the app vanishes from Files,
    // so the user cannot supply a ROM") is reachable at ANY launch, e.g. after
    // someone tidies the folder. It is a ~3 KB write on a path that is already
    // doing file I/O.
    if (![fm fileExistsAtPath:path]) {
        NSError *err = nil;
        [fm createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        BOOL ok = [shell_readme_text() writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        printf("[shell] readme seed: %s (%s)\n", ok ? "written" : "FAILED",
               ok ? path.fileSystemRepresentation : err.localizedDescription.UTF8String);
    }
}

// Sibling ports saw user-imported files land root-owned 0700, which the game
// then cannot read — presenting as "I dropped the ROM in and it still says no
// ROM." Cheap to normalise, so we do it every launch and LOG when we actually
// change something (a silent fixup teaches nobody anything).
static void shell_normalize_permissions(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = [NSString stringWithUTF8String:s_docs];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:docs error:nil];
    for (NSString *name in entries) {
        NSString *p = [docs stringByAppendingPathComponent:name];
        struct stat st;
        if (stat(p.fileSystemRepresentation, &st) != 0) { continue; }
        mode_t want = S_ISDIR(st.st_mode) ? 0755 : 0644;
        mode_t have = st.st_mode & 07777;
        if ((have & want) != want) {
            if (chmod(p.fileSystemRepresentation, want) == 0) {
                printf("[shell] normalized perms %04o -> %04o on %s\n", have, want, name.UTF8String);
            } else {
                printf("[shell] could NOT normalize perms on %s: %s\n", name.UTF8String, strerror(errno));
            }
        }
    }
}

#pragma mark - Config save on resign-active

// Swipe-kill is SIGKILL: no atexit, no signal, no chance to write anything. So
// pc_main.c:543's `if (gGameInited) { configfile_save(configfile_name()); }` —
// the desktop write-on-quit — NEVER runs on this platform, and every setting the
// user changed is silently lost. This is the same call, moved to the last moment
// the OS still lets us run code.
static void shell_save_config_now(const char *why) {
    if (!gGameInited) {
        // Before the game is up there is nothing real to save, and saving would
        // write DEFAULTS over the user's file. "Never delete user data."
        printf("[shell] %s: config not saved (game not inited yet)\n", why);
        return;
    }
    configfile_save(configfile_name());
    printf("[shell] %s: config saved synchronously\n", why);
    fflush(stdout);
}

static void shell_install_lifecycle_observers(void) {
    // Synchronously, on the notification, on the main thread — NOT dispatched.
    // A dispatch here would be a bet that the queue drains before the OS kills
    // us, and that bet loses exactly when it matters.
    //
    // Both notifications, because they answer different failures:
    //   WillResignActive     — fires first, and fires for the swipe-kill path.
    //   DidEnterBackground   — the belt to that braces.
    // Saving twice is harmless (configfile_save is a plain rewrite).
    void (^save)(NSNotification *) = ^(NSNotification *n) {
        shell_save_config_now(n.name.UTF8String);
    };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                    object:nil
                                                     queue:nil // nil == deliver synchronously on the posting thread
                                                usingBlock:save];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:save];
    printf("[shell] lifecycle observers registered (WillResignActive + DidEnterBackground -> configfile_save)\n");
}

#pragma mark - Thermal

static int shell_thermal_state(void) {
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal:  return 0;
        case NSProcessInfoThermalStateFair:     return 1;
        case NSProcessInfoThermalStateSerious:  return 2;
        case NSProcessInfoThermalStateCritical: return 3;
    }
    return -1;
}

#pragma mark - Input injection

// coopdx's binds live in DirectInput scancode space (configfile.c:152-183:
// A = 0x26 = DIK_L, Start = 0x39 = DIK_SPACE, stick = 0x11/0x1E/0x1F/0x20 =
// WASD, C-buttons = 0x148..0x14D = arrows). gfx_sdl.c:322 converts an incoming
// SDL scancode with translate_sdl_scancode() before handing it to the keyboard
// controller, so the correct thing to inject is an ordinary SDL_KEYDOWN with an
// SDL scancode — the engine then does its own translation exactly as it would
// for a real Bluetooth keyboard. Nothing here reaches behind the engine's back.
static const struct { const char *name; SDL_Scancode sc; } kInjectKeys[] = {
    { "a",      SDL_SCANCODE_L },       // DIK_L      0x26
    { "b",      SDL_SCANCODE_COMMA },   // DIK_COMMA  0x33
    { "x",      SDL_SCANCODE_I },       // DIK_I      0x17
    { "y",      SDL_SCANCODE_M },       // DIK_M      0x32
    { "z",      SDL_SCANCODE_K },       // DIK_K      0x25
    { "l",      SDL_SCANCODE_LSHIFT },  // DIK_LSHIFT 0x2A
    { "r",      SDL_SCANCODE_RSHIFT },  // DIK_RSHIFT 0x36
    { "start",  SDL_SCANCODE_SPACE },   // DIK_SPACE  0x39
    { "up",     SDL_SCANCODE_W },       // DIK_W      0x11  (stick up)
    { "down",   SDL_SCANCODE_S },       // DIK_S      0x1F  (stick down)
    { "left",   SDL_SCANCODE_A },       // DIK_A      0x1E  (stick left)
    { "right",  SDL_SCANCODE_D },       // DIK_D      0x20  (stick right)
    { "cup",    SDL_SCANCODE_UP },      // DIK_UP     0x148
    { "cdown",  SDL_SCANCODE_DOWN },    // DIK_DOWN   0x150
    { "cleft",  SDL_SCANCODE_LEFT },    // DIK_LEFT   0x14B
    { "cright", SDL_SCANCODE_RIGHT },   // DIK_RIGHT  0x14D
    { "enter",  SDL_SCANCODE_RETURN },  // DIK_RETURN 0x1C
    { "esc",    SDL_SCANCODE_ESCAPE },  // DIK_ESCAPE 0x01
};

static void shell_push_key(SDL_Scancode sc, bool down) {
    SDL_Event e;
    memset(&e, 0, sizeof(e));
    e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.key.repeat = 0;
    e.key.keysym.scancode = sc;
    e.key.keysym.sym = SDL_GetKeyFromScancode(sc);
    SDL_PushEvent(&e); // SDL's event queue is mutex-protected: thread-safe.
}

static void shell_inject_key(SDL_Scancode sc, int ms) {
    shell_push_key(sc, true);
    // The release is scheduled on a GLOBAL queue, never the main queue.
    //
    // Charter ground rule 5 forbids dispatch_sync to main because the game loop
    // owns that thread. The reference shell uses dispatch_after(MAIN) for its
    // key releases, and that would be a real bug HERE: coopdx's main thread sits
    // inside `while (true) { gWindowApi->main_loop(produce_one_frame); }`
    // (pc_main.c:708) and only re-enters the run loop incidentally, deep inside
    // SDL's event pump. Scheduling a release there makes "does the button ever
    // come back up?" depend on SDL internals. A global queue does not care what
    // the main thread is doing.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        shell_push_key(sc, false);
    });
}

#pragma mark - Remote console bridge (launch-gated TCP)

static NSString *shell_tail_file(NSString *path, int lines) {
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) { return nil; }
    NSArray *all = [content componentsSeparatedByString:@"\n"];
    NSUInteger start = all.count > (NSUInteger)lines ? all.count - (NSUInteger)lines : 0;
    return [[all subarrayWithRange:NSMakeRange(start, all.count - start)] componentsJoinedByString:@"\n"];
}

// NOTHING in here may touch the main thread. Every value it reports is either
// read from a volatile the render thread publishes, read from the filesystem, or
// pushed onto SDL's (thread-safe) event queue.
static NSString *shell_handle_line(NSString *line) {
    NSMutableArray<NSString *> *tok = [NSMutableArray array];
    for (NSString *t in [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                            componentsSeparatedByString:@" "]) {
        if (t.length > 0) { [tok addObject:t]; }
    }
    if (tok.count == 0) { return @"err empty"; }
    NSString *cmd = tok[0].lowercaseString;

    if ([cmd isEqualToString:@"ping"]) {
        return @"ok pong";
    }
    if ([cmd isEqualToString:@"help"]) {
        return @"ok verbs: ping | thermal | drawable | fidelity | perf | crashlog | "
               @"logtail N | key NAME [ms] | keys | gameinited | resign | "
               @"crash segv|abort | help";
    }
    if ([cmd isEqualToString:@"thermal"]) {
        return [NSString stringWithFormat:@"ok thermal=%d", shell_thermal_state()];
    }
    if ([cmd isEqualToString:@"drawable"]) {
        // The volatiles gfx_metal.mm publishes from the render path (M-21) —
        // read directly, precisely so this answer costs the main thread nothing.
        return [NSString stringWithFormat:@"ok drawable=%dx%d gpu_ms=%.3f",
                         gSm64DrawableW, gSm64DrawableH, (double)gSm64GpuMs];
    }
    if ([cmd isEqualToString:@"fidelity"]) {
        // The 3D supersample ratio, published by the immersive loop. Answers the
        // guide's §3 crispness question live over the bridge (batch 3 item 2):
        // ratio = eye texture px / panel footprint px in the drawable. 0 until 3D
        // is entered and the panel is placed. The SIM's optics differ (~1.2x per
        // M-41), so on the sim the VALUE is the sim's — the math is what this
        // verb proves; the real ratio is read off the device.
        if (gSm64FidEyeW <= 0) {
            return @"ok (no fidelity data yet — enter 3D and let the panel place)";
        }
        return [NSString stringWithFormat:
            @"ok drawable=%dx%d/eye eye_tex=%dx%d fov=%.1fx%.1f footprint=%.0fx%.0f "
             @"supersample=%.2fx/%.2fx",
            gSm64FidDrawableW, gSm64FidDrawableH, gSm64FidEyeW, gSm64FidEyeH,
            (double)gSm64FidFovH, (double)gSm64FidFovV,
            (double)gSm64FidFootW, (double)gSm64FidFootH,
            (double)gSm64FidSSH, (double)gSm64FidSSV];
    }
    if ([cmd isEqualToString:@"gameinited"]) {
        return [NSString stringWithFormat:@"ok gameInited=%d", gGameInited ? 1 : 0];
    }
    if ([cmd isEqualToString:@"resign"]) {
        // Post the real UIApplicationWillResignActiveNotification, to exercise
        // the config-save path.
        //
        // WHAT THIS DOES AND DOES NOT PROVE, stated plainly because the
        // distinction matters. It proves our observer is registered, that it
        // runs, and that configfile_save() works from a notification callback
        // while the game loop owns the main thread. It does NOT prove that
        // visionOS itself posts this notification at swipe-kill time — that is
        // UIKit's half, and no simctl verb backgrounds an app (on visionOS,
        // launching another app does not even resign ours: windows coexist).
        // That half is a device-test item and is recorded as such.
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification
                                                          object:UIApplication.sharedApplication];
        return @"ok resign posted (synthetic — proves the handler, not UIKit's delivery)";
    }
    if ([cmd isEqualToString:@"perf"]) {
        NSString *p = [NSString stringWithFormat:@"%s/vision-perf.log", s_docs];
        NSString *t = shell_tail_file(p, 3);
        return t.length ? [@"ok\n" stringByAppendingString:t] : @"ok (no vision-perf.log yet)";
    }
    if ([cmd isEqualToString:@"crashlog"]) {
        NSString *p = [NSString stringWithUTF8String:s_crash_path];
        NSString *c = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        return c.length ? [@"ok\n" stringByAppendingString:c] : @"ok (no crash.txt — nothing has crashed)";
    }
    if ([cmd isEqualToString:@"logtail"]) {
        int n = tok.count >= 2 ? MAX(1, MIN(500, tok[1].intValue)) : 80;
        NSString *p = [NSString stringWithUTF8String:s_log_path];
        NSString *t = shell_tail_file(p, n);
        return t.length ? [@"ok\n" stringByAppendingString:t] : @"ok (no log yet)";
    }
    if ([cmd isEqualToString:@"keys"]) {
        NSMutableString *out = [NSMutableString stringWithString:@"ok "];
        for (size_t i = 0; i < sizeof(kInjectKeys) / sizeof(kInjectKeys[0]); i++) {
            [out appendFormat:@"%s ", kInjectKeys[i].name];
        }
        return out;
    }
    if ([cmd isEqualToString:@"key"] && tok.count >= 2) {
        NSString *want = tok[1].lowercaseString;
        int ms = tok.count >= 3 ? MAX(16, MIN(5000, tok[2].intValue)) : 120;
        for (size_t i = 0; i < sizeof(kInjectKeys) / sizeof(kInjectKeys[0]); i++) {
            if ([want isEqualToString:[NSString stringWithUTF8String:kInjectKeys[i].name]]) {
                shell_inject_key(kInjectKeys[i].sc, ms);
                return [NSString stringWithFormat:@"ok key %@ %dms", want, ms];
            }
        }
        return @"err unknown key (try: keys)";
    }
    if ([cmd isEqualToString:@"crash"]) {
        // Deliberately crash the process, to prove the crash handler works.
        //
        // Shipping a "crash the app" verb deserves justification rather than a
        // shrug. The reasoning: this handler exists ENTIRELY for a device we
        // cannot attach a debugger to, and an untested crash handler is a
        // liability — it is code that only ever runs at the worst possible
        // moment, so "it compiles" is not evidence it works. The alternative is
        // shipping it unexercised on the device and hoping. This verb is the
        // only thing that turns "the crash handler should work on the Vision
        // Pro" into a measurement.
        //
        // It is unreachable in normal use: the bridge itself is off unless
        // SM64_CONSOLE is set (impossible from SpringBoard) or the user
        // deliberately creates Documents/console_enabled.txt and relaunches.
        NSString *kind = tok.count >= 2 ? tok[1].lowercaseString : @"segv";
        if ([kind isEqualToString:@"abort"]) {
            abort();
        }
        // volatile so the null deref survives the optimiser (-O2 is entitled to
        // delete a plain *(int*)0 = 1 as UB, and then this verb would silently
        // do nothing — the exact failure a test is supposed to catch).
        volatile int *p = NULL;
        *p = 1;
        return @"err crash failed (unreachable)";
    }
    return @"err unknown command (try: help)";
}

static void shell_bridge_serve(void) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { NSLog(@"[shell] bridge socket failed: %d", errno); return; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(SM64_BRIDGE_PORT);

    bool bound = false;
    for (int i = 0; i < 10 && !bound; i++) { // bind retry (sibling-port pattern)
        bound = bind(srv, (struct sockaddr *)&addr, sizeof(addr)) == 0;
        if (!bound) { usleep(500 * 1000); }
    }
    if (!bound || listen(srv, 4) != 0) {
        NSLog(@"[shell] bridge bind/listen failed on :%d: %d", SM64_BRIDGE_PORT, errno);
        close(srv);
        return;
    }
    printf("[shell] console bridge listening on :%d\n", SM64_BRIDGE_PORT);
    fflush(stdout);

    for (;;) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) { continue; }
        FILE *f = fdopen(cli, "r");
        char line[1024];
        while (f != NULL && fgets(line, sizeof(line), f) != NULL) {
            @autoreleasepool {
                NSString *in = [NSString stringWithUTF8String:line] ?: @"";
                NSString *resp = shell_handle_line(in);
                dprintf(cli, "%s\n", resp.UTF8String);
            }
        }
        if (f != NULL) { fclose(f); } else { close(cli); }
    }
}

static void shell_start_bridge(void) {
    // Launch-gated two ways, matching the reference shell:
    //   SM64_CONSOLE=1               tool launches (simctl / devicectl)
    //   Documents/console_enabled    creatable in Files, so a user on an OTA
    //   Documents/console_enabled.txt  build can opt in with no computer at all
    //                                (.txt because Files cannot easily create an
    //                                 extensionless file)
    // Default OFF: an always-listening socket on someone's headset is not a
    // thing to ship.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = [NSString stringWithUTF8String:s_docs];
    bool fileGate = [fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"console_enabled"]] ||
                    [fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"console_enabled.txt"]];
    bool envGate = getenv("SM64_CONSOLE") != NULL;
    if (!envGate && !fileGate) {
        printf("[shell] console bridge disabled (set SM64_CONSOLE=1 or create Documents/console_enabled.txt)\n");
        return;
    }
    printf("[shell] console bridge enabled via %s\n", envGate ? "SM64_CONSOLE env" : "Documents/console_enabled");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ shell_bridge_serve(); });
}

#pragma mark - Entry points

// Before main(), before coopdx's ~12,100 rom_assets constructors, before SDL.
// The crash handler and the log tee are installed here rather than in
// sm64_vision_shell_init() so that a crash or a log line from the earliest part
// of startup — the part we cannot see on a remote device and the part most
// likely to break first on a new platform — is still captured.
__attribute__((constructor)) static void sm64_vision_shell_early(void) {
    shell_init_paths();
    shell_install_crash_handler();
    shell_start_log_tee();

    // Doubles as the guide's launch beacon (§1.6): the first line in the log
    // proves the process spawned and got this far, which is the single most
    // useful bit when an OTA build dies silently before it can draw anything.
    char ts[24];
    shell_timestamp(ts);
    printf("[shell] === process spawned %s === (crash=%s log=%s)\n", ts, s_crash_path, s_log_path);
    fflush(stdout);
}

void sm64_vision_shell_init(void) {
    static bool done = false;
    // The scene disconnect/reconnect trap (charter post-guide traps): UIKit can
    // re-enter the launch path through more than one route, and coopdx's own
    // main() is the thing being re-entered. Cheap insurance against seeding,
    // observing and listening twice.
    if (done) { return; }
    done = true;

    shell_seed_readme();
    shell_normalize_permissions();
    shell_install_lifecycle_observers();
    shell_start_bridge();
}

#endif // SM64_VISION_SHELL
