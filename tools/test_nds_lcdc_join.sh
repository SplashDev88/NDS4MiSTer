#!/bin/bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-lcdc-join.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash -lc '
set -euo pipefail
nvc --std=2008 --work=MEM -a /workspace/rtl/tb_mem_sync_ram_dual_byte_enable.vhd
nvc --std=2008 -L . -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_vram_map.vhd /workspace/rtl/nds_nitro_vram.vhd /workspace/rtl/tb_nds_lcdc_join.vhd
nvc --std=2008 -L . -e tb_nds_lcdc_join
nvc --std=2008 -L . -r tb_nds_lcdc_join --ieee-warnings=off --exit-severity=error
'
