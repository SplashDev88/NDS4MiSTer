#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-replay-wake.XXXXXX")
trap 'rm -f "$test_tmp/test-host"; rmdir "$test_tmp"' EXIT
${CXX:-c++} -std=c++17 -O3 -Wall -Wextra -Wpedantic -Werror \
    -I"$repo_dir/src" "$repo_dir/tools/test_replay_wake_event.cpp" \
    -pthread -o "$test_tmp/test-host"
"$test_tmp/test-host"
docker run --rm --network none -v "$repo_dir:/workspace:ro" \
    -w /workspace "${IMAGE:-nds4mister-armhf:ubuntu-24.04}" sh -c '
    set -eu
    arm-linux-gnueabihf-g++ -std=c++17 -O3 -static -pthread \
        -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -Isrc \
        tools/test_replay_wake_event.cpp -o /tmp/test-arm
    for run in 1 2 3; do timeout 30 /tmp/test-arm; done
    '
