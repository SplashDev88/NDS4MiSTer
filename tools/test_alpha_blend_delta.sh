#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-alpha-blend-delta.XXXXXX")
sanitizer_binary=$(mktemp "${TMPDIR:-/tmp}/nds-alpha-blend-delta-san.XXXXXX")
trap 'rm -f "$host_binary" "$sanitizer_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_alpha_blend_delta.cpp" \
    -o "$host_binary"
"$host_binary"

${CXX:-c++} -std=c++17 -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_alpha_blend_delta.cpp" \
    -o "$sanitizer_binary"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
    "$sanitizer_binary"

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
        set -eu
        binary=/tmp/nds-alpha-blend-delta-arm
        disassembly=/tmp/nds-alpha-blend-delta-arm.dis
        helper=/tmp/nds-alpha-blend-delta-arm.helper.dis
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Wall -Wextra -Werror \
            -Wno-unused-parameter -Wno-missing-braces \
            -Ithird_party/melonDS/src \
            tools/test_alpha_blend_delta.cpp -o "$binary"
        "$binary"
        arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
        sed -n "/<nds_test_alpha_blend_delta>:/,/^$/p" \
            "$disassembly" >"$helper"
        ! grep -Eq "bl.*<__aeabi_(u?idiv|uidivmod|uldivmod)>" "$helper"
        multiply_count=$(grep -Ec "[[:space:]](mul|mla|mls)" "$helper")
        if [ "$multiply_count" -ne 3 ]; then
            echo "FAIL: expected three channel multiplies, got $multiply_count" >&2
            cat "$helper" >&2
            exit 1
        fi
        if grep -Eq "v(push|pop)|v(ld|st)r.*\\[sp" "$helper"; then
            echo "FAIL: alpha blend delta kernel spills vector state" >&2
            exit 1
        fi
        instructions=$(grep -Ec "^[[:space:]]*[0-9a-f]+:" "$helper")
        echo "H3D_ALPHA_BLEND_DELTA_ASSEMBLY instructions=$instructions multiplies=$multiply_count vector_spills=0"
        if [ -d /evidence ]; then
            cp "$helper" /evidence/alpha-blend-delta.helper.dis
            printf "instructions=%s\nmultiplies=%s\nvector_spills=0\n" \
                "$instructions" "$multiply_count" \
                >/evidence/alpha-blend-delta-assembly-summary.txt
            sha256sum "$binary" >/evidence/alpha-blend-delta-test.sha256
        fi
    '

echo "PASS: host/ARM exact alpha blend delta oracle"
