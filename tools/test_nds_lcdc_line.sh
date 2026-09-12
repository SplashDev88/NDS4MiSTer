#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-lcdc.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_test() {
    nvc --std=2008 -a "$1/rtl/nds_lcdc_line.vhd" "$1/rtl/tb_nds_lcdc_line.vhd"
    for delay in 0 1 7 31; do
        nvc --std=2008 -e -greply_delay="$delay" tb_nds_lcdc_line
        nvc --std=2008 -r tb_nds_lcdc_line --ieee-warnings=off --exit-severity=error
    done
    nvc --std=2008 --work=MEM -a "$1/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
    nvc --std=2008 -L . -a \
        "$1/third_party/Nitro_DarkSide/d2dabe/rtl/nds_vram_map.vhd" \
        "$1/rtl/nds_nitro_vram.vhd" "$1/rtl/tb_nds_lcdc_vram.vhd"
    nvc --std=2008 -L . -e tb_nds_lcdc_vram
    nvc --std=2008 -L . -r tb_nds_lcdc_vram --ieee-warnings=off --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"; run_test "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash -lc "set -e; $(declare -f run_test); run_test /workspace"
fi
