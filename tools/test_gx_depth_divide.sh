#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds4mister-gx-depth-divide.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT INT TERM HUP

build_and_run() {
    local output=$1
    shift
    c++ -std=c++17 -O3 -Wall -Wextra -Werror "$@" \
        -I"$repo_root/third_party/melonDS/src" \
        "$repo_root/tools/test_gx_depth_divide.cpp" \
        -o "$output"
    "$output"
}

build_and_run "$test_tmp/test_gx_depth_divide"
build_and_run "$test_tmp/test_gx_depth_divide_sanitize" \
    -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined

echo "PASS: GX depth divide oracle and sanitizers"
