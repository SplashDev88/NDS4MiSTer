#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-sound-stream-watch.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_test() {
    ghdl -a --std=08 "$1/rtl/nds_sound_stream_watch.vhd" "$1/rtl/tb_nds_sound_stream_watch.vhd"
    ghdl -e --std=08 tb_nds_sound_stream_watch
    ghdl -r --std=08 tb_nds_sound_stream_watch --assert-level=error
}
if command -v ghdl >/dev/null 2>&1; then
    cd "$test_tmp";run_test "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" \
      -w /test nds4mister-vhdl-sim:24.04 \
      bash -lc "set -eu; $(declare -f run_test); run_test /workspace"
fi
