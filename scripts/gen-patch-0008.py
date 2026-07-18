#!/usr/bin/env python3
"""Overlay patch 0008: the visionOS remote-diagnosis shell + Files data path.

WHAT IT ADDS
  - src/pc/sm64_vision_shell.{h,m} (new files, packaged from app/shell/ per
    D-010 — the source of truth is app/shell/, NOT this patch).
  - CMakeLists.txt: the .m into the target, visionOS-only.
  - pc_main.c: one hook — sm64_vision_shell_init() right after configfile_load().

WHY (charter ground rules 5 and 6). Rule 5: "Remote diagnosis floor before
device work: crash handler -> Documents/crash.txt (TIMESTAMP entries; do not let
a secondary crash overwrite the primary), spdlog file logs, and a launch-gated
TCP console bridge (pick a port != 8765-8769; those are taken) with at least:
ping, thermal, logtail N, crashlog, drawable, and input injection." Rule 6:
"Never delete user data. Synchronous config save on resign-active (swipe-kill is
SIGKILL). Files-app visibility: ... seed a readme into Documents at first launch
(an empty Documents dir hides the app in Files)."

THE READ ME SEED IS NOT COSMETIC. The ROM is a RUNTIME input (M-3 / Q-002):
rom_checker.cpp scans the write path for a *.z64 and render_rom_setup_screen()
blocks the game load until it finds a valid one. The user's only way to put it
there is Files, and an app with an EMPTY Documents dir does not appear in Files.
Without the seed, the app demands a ROM through a door it also hides.

WHY THE CRASH HANDLER IS OURS AND NOT coopdx's (the charter said audit first,
extend rather than reinvent — so: audited, and it cannot be extended).
src/pc/crash_handler.c is gated `#if defined(_WIN32) || defined(__linux__)` at
line 6. Its signal installer (`AT_STARTUP init_crash_handler`, :672) sits INSIDE
that gate and only ever does SetUnhandledExceptionFilter (Win32) or sigaction
(Linux). On Apple platforms it compiles to nothing and NO handler is installed.
The one symbol that does survive the gate is `crash_handler_init()` (:720),
which despite the name installs nothing — it is an obfuscated gPcDebug tag hash
called from network.c:125, a name collision rather than a starting point. Beyond
the gate, its DESIGN is wrong for us anyway: it draws a crash screen through djui
and re-enters the main loop (:665), which needs a live renderer and produces no
file. We need a file on a headset nobody is looking at. So the vendor file is
left completely untouched and ours is additive.

WHY THE LOG TEE (deviating from "spdlog file logs", deliberately). coopdx has no
spdlog and no file logging of ANY kind — src/pc/debuglog.h is printf() macros to
stdout. On a SpringBoard/OTA launch stdout goes nowhere, so `logtail` would have
had nothing to read. app/shell tees stdout+stderr to Documents/logs/ instead of
bolting a second logging system onto an engine that would never call it.

D6 (patches must not edit inside each other's hunks) — checked against the live
patched tree, not hoped:
  - pc_main.c: the hook is at configfile_load() (~line 620). Overlay 0002's
    pc_main hunks are at 54 / 238-243 / 267-272 and 0007's are at 318 / 352 /
    445. The nearest is ~155 lines away.
  - CMakeLists.txt: this is the constrained one. Overlay 0007 appends the probe
    to IOS_OBJC_FILES, and its hunk's TRAILING CONTEXT is
    `set(ASSET_CATALOG ...)` + `add_executable(...)` (live lines 295/297). So the
    obvious home for this patch — right next to 0007's list(APPEND) — is exactly
    the hunk we must not touch: editing there would leave 0007 un-reversible,
    apply-overlay's -R probe would fail, and the run would die "neither applied
    nor appliable" (the symptom the charter names). Instead this patch appends at
    END OF FILE, whose last 3 lines (the GAME_DATA_DIRS foreach, live 418-420)
    are pristine and ~28 lines clear of 0005's last hunk. Because the list is
    already consumed by add_executable() at that point, the append uses
    target_sources() rather than list(APPEND).
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
APP = ROOT / "app/shell"

diffs = []


def diff_new_file(text, rel):
    """/dev/null hunk for a repo-owned new file (D-010 / overlay 0001 pattern)."""
    r = subprocess.run(["git", "-C", str(VENDOR), "ls-files", "--error-unmatch", rel],
                       capture_output=True)
    assert r.returncode != 0, f"[{rel}] already tracked upstream — 0008 must not clobber it"
    with tempfile.TemporaryDirectory() as td:
        empty = pathlib.Path(td) / "empty"
        empty.write_text("")
        new = pathlib.Path(td) / "new"
        new.write_text(text)
        r = subprocess.run(
            ["diff", "-uN", "--label", "/dev/null", "--label", f"b/{rel}",
             str(empty), str(new)], capture_output=True, text=True)
    assert r.returncode == 1, f"[{rel}] no diff produced"
    return r.stdout


def diff_edit(orig, new, rel):
    with tempfile.TemporaryDirectory() as td:
        fa = pathlib.Path(td) / "a"
        fb = pathlib.Path(td) / "b"
        fa.write_text(orig)
        fb.write_text(new)
        r = subprocess.run(["diff", "-u", "--label", f"a/{rel}", "--label", f"b/{rel}",
                            str(fa), str(fb)], capture_output=True, text=True)
    assert r.returncode == 1, f"[{rel}] no diff produced"
    return r.stdout


def replace_once(text, old, new, tag, sentinel):
    """Match-count-asserted replace (charter ground rule 1) + already-applied guard.

    Both anchors below have their OLD text as a PREFIX of their NEW text (we
    insert around the anchor rather than rewrite it), so `count(old) == 1` stays
    true even on an ALREADY-PATCHED tree — the count assert alone would happily
    emit a double-applied patch. The sentinel turns the charter's
    reverse-then-regenerate workflow from a convention into an enforced failure,
    because a silently doubled hunk is invisible until it miscompiles.
    """
    assert sentinel not in text, (
        f"[{tag}] already applied (found sentinel {sentinel!r}) — "
        f"`patch -p1 -R` overlay 0008 out of vendor before regenerating")
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}"
    return text.replace(old, new)


# ---------------------------------------------------------------------------
# 1. The shell itself — packaged from app/shell/ (source of truth), not authored
#    here. D-010: a new file has no pristine anchor to assert against, so keeping
#    the real file real is what keeps the generator honest.
# ---------------------------------------------------------------------------
for src_name, rel in [("sm64_vision_shell.h", "src/pc/sm64_vision_shell.h"),
                      ("sm64_vision_shell.m", "src/pc/sm64_vision_shell.m")]:
    src = APP / src_name
    assert src.is_file(), f"missing source of truth: {src}"
    text = src.read_text()
    assert text, f"empty source: {src}"
    diffs.append(diff_new_file(text, rel))

# ---------------------------------------------------------------------------
# 2. CMakeLists.txt — the .m into the target, visionOS-only, appended at EOF.
#
#    EOF is not laziness: see the D6 note in the docstring. The natural anchor
#    (next to overlay 0007's list(APPEND IOS_OBJC_FILES ...)) is inside 0007's
#    hunk context and would make 0007 un-reversible.
# ---------------------------------------------------------------------------
REL_CMAKE = "CMakeLists.txt"
orig_cmake = (VENDOR / REL_CMAKE).read_text()

# The tail of the GAME_DATA_DIRS foreach — pristine, and the last thing in the
# file. Anchored on all three lines so the match is unambiguous (`endforeach()`
# alone appears twice in this block).
OLD_CMAKE = """        endforeach()
    endif()
endforeach()
"""
NEW_CMAKE = """        endforeach()
    endif()
endforeach()

# ---- visionOS remote-diagnosis shell (overlay 0008) ----
# Crash handler -> Documents/crash.txt, stdout/stderr tee -> Documents/logs/,
# launch-gated TCP console bridge, Documents readme seed, and the synchronous
# config save on resign-active. Charter ground rules 5 and 6.
#
# target_sources() rather than list(APPEND IOS_OBJC_FILES ...) for TWO reasons,
# both real:
#   1. IOS_OBJC_FILES was already consumed by add_executable() further up, so a
#      list(APPEND) down here would be silently ignored — the file would never
#      compile and the diagnosis floor would be missing from the build with no
#      error to show for it.
#   2. The list is bracketed by overlay 0007's hunk (its trailing context is
#      set(ASSET_CATALOG ...) / add_executable(...)), and editing inside another
#      patch's hunk breaks apply-overlay's reverse probe (charter D6).
#
# Guarded on SM64_VISIONOS so the iOS target's source list stays bit-for-bit
# identical; the file's own body is additionally gated on TARGET_OS_VISION via
# TargetConditionals, so a forgotten build flag can never be why it is missing.
if(SM64_VISIONOS)
    target_sources(sm64coopdx PRIVATE ${GAME_ROOT}/src/pc/sm64_vision_shell.m)
endif()
"""
t_cmake = replace_once(orig_cmake, OLD_CMAKE, NEW_CMAKE, "cmake-shell-source",
                       "sm64_vision_shell.m")
diffs.append(diff_edit(orig_cmake, t_cmake, REL_CMAKE))

# ---------------------------------------------------------------------------
# 3. pc_main.c — one hook, immediately after configfile_load().
#
#    The placement is load-bearing, not incidental. The shell's resign-active
#    handler calls configfile_save(); registering that observer BEFORE
#    configfile_load() would allow a resign to write DEFAULTS over the user's
#    real settings, i.e. the exact "never delete user data" failure the rule
#    exists to prevent. Hooking after the load makes that unreachable.
#
#    The crash handler and log tee deliberately do NOT wait for this hook — they
#    install from a constructor in the shell itself, so a crash in coopdx's
#    ~12,100 rom_assets constructors is still caught.
# ---------------------------------------------------------------------------
REL_MAIN = "src/pc/pc_main.c"
orig_main = (VENDOR / REL_MAIN).read_text()

# 3a. The include, at FILE scope immediately above main(). Not with the includes
#     at the top of the file: overlay 0002 owns that block (@@ -54,6 @@) and D6
#     forbids editing inside it — the same constraint, and the same resolution,
#     that overlay 0007 documented for its own include. Not inside main()'s body
#     either: legal C, but it would drag TargetConditionals.h into function scope
#     for no reason. main() is at line 594, ~130 lines clear of 0007's last hunk.
OLD_INC = """int main(int argc, char *argv[]) {
"""
NEW_INC = """// Included HERE rather than with the includes at the top of this file: overlay
// 0002 owns that block, and the charter's D6 forbids one overlay patch editing
// inside another's hunk (overlay 0007's include is displaced for the same
// reason). The header compiles to nothing off visionOS — it derives
// SM64_VISION_SHELL from TargetConditionals — so this is safe on the desktop
// oracle and the iOS target alike.
#include "sm64_vision_shell.h"

int main(int argc, char *argv[]) {
"""
t_main = replace_once(orig_main, OLD_INC, NEW_INC, "shell-include",
                      '#include "sm64_vision_shell.h"')

# 3b. The call, immediately after configfile_load().
#
#     The placement is load-bearing, not incidental. The shell's resign-active
#     handler calls configfile_save(); registering that observer BEFORE
#     configfile_load() would let a resign write DEFAULTS over the user's real
#     settings — the exact "never delete user data" failure the rule exists to
#     prevent. Hooking after the load makes that unreachable.
#
#     The crash handler and log tee deliberately do NOT wait for this hook: the
#     shell installs those from a constructor, so a crash in coopdx's ~12,100
#     rom_assets constructors (which run before main) is still caught.
OLD_CALL = """    configfile_load();
"""
NEW_CALL = """    configfile_load();

#ifdef SM64_VISION_SHELL
    // Crash handler is already live (constructor); this adds the readme seed,
    // the resign-active config save, and the launch-gated console bridge.
    sm64_vision_shell_init();
#endif
"""
t_main = replace_once(t_main, OLD_CALL, NEW_CALL, "shell-init-hook",
                      "sm64_vision_shell_init")

diffs.append(diff_edit(orig_main, t_main, REL_MAIN))

out = ROOT / "overlay/patches/0008-visionos-diag-shell.patch"
out.write_text(__doc__ + "\n" + "".join(diffs))
print(f"wrote {out} ({sum(len(d.splitlines()) for d in diffs)} diff lines)")
