#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-viewport-divide-host.XXXXXX")
trap 'rm -f "$host_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/benchmark_gx_viewport_divide.cpp" \
    -o "$host_binary"
"$host_binary"

docker run --rm --network none \
    -v "$repo_root:/workspace:ro" -w /workspace "$image" sh -lc '
        set -eu
        binary=/tmp/nds-viewport-divide-arm
        disassembly=/tmp/nds-viewport-divide-arm.dis
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Ithird_party/melonDS/src \
            tools/benchmark_gx_viewport_divide.cpp -o "$binary"
        "$binary"
        arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
        sed -n "/<oldViewportDivide>:/,/^$/p" "$disassembly" |
            grep -q "bl.*<__udivsi3>"
        ! sed -n "/<fastViewportDivide>:/,/^$/p" "$disassembly" |
            grep -Eq "vdiv|vrecpe|vrecps"
        sed -n "/<fastViewportDivide>:/,/^$/p" "$disassembly" |
            grep -q "umull"
    '
