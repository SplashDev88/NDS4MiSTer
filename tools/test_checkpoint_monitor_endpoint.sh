#!/usr/bin/env bash
# Existing barrier plus actual ARM7 monitor: cancel, timeout and host lease loss.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
  test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-monitor-endpoint.XXXXXX")
  trap 'rm -rf "$test_tmp"' EXIT
  python3 - "$repo" "$test_tmp/source" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
r,o=map(Path,sys.argv[1:])
files=['third_party/Nitro_DarkSide/d2dabe/rtl/'+n for n in
       ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','gba_cpu.vhd']]
files+=['rtl/'+n for n in ['nds_monitor_pipeline_transfer.vhd','nds_arm7_monitor_rom.vhd','nds_arm7_monitor_probe.vhd',
        'nds_checkpoint_endpoint.vhd','nds_checkpoint_coordinator.vhd',
        'nds_checkpoint_monitor_endpoint.vhd','tb_nds_checkpoint_monitor_endpoint.vhd']]
files+=['tools/test_checkpoint_monitor_endpoint.sh']
h={}
for n in files:
    (o/n).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,o/n)
    h[n]=hashlib.sha256((o/n).read_bytes()).hexdigest()
data=json.dumps(h,sort_keys=True).encode();(o/'INPUTS.json').write_bytes(data)
print('MONITOR_ENDPOINT_INPUT_SHA256',hashlib.sha256(data).hexdigest())
PY
  docker run --rm --network none -e MONITOR_SLEEP="${MONITOR_SLEEP:-false}" -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
    bash /test/source/tools/test_checkpoint_monitor_endpoint.sh --inside
  exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$repo/rtl/nds_monitor_pipeline_transfer.vhd"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/gba_cpu.vhd" \
  "$repo/rtl/nds_arm7_monitor_rom.vhd" "$repo/rtl/nds_arm7_monitor_probe.vhd" \
  "$repo/rtl/nds_checkpoint_endpoint.vhd" "$repo/rtl/nds_checkpoint_coordinator.vhd" \
  "$repo/rtl/nds_checkpoint_monitor_endpoint.vhd" "$repo/rtl/tb_nds_checkpoint_monitor_endpoint.vhd"
run() {
  nvc --std=2008 -e -gSLEEP_MODE="${MONITOR_SLEEP:-false}" "$@" tb_nds_checkpoint_monitor_endpoint
  nvc --std=2008 -r tb_nds_checkpoint_monitor_endpoint --ieee-warnings=off --exit-severity=error
}
cases=0
for step in 1 5; do
for delay in 1 11; do
  run -gCANCEL_PHASE=0 -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay"
  cases=$((cases+1))
  for hold in false true; do
    for phase in 1 2; do
      run -gCANCEL_PHASE="$phase" -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay" -gHOLD_RETURN="$hold"
      cases=$((cases+1))
    done
    for timeout in false true; do
      if [[ $timeout == true ]]; then lease=false;else lease=true;fi
      run -gCANCEL_PHASE=2 -gSTEP_PERIOD="$step" -gREAD_DELAY="$delay" \
        -gHOLD_RETURN="$hold" -gACQUIRE_TIMEOUT="$timeout" -gEXPIRE_LEASE="$lease"
      cases=$((cases+1))
    done
  done
done
done
python3 - "$repo/rtl/nds_checkpoint_monitor_endpoint.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();old='seen<=request_sync or monitor_active;'
assert s.count(old)==1
Path('early_receipt.vhd').write_text(s.replace(old,'seen<=request_sync;'))
PY
nvc --std=2008 -a early_receipt.vhd "$repo/rtl/tb_nds_checkpoint_monitor_endpoint.vhd"
if run -gCANCEL_PHASE=1 > early_receipt.log 2>&1; then
  echo 'FAIL: premature rearm escaped detection' >&2;exit 1
fi
if ! grep -E 'barrier rearmed before maintenance finished|cancel/lease did not drain before rearm' early_receipt.log; then
  cat early_receipt.log;exit 1
fi
echo "PASS: $cases endpoint cases, three attempts each, and premature-rearm fault control"
