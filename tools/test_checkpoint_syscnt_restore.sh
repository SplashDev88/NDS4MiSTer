#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-syscnt-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show '624085aec4ef5fa166c76098e2ab2e7529dc8cf9:third_party/Nitro_DarkSide/d2dabe/rtl/nds_syscnt.vhd' > "$test_tmp/baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_syscnt_restore.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
python3 - <<'PY'
from pathlib import Path
import re
s=Path('baseline.vhd').read_text();Path('reference.vhd').write_text(re.sub(r'\bnds_syscnt\b','nds_syscnt_reference',s))
PY
nvc --std=2008 -a "$p/proc_bus_gba.vhd" reference.vhd "$p/nds_syscnt.vhd" "$repo/rtl/tb_nds_checkpoint_syscnt_restore.vhd"
for cold in 0 1;do
 for scenario in {0..9};do
  nvc --std=2008 -e -gCOLD="$cold" -gSCENARIO="$scenario" tb_nds_checkpoint_syscnt_restore
  nvc --std=2008 -r tb_nds_checkpoint_syscnt_restore --exit-severity=error
  if [[ $cold == 0 ]];then cp syscnt.state "syscnt-$scenario.state";cp syscnt.trace "syscnt-$scenario.trace";fi
  for gap in 0 7;do
   nvc --std=2008 -e -gRESTORING=true -gCOLD="$cold" -gSCENARIO="$scenario" -gGAP="$gap" tb_nds_checkpoint_syscnt_restore
   nvc --std=2008 -r tb_nds_checkpoint_syscnt_restore --exit-severity=error
  done
 done
done
echo 'PASS:40 fresh-process system-control restores, pinned-source equality, raw mappings, power/ownership, sticky flags and sleep/wake'
python3 - "$p/nds_syscnt.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-exmem':('exmem9 <= checkpoint_write_data(15 downto 0);',"exmem9 <= (others => '0');"),
 'lost-wram':('r_wramcnt <= checkpoint_write_data(24 downto 23);','r_wramcnt <= "00";'),
 'lost-vram':('r_vramcnt(31 downto 0) <= checkpoint_write_data;',"r_vramcnt(31 downto 0) <= (others => '0');"),
 'lost-power':('r_powcnt <= checkpoint_write_data(23 downto 8);',"r_powcnt <= (others => '0');"),
 'lost-sleep':('console_sleep <= checkpoint_write_data(28);',"console_sleep <= '0';"),
 'lost-post':('postflg9 <= checkpoint_write_data(27 downto 26);','postflg9 <= "00";'),
 'partial-ready':('restore_count = 4 and','restore_count > 0 and'),
 'lost-order':('checkpoint_address = restore_count and','true and'),
 'invalid-power':('and x"7DF0"','and x"7DE0"'),
 'live-write':("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'"),
}
for n,(a,b) in mutations.items():
 assert s.count(a)==1,(n,s.count(a));Path(n+'.vhd').write_text(s.replace(a,b))
PY
for mutation in lost-exmem lost-wram lost-vram lost-power lost-sleep lost-post partial-ready lost-order invalid-power live-write;do
 scenario=5;check_image=false
 case "$mutation" in lost-sleep) scenario=6;;lost-post) scenario=1;;partial-ready|lost-order|invalid-power|live-write) check_image=true;;esac
 mkdir "negative-$mutation";cp "syscnt-$scenario.state" "negative-$mutation/syscnt.state";cp "syscnt-$scenario.trace" "negative-$mutation/syscnt.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" /test/reference.vhd "/test/$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_syscnt_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gCHECK_IMAGE="$check_image" tb_nds_checkpoint_syscnt_restore
 if nvc --std=2008 -r tb_nds_checkpoint_syscnt_restore --exit-severity=error > "$mutation.log" 2>&1;then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'syscnt continuation mismatch|syscnt restored word mismatch|syscnt partial restore accepted|syscnt invalid restore accepted|syscnt live restore accepted' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
