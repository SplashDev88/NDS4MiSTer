#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-gpu-reset.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_tests() {
 local src="$1"
nvc --std=2008 --work=MEM -a "$src/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a \
 "$src/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
 "$src/third_party/Nitro_DarkSide/d2dabe/rtl/reg_nds_display.vhd" \
 "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_text.vhd" \
 "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_affext.vhd" \
 "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_obj.vhd" \
 "$src/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_merge.vhd" \
 "$src/rtl/nds_lcdc_line.vhd" "$src/rtl/nds_nitro_gpu2d.vhd" \
 "$src/rtl/tb_nds_nitro_gpu2d_reset_restart.vhd"
for args in '0 0 true false' '0 1 false false' '0 1 true false' '0 2 true false' '0 3 true false' '0 4 true false' '0 5 true false' '1 0 true false' '2 0 true false' '0 0 true true'; do
 read -r old new interrupted three <<< "$args"
 nvc --std=2008 -L . -e -g OLD_MODE="$old" -g NEW_MODE="$new" -g INTERRUPT_LINE="$interrupted" -g NEW_3D="$three" tb_nds_nitro_gpu2d_reset_restart
 nvc --std=2008 -L . -r tb_nds_nitro_gpu2d_reset_restart --stop-time=501us --exit-severity=error > "mode-$old-$new-$interrupted-$three.log" 2>&1
 tail -2 "mode-$old-$new-$interrupted-$three.log"
done

}
if command -v nvc >/dev/null 2>&1; then
 cd "$test_tmp"
 run_tests "$repo_dir"
else
 docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash -lc "set -e; $(declare -f run_tests); run_tests /workspace"
fi
echo "PASS: GPU session reset and mode restart (10 cases)"
