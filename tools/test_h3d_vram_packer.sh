#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-vram-packer.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
iverilog -g2012 -s tb_nds_h3d_vram_record_packer -o "$test_tmp/test.vvp" \
    "$repo_dir/rtl/nds_h3d_vram_record_packer.sv" \
    "$repo_dir/rtl/tb_nds_h3d_vram_record_packer.sv"
vvp "$test_tmp/test.vvp"
