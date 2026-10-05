# Installing Super Mario 64 Co-op Deluxe on Apple Vision Pro

This is an Apple Vision Pro build of [sm64coopdx](https://github.com/coop-deluxe/sm64coopdx), the Coop Deluxe Team's online-multiplayer Super Mario 64 port, rendering natively on Metal. It is forked from [LeoManrique/sm64coopdx-ios](https://github.com/LeoManrique/sm64coopdx-ios). It plays in a 2D window, in a stereoscopic 3D mode on a world-locked screen in your room, and in a VR mode you can stand inside.

## What you need

- Apple Vision Pro on visionOS 2 or later
- Your own Super Mario 64 (US) ROM
- For the prebuilt app: SideStore on the headset, installed with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos) (this version supports visionOS)
- To build from source: macOS with Xcode and `cmake` (`brew install cmake`)
- Optional: a game controller, which works in every mode including VR. On-screen touch controls appear when no controller is connected. In VR, tracked controllers such as PS VR2 Sense are optional.

## Your game files

Neither this repository nor the app contains any game content. You supply your own ROM.

1. You need the **US** release of Super Mario 64: a `.z64` file, 8 MB, from a copy you own. Other regions aren't supported.
2. On first launch the app shows a ROM-setup screen and waits until it sees a valid US ROM.
3. In the Files app, drop the `.z64` into *On My Apple Vision Pro → sm64coopdx*.

The app loads what it needs directly from the ROM. Nothing is extracted to distribute, and the ROM never leaves your device. Settings and saves are kept when you swap ROMs.

HD textures and models are optional; see [Texture packs](README.md#texture-packs-highly-recommended) in the README.

## Install the prebuilt app

1. Install SideStore on the headset with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos). No Xcode or Dev Strap is required.
2. In SideStore, go to *Sources → +* and paste this source, then install Super Mario 64 Co-op Deluxe:

   ```
   https://raw.githubusercontent.com/rebelancap/sm64coopdx-ios/main/sidestore/apps-visionos.json
   ```

   The app updates from this source when new versions ship.

To install by hand instead, download `sm64coopdx-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/sm64coopdx-ios/releases/latest) and install it through SideStore.

## Build from source

From a checkout of this repo:

```sh
scripts/bootstrap.sh          # vendor sm64coopdx at the pinned commit (once)
scripts/fetch-sdl2.sh         # SDL2 source (once)
scripts/build-deps-xros.sh    # CoopNet + other xrOS dependency slices (once)
(cd vendor/sm64coopdx && ./build_ios.sh desktop)   # host asset build, about 10 minutes (once)
SM64_IOS_TEAM=YOUR_TEAM_ID scripts/build-visionos.sh   # the merged 2D + 3D visionOS app (signed)
```

`scripts/build-visionos.sh` checks for the host asset build and stops with the command above if it is missing. That step does not use a ROM: the ROM is only read at runtime. The script takes your Apple Developer team ID from `SM64_IOS_TEAM` and writes the app to `build-visionos/Release-xros/sm64coopdx.app`.

Upstream is vendored unmodified and pinned by commit. Every local change is a patch in `overlay/patches/`, applied by `scripts/apply-overlay.sh`. The Metal backend and the visionOS shell live under `app/`.

## Notes

- Online co-op uses [CoopNet](https://github.com/coop-deluxe/coopnet), the same online multiplayer as desktop coopdx.
- VR has three views (a diorama on your floor, third person, and first person at life size), and menus stay on a flat world-locked screen.
- Apps sideloaded with a free Apple account expire after 7 days (paid developer accounts last a year). SideStore refreshes them in the background; if the app stops launching, open SideStore and let it re-sign.
- Super Mario 64 is © Nintendo. This project ships no Nintendo content; you supply your own ROM.
