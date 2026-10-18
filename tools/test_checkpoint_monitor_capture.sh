#!/usr/bin/env bash
# Both real hybrid monitors, coherent transport and common maintenance return.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
  test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-monitor-capture.XXXXXX")
  trap 'rm -rf "$test_tmp"' EXIT
  python3 - "$repo" "$test_tmp/source" <<'PYFREEZE'
from pathlib import Path
import hashlib,json,shutil,sys
r,o=map(Path,sys.argv[1:])
files=['third_party/Nitro_DarkSide/d2dabe/rtl/'+n for n in ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','gba_cpu.vhd','nds_cpu9.vhd']]
files+=['rtl/'+n for n in ['nds_monitor_pipeline_transfer.vhd','nds_arm7_monitor_rom.vhd','nds_arm7_monitor_probe.vhd','nds_arm9_monitor_rom.vhd','nds_arm9_monitor_probe.vhd','nds_checkpoint_endpoint.vhd','nds_checkpoint_monitor_endpoint.vhd','nds_checkpoint_coordinator.vhd','nds_checkpoint_read_port.vhd','nds_checkpoint_monitor_capture.vhd','tb_nds_checkpoint_monitor_capture.vhd']]
files+=['tools/test_checkpoint_monitor_capture.sh'];hashes={}
for n in files:
 (o/n).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,o/n);hashes[n]=hashlib.sha256((o/n).read_bytes()).hexdigest()
manifest=json.dumps(hashes,sort_keys=True).encode();(o/'INPUTS.json').write_bytes(manifest)
print('MONITOR_CAPTURE_INPUT_SHA256',hashlib.sha256(manifest).hexdigest())
PYFREEZE
  docker run --rm --network none -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
    bash /test/source/tools/test_checkpoint_monitor_capture.sh --inside "${1:-all}"
  exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/gba_cpu.vhd" "$p/nds_cpu9.vhd" \
 "$repo/rtl/nds_monitor_pipeline_transfer.vhd" "$repo/rtl/nds_arm7_monitor_rom.vhd" "$repo/rtl/nds_arm7_monitor_probe.vhd" \
 "$repo/rtl/nds_arm9_monitor_rom.vhd" "$repo/rtl/nds_arm9_monitor_probe.vhd" \
 "$repo/rtl/nds_checkpoint_endpoint.vhd" "$repo/rtl/nds_checkpoint_monitor_endpoint.vhd" \
 "$repo/rtl/nds_checkpoint_coordinator.vhd" "$repo/rtl/nds_checkpoint_read_port.vhd" \
 "$repo/rtl/nds_checkpoint_monitor_capture.vhd" "$repo/rtl/tb_nds_checkpoint_monitor_capture.vhd"
run() { nvc --std=2008 -e "$@" tb_nds_checkpoint_monitor_capture; nvc --std=2008 -r tb_nds_checkpoint_monitor_capture --ieee-warnings=off --exit-severity=error; }
if [[ ${2:-all} == smoke ]]; then run;exit;fi
cases=0
for sleep7 in false true;do for sleep9 in false true;do
 for step in 1 5;do for delay in 1 11;do
  run -gSLEEP7="$sleep7" -gSLEEP9="$sleep9" -gSTEP7="$step" -gREAD_DELAY="$delay" -gHOLD_RETURN=true
  cases=$((cases+1))
 done;done
done;done
for scenario in early_cancel mid_cancel lease owner_loss read_stopped read_cancel;do
 for step in 1 5;do for delay in 1 11;do
  run -gSCENARIO="$scenario" -gSTEP7="$step" -gREAD_DELAY="$delay" -gHOLD_RETURN=true
  cases=$((cases+1))
 done;done
done
echo "PASS: $cases real hybrid monitor pair cases, three attempts each"

python3 - "$repo/rtl" <<'PYFAULT'
from pathlib import Path
import sys
p=Path(sys.argv[1]);cap=(p/'nds_checkpoint_monitor_capture.vhd').read_text();rd=(p/'nds_checkpoint_read_port.vhd').read_text();ep=(p/'nds_checkpoint_monitor_endpoint.vhd').read_text()
assert cap.count('RAM_READ_LATENCY=>1')==2
Path('stale-ram.vhd').write_text(cap.replace('RAM_READ_LATENCY=>1','RAM_READ_LATENCY=>0'))
assert cap.count('wait_sync="11" and')==1
Path('early-return.vhd').write_text(cap.replace('wait_sync="11" and',''))
assert rd.count('and unsigned(read_address) < WORD_COUNT')==1
assert rd.count('if unsigned(cpu_address) < WORD_COUNT then')==1
Path('range-alias.vhd').write_text(rd.replace('and unsigned(read_address) < WORD_COUNT','').replace('if unsigned(cpu_address) < WORD_COUNT then','if true then'))
assert ep.count('seen<=request_sync or monitor_active;')==1
Path('early-rearm.vhd').write_text(ep.replace('seen<=request_sync or monitor_active;','seen<=request_sync;'))
PYFAULT
for fault in stale-ram range-alias early-return early-rearm;do
 nvc --std=2008 -a "$repo/rtl/nds_checkpoint_read_port.vhd" "$repo/rtl/nds_checkpoint_monitor_endpoint.vhd"
 case "$fault" in
  range-alias|early-rearm) nvc --std=2008 -a "$fault.vhd"; nvc --std=2008 -a "$repo/rtl/nds_checkpoint_monitor_capture.vhd" ;;
  *) nvc --std=2008 -a "$repo/rtl/nds_checkpoint_monitor_capture.vhd" "$fault.vhd" ;;
 esac
 nvc --std=2008 -a "$repo/rtl/tb_nds_checkpoint_monitor_capture.vhd"
 if run -gSTEP7=5 > "$fault.log" 2>&1;then echo "FAIL: $fault escaped detection" >&2;exit 1;fi
 grep -E 'monitor transport returned wrong word|invalid read exposed monitor data|one CPU escaped before other return was ready|barrier rearmed before maintenance finished|maintenance failed to drain' "$fault.log"
 echo "PASS: detected $fault fault control"
done
echo "PASS: $cases hybrid monitor pair cases and four functional/protocol faults"
