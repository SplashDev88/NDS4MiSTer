#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${BUILD_DIR:-/tmp/nds4mister-gx-w-normalization}

mkdir -p "$build_dir"
"${CXX:-c++}" \
  -std=c++17 -O3 -Wall -Wextra -Werror \
  -I"$repo_root/third_party/melonDS/src" \
  "$repo_root/tools/test_gx_w_normalization.cpp" \
  -o "$build_dir/test_gx_w_normalization"
"$build_dir/test_gx_w_normalization"
