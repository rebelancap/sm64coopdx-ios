#!/usr/bin/env python3
"""Overlay patch 0003: teach the desktop Makefile to build the Metal
backend (Objective-C++) on macOS.

This is the DESKTOP oracle's half of the Metal work (D-003): it is what
makes `SM64_RAPI=metal ./build/us_pc/sm64coopdx` runnable on macOS, which
is where the backend was proven pixel-identical to GL (M-13). The
iOS/visionOS targets build through CMake and pick gfx_metal.mm up
separately (overlay 0005) — hence the OSX_BUILD gate here.

ENABLE_METAL_BACKEND rides in BACKEND_CFLAGS next to the existing OpenGL
selection, so no non-macOS build sees any of it.
"""
import subprocess, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
REL = "Makefile"
orig = (VENDOR / REL).read_text()


def replace_once(text, old, new, tag):
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}: {old[:70]!r}"
    return text.replace(old, new)


t = orig

t = replace_once(t, """CPP_FILES         := $(foreach dir,$(SRC_DIRS),$(wildcard $(dir)/*.cpp))
S_FILES           := $(foreach dir,$(SRC_DIRS),$(wildcard $(dir)/*.s))""",
"""CPP_FILES         := $(foreach dir,$(SRC_DIRS),$(wildcard $(dir)/*.cpp))
# Objective-C++ sources: the Metal rendering backend. macOS-only for now; the
# iOS/visionOS targets build through CMake and pick this up separately.
OBJCPP_FILES      :=
ifeq ($(OSX_BUILD),1)
  OBJCPP_FILES    += src/pc/gfx/gfx_metal.mm
endif
S_FILES           := $(foreach dir,$(SRC_DIRS),$(wildcard $(dir)/*.s))""", "mk-src-list")

t = replace_once(t, """O_FILES := $(foreach file,$(C_FILES),$(BUILD_DIR)/$(file:.c=.o)) \\
           $(foreach file,$(CPP_FILES),$(BUILD_DIR)/$(file:.cpp=.o)) \\
           $(foreach file,$(S_FILES),$(BUILD_DIR)/$(file:.s=.o)) \\""",
"""O_FILES := $(foreach file,$(C_FILES),$(BUILD_DIR)/$(file:.c=.o)) \\
           $(foreach file,$(CPP_FILES),$(BUILD_DIR)/$(file:.cpp=.o)) \\
           $(foreach file,$(OBJCPP_FILES),$(BUILD_DIR)/$(file:.mm=.o)) \\
           $(foreach file,$(S_FILES),$(BUILD_DIR)/$(file:.s=.o)) \\""", "mk-o-files")

t = replace_once(t, """else ifeq ($(OSX_BUILD),1)
  BACKEND_LDFLAGS += -framework OpenGL `pkg-config --libs glew` -mmacosx-version-min=$(MIN_MACOS_VERSION)
  EXTRA_CPP_FLAGS += -stdlib=libc++ -std=c++17 -mmacosx-version-min=$(MIN_MACOS_VERSION)""",
"""else ifeq ($(OSX_BUILD),1)
  BACKEND_LDFLAGS += -framework OpenGL `pkg-config --libs glew` -mmacosx-version-min=$(MIN_MACOS_VERSION)
  # Metal backend (gfx_metal.mm). QuartzCore supplies CAMetalLayer.
  BACKEND_LDFLAGS += -framework Metal -framework QuartzCore -framework Foundation
  BACKEND_CFLAGS  += -DENABLE_METAL_BACKEND=1
  EXTRA_CPP_FLAGS += -stdlib=libc++ -std=c++17 -mmacosx-version-min=$(MIN_MACOS_VERSION)""", "mk-osx-backend")

t = replace_once(t, """# Compile C code
$(BUILD_DIR)/%.o: %.c
	$(call print,Compiling:,$<,$@)""",
"""# Compile Objective-C++ code (Metal backend)
$(BUILD_DIR)/%.o: %.mm
	$(call print,Compiling:,$<,$@)
	$(V)$(CXX) $(PROF_FLAGS) -c -x objective-c++ -fobjc-arc $(EXTRA_CPP_FLAGS) $(EXTRA_CPP_INCLUDES) $(CFLAGS) -MMD -MP -MT $@ -MF $(BUILD_DIR)/$*.d -o $@ $<

# Compile C code
$(BUILD_DIR)/%.o: %.c
	$(call print,Compiling:,$<,$@)""", "mk-objcpp-rule")

with tempfile.TemporaryDirectory() as td:
    a = pathlib.Path(td) / "a"; a.write_text(orig)
    b = pathlib.Path(td) / "b"; b.write_text(t)
    r = subprocess.run(["diff", "-u", "--label", f"a/{REL}", "--label", f"b/{REL}",
                        str(a), str(b)], capture_output=True, text=True)
assert r.returncode == 1, "no diff produced"

out = ROOT / "overlay/patches/0003-makefile-metal-objcpp.patch"
out.write_text(__doc__ + "\n" + r.stdout)
print(f"wrote {out}")
