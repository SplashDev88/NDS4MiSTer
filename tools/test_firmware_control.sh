#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-firmware-control.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
iverilog -g2012 -s tb_nds_firmware_control -o "$test_tmp/test.vvp" \
    "$repo_dir/rtl/nds_firmware_control.sv" "$repo_dir/rtl/tb_nds_firmware_control.sv"
vvp "$test_tmp/test.vvp"
# Set QUARTUS_SIM_LIB to quartus/eda/sim_lib to exercise the product RAM too.
if [[ -n "${QUARTUS_SIM_LIB:-}" ]]; then
    iverilog -g2012 -s tb_nds_firmware_control \
        -Ptb_nds_firmware_control.RAM_SIMULATE=0 -o "$test_tmp/vendor.vvp" \
        "$repo_dir/rtl/nds_firmware_control.sv" "$repo_dir/rtl/tb_nds_firmware_control.sv" \
        "$QUARTUS_SIM_LIB/altera_mf.v"
    vvp "$test_tmp/vendor.vvp"
fi
