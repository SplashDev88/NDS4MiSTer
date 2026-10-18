#!/usr/bin/env bash
# Coordinated monitor return and pending IRQ delivery; authored software only.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
  test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-monitor-irq.XXXXXX")
  trap 'rm -rf "$test_tmp"' EXIT
  python3 - "$repo" "$test_tmp/source" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
r,o=map(Path,sys.argv[1:])
files=['third_party/Nitro_DarkSide/d2dabe/rtl/'+n for n in
       ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','gba_cpu.vhd']]
files+=['rtl/nds_arm7_monitor_rom.vhd','rtl/nds_arm7_monitor_probe.vhd',
        'rtl/tb_nds_arm7_monitor_irq.vhd','tools/test_arm7_monitor_irq.sh']
h={}
for n in files:
    (o/n).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,o/n)
    h[n]=hashlib.sha256((o/n).read_bytes()).hexdigest()
data=json.dumps(h,sort_keys=True).encode();(o/'INPUTS.json').write_bytes(data)
print('ARM7_MONITOR_IRQ_INPUT_SHA256',hashlib.sha256(data).hexdigest())
PY
  docker run --rm --network none -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
    bash /test/source/tools/test_arm7_monitor_irq.sh --inside
  exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/gba_cpu.vhd" \
  "$repo/rtl/nds_arm7_monitor_rom.vhd" "$repo/rtl/nds_arm7_monitor_probe.vhd" "$repo/rtl/tb_nds_arm7_monitor_irq.vhd"
run() {
  nvc --std=2008 -e "$@" tb_nds_arm7_monitor_irq
  nvc --std=2008 -r tb_nds_arm7_monitor_irq --ieee-warnings=off --exit-severity=error
}
for thumb in false true; do
for masked in false true; do
for phase in 0 1 2 3; do
for step in 1 5; do
for delay in 1 11; do
  echo "thumb=$thumb masked=$masked phase=$phase step=$step delay=$delay"
  for operation in capture restore; do
    run -gOPERATION="$operation" -gTHUMB="$thumb" -gMASKED="$masked" -gIRQ_PHASE="$phase" \
      -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay"
  done
done
done
done
done
done
# Real resumed behavior must notice a lost IRQ or bypassed common release.
run -gOPERATION=capture
for fault in lost_irq early_release; do
  python3 - "$p/gba_cpu.vhd" "$repo/rtl/nds_arm7_monitor_probe.vhd" "$fault" <<'PY'
from pathlib import Path
import sys
cpu,wrapper,fault=sys.argv[1:]
c=Path(cpu).read_text();w=Path(wrapper).read_text()
if fault=='lost_irq':
    old='IRQ_in=>irq,unhalt=>unhalt,new_halt=>new_halt'
    assert w.count(old)==1
    w=w.replace(old,"IRQ_in=>'0',unhalt=>unhalt,new_halt=>new_halt")
else:
    old="mon_ready = '1' and mon_error = '0' and monitor_release = '1'"
    assert c.count(old)==1
    c=c.replace(old,"mon_ready = '1' and mon_error = '0'")
Path('fault_cpu.vhd').write_text(c);Path('fault_wrapper.vhd').write_text(w)
PY
  nvc --std=2008 -a fault_cpu.vhd fault_wrapper.vhd "$repo/rtl/tb_nds_arm7_monitor_irq.vhd"
  if run -gOPERATION=restore > "$fault.log" 2>&1; then
    echo "FAIL: $fault was invisible" >&2;exit 1
  fi
  grep -E 'pending IRQ not delivered exactly once|IRQ or guest execution escaped return hold' "$fault.log"
done
echo 'PASS: 64 pending-IRQ capture/fresh-restore pairs and 2 lost-IRQ/early-release fault controls'
