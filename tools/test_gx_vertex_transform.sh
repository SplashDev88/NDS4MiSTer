#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="${IMAGE:-nds4mister-armhf:ubuntu-24.04}"
host_binary="${TMPDIR:-/tmp}/nds4mister-test-gx-vertex-transform"

cleanup() {
    rm -f "$host_binary"
}
trap cleanup EXIT INT TERM

c++ -std=c++17 -O3 -Wall -Wextra -Werror \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_gx_vertex_transform.cpp" \
    -o "$host_binary"
"$host_binary"

docker run --rm --network none \
    -v "$repo_root:/workspace:ro" \
    -w /workspace \
    "$image" \
    sh -lc '
        set -eu
        binary=/tmp/nds4mister-test-gx-vertex-transform-arm
        arm-linux-gnueabihf-g++ \
            -std=c++17 -O3 -static -mcpu=cortex-a9 -mfpu=neon \
            -mfloat-abi=hard -Wall -Wextra -Werror \
            -Ithird_party/melonDS/src \
            tools/test_gx_vertex_transform.cpp \
            -o "$binary"
        arm-linux-gnueabihf-objdump -d "$binary" \
            >/tmp/nds4mister-test-gx-vertex-transform-arm.dis
        grep -Eq "vmull\\.s32" \
            /tmp/nds4mister-test-gx-vertex-transform-arm.dis
        grep -Eq "vmlal\\.s32" \
            /tmp/nds4mister-test-gx-vertex-transform-arm.dis
        "$binary"
        rm -f "$binary" /tmp/nds4mister-test-gx-vertex-transform-arm.dis
    '

echo "PASS: host and Cortex-A9 NEON GX vertex-transform regression"
