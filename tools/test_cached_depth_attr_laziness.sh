#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-cached-depth-attr.XXXXXX")
sanitizer_binary=$(mktemp "${TMPDIR:-/tmp}/nds-cached-depth-attr-san.XXXXXX")
trap 'rm -f "$host_binary" "$sanitizer_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_cached_depth_attr_laziness.cpp" \
    -o "$host_binary"
"$host_binary"

${CXX:-c++} -std=c++17 -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_cached_depth_attr_laziness.cpp" \
    -o "$sanitizer_binary"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
    "$sanitizer_binary"

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
        set -eu
        binary=/tmp/nds-cached-depth-attr-arm
        disassembly=/tmp/nds-cached-depth-attr-arm.dis
        helper=/tmp/nds-cached-depth-attr-arm.helper.dis
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Wall -Wextra -Werror \
            -Wno-unused-parameter -Wno-missing-braces \
            -Ithird_party/melonDS/src \
            tools/test_cached_depth_attr_laziness.cpp -o "$binary"
        "$binary"
        arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
        sed -n "/<nds_test_cached_depth_select>:/,/^$/p" \
            "$disassembly" >"$helper"
        ! grep -Eq "[[:space:]]bl[x]?[[:space:]]" "$helper"
        ! grep -Eq "__aeabi_(u?idiv|uidivmod|uldivmod)" "$helper"
        ! grep -Eq "v(push|pop)|v(ld|st)r.*\\[sp" "$helper"
        instructions=$(grep -Ec "^[[:space:]]*[0-9a-f]+:" "$helper")
        attr_loads=$(grep -Ec "[[:space:]]ldr([.]w)?[[:space:]].*\\[r1" "$helper")
        if [ "$attr_loads" -lt 1 ]; then
            echo "FAIL: expected conditional AttrBuffer loads in helper" >&2
            cat "$helper" >&2
            exit 1
        fi
        echo "H3D_CACHED_DEPTH_ATTR_ASSEMBLY instructions=$instructions attr_load_sites=$attr_loads calls=0 vector_spills=0"
        if [ -d /evidence ]; then
            cp "$helper" /evidence/cached-depth-attr.helper.dis
            printf "instructions=%s\\nattr_load_sites=%s\\ncalls=0\\nvector_spills=0\\n" \
                "$instructions" "$attr_loads" \
                >/evidence/cached-depth-attr-assembly-summary.txt
            sha256sum "$binary" \
                >/evidence/cached-depth-attr-test.sha256
        fi
    '

echo "PASS: host/sanitizer/ARM cached depth lazy-attribute oracle"
