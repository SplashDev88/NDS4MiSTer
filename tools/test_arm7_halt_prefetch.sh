#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
    test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-arm7-halt.XXXXXX")
    trap 'rm -rf "$test_tmp"' EXIT
    docker run --rm --network none -v "$repo:/repo:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash /repo/tools/test_arm7_halt_prefetch.sh --inside
    exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
tb="$repo/rtl/tb_nds_arm7_halt_prefetch.vhd"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" \
    "$p/reg_savestates.vhd" "$p/gba_cpu.vhd" "$p/nds_membus7.vhd" \
    "$p/nds_syscnt.vhd" "$tb"
for masked in true false; do
for thumb in false true; do
    for return_thumb in false true; do
        for padding in 0 1 2 3; do
            for dma in false true; do
                for wake in 0 1 7; do
                    echo "CASE masked=$masked thumb=$thumb return_thumb=$return_thumb padding=$padding dma=$dma wake=$wake"
                    nvc --std=2008 -e -gMASK_IRQ="$masked" -gTHUMB="$thumb" \
                        -gRETURN_THUMB="$return_thumb" -gHALT_NOPS="$padding" \
                        -gDMA_PAUSE="$dma" -gWAKE_TICKS="$wake" \
                        tb_nds_arm7_halt_prefetch
                    nvc --std=2008 -r tb_nds_arm7_halt_prefetch \
                        --ieee-warnings=off --exit-severity=error
                done
            done
        done
    done
done
done
# The native-shaped sequence is a masked HALTCNT store, two NOPs, and BX LR.
nvc --std=2008 -e -gCOUNT_NOPS=false tb_nds_arm7_halt_prefetch
nvc --std=2008 -r tb_nds_arm7_halt_prefetch --ieee-warnings=off --exit-severity=error

# Negative control: restoring the old overwrite must fail the same fixture.
python3 - "$p/gba_cpu.vhd" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
a = s.index("            if (fetch_done = '1') then", s.index('   -- fetch\n'))
b = s.index("            if (execute_branch = '1') then", a)
if "decode_halt = '1' and fetch_ready = '1'" not in s[a:b]:
    raise SystemExit('HALT prefetch fix not found for negative control')
s = s[:a] + """            if (fetch_done = '1') then
               fetch_data <= gb_bus_din;
-- synthesis translate_off
               if (thumbmode = '1') then
                  fetch_data(31 downto 16) <= (others => '0');
               end if;
-- synthesis translate_on
               fetch_ready <= '1';
            end if;

""" + s[b:]
Path('gba_cpu-halt-negative.vhd').write_text(s)
PY
nvc --std=2008 -a gba_cpu-halt-negative.vhd "$tb"
nvc --std=2008 -e -gCOUNT_NOPS=false tb_nds_arm7_halt_prefetch
if nvc --std=2008 -r tb_nds_arm7_halt_prefetch --ieee-warnings=off \
    --exit-severity=error > negative.log 2>&1; then
    echo 'FAIL: old prefetch overwrite unexpectedly passed' >&2
    exit 1
fi
grep -F 'HALT wake failed return / skipped BX LR' negative.log
echo 'PASS: 192 masked/unmasked HALT side-effect/interworking cases, native NOP sequence, and negative control'
