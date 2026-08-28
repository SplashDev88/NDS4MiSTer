#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-nitro-touch.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

run_nvc_test() {
    cd "$test_tmp"
    nvc --std=2008 -a \
        "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd"
    nvc --std=2008 -a \
        "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_spi.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/tb_nds_spi_touch.vhd"
    nvc --std=2008 -e tb_nds_spi_touch
    nvc --std=2008 -r tb_nds_spi_touch --stop-time=2ms
    rm -rf work
    nvc --std=2008 -a \
        "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/tb_nds_loader_touch_calibration.vhd"
    nvc --std=2008 -e tb_nds_loader_touch_calibration
    nvc --std=2008 -r tb_nds_loader_touch_calibration --stop-time=100us
}

if command -v nvc >/dev/null 2>&1; then
    run_nvc_test
else
    docker run --rm --network none \
        -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" \
        -w /test \
        nds4mister-nvc-arm64:1.22.1 \
        sh -lc '
            set -eu
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_spi.vhd
            nvc --std=2008 -a /workspace/rtl/tb_nds_spi_touch.vhd
            nvc --std=2008 -e tb_nds_spi_touch
            nvc --std=2008 -r tb_nds_spi_touch --stop-time=2ms
            rm -rf work
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd
            nvc --std=2008 -a /workspace/rtl/tb_nds_loader_touch_calibration.vhd
            nvc --std=2008 -e tb_nds_loader_touch_calibration
            nvc --std=2008 -r tb_nds_loader_touch_calibration --stop-time=100us
        '
fi

grep -Fq 'touch_active => touch_active, touch_x => touch_x, touch_y => touch_y' \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
grep -Fq 'when 36            => wr_data <= x"0FF00000";' \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd"
grep -Fq 'when 37            => wr_data <= x"BFFFF00B";' \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd"

echo "PASS: Nitro controller touch regression"
