#!/bin/bash
# Launch the macOS desktop build as the RENDER ORACLE and capture its window.
#
# Purpose (DECISIONS.md D-003): the desktop build renders through the same
# gfx_pc.c + GfxRenderingAPI seam as the iOS/visionOS targets, so it is the
# pixel reference for validating the new Metal backend (D-002) against the
# existing GL backend. Same machine, same tree, switchable backend.
#
#   scripts/run-oracle.sh --shot NAME [--wait SECONDS] [--backend gl|metal]
#
# --backend selects the renderer at RUNTIME via SM64_RAPI, so both backends come
# out of ONE binary: any pixel difference is the backend, not the build. This
# works against vendor/ once overlay patches 0001-0003 are applied (before that,
# vendor has no Metal backend and --backend metal is a no-op that renders GL).
# Defaults to gl, which is the pre-existing behaviour of this script.
#
# Captures by WINDOW ID, never the display: this Mac is driven over SSH with the
# panel asleep, so `screencapture -x` of the display returns a solid black
# frame. Window-ID capture reads the window's backing store and works headless.
# (Charter: never trust a screenshot you haven't looked at.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/vendor/sm64coopdx/build/us_pc/sm64coopdx.app/Contents/MacOS/sm64coopdx"
WRITE_PATH="$HOME/Library/Application Support/sm64coopdx"
SHOT=""; WAIT=25; BACKEND="gl"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shot) SHOT="${2:?--shot needs a name}"; shift 2 ;;
        --wait) WAIT="${2:?--wait needs seconds}"; shift 2 ;;
        --backend) BACKEND="${2:?--backend needs gl|metal}"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done
[[ "$BACKEND" == "gl" || "$BACKEND" == "metal" ]] || { echo "FATAL: --backend must be gl or metal" >&2; exit 1; }

[[ -x "$APP" ]] || { echo "FATAL: oracle not built — run build_ios.sh desktop in vendor/sm64coopdx" >&2; exit 1; }
[[ -f "$WRITE_PATH/baserom.us.z64" ]] || {
    echo "FATAL: no ROM at $WRITE_PATH/baserom.us.z64 — the game blocks on render_rom_setup_screen()" >&2
    exit 1
}

pkill -f "MacOS/sm64coopdx" 2>/dev/null || true
sleep 1

if [[ "$BACKEND" == "metal" ]]; then
    export SM64_RAPI=metal
else
    unset SM64_RAPI || true
fi

"$APP" > "$ROOT/work/oracle-run-$BACKEND.log" 2>&1 &
PID=$!
echo "oracle running: pid $PID backend=$BACKEND (log: work/oracle-run-$BACKEND.log)"

if [[ -n "$SHOT" ]]; then
    mkdir -p "$ROOT/artifacts"
    sleep "$WAIT"

    if ! kill -0 "$PID" 2>/dev/null; then
        echo "FATAL: process died before capture. Tail of log:" >&2
        tail -25 "$ROOT/work/oracle-run-$BACKEND.log" >&2
        exit 1
    fi

    WID=$(swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").lowercased().contains("sm64") {
    let h = (w[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0
    if h > 100 { print(w[kCGWindowNumber as String] as! Int); break }
}' 2>/dev/null)
    [[ -n "$WID" ]] || { echo "FATAL: no sm64coopdx window found" >&2; exit 1; }
    screencapture -x -o -l "$WID" "$ROOT/artifacts/$SHOT.png"

    # An OpenGL surface is only composited while the display is AWAKE; capture it
    # with the panel asleep and you get a perfectly valid, perfectly black PNG
    # (M-4/M-8). That failure is silent and reads like a render bug, so assert
    # the frame has content rather than trusting it. Non-GL windows (Finder) do
    # NOT have this problem, which is what made it so easy to mis-diagnose.
    MEAN=$(swift -e '
import AppKit
let p = CommandLine.arguments.last!
guard let img = NSImage(contentsOfFile: p), let tiff = img.tiffRepresentation,
      let bmp = NSBitmapImageRep(data: tiff) else { print("0"); exit(0) }
var sum = 0.0; var n = 0
let w = bmp.pixelsWide, h = bmp.pixelsHigh
for y in stride(from: h/3, to: 2*h/3, by: 7) {
  for x in stride(from: w/4, to: 3*w/4, by: 7) {
    if let c = bmp.colorAt(x: x, y: y) {
      sum += Double(c.redComponent + c.greenComponent + c.blueComponent)/3.0; n += 1
    }
  }
}
print(String(format: "%.4f", sum/Double(max(n,1))))' "$ROOT/artifacts/$SHOT.png" 2>/dev/null)

    if [[ -z "$MEAN" ]] || awk "BEGIN{exit !($MEAN < 0.005)}"; then
        echo "FATAL: artifacts/$SHOT.png is blank (mean=$MEAN) — is the display asleep?" >&2
        echo "       GL surfaces do not composite while the panel sleeps; wake it and retry." >&2
        exit 1
    fi
    echo "captured artifacts/$SHOT.png (window $WID, backend=$BACKEND, mean=$MEAN)"
fi
