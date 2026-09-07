#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-ncolor4-decode.XXXXXX")
sanitize_binary=$(mktemp "${TMPDIR:-/tmp}/nds-ncolor4-decode-sanitize.XXXXXX")
trap 'rm -f "$host_binary" "$sanitize_binary"' EXIT INT TERM

common_flags=(
    -std=c++17 -Wall -Wextra -Werror
    -Wno-unused-parameter -Wno-missing-braces
    -I"$repo_root/third_party/melonDS/src"
)
${CXX:-c++} "${common_flags[@]}" -O3 \
    "$repo_root/tools/test_ncolor4_palette_decode.cpp" \
    -o "$host_binary"
"$host_binary"

${CXX:-c++} "${common_flags[@]}" -O1 -g \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$repo_root/tools/test_ncolor4_palette_decode.cpp" \
    -o "$sanitize_binary"
"$sanitize_binary"

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
    set -eu
    binary=/tmp/nds-ncolor4-decode-arm
    disassembly=/tmp/nds-ncolor4-decode-arm.dis
    helper=/tmp/nds-ncolor4-decode-arm.helper.dis
    arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
        -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
        -Wall -Wextra -Werror \
        -Wno-unused-parameter -Wno-missing-braces \
        -Ithird_party/melonDS/src \
        tools/test_ncolor4_palette_decode.cpp -o "$binary"
    "$binary"
    arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
    sed -n "/<nds_test_ncolor4_decode>:/,/^$/p" \
        "$disassembly" >"$helper"
    instructions=$(grep -Ec "^[[:space:]]*[0-9a-f]+:" "$helper")
    indexed_loads=$(grep -Ec "ldr.*\[r[0-9]+,.*lsl #2\]" "$helper")
    if [ "$indexed_loads" -ne 4 ]; then
        echo "FAIL: expected four indexed palette loads, got $indexed_loads" >&2
        cat "$helper" >&2
        exit 1
    fi
    if grep -Eq "\b(bl|blx)\b" "$helper"; then
        echo "FAIL: packed-word helper contains a call" >&2
        cat "$helper" >&2
        exit 1
    fi
    echo "H3D_NCOLOR4_ASSEMBLY instructions=$instructions indexed_palette_loads=$indexed_loads"
    if [ -d /evidence ]; then
        cp "$helper" /evidence/ncolor4-decode.helper.dis
        printf "instructions=%s\nindexed_palette_loads=%s\n" \
            "$instructions" "$indexed_loads" \
            >/evidence/ncolor4-decode-assembly-summary.txt
        sha256sum "$binary" >/evidence/ncolor4-decode-test.sha256
    fi
'

echo "PASS: host/sanitizer/ARM 4bpp staged-palette decode oracle"
