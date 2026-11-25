#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --inside ]]; then
    test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-related-event.XXXXXX")"
    trap 'rm -rf "$test_tmp"' EXIT
    docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_nds_related_clock_event.sh --inside
    exit
fi
p="$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo_dir/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$repo_dir/rtl/nds_related_clock_event.vhd" "$repo_dir/rtl/tb_nds_related_clock_event.vhd" \
    "$p/proc_bus_gba.vhd" "$p/nds_cache9.vhd" "$repo_dir/rtl/nds_nitro_membus9.vhd" \
    "$repo_dir/rtl/tb_nds_nitro_pal_oam_cdc.vhd"
nvc --std=2008 -L . -e tb_nds_related_clock_event
nvc --std=2008 -L . -r tb_nds_related_clock_event --ieee-warnings=off --exit-severity=error
for phase in 0 2 5 7 10 12 15 17; do
    nvc --std=2008 -L . -e -gCLK1X_PHASE_NS="$phase" tb_nds_nitro_pal_oam_cdc
    nvc --std=2008 -L . -r tb_nds_nitro_pal_oam_cdc --ieee-warnings=off --exit-severity=error
 done
