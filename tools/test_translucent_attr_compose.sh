#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-translucent-attr.XXXXXX")
sanitizer_binary=$(mktemp "${TMPDIR:-/tmp}/nds-translucent-attr-san.XXXXXX")
trap 'rm -f "$host_binary" "$sanitizer_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_translucent_attr_compose.cpp" \
    -o "$host_binary"
"$host_binary"

${CXX:-c++} -std=c++17 -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_translucent_attr_compose.cpp" \
    -o "$sanitizer_binary"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
    "$sanitizer_binary"

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
        set -eu
        binary=/tmp/nds-translucent-attr-arm
        disassembly=/tmp/nds-translucent-attr-arm.dis
        helper=/tmp/nds-translucent-attr-arm.helper.dis
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Wall -Wextra -Werror \
            -Wno-unused-parameter -Wno-missing-braces \
            -Ithird_party/melonDS/src \
            tools/test_translucent_attr_compose.cpp -o "$binary"
        "$binary"
        arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
        sed -n "/<nds_test_translucent_attr_compose>:/,/^$/p" \
            "$disassembly" >"$helper"
        grep -Eq "[[:space:]]bfi[.]?[a-z]*[[:space:]]" "$helper"
        ! grep -Eq "[[:space:]]bl[x]?[[:space:]]" "$helper"
        ! grep -Eq "v(push|pop)|v(ld|st)r.*\\[sp" "$helper"
        instructions=$(grep -E "^[[:space:]]*[0-9a-f]+:" "$helper" | \
            grep -Evc "[[:space:]]nop([[:space:]]|$)")
        if [ "$instructions" -gt 8 ]; then
            echo "FAIL: expected no more than eight helper instructions, got $instructions" >&2
            cat "$helper" >&2
            exit 1
        fi
        echo "H3D_TRANSLUCENT_ATTR_ASSEMBLY instructions=$instructions bfi=1 calls=0 vector_spills=0"
        if [ -d /evidence ]; then
            cp "$helper" /evidence/translucent-attr.helper.dis
            printf "instructions=%s\\nbfi=1\\ncalls=0\\nvector_spills=0\\n" \
                "$instructions" \
                >/evidence/translucent-attr-assembly-summary.txt
            sha256sum "$binary" \
                >/evidence/translucent-attr-test.sha256
        fi
    '

echo "PASS: host/sanitizer/ARM translucent attribute oracle"
