#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-lcdc-bandwidth.XXXXXX")
trap 'rm -rf "$out"' EXIT
docker run --rm --network none -v "$repo:/workspace:ro" -v "$out:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash -lc '
set -euo pipefail
nvc --std=2008 --work=MEM -a /workspace/rtl/tb_mem_sync_ram_dual_byte_enable.vhd
nvc --std=2008 -L . -a /workspace/rtl/nds_lcdc_line.vhd /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_vram_map.vhd /workspace/rtl/nds_nitro_vram.vhd /workspace/rtl/tb_nds_lcdc_bandwidth.vhd
for config in "6 3" "12 3" "12 8" "31 8" "31 16"; do
  read -r latency interval <<< "$config"
  nvc --std=2008 -L . -e -greply_latency="$latency" -gissue_interval="$interval" tb_nds_lcdc_bandwidth
  nvc --std=2008 -L . -r tb_nds_lcdc_bandwidth --ieee-warnings=off --exit-severity=error
done
'
