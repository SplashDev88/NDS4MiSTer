#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-factor-ceil.XXXXXX")
trap 'rm -f "$host_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_perspective_factor_ceil.cpp" -o "$host_binary"
"$host_binary"

docker run --rm --network none \
    -v "$repo_root:/workspace:ro" -w /workspace "$image" sh -lc '
        set -eu
        binary=/tmp/nds-factor-ceil-arm
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Ithird_party/melonDS/src \
            tools/test_perspective_factor_ceil.cpp -o "$binary"
        "$binary"
    '

echo "PASS: host/ARM bounded perspective-factor ceil regression"
