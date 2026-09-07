#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-cached-translucent.XXXXXX")
sanitizer_binary=$(mktemp "${TMPDIR:-/tmp}/nds-cached-translucent-san.XXXXXX")
trap 'rm -f "$host_binary" "$sanitizer_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_cached_translucent_modulate.cpp" \
    -o "$host_binary"
"$host_binary"

${CXX:-c++} -std=c++17 -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_cached_translucent_modulate.cpp" \
    -o "$sanitizer_binary"
"$sanitizer_binary"

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
        set -eu
        binary=/tmp/nds-cached-translucent-arm
        disassembly=/tmp/nds-cached-translucent-arm.dis
        helper=/tmp/nds-cached-translucent-arm.helper.dis
        visible_helper=/tmp/nds-visible-cached-modulate-arm.helper.dis
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Wall -Wextra -Werror \
            -Wno-unused-parameter -Wno-missing-braces \
            -Ithird_party/melonDS/src \
            tools/test_cached_translucent_modulate.cpp -o "$binary"
        "$binary"
        arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
        sed -n "/<nds_test_cached_translucent_modulate>:/,/^$/p" \
            "$disassembly" >"$helper"
        sed -n "/<nds_test_visible_cached_modulate>:/,/^$/p" \
            "$disassembly" >"$visible_helper"
        ! grep -Eq "bl.*<__aeabi_(u?idiv|uidivmod|uldivmod)>" "$helper"
        ! grep -Eq "bl.*<__aeabi_(u?idiv|uidivmod|uldivmod)>" \
            "$visible_helper"
        if grep -Eq "v(push|pop)|v(ld|st)r.*\\[sp" "$helper"; then
            echo "FAIL: cached translucent kernel spills vector state" >&2
            exit 1
        fi
        alpha_branch_line=$(grep -n -m1 "[[:space:]]bcs" \
            "$visible_helper" | cut -d: -f1)
        rgb_unpack_line=$(grep -n -m1 \
            "ubfx.*#8, #6" "$visible_helper" | cut -d: -f1)
        if [ -z "$alpha_branch_line" ] || [ -z "$rgb_unpack_line" ] || \
            [ "$alpha_branch_line" -ge "$rgb_unpack_line" ]; then
            echo "FAIL: visible cached kernel does not reject before RGB" >&2
            exit 1
        fi
        instructions=$(grep -Ec "^[[:space:]]*[0-9a-f]+:" "$helper")
        visible_instructions=$(grep -Ec \
            "^[[:space:]]*[0-9a-f]+:" "$visible_helper")
        echo "H3D_CACHED_TRANSLUCENT_ASSEMBLY instructions=$instructions visible_instructions=$visible_instructions alpha_branch_before_rgb=1 vector_spills=0"
        if [ -d /evidence ]; then
            cp "$helper" /evidence/cached-translucent-modulate.helper.dis
            cp "$visible_helper" \
                /evidence/visible-cached-modulate.helper.dis
            printf "instructions=%s\\nvisible_instructions=%s\\nalpha_branch_before_rgb=1\\nvector_spills=0\\n" \
                "$instructions" "$visible_instructions" \
                >/evidence/cached-translucent-modulate-assembly-summary.txt
            sha256sum "$binary" \
                >/evidence/cached-translucent-modulate-test.sha256
        fi
    '

echo "PASS: host/ARM cached translucent modulation oracle"
