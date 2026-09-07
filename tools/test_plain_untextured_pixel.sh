#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
evidence_dir=${EVIDENCE_DIR:-}
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-plain-untextured.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT INT TERM

common_flags=(
    -std=c++17 -O3 -Wall -Wextra -Werror
    -Wno-unused-parameter -Wno-missing-braces
    -I"$repo_root/third_party/melonDS/src"
)

${CXX:-c++} "${common_flags[@]}" \
    "$repo_root/tools/test_plain_untextured_pixel.cpp" \
    -o "$test_tmp/host"
"$test_tmp/host"

${CXX:-c++} "${common_flags[@]}" \
    -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined \
    "$repo_root/tools/test_plain_untextured_pixel.cpp" \
    -o "$test_tmp/sanitized"
ASAN_OPTIONS=detect_leaks=0 "$test_tmp/sanitized"

docker_args=(--rm --network none -v "$repo_root:/workspace:ro" -w /workspace)
if [[ -n "$evidence_dir" ]]; then
    docker_args+=(-v "$evidence_dir:/evidence")
fi

docker run "${docker_args[@]}" "$image" sh -lc '
        set -eu
        binary=/tmp/nds-plain-untextured-arm
        disassembly=/tmp/nds-plain-untextured-arm.dis
        helper=/tmp/nds-plain-untextured-arm.helper.dis
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Wall -Wextra -Werror \
            -Wno-unused-parameter -Wno-missing-braces \
            -Ithird_party/melonDS/src \
            tools/test_plain_untextured_pixel.cpp -o "$binary"
        "$binary"
        arm-linux-gnueabihf-objdump -d -C "$binary" >"$disassembly"
        sed -n "/<nds_test_plain_untextured_pixel>:/,/^$/p" \
            "$disassembly" >"$helper"
        ! grep -Eq "bl.*<__aeabi_(u?idiv|uidivmod|uldivmod)>" "$helper"
        ! grep -Eq "\bv[a-z0-9.]+" "$helper"
        instructions=$(grep -Ec "^[[:space:]]*[0-9a-f]+:" "$helper")
        calls=$(grep -Ec "[[:space:]]bl[x]?[[:space:]]" "$helper" || true)
        echo "H3D_PLAIN_UNTEXTURED_ASSEMBLY instructions=$instructions calls=$calls neon=0"
        if [ "$calls" -ne 0 ]; then
            echo "FAIL: plain untextured helper contains a call" >&2
            exit 1
        fi
        if [ -d /evidence ]; then
            cp "$helper" /evidence/plain-untextured-pixel.helper.dis
            printf "instructions=%s\ncalls=%s\nneon=0\n" \
                "$instructions" "$calls" \
                >/evidence/plain-untextured-pixel-assembly-summary.txt
            sha256sum "$binary" \
                >/evidence/plain-untextured-pixel-test.sha256
        fi
    '

echo "PASS: host/sanitizer/ARM plain untextured pixel oracle"
