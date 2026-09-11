#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
host_binary=$(mktemp "${TMPDIR:-/tmp}/nds-modulate4.XXXXXX")
sanitizer_binary=$(mktemp "${TMPDIR:-/tmp}/nds-modulate4-san.XXXXXX")
trap 'rm -f "$host_binary" "$sanitizer_binary"' EXIT INT TERM

${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_cached_modulate_batch.cpp" -o "$host_binary"
"$host_binary"

${CXX:-c++} -std=c++17 -O1 -fno-omit-frame-pointer \
    -fsanitize=address,undefined -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-braces \
    -I"$repo_root/third_party/melonDS/src" \
    "$repo_root/tools/test_cached_modulate_batch.cpp" -o "$sanitizer_binary"
"$sanitizer_binary"

docker run --rm --network none \
    -v "$repo_root:/workspace:ro" -w /workspace "$image" sh -lc '
        set -eu
        binary=/tmp/nds-modulate4-arm
        arm-linux-gnueabihf-g++ -std=c++17 -O3 -static \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
            -Ithird_party/melonDS/src \
            tools/test_cached_modulate_batch.cpp -o "$binary"
        "$binary"
    '

echo "PASS: host/ARM four-pixel exact modulation regression"
