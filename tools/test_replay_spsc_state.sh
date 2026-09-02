#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds4mister-replay-spsc.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT

c++ -std=c++17 -O3 -DNDEBUG -Wall -Wextra -Wpedantic \
    -I"$repo_dir/src" \
    "$repo_dir/tools/test_replay_spsc_state.cpp" \
    -pthread -o "$test_tmp/test_replay_spsc_state"

"$test_tmp/test_replay_spsc_state"
