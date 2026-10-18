#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-timer-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_timer_restore.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/reggba_timer.vhd" \
 "$p/gba_timer_module.vhd" "$p/gba_timer.vhd" "$repo/rtl/tb_nds_checkpoint_timer_restore.vhd"
cases=0
for prescaler in 0 1 2 3; do
 scenarios='0 1'; if [[ $prescaler == 0 ]]; then scenarios='0 1 2 3 4 5'; fi
 for scenario in $scenarios; do
  nvc --std=2008 -e -gPRESCALER="$prescaler" -gSCENARIO="$scenario" tb_nds_checkpoint_timer_restore
  nvc --std=2008 -r tb_nds_checkpoint_timer_restore --ieee-warnings=off --exit-severity=error
  cp timer.state "timer-$prescaler-$scenario.state"
  cp timer.trace "timer-$prescaler-$scenario.trace"
  for order in 0 1 2; do
   nvc --std=2008 -e -gRESTORING=true -gPRESCALER="$prescaler" -gSCENARIO="$scenario" -gWRITE_ORDER="$order" tb_nds_checkpoint_timer_restore
   nvc --std=2008 -r tb_nds_checkpoint_timer_restore --ieee-warnings=off --exit-severity=error
   cases=$((cases+1))
  done
 done
done
echo "PASS: $cases fresh-process timer restores and 8705-step continuations"

python3 - "$p" <<'PYCODE'
from pathlib import Path
import sys
p=Path(sys.argv[1])
top=(p/'gba_timer.vhd').read_text();module=(p/'gba_timer_module.vhd').read_text()
mutations={
 'lost-phase':('top','prescaleCounter <= unsigned(checkpoint_write_data(9 downto 0));',"prescaleCounter <= (others => '0');"),
 'lost-startwait':('module','startwait <= checkpoint_write_data(1);',"startwait <= '0';"),
 'lost-readback':('module','counter_readback <= checkpoint_write_data(31 downto 16);','counter_readback <= checkpoint_write_data(15 downto 0);'),
 'erase-registers':('module',"register_bus.rst <= '0'; register_bus.ena <= '0';","register_bus.rst <= gb_bus.rst; register_bus.ena <= '0';"),
 'partial-ready':('top',"restore_loaded = (12 downto 0 => '1')","restore_loaded /= (12 downto 0 => '0')"),
 'live-write':('both',"EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'")
}
for name,(target,old,new) in mutations.items():
 d=Path('negative-'+name);d.mkdir()
 for kind,source,file in (('top',top,'gba_timer.vhd'),('module',module,'gba_timer_module.vhd')):
  if target in (kind,'both'):
   assert source.count(old)==1,(name,kind,source.count(old))
   source=source.replace(old,new)
  (d/file).write_text(source)
PYCODE
for mutation in lost-phase lost-startwait lost-readback erase-registers partial-ready live-write; do
 prescaler=1;scenario=0
 if [[ $mutation == lost-startwait ]]; then prescaler=0;scenario=2;fi
 if [[ $mutation == lost-readback ]]; then prescaler=0;scenario=4;fi
 cp "timer-$prescaler-$scenario.state" "negative-$mutation/timer.state"
 cp "timer-$prescaler-$scenario.trace" "negative-$mutation/timer.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/reggba_timer.vhd" \
  gba_timer_module.vhd gba_timer.vhd "$repo/rtl/tb_nds_checkpoint_timer_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gPRESCALER="$prescaler" -gSCENARIO="$scenario" tb_nds_checkpoint_timer_restore
 if nvc --std=2008 -r tb_nds_checkpoint_timer_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'timer restored word differs|incomplete timer restore accepted|complete timer restore never|timer continuation mismatch' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
