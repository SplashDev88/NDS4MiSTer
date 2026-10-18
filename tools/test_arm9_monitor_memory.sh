#!/usr/bin/env bash
# CPU-assisted monitor against the real cache/TCM decoder. No hardware action.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
  test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-arm9-monitor-memory.XXXXXX")
  trap 'rm -rf "$test_tmp"' EXIT
  python3 - "$repo" "$test_tmp/source" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
r,o=map(Path,sys.argv[1:])
files=['third_party/Nitro_DarkSide/d2dabe/rtl/'+n for n in
       ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','nds_cpu9.vhd','nds_cache9.vhd']]
files+=['rtl/nds_arm9_monitor_rom.vhd','rtl/nds_arm9_monitor_probe.vhd',
        'rtl/tb_nds_arm9_monitor_memory.vhd','rtl/nds_nitro_membus9.vhd',
        'rtl/tb_mem_sync_ram_dual_byte_enable.vhd','tools/test_arm9_monitor_memory.sh']
h={}
for n in files:
    (o/n).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,o/n)
    h[n]=hashlib.sha256((o/n).read_bytes()).hexdigest()
data=json.dumps(h,sort_keys=True).encode();(o/'INPUTS.json').write_bytes(data)
print('ARM9_MONITOR_MEMORY_INPUT_SHA256',hashlib.sha256(data).hexdigest())
PY
  docker run --rm --network none -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
    bash /test/source/tools/test_arm9_monitor_memory.sh --inside
  exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/nds_cpu9.vhd" \
  "$repo/rtl/nds_arm9_monitor_rom.vhd" "$repo/rtl/nds_arm9_monitor_probe.vhd" \
  "$p/nds_cache9.vhd" "$repo/rtl/nds_nitro_membus9.vhd" "$repo/rtl/tb_nds_arm9_monitor_memory.vhd"
run() {
  nvc --std=2008 -L . -e "$@" tb_nds_arm9_monitor_memory
  nvc --std=2008 -L . -r tb_nds_arm9_monitor_memory --ieee-warnings=off --exit-severity=error
}
for overlay in false true; do
for delay in 0 17; do
  run -gITCM_OVERLAY="$overlay" -gMEMORY_DELAY="$delay"
done
done
if run -gLOSE_CACHE=true > lost-cache.log 2>&1; then
  echo 'FAIL: cache loss was invisible' >&2;exit 1
fi
grep -E 'retained memory mismatch|dirty D/I cache was lost' lost-cache.log
python3 - "$repo/rtl/nds_arm9_monitor_probe.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();old='ena<=go and not private_select;';assert s.count(old)==1
Path('leak.vhd').write_text(s.replace(old,'ena<=go;'))
PY
nvc --std=2008 -L . -a leak.vhd "$repo/rtl/tb_nds_arm9_monitor_memory.vhd"
if run > leak.log 2>&1; then
  echo 'FAIL: private memory leak was invisible' >&2;exit 1
fi
grep -E 'maintenance leaked into guest cache/TCM|unexpected guest memory access' leak.log
echo 'PASS: 4 real-memory monitor cases and 2 cache-loss/private-leak controls'
