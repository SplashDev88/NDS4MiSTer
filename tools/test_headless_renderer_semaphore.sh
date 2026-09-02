#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
platform_source=${HEADLESS_PLATFORM_CPP:-$repo_dir/src/melonds/HeadlessPlatform.cpp}
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds4mister-fast-fence.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT

link_gc=(-Wl,--gc-sections)
if [[ $(uname -s) == Darwin ]]; then
    link_gc=(-Wl,-dead_strip)
fi

c++ -std=c++17 -O3 -DNDEBUG -ffunction-sections -fdata-sections \
    -Wall -Wextra -Wpedantic \
    -I"$repo_dir/third_party/melonDS/src" -I"$repo_dir/src" \
    "$repo_dir/tools/test_headless_renderer_semaphore.cpp" \
    "$platform_source" \
    "${link_gc[@]}" -pthread -ldl \
    -o "$test_tmp/test_headless_renderer_semaphore"

"$test_tmp/test_headless_renderer_semaphore"
