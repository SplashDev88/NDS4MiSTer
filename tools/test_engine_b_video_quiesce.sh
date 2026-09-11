#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-engine-b-video.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_sv() {
    local top="$1"
    shift
    iverilog -g2012 -s "$top" -o "$test_tmp/$top" "$@"
    vvp "$test_tmp/$top"
}
run_sv tb_nds_nitro_fb_external_quiesce \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv" \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
    "$repo_dir/rtl/tb_nds_nitro_fb_external_quiesce.sv"
for top in tb_nds_nitro_fb_side_by_side \
           tb_nds_nitro_fb_publication_source_ack \
           tb_nds_nitro_fb_telemetry; do
    run_sv "$top" "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
        "$repo_dir/rtl/$top.sv"
done
run_sv tb_nds_nitro_video_scanout \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
    "$repo_dir/rtl/tb_nds_nitro_video_scanout.sv"
run_sv tb_nds_h3d_plane_reader \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
    "$repo_dir/rtl/nds_h3d_plane_reader.sv" \
    "$repo_dir/rtl/tb_nds_h3d_plane_reader.sv"
