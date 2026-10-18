#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
    test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-dma.XXXXXX")
    trap 'rm -rf "$test_tmp"' EXIT
    docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" \
        -w /test nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_dma.sh --inside
    exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/nds_dma7.vhd" "$p/nds_dma9.vhd" \
    "$repo/rtl/tb_nds_checkpoint_dma.vhd"
for card in false true; do
for cpu in true false; do
    for latency in 1 4 11; do
        nvc --std=2008 -e -gARM9="$cpu" -gLATENCY="$latency" -gCARD_TRIGGER="$card" tb_nds_checkpoint_dma
        nvc --std=2008 -r tb_nds_checkpoint_dma --ieee-warnings=off --exit-severity=error
    done
done

done

# Losing the pending bit at an ungranted cancellation must break the retry.
python3 - "$p/nds_dma7.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old="dma_on <= '0'; dma_bus_on <= '0'; state <= IDLE;"
assert s.count(old)==1
Path('lost-pending.vhd').write_text(s.replace(old, old+" ch(active).pend <= '0';"))
PYCODE
nvc --std=2008 -a lost-pending.vhd "$repo/rtl/tb_nds_checkpoint_dma.vhd"
nvc --std=2008 -e -gARM9=false tb_nds_checkpoint_dma
if nvc --std=2008 -r tb_nds_checkpoint_dma --ieee-warnings=off --exit-severity=error > lost-pending.log 2>&1; then
    echo 'FAIL: lost pending DMA unexpectedly passed' >&2; exit 1
fi
grep -F 'DMA lost queued work after release' lost-pending.log
echo 'PASS: both DMA controllers drain, preserve triggers, cancel, and detect lost-pending negative control'

# The old ARM7 LATCH clears a trigger arriving on its own consumption edge.
python3 - "$p/nds_dma7.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
needle='if EXPERIMENTAL_CHECKPOINT and\n                     ((trig_vblank'
assert s.count(needle)==1
Path('lost-latch-event.vhd').write_text(s.replace(needle,'if false and\n                     ((trig_vblank'))
PYCODE
nvc --std=2008 -a lost-latch-event.vhd "$repo/rtl/tb_nds_checkpoint_dma.vhd"
nvc --std=2008 -e -gARM9=false tb_nds_checkpoint_dma
if nvc --std=2008 -r tb_nds_checkpoint_dma --ieee-warnings=off --exit-severity=error > lost-latch-event.log 2>&1; then
    echo 'FAIL: overwritten LATCH trigger unexpectedly passed' >&2; exit 1
fi
grep -F 'DMA lost queued work after release' lost-latch-event.log
echo 'PASS: 12 DMA CPU/latency/trigger configurations and LATCH-collision negative control'
