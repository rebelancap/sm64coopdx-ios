#!/usr/bin/env python3
"""Generate overlay/assets/lua-5.3.5-xros-no-system.patch.

WHY: Lua 5.3.5's loslib.c calls system() (once, in os_execute). Apple marks
system() __IOS_PROHIBITED in <stdlib.h> -- identically in the iOS and xrOS SDKs
-- so loslib.c does not COMPILE for arm64-apple-xros:

    loslib.c:143:14: error: 'system' is unavailable: not available on visionOS
    _stdlib.h:208:6: note: 'system' has been explicitly marked unavailable here

This is not an xrOS-specific wall. It is an Apple-embedded one, and the fork's
own shipped iOS prebuilt already cleared it: `nm -u lib/lua/ios/liblua53.a`
references _popen/_pclose but NO _system, i.e. whoever built it neutered
os.execute the same way. We just do it in the open, with a patch.

The stub keeps os.execute's documented contract rather than lying:
  os.execute()     -> false           ("no shell available")
  os.execute(cmd)  -> nil, msg, errno (via luaL_execresult(-1) -> luaL_fileresult)

Detection is via TargetConditionals (__APPLE__ && !TARGET_OS_OSX) rather than a
-D flag, so the patch is self-contained and cannot silently regress if a build
script forgets to pass the define. macOS builds keep real system().

Per the charter: assert match counts against PRISTINE upstream text, so the
patch can never apply to something it was not written for.
"""

import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work" / "xros-src"
OUT = ROOT / "overlay" / "assets" / "lua-5.3.5-xros-no-system.patch"

LUA_VER = "5.3.5"
LUA_URL = f"https://www.lua.org/ftp/lua-{LUA_VER}.tar.gz"
LUA_SHA256 = "0c2eed3f960446e1a3e4b9a1ca2f3ff893b6ce41942cf54d5dd59ab4b3b058ac"

# --- pristine anchors -------------------------------------------------------

ANCHOR_INCLUDES = '''#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"
'''

REPL_INCLUDES = '''#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"


/*
** Apple's embedded platforms (iOS, tvOS, watchOS, visionOS) mark system() as
** __IOS_PROHIBITED in <stdlib.h>: process spawning is unavailable there, so the
** stock os_execute below does not compile. Detect those platforms and stub it.
*/
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if !TARGET_OS_OSX
#define LUA_NO_PROCESS_SPAWN 1
#endif
#endif
'''

ANCHOR_EXECUTE = '''static int os_execute (lua_State *L) {
  const char *cmd = luaL_optstring(L, 1, NULL);
  int stat = system(cmd);
  if (cmd != NULL)
    return luaL_execresult(L, stat);
  else {
    lua_pushboolean(L, stat);  /* true if there is a shell */
    return 1;
  }
}
'''

REPL_EXECUTE = '''static int os_execute (lua_State *L) {
#if defined(LUA_NO_PROCESS_SPAWN)
  /*
  ** No shell and no process spawning on this platform. Honour os.execute's
  ** documented contract instead of pretending a shell exists:
  **   os.execute()    -> false
  **   os.execute(cmd) -> nil, "...", ENOSYS   (luaL_execresult(-1) routes to
  **                                            luaL_fileresult)
  */
  const char *cmd = luaL_optstring(L, 1, NULL);
  if (cmd == NULL) {
    lua_pushboolean(L, 0);  /* no shell available */
    return 1;
  }
  errno = ENOSYS;
  return luaL_execresult(L, -1);
#else
  const char *cmd = luaL_optstring(L, 1, NULL);
  int stat = system(cmd);
  if (cmd != NULL)
    return luaL_execresult(L, stat);
  else {
    lua_pushboolean(L, stat);  /* true if there is a shell */
    return 1;
  }
#endif
}
'''

EDITS = [
    ("src/loslib.c", ANCHOR_INCLUDES, REPL_INCLUDES, 1),
    ("src/loslib.c", ANCHOR_EXECUTE, REPL_EXECUTE, 1),
]


def fetch_pristine() -> Path:
    """Extract a guaranteed-pristine lua tree to diff against."""
    WORK.mkdir(parents=True, exist_ok=True)
    tarball = WORK / f"lua-{LUA_VER}.tar.gz"
    if not tarball.exists():
        urllib.request.urlretrieve(LUA_URL, tarball)

    import hashlib

    got = hashlib.sha256(tarball.read_bytes()).hexdigest()
    if got != LUA_SHA256:
        sys.exit(f"FATAL: lua tarball sha256 {got} != pinned {LUA_SHA256}")

    dest = WORK / "lua-pristine"
    if dest.exists():
        subprocess.run(["rm", "-rf", str(dest)], check=True)
    dest.mkdir(parents=True)
    with tarfile.open(tarball) as tf:
        tf.extractall(dest)
    return dest / f"lua-{LUA_VER}"


def main() -> None:
    pristine = fetch_pristine()
    patched = WORK / "lua-patched"
    if patched.exists():
        subprocess.run(["rm", "-rf", str(patched)], check=True)
    subprocess.run(["cp", "-R", str(pristine), str(patched)], check=True)

    for rel, anchor, repl, want in EDITS:
        f = patched / rel
        text = f.read_text()
        got = text.count(anchor)
        if got != want:
            sys.exit(
                f"FATAL: {rel}: anchor matched {got}x, expected {want}x.\n"
                f"       Upstream text drifted -- re-read the source before regenerating.\n"
                f"       anchor:\n{anchor}"
            )
        f.write_text(text.replace(anchor, repl))

    # Sanity: the whole point is that system() is gone from the compiled paths.
    body = (patched / "src" / "loslib.c").read_text()
    if "LUA_NO_PROCESS_SPAWN" not in body:
        sys.exit("FATAL: guard not present after edit")

    proc = subprocess.run(
        ["diff", "-ru", f"lua-{LUA_VER}", "lua-patched"],
        cwd=str(WORK / "lua-pristine") if False else str(WORK),
        capture_output=True,
        text=True,
    )
    # diff exits 1 when files differ, which is the expected outcome.
    if proc.returncode not in (0, 1):
        sys.exit(f"FATAL: diff failed: {proc.stderr}")
    if not proc.stdout.strip():
        sys.exit("FATAL: patch is empty -- edits did not take")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    header = (
        "# Lua 5.3.5: stub os.execute on Apple embedded platforms (iOS/tvOS/watchOS/visionOS).\n"
        "#\n"
        "# system() is __IOS_PROHIBITED in <stdlib.h> on every Apple embedded SDK, so\n"
        "# loslib.c fails to COMPILE for arm64-apple-xros:\n"
        "#   loslib.c:143:14: error: 'system' is unavailable: not available on visionOS\n"
        "#\n"
        "# Generated by scripts/gen-patch-lua-xros-no-system.py -- do not hand-edit.\n"
        "# Applied to work/xros-src/lua-5.3.5 by scripts/build-deps-xros.sh.\n"
    )
    OUT.write_text(header + proc.stdout)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(proc.stdout.splitlines())} diff lines)")


if __name__ == "__main__":
    main()
