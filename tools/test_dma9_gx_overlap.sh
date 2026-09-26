#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-dma-gx-overlap.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
# Exercise the console's actual grant expression, with only signal names
# adapted to the testbench. This includes its cache, lock and query guards.
python3 - "$repo" "$test_tmp" <<'PYCODE'
from pathlib import Path
import re,sys
root,dest=map(Path,sys.argv[1:])
top=(root/'rtl/nds_nitro_console_top.vhd').read_text()
expr=re.search(r'dma_io_read_wait_grant\s*<=\s*(.*?);',top,re.S).group(1)
for before,after in {'gx_readback_busy':'gx_busy','gx_readback_fence':'fence','h3d_readback_request':'query','dma_mr_idle1':'cache_idle','dma_mr_idle2':'cache_idle','ld_busy':'loader','dbg_pk_sel':'peek','cpu9_lock':'locked'}.items():
 expr=re.sub(r'\b'+before+r'\b',after,expr)
bench=(root/'rtl/tb_nds_dma9_gx_overlap.vhd').read_text()
bench,n=re.subn(r'allow_overlap\s*<=.*?;',lambda _: 'allow_overlap <= '+expr+';',bench,flags=re.S)
assert n==1
(dest/'actual_gx_overlap.vhd').write_text(bench)
PYCODE
if ! command -v nvc >/dev/null; then
 docker run --rm --network none -v "$repo:/workspace:ro" -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash -lc '
 set -eu
 nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_dma9.vhd /workspace/rtl/nds_h3d_gx_readback_owner.vhd /workspace/rtl/nds_h3d_gx_dma_completion.vhd /test/actual_gx_overlap.vhd /workspace/rtl/tb_nds_dma9_mainram_fast.vhd
 nvc --std=2008 -e tb_nds_dma9_gx_overlap
 nvc --std=2008 -r tb_nds_dma9_gx_overlap --ieee-warnings=off --exit-severity=error
 nvc --std=2008 -e tb_nds_dma9_mainram_fast
 nvc --std=2008 -r tb_nds_dma9_mainram_fast --ieee-warnings=off --exit-severity=error
 '
else
 cd "$test_tmp"
 nvc --std=2008 -a "$repo/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" "$repo/third_party/Nitro_DarkSide/d2dabe/rtl/nds_dma9.vhd" "$repo/rtl/nds_h3d_gx_readback_owner.vhd" "$repo/rtl/nds_h3d_gx_dma_completion.vhd" "$test_tmp/actual_gx_overlap.vhd" "$repo/rtl/tb_nds_dma9_mainram_fast.vhd"
 nvc --std=2008 -e tb_nds_dma9_gx_overlap
 nvc --std=2008 -r tb_nds_dma9_gx_overlap --ieee-warnings=off --exit-severity=error
 nvc --std=2008 -e tb_nds_dma9_mainram_fast
 nvc --std=2008 -r tb_nds_dma9_mainram_fast --ieee-warnings=off --exit-severity=error
fi
