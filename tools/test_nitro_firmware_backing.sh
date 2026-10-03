#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-fw-backing.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
iverilog -g2012 -s tb_nds_firmware_cache -o "$test_tmp/cache" \
    "$repo_dir/rtl/nds_firmware_cache.sv" "$repo_dir/rtl/tb_nds_firmware_cache.sv"
vvp "$test_tmp/cache"
# Optional vendor-model parity run exercises the product-default RAM branch.
# Point QUARTUS_SIM_LIB at quartus/eda/sim_lib in a local Quartus installation.
if [[ -n "${QUARTUS_SIM_LIB:-}" ]]; then
    iverilog -g2012 -s tb_nds_firmware_cache \
        -Ptb_nds_firmware_cache.RAM_SIMULATE=0 -o "$test_tmp/cache_vendor" \
        "$repo_dir/rtl/nds_firmware_cache.sv" "$repo_dir/rtl/tb_nds_firmware_cache.sv" \
        "$QUARTUS_SIM_LIB/altera_mf.v"
    vvp "$test_tmp/cache_vendor"
fi
run_spi() {
    local root=$1 out=$2
    cd "$out"
    nvc --std=2008 -a "$root/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
        "$root/rtl/nds_nitro_spi.vhd" "$root/rtl/tb_nds_spi_firmware_backpressure.vhd"
    nvc --std=2008 -e tb_nds_spi_firmware_backpressure
    nvc --std=2008 -r tb_nds_spi_firmware_backpressure --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    run_spi "$repo_dir" "$test_tmp"
else
    docker run --rm --network none -v "$repo_dir:/repo:ro" -v "$test_tmp:/test" \
        -w /test nds4mister-nvc-arm64:1.22.1 /bin/bash -euo pipefail -c \
        "$(declare -f run_spi); run_spi /repo /test"
fi
bash "$repo_dir/tools/test_nitro_firmware_vhdl.sh"
