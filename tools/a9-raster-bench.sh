#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run the melonDS software-rasterizer timing bench on the MiSTer's Cortex-A9.
#
# This answers the one question that decides the hybrid 3D core's architecture:
# can the HPS ARM rasterize a DS frame inside a 16.67 ms budget? Everything else
# in the plan (DDR3 rings, the fabric matrix shadow, the VRAM bank mirror) is
# only worth building if the answer is yes, or yes-at-30-Hz.
#
# STEP 1, on the dev machine — build both binaries and capture a scene:
#
#   sim/melonds_tracer/build.sh                       # native, also applies tracer.patch
#   cmake --build sim/melonds_tracer/build-native --target melonds_gxbench
#   sim/melonds_tracer/build-armhf.sh                 # the board binary
#
#   sim/melonds_tracer/build-native/melonds_gxbench \
#       --frames 900 --capture scene.mln --iters 2 game.nds
#
#   Pick --frames so the game is on a BUSY 3D screen, not a title card. The bench
#   prints the polygon count it found; if that is 0 you captured a menu and the
#   timing below means nothing. Iterate on the desktop, where 900 frames take
#   seconds, before touching the board.
#
# STEP 2, here:
#
#   tools/a9-raster-bench.sh --rom game.nds --state scene.mln
#   HOST=192.168.1.243 tools/a9-raster-bench.sh --remote-rom /media/fat/games/NDS/g.nds --frames 900
#
# The ROM is needed on the board even with a savestate: melonDS states carry
# machine state, not cart contents, so the cart has to be inserted before the
# state loads. --remote-rom uses one that is already there rather than copying
# a 128 MB image over scp.
set -eu

HOST="${HOST:-192.168.1.243}"
BENCHDIR="${BENCHDIR:-/media/fat/nds-bench}"
SSH="ssh -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new"
SCP="scp -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new"

cd "$(dirname "$0")/.."
BIN="sim/melonds_tracer/build-armhf/melonds_gxbench"

ROM=""; REMOTE_ROM=""; STATE=""; ITERS=300; FRAMES=0
while [ $# -gt 0 ]; do
   case "$1" in
      --rom)        ROM="$2"; shift 2 ;;
      --remote-rom) REMOTE_ROM="$2"; shift 2 ;;
      --state)      STATE="$2"; shift 2 ;;
      --iters)      ITERS="$2"; shift 2 ;;
      --frames)     FRAMES="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
   esac
done

[ -f "$BIN" ] || { echo "no armhf binary - run sim/melonds_tracer/build-armhf.sh" >&2; exit 1; }
[ -n "$ROM" ] || [ -n "$REMOTE_ROM" ] || { echo "need --rom or --remote-rom" >&2; exit 2; }

if ! $SSH "root@$HOST" true 2>/dev/null; then
   echo "cannot reach root@$HOST - is the board powered on and on the network?" >&2
   exit 3
fi

$SSH "root@$HOST" "mkdir -p '$BENCHDIR'"

echo "== uploading bench binary ($(wc -c < "$BIN" | tr -d ' ') bytes)"
$SCP "$BIN" "root@$HOST:$BENCHDIR/melonds_gxbench"
$SSH "root@$HOST" "chmod +x '$BENCHDIR/melonds_gxbench'"

if [ -n "$ROM" ]; then
   [ -f "$ROM" ] || { echo "no such ROM: $ROM" >&2; exit 1; }
   REMOTE_ROM="$BENCHDIR/$(basename "$ROM")"
   echo "== uploading ROM $(basename "$ROM") ($(wc -c < "$ROM" | tr -d ' ') bytes)"
   $SCP "$ROM" "root@$HOST:$REMOTE_ROM"
fi

ARGS="--iters $ITERS"
[ "$FRAMES" -gt 0 ] && ARGS="$ARGS --frames $FRAMES"
if [ -n "$STATE" ]; then
   [ -f "$STATE" ] || { echo "no such state: $STATE" >&2; exit 1; }
   echo "== uploading state $(basename "$STATE")"
   $SCP "$STATE" "root@$HOST:$BENCHDIR/$(basename "$STATE")"
   ARGS="$ARGS --state $BENCHDIR/$(basename "$STATE")"
fi

# The CPU's actual clock and governor are part of the result. A number measured
# at 800 MHz means something different from one measured at 400, and MiSTer
# images have shipped with both ondemand and performance governors.
echo
echo "== board CPU state"
$SSH "root@$HOST" '
   grep -m1 "model name\|Processor" /proc/cpuinfo || true
   echo "cores: $(nproc)"
   for c in /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq \
            /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do
      [ -r "$c" ] && echo "$(basename "$c"): $(cat "$c")"
   done
   uptime
' || true

# taskset pins to core 0 so the scheduler cannot migrate the run mid-measurement
# and smear the percentiles. MiSTer's own main process runs on this box, so the
# p95 matters more than the min: it is what the core would actually see.
echo
echo "== running: melonds_gxbench $ARGS $REMOTE_ROM"
echo
$SSH "root@$HOST" "cd '$BENCHDIR' && taskset -c 0 ./melonds_gxbench $ARGS '$REMOTE_ROM'"
