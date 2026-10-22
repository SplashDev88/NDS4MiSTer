#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm --network none -v "$repo/tools/fixtures/fmv_color:/src:ro" \
  nds4mister-armhf:ubuntu-24.04 sh -c '
    arm-linux-gnueabihf-g++ -std=c++17 -O2 -static -mcpu=cortex-a9 \
      -mfpu=neon -mfloat-abi=hard /src/test_clamp.cpp /src/test_clamp.S \
      -o /tmp/test-clamp && /tmp/test-clamp
  '
