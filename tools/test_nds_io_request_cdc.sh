#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ${1:-} != --inside ]]; then
 tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-io-request.XXXXXX")"
 trap 'rm -rf "$tmp"' EXIT
 docker run --rm --network none -v "$repo:/workspace:ro" -v "$tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_nds_io_request_cdc.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$repo/rtl/nds_related_clock_event.vhd" "$p/proc_bus_gba.vhd" "$p/nds_cache9.vhd" "$repo/rtl/nds_nitro_membus9.vhd" "$repo/rtl/tb_nds_io_request_cdc.vhd"
for phase in {0..19}; do
 nvc --std=2008 -L . -e -gCLK1X_PHASE_NS="$phase" tb_nds_io_request_cdc
 nvc --std=2008 -L . -r tb_nds_io_request_cdc --ieee-warnings=off --exit-severity=error
done
nvc --std=2008 -L . -e -gCLK1X_PHASE_NS=6 -gSETTLED_REQUEST=false tb_nds_io_request_cdc
if nvc --std=2008 -L . -r tb_nds_io_request_cdc --ieee-warnings=off --exit-severity=error > legacy.log 2>&1; then
 echo 'FAIL: legacy request detector escaped delayed-payload scoreboard' >&2
 exit 1
fi
grep -F 'IO payload changed before sink commit' legacy.log
echo 'PASS: IO request settling across 20 clock phases and detecting legacy control'
