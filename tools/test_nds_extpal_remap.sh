#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-extpal-remap.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
generator_args=("$test_tmp/test.vhd")
if [[ -n "${SOURCE_REVISION:-}" ]]; then generator_args+=(--revision "$SOURCE_REVISION"); fi
python3 "$repo_dir/tools/generate_extpal_remap_test.py" "${generator_args[@]}"
run_tests() {
    local src="$1"
    nvc --std=2008 --work=MEM -a "$src/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
    nvc --std=2008 -L . -a \
        "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_vram_map.vhd" \
        "$src/rtl/nds_nitro_vram.vhd" test.vhd
    nvc --std=2008 -L . -e -g REMAP=false tb_nds_extpal_remap
    nvc --std=2008 -L . -r tb_nds_extpal_remap --exit-severity=error
    # Line-granular hardware evidence: unmap on199, restore on202 or203.
    # Exercise early/late points within each line, not guessed exact timestamps.
    for unmap in 14910 16510; do
        for restore in 21300 22800 23430 24930; do
            nvc --std=2008 -L . -e -g UNMAP_CYCLE="$unmap" \
                -g RESTORE_CYCLE="$restore" tb_nds_extpal_remap
            nvc --std=2008 -L . -r tb_nds_extpal_remap --exit-severity=error
        done
    done
    # Analyze and exercise the complete production GPU, including all drawers.
    nvc --std=2008 -L . -a \
        "$src/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
        "$src/third_party/Nitro_DarkSide/d2dabe/rtl/reg_nds_display.vhd" \
        "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_text.vhd" \
        "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_affext.vhd" \
        "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_obj.vhd" \
        "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_merge.vhd" \
        "$src/rtl/nds_lcdc_line.vhd" \
        "$src/rtl/nds_nitro_gpu2d.vhd" \
        "$src/rtl/tb_nds_nitro_gpu2d_mode_race.vhd"
    nvc --std=2008 -L . -e tb_nds_nitro_gpu2d_mode_race
    nvc --std=2008 -L . -r tb_nds_nitro_gpu2d_mode_race --stop-time=201us --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_tests "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash -lc "set -e; $(declare -f run_tests); run_tests /workspace"
fi
echo "PASS: extended-palette remap retry (9 cases) and full GPU mode/3D-line regression"
