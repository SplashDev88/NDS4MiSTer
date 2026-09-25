#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-mr-fast.XXXXXX")
 trap 'rm -rf "$tmp"' EXIT
 docker run --rm --network none -v "$repo:/workspace:ro" -v "$tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_nds_dma9_mainram_fast.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/nds_dma9.vhd" "$repo/rtl/tb_nds_dma9_mainram_fast.vhd"
for latency in 1 4 11; do
 nvc --std=2008 -e -gLATENCY="$latency" tb_nds_dma9_mainram_fast
 nvc --std=2008 -r tb_nds_dma9_mainram_fast --ieee-warnings=off --exit-severity=error
done
