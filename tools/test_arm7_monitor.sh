#!/usr/bin/env bash
# Isolated CPU-assisted capture/restore. No console build or hardware deployment.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
  test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-arm7-monitor.XXXXXX")
  trap 'rm -rf "$test_tmp"' EXIT
  python3 - "$repo" "$test_tmp/source" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
r,o=map(Path,sys.argv[1:])
files=['third_party/Nitro_DarkSide/d2dabe/rtl/'+n for n in
       ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','gba_cpu.vhd','nds_membus7.vhd','nds_syscnt.vhd']]
files+=['rtl/nds_arm7_monitor_rom.vhd','rtl/nds_arm7_monitor_probe.vhd',
        'rtl/tb_nds_arm7_monitor.vhd','rtl/tb_nds_arm7_halt_prefetch.vhd',
        'tools/suspend_resume/arm7_monitor_rom.py','tools/suspend_resume/arm7_monitor_rom.lst',
        'tools/suspend_resume/arm7_monitor_fixture.py','tools/test_arm7_monitor.sh']
hashes={}
for n in files:
    (o/n).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,o/n)
    hashes[n]=hashlib.sha256((o/n).read_bytes()).hexdigest()
manifest=json.dumps(hashes,sort_keys=True).encode()
(o/'INPUTS.json').write_bytes(manifest)
print('ARM7_MONITOR_INPUT_SHA256',hashlib.sha256(manifest).hexdigest())
PY
  docker run --rm --network none -v "$test_tmp:/test" -w /test \
    nds4mister-nvc-arm64:1.22.1 bash /test/source/tools/test_arm7_monitor.sh --inside "${1:-all}"
  exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
python3 "$repo/tools/suspend_resume/arm7_monitor_rom.py" --check
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
  "$p/gba_cpu.vhd" "$repo/rtl/nds_arm7_monitor_rom.vhd" \
  "$repo/rtl/nds_arm7_monitor_probe.vhd" "$repo/rtl/tb_nds_arm7_monitor.vhd"
run() {
  nvc --std=2008 -e "$@" tb_nds_arm7_monitor
  nvc --std=2008 -r tb_nds_arm7_monitor --ieee-warnings=off --exit-severity=error
}
if [[ ${2:-all} != --negative-only ]]; then
for mode in 0x10 0x11 0x12 0x13 0x17 0x1B 0x1F; do
  python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --mode "$mode"
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
  python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --thumb
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
python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py"
run -gOPERATION=baseline
run -gOPERATION=capture
for word in 3 8 22 29 30 32 33 35 36 38 39 41; do
  if run -gOPERATION=restore -gCORRUPT_WORD="$word" > negative.log 2>&1; then
    echo "FAIL: corrupted snapshot word $word was invisible" >&2;exit 1
  fi
  grep -F 'guest continuation mismatch' negative.log
done
python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --mode 0x11
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
python3 - "$repo/rtl/nds_arm7_monitor_rom.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old='259 => x"E880000E"'
assert s.count(old)==1
Path('missing_meta_rom.vhd').write_text(s.replace(old,'259 => x"E8800006"'))
PY
nvc --std=2008 -a missing_meta_rom.vhd "$repo/rtl/nds_arm7_monitor_probe.vhd" "$repo/rtl/tb_nds_arm7_monitor.vhd"
run -gOPERATION=restore -gEXPECT_REJECT=true
nvc --std=2008 -a "$repo/rtl/nds_arm7_monitor_rom.vhd" "$repo/rtl/nds_arm7_monitor_probe.vhd" "$repo/rtl/tb_nds_arm7_monitor.vhd"
python3 "$repo/tools/suspend_resume/arm7_monitor_fixture.py" --no-branch
run -gOPERATION=baseline
for step in 1 5; do
  for delay in 1 11; do
    run -gOPERATION=cancel -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay"
  done
done
nvc --std=2008 -a "$p/nds_membus7.vhd" "$p/nds_syscnt.vhd" "$repo/rtl/tb_nds_arm7_halt_prefetch.vhd"
for masked in true false; do
  for thumb in true false; do
    for dma in true false; do
      nvc --std=2008 -e -gMONITOR_CANCEL=true -gMASK_IRQ="$masked" \
        -gTHUMB="$thumb" -gDMA_PAUSE="$dma" tb_nds_arm7_halt_prefetch
      nvc --std=2008 -r tb_nds_arm7_halt_prefetch --ieee-warnings=off --exit-severity=error
    done
  done
done
echo 'PASS: ARM7 monitor suite (36 pairs unless --negative-only), 13 functional corruption controls, 3 metadata rejects, 4 no-branch and 8 native HALT cancellations'
