#!/usr/bin/env bash
# Native sleep context plus CPU-assisted registers; separate fresh processes.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
  test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-monitor-sleep.XXXXXX")
  trap 'rm -rf "$test_tmp"' EXIT
  python3 - "$repo" "$test_tmp/source" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
r,o=map(Path,sys.argv[1:])
files=['third_party/Nitro_DarkSide/d2dabe/rtl/'+n for n in
       ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','gba_cpu.vhd','nds_cpu9.vhd','nds_membus7.vhd','nds_syscnt.vhd']]
files+=['rtl/nds_monitor_pipeline_transfer.vhd','tools/test_cpu_monitor_sleep.sh']
for cpu in [7,9]:
    files += [f'rtl/nds_arm{cpu}_monitor_rom.vhd',f'rtl/nds_arm{cpu}_monitor_probe.vhd',f'rtl/tb_nds_arm{cpu}_monitor_sleep.vhd']
h={}
for n in files:
    (o/n).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,o/n)
    h[n]=hashlib.sha256((o/n).read_bytes()).hexdigest()
data=json.dumps(h,sort_keys=True).encode();(o/'INPUTS.json').write_bytes(data)
print('CPU_MONITOR_SLEEP_INPUT_SHA256',hashlib.sha256(data).hexdigest())
PY
  docker run --rm --network none -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
    bash /test/source/tools/test_cpu_monitor_sleep.sh --inside "${1:-all}"
  exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
  "$p/gba_cpu.vhd" "$p/nds_cpu9.vhd" "$p/nds_membus7.vhd" "$p/nds_syscnt.vhd" \
  "$repo/rtl/nds_monitor_pipeline_transfer.vhd"
for cpu in 7 9; do
  nvc --std=2008 -a "$repo/rtl/nds_arm${cpu}_monitor_rom.vhd" "$repo/rtl/nds_arm${cpu}_monitor_probe.vhd" \
    "$repo/rtl/tb_nds_arm${cpu}_monitor_sleep.vhd"
done
run() {
  local cpu=$1;shift
  nvc --std=2008 -e "$@" "tb_nds_arm${cpu}_monitor_sleep"
  nvc --std=2008 -r "tb_nds_arm${cpu}_monitor_sleep" --ieee-warnings=off --exit-severity=error
}
if [[ ${2:-all} == --dma-case ]]; then
  run 7 -gDMA_PAUSE=true -gHALT_NOPS=0 -gWAKE_TICKS=50 -gMASK_IRQ=false
  exit
fi
pairs=0
pair() {
  local cpu=$1;shift
  echo "sleep-pair cpu=$cpu $*"
  run "$cpu" -gOPERATION=capture "$@"
  run "$cpu" -gOPERATION=restore "$@"
  pairs=$((pairs+1))
}
for thumb in false true; do
for ret in false true; do
for masked in false true; do
for dma in false true; do
for nops in 0 2 5; do
for wake in 0 50; do
  pair 7 -gTHUMB="$thumb" -gRETURN_THUMB="$ret" -gMASK_IRQ="$masked" -gDMA_PAUSE="$dma" \
    -gHALT_NOPS="$nops" -gWAKE_TICKS="$wake" -gMUTATE_PREFETCH="$masked"
done
done
done
done
done
done
for phase in 1 2; do
for thumb in false true; do
for masked in false true; do
for dma in false true; do
  pair 7 -gWAKE_PHASE="$phase" -gTHUMB="$thumb" -gMASK_IRQ="$masked" -gDMA_PAUSE="$dma" -gMUTATE_PREFETCH="$masked"
done
done
done
done
for delay in 1 3 11; do
for wake in 0 4 12; do
for irq in false true; do
  mutate=false;if [[ $irq == false ]]; then mutate=true;fi
  pair 9 -gREAD_DELAY="$delay" -gWAKE_DELAY="$wake" -gIRQ_ENABLED="$irq" -gMUTATE_PREFETCH="$mutate"
done
done
done
for phase in 1 2; do
for delay in 1 11; do
for irq in false true; do
  mutate=false;if [[ $irq == false ]]; then mutate=true;fi
  pair 9 -gWAKE_PHASE="$phase" -gREAD_DELAY="$delay" -gIRQ_ENABLED="$irq" -gMUTATE_PREFETCH="$mutate"
done
done
done
for cpu in 7 9; do
  extra=()
  if [[ $cpu == 7 ]]; then extra=(-gMASK_IRQ=true); base=45;functional=56;else extra=(-gIRQ_ENABLED=false);base=64;functional=68;fi
  run "$cpu" -gOPERATION=capture "${extra[@]}" -gMUTATE_PREFETCH=true
  for word in "$base" "$((base+4))"; do
    run "$cpu" -gOPERATION=restore "${extra[@]}" -gCORRUPT_WORD="$word" -gEXPECT_REJECT=true
  done
  # ARM7 uses its prefetched word; ARM9 has already decoded BX. Corrupt the
  # actual live instruction/decoded source register and observe resumed behavior.
  if run "$cpu" -gOPERATION=restore "${extra[@]}" -gCORRUPT_WORD="$functional" > corrupt-prefetch.log 2>&1; then
    echo "FAIL: ARM$cpu prefetch/decode corruption was invisible" >&2;exit 1
  fi
  grep -E 'Post-halt operation skipped/repeated|FAIL: executed terminal guard|did not return to caller|HALT wake failed return' corrupt-prefetch.log
done
# An omitted pipeline write must not be treated as a completed restore.
python3 - "$repo/rtl/nds_monitor_pipeline_transfer.vhd" <<'PYFAULT'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();old="cpu_write<='1' when state=LOAD_DATA else '0';";assert s.count(old)==1
Path('missing-word.vhd').write_text(s.replace(old,"cpu_write<='1' when state=LOAD_DATA and index/=13 else '0';"))
PYFAULT
nvc --std=2008 -a missing-word.vhd
for cpu in 7 9; do
  nvc --std=2008 -a "$repo/rtl/nds_arm${cpu}_monitor_probe.vhd" "$repo/rtl/tb_nds_arm${cpu}_monitor_sleep.vhd"
  run "$cpu" -gOPERATION=restore -gEXPECT_REJECT=true
done
nvc --std=2008 -a "$repo/rtl/nds_monitor_pipeline_transfer.vhd"
# DMA belongs to the guest bus; applying it to private execution loses PARK.
python3 - "$repo/rtl/nds_arm7_monitor_probe.vhd" <<'PYFAULT'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();old='dma_on=>dma and not act';assert s.count(old)==1
Path('private-dma.vhd').write_text(s.replace(old,'dma_on=>dma'))
PYFAULT
nvc --std=2008 -a private-dma.vhd "$repo/rtl/tb_nds_arm7_monitor_sleep.vhd"
if run 7 -gDMA_PAUSE=true -gHALT_NOPS=0 -gWAKE_TICKS=50 -gMASK_IRQ=false > private-dma.log 2>&1; then
  echo 'FAIL: private DMA pause was invisible' >&2;exit 1
fi
grep -F 'illegal private monitor access' private-dma.log
# Ready must wait for all live pipeline fields, not just the ARM load routine.
python3 - "$p/gba_cpu.vhd" <<'PYFAULT'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();old="mon_return_copy <= '1'; mon_pipe_count <= (others => '0');";assert s.count(old)==1
Path('early-pipeline-ready.vhd').write_text(s.replace(old,old+" mon_ready <= '1';"))
PYFAULT
nvc --std=2008 -a early-pipeline-ready.vhd "$repo/rtl/nds_arm7_monitor_probe.vhd" "$repo/rtl/tb_nds_arm7_monitor_sleep.vhd"
if run 7 -gOPERATION=restore > early-ready.log 2>&1; then
  echo 'FAIL: premature pipeline ready was invisible' >&2;exit 1
fi
grep -F 'restored HALT pipeline missing at return hold' early-ready.log
echo "PASS: $pairs native sleep capture/fresh-restore pairs, 4 invalid-header/enum controls, 2 functional prefetch/decode corruptions, 2 incomplete-pipeline rejects, DMA isolation and early-ready controls"
