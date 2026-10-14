#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-host-save.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
python3 "$repo_dir/tools/test_host_save_profiles.py"
iverilog -g2012 -s tb_nds_host_save_control -o "$test_tmp/control" \
    "$repo_dir/rtl/nds_firmware_control.sv" "$repo_dir/rtl/tb_nds_host_save_control.sv"
vvp "$test_tmp/control"
run_vhdl() {
    nvc --std=2008 -a "$1/rtl/nds_host_save_profile.vhd" "$1/rtl/tb_nds_host_save_profile.vhd"
    nvc --std=2008 -e tb_nds_host_save_profile
    nvc --std=2008 -r tb_nds_host_save_profile --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_vhdl "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash -lc "set -e; $(declare -f run_vhdl); run_vhdl /workspace"
fi
