#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-texture-binding.XXXXXX")
sanitize_binary=$(mktemp "${TMPDIR:-/tmp}/nds-texture-binding-san.XXXXXX")
trap 'rm -f "$host_binary" "$sanitize_binary"' EXIT INT TERM

common_flags=(
    -std=c++17 -Wall -Wextra -Werror
    -Wno-unused-parameter -Wno-missing-braces
    -I"$repo_root/third_party/melonDS/src"
)
${CXX:-c++} "${common_flags[@]}" -O3 \
    "$repo_root/tools/test_texture_binding_validity.cpp" \
    -o "$host_binary"
"$host_binary"

${CXX:-c++} "${common_flags[@]}" -O1 -g \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$repo_root/tools/test_texture_binding_validity.cpp" \
    -o "$sanitize_binary"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
    "$sanitize_binary"

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
    set -eu
    binary=/tmp/nds-texture-binding-arm
    disassembly=/tmp/nds-texture-binding-arm.dis
    helper=/tmp/nds-texture-binding-arm.helper.dis
    arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
        -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
        -Wall -Wextra -Werror \
        -Wno-unused-parameter -Wno-missing-braces \
        -Ithird_party/melonDS/src \
        tools/test_texture_binding_validity.cpp -o "$binary"
    "$binary"
    arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
    sed -n "/<nds_test_texture_binding_match>:/,/^$/p" \
        "$disassembly" >"$helper"
    comparisons=$(grep -Ec "[[:space:]]cmp(eq)?([.]w)?[[:space:]]" "$helper")
    calls=$(grep -Ec "[[:space:]]blx?([.]w)?[[:space:]]" "$helper" || true)
    null_compares=$(grep -Ec "[[:space:]]cmp([.]w)?[[:space:]]+r[0-9]+,[[:space:]]*#0" "$helper" || true)
    instructions=$(grep -Ec "^[[:space:]]*[0-9a-f]+:" "$helper")
    if [ "$comparisons" -ne 2 ] || [ "$calls" -ne 0 ] || [ "$null_compares" -ne 0 ]; then
        echo "FAIL: expected two key compares, no call, and no pointer-null compare" >&2
        cat "$helper" >&2
        exit 1
    fi
    echo "H3D_TEXTURE_BINDING_ASSEMBLY instructions=$instructions comparisons=$comparisons calls=$calls pointer_null_compares=$null_compares"
    if [ -d /evidence ]; then
        cp "$helper" /evidence/texture-binding.helper.dis
        printf "instructions=%s\ncomparisons=%s\ncalls=%s\npointer_null_compares=%s\n" \
            "$instructions" "$comparisons" "$calls" "$null_compares" \
            >/evidence/texture-binding-assembly-summary.txt
        sha256sum "$binary" >/evidence/texture-binding-test.sha256
    fi
'

echo "PASS: host/sanitizer/ARM texture-binding validity oracle"
