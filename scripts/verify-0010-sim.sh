#!/bin/bash
# Sim regression for overlay 0010 (visionOS panel-rate measurement + framerate
# policy).
#
# THE POINT OF THE SEED. `framerate_mode` and `frame_limit` are PERSISTED, so a
# fresh install cannot catch the bug this patch fixes — a fresh config would get
# the right values through the "default" path and prove nothing about the user's
# ACTUAL config, which already has framerate_mode=0/frame_limit=60 on disk. The
# charter is explicit: "the sim regression test must SEED the legacy value, since
# fresh installs can't catch it." So launch 1 runs against a hand-seeded LEGACY
# config with no rev marker.
#
# Launch 1  legacy config (mode=AUTO, limit=60, NO rev)  -> must MIGRATE
# Launch 2  the migrated config                          -> must NOT re-migrate
# Launch 3  user has deliberately chosen AUTO, rev=1     -> AUTO must SURVIVE
set -uo pipefail

UDID=33150978-17BA-42B6-9EC7-3C2DD54273E1   # sm64vp-xros265 — OUR sim (charter: never boot sims you don't own)
BUNDLE=com.sm64coopdx.ios
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build-vision-sim/Release-xrsimulator/sm64coopdx.app"
ROM="$HOME/dev/libsm64visionos/baserom.us.z64"
OUT="$ROOT/work/verify-0010"
mkdir -p "$OUT"

say() { echo; echo "############ $* ############"; }

say "install"
xcrun simctl install "$UDID" "$APP" || exit 1
D=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data) || exit 1
echo "container=$D"
mkdir -p "$D/Documents"

say "stage ROM (runtime input — M-3) + enable the console bridge"
cp -f "$ROM" "$D/Documents/baserom.us.z64"
md5 -q "$D/Documents/baserom.us.z64"

seed_legacy_config() {
    # A realistic pre-0010 visionOS config: exactly what a user who installed
    # the days-old build and never touched Display would have on disk.
    # NOTE: no `vision_framerate_rev` line — that is what makes it LEGACY.
    cat > "$D/Documents/sm64config.txt" <<'EOF'
fullscreen true
window_x 0
window_y 0
window_w 1920
window_h 1080
vsync true
msaa 0
hidpi true
graphics_backend 0
texture_filtering 2
show_fps false
show_ping false
framerate_mode 0
frame_limit 60
interpolation_mode 1
coop_draw_distance 6
master_volume 80
music_volume 127
sfx_volume 127
env_volume 127
player_name Mario
EOF
}

launch_and_capture() {
    local tag="$1" secs="${2:-30}"
    rm -rf "$D/Documents/logs"
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" \
        SM64_CONSOLE=1 > "$OUT/$tag-launch.txt" 2>&1
    echo "launched ($tag): $(cat "$OUT/$tag-launch.txt")"
    sleep "$secs"
    cat "$D"/Documents/logs/*.log > "$OUT/$tag.log" 2>/dev/null
    echo "--- [hz] lines ($tag) ---"
    grep -a "\[hz\]" "$OUT/$tag.log" || echo "(NO [hz] LINES — investigate)"
    echo "--- config on disk after $tag (pre-save) ---"
    grep -aE "^(framerate_mode|frame_limit|vision_framerate_rev) " "$D/Documents/sm64config.txt"
}

save_config_via_bridge() {
    # configfile_save only runs on resign-active (our shell, D-016/overlay 0008)
    # or clean quit; `simctl terminate` is SIGKILL and would save nothing. The
    # bridge's `resign` verb posts the real notification.
    printf 'resign\n' | nc -w 3 127.0.0.1 8791 || echo "(bridge resign failed)"
    sleep 2
}

# ---------------------------------------------------------------- launch 1
say "LAUNCH 1 — SEEDED LEGACY CONFIG (mode=AUTO, limit=60, no rev). Must MIGRATE."
seed_legacy_config
echo "--- seeded config ---"
grep -aE "^(framerate_mode|frame_limit|vision_framerate_rev) " "$D/Documents/sm64config.txt"
launch_and_capture run1 35
say "save the migrated config through the resign path"
save_config_via_bridge
echo "--- sm64config.txt AFTER the migration was saved ---"
grep -aE "^(framerate_mode|frame_limit|vision_framerate_rev) " "$D/Documents/sm64config.txt"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null

# ---------------------------------------------------------------- launch 2
say "LAUNCH 2 — the migrated config. Must NOT re-migrate."
launch_and_capture run2 30
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null

# ---------------------------------------------------------------- launch 3
say "LAUNCH 3 — user has DELIBERATELY chosen AUTO (rev stays 1). AUTO must SURVIVE."
sed -i '' 's/^framerate_mode .*/framerate_mode 0/' "$D/Documents/sm64config.txt"
echo "--- config with a deliberate AUTO ---"
grep -aE "^(framerate_mode|frame_limit|vision_framerate_rev) " "$D/Documents/sm64config.txt"
launch_and_capture run3 30
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null

say "DONE — artifacts in $OUT"
