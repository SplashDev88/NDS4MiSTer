#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-fast-divide.XXXXXX")
trap 'rm -f "$host_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_soft_renderer_fast_divide.cpp" \
    -o "$host_binary"
"$host_binary"

docker run --rm --network none \
    -v "$repo_root:/workspace:ro" -w /workspace "$image" sh -lc '
        set -eu
        binary=/tmp/nds-soft-renderer-fast-divide-arm
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Ithird_party/melonDS/src \
            tools/test_soft_renderer_fast_divide.cpp -o "$binary"
        "$binary"
        arm-linux-gnueabihf-objdump -d -C "$binary" \
            >/tmp/nds-soft-renderer-fast-divide-arm.dis
        ! sed -n "/<nds_test_div_u32_exact>:/,/^$/p" \
            /tmp/nds-soft-renderer-fast-divide-arm.dis |
            grep -Eq "bl.*<__aeabi_(u?idiv|uidivmod)>"
        ! sed -n "/<nds_test_scale_permille_ceil>:/,/^$/p" \
            /tmp/nds-soft-renderer-fast-divide-arm.dis |
            grep -Eq "bl.*<__aeabi_(u?idiv|uidivmod|uldivmod)>"
        ! sed -n "/<nds_test_div_prepared_u32>:/,/^$/p" \
            /tmp/nds-soft-renderer-fast-divide-arm.dis |
            grep -Eq "bl.*<__aeabi_(u?idiv|uidivmod|uldivmod)>"
        ! sed -n "/<nds_test_div_factor_delta_exact>:/,/^$/p" \
            /tmp/nds-soft-renderer-fast-divide-arm.dis |
            grep -Eq "(vrecpe|vrecps|vdiv|bl.*<__aeabi_(u?idiv|uidivmod|uldivmod)>)"
        grep -A80 -m1 "<nds_test_div_u32_exact>:" \
            /tmp/nds-soft-renderer-fast-divide-arm.dis |
            grep -Eq "vdiv.f64"
        sed -n "/<nds_test_texture_indices4>:/,/^$/p" \
            /tmp/nds-soft-renderer-fast-divide-arm.dis |
            grep -q "vshl.u32"
    '

echo "PASS: host/ARM soft-renderer fast-divide regression"
