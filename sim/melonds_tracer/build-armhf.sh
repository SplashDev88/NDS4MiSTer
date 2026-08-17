#!/bin/sh
# Cross-build melonds_gxbench for the DE10-Nano's Cortex-A9 (armhf, static).
#
#   MELONDS_DIR=~/sources/melonDS sim/melonds_tracer/build-armhf.sh
#   -> sim/melonds_tracer/build-armhf/melonds_gxbench
#
# WHY DOCKER. There is no armhf cross-toolchain on the dev machine and MiSTer's
# userland has no compiler, so the binary has to come from somewhere. A Debian
# container matching the HOST arch (arm64 here, amd64 on a Linux box) running
# crossbuild-essential-armhf compiles at native speed — no qemu anywhere in the
# loop. Building inside an arm/v7 container instead would be emulated on Apple
# Silicon, which turns a 2-minute build into a 40-minute one.
#
# The toolchain image is cached under a tag, so only the first run pays for apt.
set -eu
cd "$(dirname "$0")"

MELONDS_DIR="${MELONDS_DIR:-$HOME/sources/melonDS}"
IMAGE="nds-armhf-xc:bookworm"

[ -d "$MELONDS_DIR" ] || { echo "no melonDS checkout at $MELONDS_DIR - run build.sh first" >&2; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
   echo "== building toolchain image $IMAGE (first run only)"
   docker build -t "$IMAGE" - <<'EOF'
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
        crossbuild-essential-armhf cmake ninja-build make \
    && rm -rf /var/lib/apt/lists/*
EOF
fi

echo "== cross-compiling melonds_gxbench for armhf"
docker run --rm \
   -v "$(pwd):/harness" \
   -v "$MELONDS_DIR:/melonds:ro" \
   -w /harness \
   "$IMAGE" sh -c '
      set -e
      cmake -S /harness -B /harness/build-armhf -G Ninja \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_TOOLCHAIN_FILE=/harness/armhf-toolchain.cmake \
         -DMELONDS_DIR=/melonds
      cmake --build /harness/build-armhf --target melonds_gxbench
   '

BIN="$(pwd)/build-armhf/melonds_gxbench"
echo "== built: $BIN"
file "$BIN" 2>/dev/null || true
