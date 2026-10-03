#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
# The store is an explicit byte-enabled M10K. Exercise the real Intel model.
intel_sim_lib="${NDS_INTEL_SIM_LIB:-${QUARTUS_ROOTDIR:+$QUARTUS_ROOTDIR/eda/sim_lib}}"
if [[ -z "$intel_sim_lib" || ! -f "$intel_sim_lib/altera_mf.vhd" || ! -f "$intel_sim_lib/altera_mf_components.vhd" ]]; then
    echo 'Set NDS_INTEL_SIM_LIB to the Quartus eda/sim_lib directory.' >&2
    exit 2
fi
intel_sim_lib="$(cd "$intel_sim_lib" && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-firmware-vhdl.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

if ! command -v nvc >/dev/null 2>&1; then
    docker run --rm --network none \
        -v "$repo_dir:/workspace:ro" -v "$intel_sim_lib:/intel:ro" \
        -v "$test_tmp:/test" -e TMPDIR=/test -e NDS_INTEL_SIM_LIB=/intel \
        nds4mister-nvc-arm64:1.22.1 \
        bash /workspace/tools/test_nitro_firmware_vhdl.sh
    exit
fi

# Preserve the synthesis-relative MIF path without modifying the source tree.
mkdir -p "$test_tmp/rtl" "$test_tmp/fpga/sim"
cp "$repo_dir/rtl/nds_nitro_firmware.mif" "$test_tmp/rtl/"
cd "$test_tmp/fpga/sim"
nvc --std=2008 --work=altera_mf -a \
    "$intel_sim_lib/altera_mf_components.vhd" "$intel_sim_lib/altera_mf.vhd"
nvc --std=2008 -L . -a "$repo_dir/rtl/nds_nitro_firmware.vhd" \
    "$repo_dir/rtl/tb_nds_nitro_firmware.vhd" "$repo_dir/rtl/tb_nds_nitro_firmware_cfg.vhd"
for tb in tb_nds_nitro_firmware tb_nds_nitro_firmware_cfg; do
    nvc --std=2008 -L . -e "$tb"
    nvc --std=2008 -L . -r "$tb" --exit-severity=error
done
nvc --std=2008 -L . -a \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
    "$repo_dir/rtl/nds_nitro_spi.vhd" "$repo_dir/rtl/tb_nds_spi_firmware_read.vhd"
nvc --std=2008 -L . -e tb_nds_spi_firmware_read
nvc --std=2008 -L . -r tb_nds_spi_firmware_read --exit-severity=error
echo "PASS: writable Nitro firmware store, configuration and SPI transactions"
