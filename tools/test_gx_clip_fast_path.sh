#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="${IMAGE:-nds4mister-armhf:ubuntu-24.04}"
host_binary="${TMPDIR:-/tmp}/nds4mister-test-gx-clip-fast-path"

cleanup() {
    rm -f "$host_binary"
}
trap cleanup EXIT INT TERM

c++ -std=c++17 -O3 -Wall -Wextra -Werror \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_gx_clip_fast_path.cpp" \
    -o "$host_binary"
"$host_binary"

c++ -std=c++17 -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined -Wall -Wextra -Werror \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_gx_clip_fast_path.cpp" \
    -o "$host_binary"
ASAN_OPTIONS=detect_leaks=0 "$host_binary"

docker run --rm --network none \
    -v "$repo_root:/workspace:ro" \
    -w /workspace \
    "$image" \
    sh -lc '
        set -eu
        binary=/tmp/nds4mister-test-gx-clip-fast-path-arm
        arm-linux-gnueabihf-g++ \
            -std=c++17 -O3 -static -Wall -Wextra -Werror \
            -Ithird_party/melonDS/src \
            tools/test_gx_clip_fast_path.cpp \
            -o "$binary"
        arm-linux-gnueabihf-objdump -d \
            --disassemble=nds_test_clip_fast_path "$binary" \
            >/tmp/nds4mister-test-gx-clip-fast-path-arm.asm
        ! grep -Eq "bl.*<(memcpy|memcmp|__aeabi_)" \
            /tmp/nds4mister-test-gx-clip-fast-path-arm.asm
        grep -Eq "cmp|cmn" \
            /tmp/nds4mister-test-gx-clip-fast-path-arm.asm
        "$binary"
        rm -f "$binary" \
            /tmp/nds4mister-test-gx-clip-fast-path-arm.asm
    '

echo "PASS: host, sanitizer, and ARM GX clip fast-path regression"
