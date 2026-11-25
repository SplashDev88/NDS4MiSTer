#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-dma-bridge.XXXXXX")
 trap 'rm -rf "$tmp"' EXIT
 docker run --rm --network none -v "$repo:/workspace:ro" -v "$tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_nds_dma9_request_bridge.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$repo/rtl/nds_related_clock_event.vhd" "$p/proc_bus_gba.vhd" "$p/nds_dma9.vhd" "$repo/rtl/tb_nds_dma9_request_bridge.vhd"
for latency in 1 4 11; do
 nvc --std=2008 -e -gLATENCY="$latency" tb_nds_dma9_request_bridge
 nvc --std=2008 -r tb_nds_dma9_request_bridge --ieee-warnings=off --exit-severity=error
done
# The former raw-source detector must fail the routed-payload scoreboard.
python3 - "$repo/rtl/nds_related_clock_event.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
s=s.replace('settled xor history when TOGGLE_EVENT else', 'event_in xor capture when TOGGLE_EVENT else')
s=s.replace('settled and not history;', 'event_in and not capture;')
Path('legacy-event.vhd').write_text(s)
PY
nvc --std=2008 -a legacy-event.vhd "$repo/rtl/tb_nds_dma9_request_bridge.vhd"
nvc --std=2008 -e tb_nds_dma9_request_bridge
if nvc --std=2008 -r tb_nds_dma9_request_bridge --ieee-warnings=off --exit-severity=error > legacy.log 2>&1; then
    cat legacy.log
    echo 'FAIL: former event detector escaped payload scoreboard' >&2
    exit 1
fi
grep -E 'fallback destination address|fallback word data|fallback halfword data|DMA timeout' legacy.log
echo 'PASS: former raw-source detector is rejected with modeled payload routing delay'
