#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-save-8k-64k.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

"$repo_dir/tools/generate_nds_save_profiles.sh" >/dev/null

iverilog -g2012 -Wall -s tb_nds_nitro_save_bridge \
    -o "$test_tmp/tb_nds_nitro_save_bridge" \
    "$repo_dir/rtl/nds_nitro_save_bridge.sv" \
    "$repo_dir/rtl/tb_nds_nitro_save_bridge.sv"
vvp "$test_tmp/tb_nds_nitro_save_bridge"

iverilog -g2012 -Wall -s tb_nds_nitro_save_profile \
    -o "$test_tmp/tb_nds_nitro_save_profile" \
    "$repo_dir/rtl/nds_nitro_save_profile.sv" \
    "$repo_dir/rtl/tb_nds_nitro_save_profile.sv"
(cd "$repo_dir/fpga/mister_nitro_console_island" &&
    vvp "$test_tmp/tb_nds_nitro_save_profile")

run_nvc_tests() {
    rm -rf "$test_tmp/work"
    cd "$test_tmp"
    nvc --std=2008 -a "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd"
    nvc --std=2008 -a "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/tb_nds_card_eeprom_sizes.vhd"
    nvc --std=2008 -e tb_nds_card_eeprom_sizes
    nvc --std=2008 -r tb_nds_card_eeprom_sizes --stop-time=2ms

    rm -rf "$test_tmp/work"
    nvc --std=2008 -a "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/tb_nds_loader_save_size.vhd"
    nvc --std=2008 -e tb_nds_loader_save_size
    nvc --std=2008 -r tb_nds_loader_save_size --stop-time=100us
}

if command -v nvc >/dev/null 2>&1; then
    run_nvc_tests
else
    docker run --rm \
        -v "$repo_dir:/workspace" \
        -v "$test_tmp:/test" \
        -w /test \
        nds4mister-nvc-arm64:1.22.1 \
        sh -lc '
            set -eu
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd
            nvc --std=2008 -a /workspace/rtl/tb_nds_card_eeprom_sizes.vhd
            nvc --std=2008 -e tb_nds_card_eeprom_sizes
            nvc --std=2008 -r tb_nds_card_eeprom_sizes --stop-time=2ms
            rm -rf work
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd
            nvc --std=2008 -a /workspace/rtl/tb_nds_loader_save_size.vhd
            nvc --std=2008 -e tb_nds_loader_save_size
            nvc --std=2008 -r tb_nds_loader_save_size --stop-time=100us
        '
fi

echo "PASS: Nitro EEPROM/FRAM/flash save regression"
