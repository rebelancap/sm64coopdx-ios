#!/bin/bash
# Adapted from run-oracle.sh (which is left untouched and still points at
# vendor/) to run the METAL SPIKE build and A/B its backends.
#
#   scripts/run-spike-oracle.sh --backend metal|gl --shot NAME [--wait SECONDS]
#
# The backend is chosen at runtime via SM64_RAPI (see gfx_metal_requested() in
# src/pc/gfx/gfx_metal.mm) so both backends come out of ONE binary, which is the
# whole point of the A/B: any pixel difference is the backend, not the build.
#
# Everything else is inherited from run-oracle.sh verbatim, including the
# window-ID capture and the blank-frame assert. Re-read that script's comments
# before changing anything here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/spikes/metal-spike/build/us_pc/sm64coopdx.app/Contents/MacOS/sm64coopdx"
WRITE_PATH="$HOME/Library/Application Support/sm64coopdx"
SHOT=""; WAIT=25; BACKEND="metal"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shot) SHOT="${2:?--shot needs a name}"; shift 2 ;;
        --wait) WAIT="${2:?--wait needs seconds}"; shift 2 ;;
        --backend) BACKEND="${2:?--backend needs gl|metal}"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -x "$APP" ]] || { echo "FATAL: spike not built — run ./build_ios.sh desktop in spikes/metal-spike" >&2; exit 1; }
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

"$APP" > "$ROOT/work/spike-oracle-$BACKEND.log" 2>&1 &
PID=$!
echo "spike oracle running: pid $PID backend=$BACKEND (log: work/spike-oracle-$BACKEND.log)"

if [[ -n "$SHOT" ]]; then
    mkdir -p "$ROOT/artifacts"
    sleep "$WAIT"

    if ! kill -0 "$PID" 2>/dev/null; then
        echo "FATAL: process died before capture. Tail of log:" >&2
        tail -25 "$ROOT/work/spike-oracle-$BACKEND.log" >&2
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

    # A Metal/GL surface only composites while the display is AWAKE; capturing
    # with the panel asleep yields a valid, perfectly BLACK png that reads like
    # a render bug. Assert content rather than trusting the file. (M-4/M-8)
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
        echo "       GPU surfaces do not composite while the panel sleeps; wake it and retry." >&2
        exit 1
    fi
    echo "captured artifacts/$SHOT.png (window $WID, backend=$BACKEND, mean=$MEAN)"
fi
