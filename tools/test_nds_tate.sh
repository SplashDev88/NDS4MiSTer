#!/usr/bin/env bash
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/nds-tate.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
iverilog -g2012 -s tb_nds_tate_controls -o "$test_dir/controls" \
    "$repo/rtl/nds_tate_controls.sv" "$repo/rtl/tb_nds_tate_controls.sv"
vvp "$test_dir/controls"
for ccw in 0 1; do
for rows in 4 8; do
    iverilog -g2012 -s tb_nds_tate_video -Ptb_nds_tate_video.TILE_ROWS="$rows" -Ptb_nds_tate_video.CCW_ONLY="$ccw" \
        -o "$test_dir/video-$rows" "$repo/rtl/nds_tate_video.sv" "$repo/rtl/tb_nds_tate_video.sv"
    vvp "$test_dir/video-$rows"
    echo "PASS TATE tile rows=$rows CCW_ONLY=$ccw"
done
done
