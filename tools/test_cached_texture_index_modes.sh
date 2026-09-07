#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-cached-texture-index.XXXXXX")
sanitizer_binary=$(mktemp "${TMPDIR:-/tmp}/nds-cached-texture-index-san.XXXXXX")
trap 'rm -f "$host_binary" "$sanitizer_binary"' EXIT INT TERM

common_flags=(
    -std=c++17 -Wall -Wextra -Werror
    -Wno-unused-parameter -Wno-missing-braces
    -I"$repo_root/third_party/melonDS/src"
)
${CXX:-c++} "${common_flags[@]}" -O3 \
    "$repo_root/tools/test_cached_texture_index_modes.cpp" \
    -o "$host_binary"
"$host_binary"

${CXX:-c++} "${common_flags[@]}" -O1 -g \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$repo_root/tools/test_cached_texture_index_modes.cpp" \
    -o "$sanitizer_binary"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
    "$sanitizer_binary"

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
    set -eu
    binary=/tmp/nds-cached-texture-index-arm
    disassembly=/tmp/nds-cached-texture-index-arm.dis
    helper=/tmp/nds-cached-texture-index-arm.helper.dis
    mode0=/tmp/nds-cached-texture-index-arm.mode0.dis
    mode3=/tmp/nds-cached-texture-index-arm.mode3.dis
    generic=/tmp/nds-cached-texture-index-arm.generic.dis
    arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
        -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
        -Wall -Wextra -Werror \
        -Wno-unused-parameter -Wno-missing-braces \
        -Ithird_party/melonDS/src \
        tools/test_cached_texture_index_modes.cpp -o "$binary"
    "$binary"
    arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
    sed -n "/<nds_test_cached_texture_index_modes>:/,/^$/p" \
        "$disassembly" >"$helper"
    sed -n "/<nds_test_cached_texture_index_mode0>:/,/^$/p" \
        "$disassembly" >"$mode0"
    sed -n "/<nds_test_cached_texture_index_mode3>:/,/^$/p" \
        "$disassembly" >"$mode3"
    sed -n "/<nds_test_cached_texture_index_generic>:/,/^$/p" \
        "$disassembly" >"$generic"
    cat "$mode0" "$mode3" "$generic" >>"$helper"
    calls=$(grep -Ec "[[:space:]]blx?([.]w)?[[:space:]]" "$helper" || true)
    divisions=$(grep -Ec "__aeabi_(u?idiv|uidivmod|uldivmod)" "$helper" || true)
    vector_spills=$(grep -Ec "v(push|pop)|v(ld|st)r.*\\[sp" "$helper" || true)
    instructions=$(grep -Ec "^[[:space:]]*[0-9a-f]+:" "$helper")
    mode0_instructions=$(grep -Ec \
        "^[[:space:]]*[0-9a-f]+:" "$mode0")
    mode3_instructions=$(grep -Ec \
        "^[[:space:]]*[0-9a-f]+:" "$mode3")
    generic_instructions=$(grep -Ec \
        "^[[:space:]]*[0-9a-f]+:" "$generic")
    if [ "$calls" -ne 0 ] || [ "$divisions" -ne 0 ] || \
       [ "$vector_spills" -ne 0 ]; then
        echo "FAIL: cached texture index helper has a call, divide, or vector spill" >&2
        cat "$helper" >&2
        exit 1
    fi
    echo "H3D_CACHED_TEXTURE_INDEX_MODES_ASSEMBLY instructions=$instructions mode0_instructions=$mode0_instructions mode3_instructions=$mode3_instructions generic_instructions=$generic_instructions calls=$calls divisions=$divisions vector_spills=$vector_spills"
    if [ -d /evidence ]; then
        cp "$helper" /evidence/cached-texture-index-modes.helper.dis
        printf "instructions=%s\nmode0_instructions=%s\nmode3_instructions=%s\ngeneric_instructions=%s\ncalls=%s\ndivisions=%s\nvector_spills=%s\n" \
            "$instructions" "$mode0_instructions" \
            "$mode3_instructions" "$generic_instructions" \
            "$calls" "$divisions" "$vector_spills" \
            >/evidence/cached-texture-index-modes-assembly-summary.txt
        sha256sum "$binary" \
            >/evidence/cached-texture-index-modes-test.sha256
    fi
'

echo "PASS: host/sanitizer/ARM cached texture-index mode oracle"
