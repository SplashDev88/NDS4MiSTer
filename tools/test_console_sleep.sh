#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
    test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-console-sleep.XXXXXX")
    trap 'rm -rf "$test_tmp"' EXIT
    docker run --rm --network none -v "$repo:/repo:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash /repo/tools/test_console_sleep.sh --inside
    exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
tb="$repo/rtl/tb_nds_console_sleep.vhd"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" \
    "$p/reg_savestates.vhd" "$p/nds_cpu9.vhd" "$p/nds_syscnt.vhd" "$tb"
for delay in 1 3 11; do
    for phase in 0 1 2 3 4 5 6 7 8; do
        nvc --std=2008 -e -gREAD_DELAY="$delay" -gSLEEP_PHASE="$phase" tb_nds_console_sleep
        nvc --std=2008 -r tb_nds_console_sleep --ieee-warnings=off --exit-severity=error
    done
done
# Reproduce the shipped ARM7-only sleep behavior; the same program must fail.
sed 's/dma_on=>sleep9/dma_on=>\x270\x27/' "$tb" > sleep-negative.vhd
nvc --std=2008 -a sleep-negative.vhd
nvc --std=2008 -e tb_nds_console_sleep
if nvc --std=2008 -r tb_nds_console_sleep --ieee-warnings=off \
    --exit-severity=error > negative.log 2>&1; then
    echo 'FAIL: ARM7-only sleep unexpectedly passed' >&2
    exit 1
fi
grep -F 'ARM9 continued while ARM7 slept' negative.log
echo 'PASS: 27 sleep/resume bus timing cases and ARM7-only negative control'
