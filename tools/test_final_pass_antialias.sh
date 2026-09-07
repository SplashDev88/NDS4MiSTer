#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
fixture=${1:-}
if [[ $# -gt 1 ]]; then
    echo "usage: $0 [compact-aa-only-fixture.hgs]" >&2
    exit 2
fi
if [[ -n "$fixture" && ! -f "$fixture" ]]; then
    echo "FAIL: fixture does not exist: $fixture" >&2
    exit 2
fi
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-final-pass-aa.XXXXXX")
trap 'rm -f "$host_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_final_pass_antialias.cpp" \
    -o "$host_binary"
if [[ -n "$fixture" ]]; then
    "$host_binary" "$fixture"
else
    "$host_binary"
fi

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi
if [[ -n "$fixture" ]]; then
    docker_args+=(-v "$fixture:/fixture/aa-only.hgs:ro")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
        set -eu
        binary=/tmp/nds-final-pass-aa-arm
        disassembly=/tmp/nds-final-pass-aa-arm.dis
        block_helper=/tmp/nds-final-pass-aa-arm.block.dis
        pixel_wrapper=/tmp/nds-final-pass-aa-arm.pixel-wrapper.dis
        pixel_kernel=/tmp/nds-final-pass-aa-arm.pixel-kernel.dis
        scanline_wrapper=/tmp/nds-final-pass-aa-arm.scanline-wrapper.dis
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Wall -Wextra -Werror \
            -Wno-unused-parameter -Wno-missing-braces \
            -Ithird_party/melonDS/src \
            tools/test_final_pass_antialias.cpp -o "$binary"
        if [ -f /fixture/aa-only.hgs ]; then
            "$binary" /fixture/aa-only.hgs
        else
            "$binary"
        fi
        arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
        sed -n "/<nds_test_antialias_block_has_edge>:/,/^$/p" \
            "$disassembly" >"$block_helper"
        sed -n "/<nds_test_apply_antialias_pixel>:/,/^$/p" \
            "$disassembly" >"$pixel_wrapper"
        sed -n "/^[0-9a-f].*<melonDS::NDS4MiSTerApplyAntiAliasPixel/,/^$/p" \
            "$disassembly" >"$pixel_kernel"
        sed -n "/<nds_test_apply_antialias_scanline>:/,/^$/p" \
            "$disassembly" >"$scanline_wrapper"
        grep -Eq "ldr|ldm" "$block_helper"
        grep -q "orr" "$block_helper"
        grep -q "NDS4MiSTerApplyAntiAliasPixel" "$pixel_kernel"
        grep -q "NDS4MiSTerApplyAntiAliasPixel" "$scanline_wrapper"
        if grep -Eq "v(push|pop)|v(ld|st)r|[[:space:]]v[a-z]" \
            "$block_helper" "$pixel_wrapper" "$pixel_kernel" \
            "$scanline_wrapper"; then
            echo "FAIL: scalar antialias helpers use NEON" >&2
            exit 1
        fi
        block_instructions=$(grep -Ec \
            "^[[:space:]]*[0-9a-f]+:" "$block_helper")
        pixel_wrapper_instructions=$(grep -Ec \
            "^[[:space:]]*[0-9a-f]+:" "$pixel_wrapper")
        pixel_kernel_instructions=$(grep -Ec \
            "^[[:space:]]*[0-9a-f]+:" "$pixel_kernel")
        scanline_wrapper_instructions=$(grep -Ec \
            "^[[:space:]]*[0-9a-f]+:" "$scanline_wrapper")
        echo "H3D_FINAL_PASS_AA_ASSEMBLY block_instructions=$block_instructions pixel_wrapper_instructions=$pixel_wrapper_instructions pixel_kernel_instructions=$pixel_kernel_instructions scanline_wrapper_instructions=$scanline_wrapper_instructions neon=0"
        if [ -d /evidence ]; then
            cp "$block_helper" /evidence/final-pass-aa-block.helper.dis
            cp "$pixel_wrapper" /evidence/final-pass-aa-pixel-wrapper.helper.dis
            cp "$pixel_kernel" /evidence/final-pass-aa-pixel-kernel.helper.dis
            cp "$scanline_wrapper" /evidence/final-pass-aa-scanline-wrapper.helper.dis
            printf "block_instructions=%s\npixel_wrapper_instructions=%s\npixel_kernel_instructions=%s\nscanline_wrapper_instructions=%s\nneon=0\n" \
                "$block_instructions" "$pixel_wrapper_instructions" \
                "$pixel_kernel_instructions" "$scanline_wrapper_instructions" \
                >/evidence/final-pass-aa-assembly-summary.txt
            sha256sum "$binary" \
                >/evidence/final-pass-aa-test.sha256
        fi
    '

echo "PASS: host/ARM final-pass antialias oracle"
