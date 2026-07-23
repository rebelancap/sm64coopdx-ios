# vision3d.cmake — build wiring for the visionOS stereoscopic 3D layer (Phase 2).
#
# Included as the LAST STEP of `project(sm64coopdx ...)` via
#   -DCMAKE_PROJECT_sm64coopdx_INCLUDE=<repo>/app/vision3d/vision3d.cmake
# passed by the two build scripts — exactly like SM64_VISIONOS_PLIST and
# SM64_VISIONOS_ASSETS are passed by path (D-018).
#
# WHY NOT A HUNK IN CMakeLists.txt (this is the interesting part):
#
# Every legal anchor after add_executable() is boxed in. Overlay 0005 owns the
# link/properties/frameworks region, 0007 owns the IOS_OBJC_FILES list, 0008
# owns the EOF slot (and M-26 says at most ONE patch may ever hold it), 0009
# owns the asset-catalog swap, and 0010 — authored CONCURRENTLY with this — took
# the slot immediately after add_executable(). Inserting between any of those
# blocks and its trailing context would split that context and break the
# victim's `patch -p1 -R` probe, which is exactly the D6 failure apply-overlay
# reports as "neither applied nor appliable".
#
# Rather than compete for a shrinking anchor — and silently break 0010 the next
# time either patch is regenerated — this uses CMake's own documented extension
# point and touches CMakeLists.txt ZERO times. Overlay 0011 therefore has no
# CMakeLists.txt hunk at all, and no ordering relationship with 0010 whatsoever.
#
# The two-step shape below is forced by WHEN this file runs: project() is at
# CMakeLists.txt:3, so at include time GAME_ROOT is not set yet and the target
# does not exist. enable_language() must run at directory scope (here, now); the
# target wiring must run after add_executable(), so it is DEFERred to the end of
# this directory's processing, by which time both exist.
#
# MEASURED, NOT ASSUMED: a standalone spike built a SwiftUI @main +
# CompositorLayer + ObjC bridging header for xrsimulator through this exact
# mechanism (CMAKE_PROJECT_<name>_INCLUDE + enable_language(Swift) +
# cmake_language(DEFER)) before any of it was wired here.

# Gate on CMAKE_SYSTEM_NAME, NOT SM64_VISIONOS — and this distinction is MEASURED,
# not stylistic. SM64_VISIONOS is set by CMakeLists.txt:13, which runs AFTER
# project() at :3 — i.e. after this file has already been included and returned.
# Gating on it here made the whole layer a SILENT NO-OP: configure succeeded, the
# build succeeded, and not one Swift file was compiled. There was no error to
# read, only an absence (grep -c SwiftCompile == 0). CMAKE_SYSTEM_NAME comes from
# the -D cache and is therefore already set when project() runs.
#
# The same "not set yet" hazard is why the wiring below is deferred: GAME_ROOT
# (CMakeLists.txt:10) and the sm64coopdx target do not exist at this point either.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "visionOS")
    return() # iOS / desktop: this layer does not exist at all
endif()

# Swift is unavoidable: an ImmersiveSpace can ONLY be declared from a SwiftUI
# App. CMake supports Swift only with the Xcode generator — which is what both
# visionOS build scripts already use.
enable_language(Swift)

# Build number -> CFBundleVersion (via $(CURRENT_PROJECT_VERSION) in the plist).
# The build scripts pass -DIOS_BUILD_NUMBER (monotonic: git commit count, or
# SM64_BUILD_NUMBER to iterate test builds). Kept SEPARATE from overlay 0005's
# IOS_MARKETING_VERSION (-> CFBundleShortVersionString) so the PUBLIC marketing
# version stays curated + contiguous while the build number churns per build —
# the App-Store-standard split (TestFlight ships many builds of one marketing
# version). Default 1 for a bare configure / the sim script, which pass nothing.
set(IOS_BUILD_NUMBER "1" CACHE STRING "visionOS app CFBundleVersion (build number)")

function(_sm64_vision3d_wire)
    # By now CMakeLists.txt has run to the end, so SM64_VISIONOS exists and can
    # be asserted rather than assumed. If this ever fires, the two gates have
    # drifted apart and the layer would otherwise wire into a non-visionOS target.
    if(NOT SM64_VISIONOS)
        message(FATAL_ERROR "vision3d: CMAKE_SYSTEM_NAME says visionOS but SM64_VISIONOS is unset")
    endif()
    # target_sources() rather than list(APPEND ...) for the same reason as
    # overlay 0008: by now add_executable() has long since consumed the source
    # lists, so a list(APPEND) would be SILENTLY ignored.
    set(_sm64_v3d_objc
        ${GAME_ROOT}/src/pc/vision3d/sm64_vision_host.m
        ${GAME_ROOT}/src/pc/vision3d/sm64_immersive.m
        ${GAME_ROOT}/src/pc/vision3d/sm64_vision_settings.m
    )
    # -fobjc-arc is MANDATORY, and its absence is not a compile error — it is a
    # crash days later. This tree does NOT enable ARC globally; overlay 0005
    # turns it on for gfx_metal.mm alone, per-file, and every .m added since has
    # had to opt in the same way. These files are written as ARC code.
    #
    # MEASURED (M-40), not theorised. Without this line the settings table died
    # with:
    #   -[_BKSHIDCAContextEventDeferringToken objectAtIndexedSubscript:]:
    #       unrecognized selector sent to instance 0x121a78700
    # `_rows = @[...]` under MRC stores an AUTORELEASED array and never retains
    # it, so the ivar dangles and the freed memory comes back as an unrelated
    # UIKit internal. The selector in the crash names an object we never wrote,
    # which is exactly what makes this class of bug so hard to read backwards.
    set_source_files_properties(${_sm64_v3d_objc} PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_sources(sm64coopdx PRIVATE
        ${_sm64_v3d_objc}
        ${GAME_ROOT}/src/pc/vision3d/SM64VisionApp.swift
    )
    set_target_properties(sm64coopdx PROPERTIES
        # Build number (CFBundleVersion). Separate build setting from 0005's
        # MARKETING_VERSION so the two version fields move independently.
        XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "${IOS_BUILD_NUMBER}"
        XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
        XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER
            "${GAME_ROOT}/src/pc/vision3d/sm64-bridging-header.h"
        # The tree's C flags are directory-wide (add_compile_options at
        # CMakeLists.txt:81: -fsigned-char, -fwrapv, -Wno-* ...), and CMake's
        # Xcode generator copies COMPILE_OPTIONS into EVERY language's flags —
        # including OTHER_SWIFT_FLAGS, where they are nonsense. swiftc rejects
        # the first one outright:
        #     error: Driver threw unknown argument: '-fsigned-char'
        # Pinning OTHER_SWIFT_FLAGS here overrides the generated value for this
        # target. Nothing is lost: those flags are C dialect/warning knobs with
        # no Swift meaning, and the C/ObjC/ObjC++ side still gets them via
        # OTHER_CFLAGS exactly as before — so the iOS and desktop builds are
        # untouched.
        XCODE_ATTRIBUTE_OTHER_SWIFT_FLAGS ""
    )
    # NOTE: the Swift entry file must NOT be named main.swift — Swift parses that
    # exact filename as top-level code, which collides with @main
    # ("'main' attribute cannot be used in a module that contains top-level
    # code"). Measured in the spike, not guessed. Hence SM64VisionApp.swift.
    target_link_libraries(sm64coopdx
        "-framework CompositorServices"
        "-framework ARKit"
        "-framework SwiftUI"
        "-framework AVFAudio"
    )
    message(STATUS "visionOS stereo 3D: wired (Swift @main + CompositorServices)")
endfunction()

# Deferred to the end of this directory: add_executable() and GAME_ROOT both
# exist by then, neither does right now.
cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" CALL _sm64_vision3d_wire)
