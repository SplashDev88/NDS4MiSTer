#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-gx-dma-invalidation.XXXXXX")
 trap 'rm -rf "$tmp"' EXIT
 python3 - "$repo" "$tmp" <<'PY'
from pathlib import Path
import re,sys
repo,tmp=map(Path,sys.argv[1:])
s=(repo/'rtl/nds_nitro_console_top.vhd').read_text()
expr=re.findall(r"   gx_readback_geometry_write <= .*?;",s,re.S)
assert len(expr)==1
bench=(repo/'rtl/tb_nds_h3d_gx_dma_invalidation.vhd').read_text()
(tmp/'actual.vhd').write_text(bench.replace('-- PRODUCTION_INVALIDATION_EXPRESSION',expr[0]))
old="gx_readback_geometry_write <= '1' when dma_gx_write_valid = '1' or (io_bus9.ena = '1' and io_bus9.rnw = '0' and ((unsigned(io_bus9.Adr) >= 16#400# and unsigned(io_bus9.Adr) <= 16#5cb#) or io_bus9.Adr = x\"0000600\" or io_bus9.Adr = x\"0000304\")) else '0';"
(tmp/'old.vhd').write_text(bench.replace('-- PRODUCTION_INVALIDATION_EXPRESSION',old))
PY
 docker run --rm --network none -v "$repo:/workspace:ro" -v "$tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_h3d_gx_dma_invalidation.sh --inside
 exit
fi
nvc --std=2008 -a "$repo/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" "$repo/rtl/nds_h3d_gx_readback_owner.vhd" actual.vhd
nvc --std=2008 -e tb_nds_h3d_gx_dma_invalidation
nvc --std=2008 -r tb_nds_h3d_gx_dma_invalidation --ieee-warnings=off --exit-severity=error
nvc --std=2008 -a old.vhd
nvc --std=2008 -e tb_nds_h3d_gx_dma_invalidation
if nvc --std=2008 -r tb_nds_h3d_gx_dma_invalidation --ieee-warnings=off --exit-severity=error > old.log 2>&1; then
 echo 'FAIL: old DMA invalidation was not rejected';exit 1
fi
grep -q 'DMA/CPU address filter wrong at 20' old.log
echo 'PASS: published v0.5.0 invalidation expression fails the same regression'
