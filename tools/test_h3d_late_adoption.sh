#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-late-adoption.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
iverilog -g2012 -s tb_nds_h3d_adoption_window -o "$test_tmp/window" \
    "$repo_dir/rtl/nds_h3d_adoption_window.sv" \
    "$repo_dir/rtl/tb_nds_h3d_adoption_window.sv"
vvp "$test_tmp/window"
iverilog -g2012 -s tb_nds_h3d_adoption_equivalence -o "$test_tmp/equivalence" \
    "$repo_dir/rtl/nds_h3d_adoption_window.sv" \
    "$repo_dir/rtl/tb_nds_h3d_adoption_equivalence.sv"
vvp "$test_tmp/equivalence"
for enabled in 1 0; do
    iverilog -g2012 -s tb_nds_h3d_plane_reader \
        -Ptb_nds_h3d_plane_reader.LATE_ADOPTION="$enabled" \
        -Ptb_nds_h3d_plane_reader.REQUIRE_LATE_TEST=1 \
        -o "$test_tmp/reader-$enabled" \
        "$repo_dir/rtl/nds_h3d_adoption_window.sv" \
        "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
        "$repo_dir/rtl/nds_h3d_plane_reader.sv" \
        "$repo_dir/rtl/tb_nds_h3d_plane_reader.sv"
    if [[ "$enabled" == 1 ]]; then
        vvp "$test_tmp/reader-$enabled"
    else
        if vvp "$test_tmp/reader-$enabled" > "$test_tmp/negative.txt"; then
            echo "FAIL: legacy cutoff unexpectedly passed late-arrival test" >&2
            exit 1
        fi
        grep -q 'descriptor did not cross' "$test_tmp/negative.txt"
        echo "PASS: legacy cutoff negative control detects missed blanking opportunity"
    fi
done

# Removing only the DDR-side recheck must expose a switch during an old line.
python3 - "$repo_dir/rtl/nds_h3d_plane_reader.sv" "$test_tmp/reader-no-ddr-window.sv" <<'PY_MUTATE'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old = 'descriptor_link_free && switch_opportunity_ddr)'
assert source.count(old) == 1
Path(sys.argv[2]).write_text(source.replace(old, 'descriptor_link_free)'))
PY_MUTATE
iverilog -g2012 -s tb_nds_h3d_plane_reader \
    -Ptb_nds_h3d_plane_reader.LATE_ADOPTION=1 \
    -Ptb_nds_h3d_plane_reader.REQUIRE_LATE_TEST=1 \
    -o "$test_tmp/reader-no-ddr-window" \
    "$repo_dir/rtl/nds_h3d_adoption_window.sv" \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
    "$test_tmp/reader-no-ddr-window.sv" \
    "$repo_dir/rtl/tb_nds_h3d_plane_reader.sv"
if vvp "$test_tmp/reader-no-ddr-window" > "$test_tmp/negative-ddr.txt"; then
    echo "FAIL: missing DDR window safeguard unexpectedly passed" >&2
    exit 1
fi
grep -q 'pixel_valid changed within line' "$test_tmp/negative-ddr.txt"
echo "PASS: DDR safeguard negative control detects an unsafe mid-line switch"
