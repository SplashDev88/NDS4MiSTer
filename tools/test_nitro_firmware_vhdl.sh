#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-firmware-vhdl.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

run_tests() {
    cd "$test_tmp"
    nvc --std=2008 -a "$repo_dir/rtl/nds_nitro_firmware.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/tb_nds_nitro_firmware.vhd"
    nvc --std=2008 -e tb_nds_nitro_firmware
    nvc --std=2008 -r tb_nds_nitro_firmware --exit-severity=error

    nvc --std=2008 -a \
        "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/nds_nitro_spi.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/tb_nds_spi_firmware_read.vhd"
    nvc --std=2008 -e tb_nds_spi_firmware_read
    nvc --std=2008 -r tb_nds_spi_firmware_read --exit-severity=error
}

if command -v nvc >/dev/null 2>&1; then
    run_tests
else
    docker run --rm \
        -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" \
        -w /test \
        nds4mister-nvc-arm64:1.22.1 \
        sh -lc '
            set -eu
            nvc --std=2008 -a /workspace/rtl/nds_nitro_firmware.vhd
            nvc --std=2008 -a /workspace/rtl/tb_nds_nitro_firmware.vhd
            nvc --std=2008 -e tb_nds_nitro_firmware
            nvc --std=2008 -r tb_nds_nitro_firmware --exit-severity=error
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd
            nvc --std=2008 -a /workspace/rtl/nds_nitro_spi.vhd
            nvc --std=2008 -a /workspace/rtl/tb_nds_spi_firmware_read.vhd
            nvc --std=2008 -e tb_nds_spi_firmware_read
            nvc --std=2008 -r tb_nds_spi_firmware_read --exit-severity=error
        '
fi

echo "PASS: writable Nitro firmware store and SPI read/write transactions"
