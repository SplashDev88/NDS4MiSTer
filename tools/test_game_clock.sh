#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cxx=${CXX:-g++}
for name in test_game_clock test_game_clock_environment test_host_game_clock; do
  "$cxx" -std=c++17 -O2 -Wall -Wextra -Werror \
    -D_TIME_BITS=64 -D_FILE_OFFSET_BITS=64 \
    "$root/tools/standalone_host/$name.cpp" -o "$scratch/$name"
  "$scratch/$name"
done
