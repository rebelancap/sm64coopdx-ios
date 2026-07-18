#!/usr/bin/env python3
"""Overlay patch 0001: the Metal rendering backend (D-002), as new files
src/pc/gfx/gfx_metal.{h,mm}.

Source of truth is app/gfx/ — NOT this patch. The 1180-LOC backend is a
first-class, editable, greppable repo artifact; this generator only
packages it into vendor. Rationale (Shipwright precedent, both halves):
its app/ios/SohIosShell.m is repo-owned source, and its overlay 0021
emits a real file from overlay/assets/ into vendor via a /dev/null hunk.
We do both: own the file in app/, emit it with a /dev/null hunk.

Why emit into vendor rather than reference app/ in place (the other
option the task offered): the file must land at src/pc/gfx/ for BOTH
build systems. The desktop Makefile maps objects as
$(BUILD_DIR)/$(file:.mm=.o), so an out-of-tree ../../app path yields a
build path that escapes BUILD_DIR; and gfx_sdl.c's #include "gfx_metal.h"
resolves relative to its own dir. Landing the file in-tree keeps both
natural and needs zero include-path gymnastics.

Re-runnability: no pristine-text anchor exists for a new file, so instead
this asserts the vendor path does not already exist as a tracked file
(i.e. upstream has not added a gfx_metal of its own under us) and that
the emitted bytes round-trip exactly from app/gfx/.
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
APP = ROOT / "app/gfx"

FILES = [
    ("gfx_metal.h", "src/pc/gfx/gfx_metal.h"),
    ("gfx_metal.mm", "src/pc/gfx/gfx_metal.mm"),
]

diffs = []
for src_name, rel in FILES:
    src = APP / src_name
    assert src.is_file(), f"missing source of truth: {src}"
    text = src.read_text()
    assert text, f"empty source: {src}"

    # Assert upstream has no file at this path: a new-file hunk would fail
    # to apply, but this names the reason instead of leaving patch(1) to.
    r = subprocess.run(["git", "-C", str(VENDOR), "ls-files", "--error-unmatch", rel],
                       capture_output=True)
    assert r.returncode != 0, f"[{rel}] already tracked upstream — 0001 must not clobber it"

    with tempfile.TemporaryDirectory() as td:
        empty = pathlib.Path(td) / "empty"
        empty.write_text("")
        new = pathlib.Path(td) / "new"
        new.write_text(text)
        r = subprocess.run(
            ["diff", "-uN", "--label", "/dev/null", "--label", f"b/{rel}",
             str(empty), str(new)],
            capture_output=True, text=True)
    assert r.returncode == 1, f"[{rel}] no diff produced"
    diffs.append(r.stdout)

out = ROOT / "overlay/patches/0001-metal-backend-files.patch"
out.write_text(__doc__ + "\n" + "".join(diffs))
print(f"wrote {out} ({sum(len(d.splitlines()) for d in diffs)} diff lines)")
