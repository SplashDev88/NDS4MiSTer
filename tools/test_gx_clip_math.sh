#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="${IMAGE:-nds4mister-armhf:ubuntu-24.04}"
host_binary="${TMPDIR:-/tmp}/nds4mister-test-gx-clip-math"

cleanup() {
    rm -f "$host_binary"
}
trap cleanup EXIT INT TERM

c++ -std=c++17 -O3 -Wall -Wextra -Werror \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_gx_clip_math.cpp" \
    -o "$host_binary"
"$host_binary"

docker run --rm \
    -v "$repo_root:/workspace:ro" \
    -w /workspace \
    "$image" \
    sh -lc '
        set -eu
        binary=/tmp/nds4mister-test-gx-clip-math-arm
        arm-linux-gnueabihf-g++ \
            -std=c++17 -O3 -static -Wall -Wextra -Werror \
            -Ithird_party/melonDS/src \
            tools/test_gx_clip_math.cpp \
            -o "$binary"
        arm-linux-gnueabihf-objdump -d --disassemble=main "$binary" \
            >/tmp/nds4mister-test-gx-clip-math-arm.main
        ! grep -Eq "bl.*<__aeabi_(l|ul)div" \
            /tmp/nds4mister-test-gx-clip-math-arm.main
        grep -Eq "umull|umlal" \
            /tmp/nds4mister-test-gx-clip-math-arm.main
        "$binary"
        rm -f "$binary" /tmp/nds4mister-test-gx-clip-math-arm.main
    '

echo "PASS: host and ARM GX clip wrap-alias regression"
