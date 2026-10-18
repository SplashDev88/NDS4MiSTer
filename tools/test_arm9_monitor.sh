#!/usr/bin/env bash
# Isolated CPU-assisted capture/restore. No console build or hardware deployment.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
  test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-arm9-monitor.XXXXXX")
  trap 'rm -rf "$test_tmp"' EXIT
  python3 - "$repo" "$test_tmp/source" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
r,o=map(Path,sys.argv[1:])
files=['third_party/Nitro_DarkSide/d2dabe/rtl/'+n for n in
       ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','nds_cpu9.vhd']]
files+=['rtl/nds_arm9_monitor_rom.vhd','rtl/nds_arm9_monitor_probe.vhd',
        'rtl/tb_nds_arm9_monitor.vhd','rtl/tb_nds_cpu9_wfi_return.vhd',
        'tools/suspend_resume/arm9_monitor_rom.py','tools/suspend_resume/arm9_monitor_rom.lst',
        'tools/suspend_resume/arm7_monitor_fixture.py','tools/suspend_resume/arm7_monitor_rom.py','tools/test_arm9_monitor.sh']
hashes={}
for n in files:
    (o/n).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,o/n)
    hashes[n]=hashlib.sha256((o/n).read_bytes()).hexdigest()
manifest=json.dumps(hashes,sort_keys=True).encode()
(o/'INPUTS.json').write_bytes(manifest)
print('ARM9_MONITOR_INPUT_SHA256',hashlib.sha256(manifest).hexdigest())
PY
  docker run --rm --network none -v "$test_tmp:/test" -w /test \
    nds4mister-nvc-arm64:1.22.1 bash /test/source/tools/test_arm9_monitor.sh --inside "${1:-all}"
  exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
python3 "$repo/tools/suspend_resume/arm9_monitor_rom.py" --check
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
  "$p/nds_cpu9.vhd" "$repo/rtl/nds_arm9_monitor_rom.vhd" \
  "$repo/rtl/nds_arm9_monitor_probe.vhd" "$repo/rtl/tb_nds_arm9_monitor.vhd"
run() {
  nvc --std=2008 -e "$@" tb_nds_arm9_monitor
  nvc --std=2008 -r tb_nds_arm9_monitor --ieee-warnings=off --exit-severity=error
}
if [[ ${2:-all} != --negative-only ]]; then
for mode in 0x10 0x11 0x12 0x13 0x17 0x1B 0x1F; do
  python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --arm9 --mode "$mode"
  for step in 1 5; do
    for delay in 1 11; do
      echo "mode=$mode step=$step delay=$delay"
      run -gOPERATION=baseline -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay"
      run -gOPERATION=capture -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay" -gCANCEL_DMA=true
      run -gOPERATION=restore -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay"
    done
  done
done
for early in false true; do
  python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --arm9 --thumb
  for step in 1 5; do
    for delay in 1 11; do
      echo "thumb early=$early step=$step delay=$delay"
      run -gOPERATION=baseline -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay"
      run -gOPERATION=capture -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay" -gEARLY_CAPTURE="$early"
      run -gOPERATION=restore -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay"
    done
  done
done
fi
python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --arm9
run -gOPERATION=baseline
run -gOPERATION=capture
for word in 3 8 22 29 30 32 33 35 36 38 39 41 43 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63; do
  if run -gOPERATION=restore -gCORRUPT_WORD="$word" > negative.log 2>&1; then
    echo "FAIL: corrupted snapshot word $word was invisible" >&2;exit 1
  fi
  grep -F 'guest continuation mismatch' negative.log
done
python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --arm9 --mode 0x11
run -gOPERATION=baseline
run -gOPERATION=capture
if run -gOPERATION=restore -gCORRUPT_WORD=15 > negative.log 2>&1; then
  echo 'FAIL: inactive System bank corruption was invisible' >&2;exit 1
fi
grep -F 'guest continuation mismatch' negative.log
for word in 42 43; do
  run -gOPERATION=restore -gCORRUPT_WORD="$word" -gEXPECT_REJECT=true
done
# Omit the third metadata store in a private ROM copy. The hardware coverage
# check must prevent a return even though the remaining register image is valid.
python3 - "$repo/rtl/nds_arm9_monitor_rom.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old='259 => x"E880000E"'
assert s.count(old)==1
Path('missing_meta_rom.vhd').write_text(s.replace(old,'259 => x"E8800006"'))
PY
nvc --std=2008 -a missing_meta_rom.vhd "$repo/rtl/nds_arm9_monitor_probe.vhd" "$repo/rtl/tb_nds_arm9_monitor.vhd"
run -gOPERATION=restore -gEXPECT_REJECT=true
nvc --std=2008 -a "$repo/rtl/nds_arm9_monitor_rom.vhd" "$repo/rtl/nds_arm9_monitor_probe.vhd" "$repo/rtl/tb_nds_arm9_monitor.vhd"
# A real owner drain must precede private instruction execution.
python3 - "$p/nds_cpu9.vhd" <<'PYFAULT'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();old="mon_draining = '1' and monitor_memory_idle = '1' and cache_op_busy = '0'"
assert s.count(old)==1
Path('early-drain.vhd').write_text(s.replace(old,"mon_draining = '1'"))
PYFAULT
nvc --std=2008 -a early-drain.vhd "$repo/rtl/nds_arm9_monitor_probe.vhd" "$repo/rtl/tb_nds_arm9_monitor.vhd"
if run -gOPERATION=restore > early-drain.log 2>&1; then
  echo 'FAIL: early drain was invisible' >&2;exit 1
fi
grep -F 'fresh load ran before memory drained' early-drain.log
nvc --std=2008 -a "$p/nds_cpu9.vhd" "$repo/rtl/nds_arm9_monitor_probe.vhd" "$repo/rtl/tb_nds_arm9_monitor.vhd"
python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --arm9 --no-branch
run -gOPERATION=baseline
for step in 1 5; do
  for delay in 1 11; do
    run -gOPERATION=cancel -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay"
  done
done
nvc --std=2008 -a "$repo/rtl/tb_nds_cpu9_wfi_return.vhd"
for delay in 1 11; do
for wake in 0 4 12; do
for irq in true false; do
  mutate=false
  if [[ $irq == false ]]; then mutate=true; fi
  nvc --std=2008 -e -gMONITOR_CANCEL=true -gIRQ_ENABLED="$irq" -gREAD_DELAY="$delay" \
    -gWAKE_DELAY="$wake" -gMUTATE_PREFETCH="$mutate" tb_nds_cpu9_wfi_return
  nvc --std=2008 -r tb_nds_cpu9_wfi_return --ieee-warnings=off --exit-severity=error
done
done
done
echo 'PASS: ARM9 monitor suite, 33 functional corruption controls, 3 metadata rejects, 1 early-drain control, 4 no-branch and 12 WFI cancellations'
