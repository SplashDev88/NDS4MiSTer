#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/nds-span-setup.XXXXXX")
cleanup() {
    rm -f "$test_dir/test-host" "$test_dir/test-san"
    # Clang on macOS may put debug symbols next to the sanitizer executable.
    # Keep that small temporary directory when it contains a dSYM bundle.
    rmdir "$test_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
common=(-std=c++17 -fno-access-control -I"$repo_root/third_party/melonDS/src")
${CXX:-c++} "${common[@]}" -O3 "$repo_root/tools/test_raster_span_setup.cpp" -o "$test_dir/test-host"
"$test_dir/test-host"
${CXX:-c++} "${common[@]}" -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined \
    "$repo_root/tools/test_raster_span_setup.cpp" -o "$test_dir/test-san"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$test_dir/test-san"
docker run --rm --network none -v "$repo_root:/src:ro" -w /src "$image" sh -c '
    set -eu
    arm-linux-gnueabihf-g++ -std=c++17 -O3 -static -fno-access-control \
        -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
        -Ithird_party/melonDS/src tools/test_raster_span_setup.cpp -o /tmp/span-oracle
    /tmp/span-oracle
'
echo 'PASS: host/sanitizer/ARM span setup and constant-color interpolation'
