#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-gx-readback-owner.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

if command -v ghdl >/dev/null 2>&1; then
    cd "$test_tmp"
    ghdl -a --std=08 "$repo_dir/rtl/nds_h3d_gx_readback_owner.vhd" \
        "$repo_dir/rtl/tb_nds_h3d_gx_readback_owner.vhd"
    ghdl -a --std=08 "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" "$repo_dir/rtl/nds_h3d_gx_status.vhd" "$repo_dir/rtl/tb_nds_h3d_gx_status.vhd"
    ghdl -e --std=08 tb_nds_h3d_gx_status
    ghdl -r --std=08 tb_nds_h3d_gx_status --assert-level=error
    ghdl -e --std=08 tb_nds_h3d_gx_readback_owner
    ghdl -r --std=08 tb_nds_h3d_gx_readback_owner --assert-level=error
else
    docker run --rm -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" \
        -w /test nds4mister-vhdl-sim:24.04 sh -lc '
            set -eu
            ghdl -a --std=08 /workspace/rtl/nds_h3d_gx_readback_owner.vhd /workspace/rtl/tb_nds_h3d_gx_readback_owner.vhd
            ghdl -a --std=08 /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd /workspace/rtl/nds_h3d_gx_status.vhd /workspace/rtl/tb_nds_h3d_gx_status.vhd
            ghdl -e --std=08 tb_nds_h3d_gx_status
            ghdl -r --std=08 tb_nds_h3d_gx_status --assert-level=error
            ghdl -e --std=08 tb_nds_h3d_gx_readback_owner
            ghdl -r --std=08 tb_nds_h3d_gx_readback_owner --assert-level=error
        '
fi
