#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-irq-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_irq_restore.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/nds_irq.vhd" "$repo/rtl/tb_nds_checkpoint_irq_restore.vhd"
for scenario in 0 1 2 3 4 5; do
 nvc --std=2008 -e -gSCENARIO="$scenario" tb_nds_checkpoint_irq_restore
 nvc --std=2008 -r tb_nds_checkpoint_irq_restore --exit-severity=error
 if [[ $scenario == 3 ]]; then cp irq.state irq-negative.state; cp irq.trace irq-negative.trace; fi
 for order in 0 1 2 3 4 5; do
  nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gWRITE_ORDER="$order" tb_nds_checkpoint_irq_restore
  nvc --std=2008 -r tb_nds_checkpoint_irq_restore --exit-severity=error
 done
done
echo 'PASS: 36 fresh-process IRQ restores, all word orders, invalid-word/coverage/live-write rejection and 513-step continuations'

python3 - "$p/nds_irq.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'missing-if':('IRPFLags <= checkpoint_write_data;',"IRPFLags <= (others => '0');"),
 'partial-ready':('restore_loaded = "111"','restore_loaded /= "000"'),
 'erase-registers':("register_bus.rst <= '0'; register_bus.rnw <= '0';","register_bus.rst <= gb_bus.rst; register_bus.rnw <= '0';"),
 'lost-irq':('cpu_irq <= expected_irq; cpu_unhalt <= expected_unhalt;',"cpu_irq <= '0'; cpu_unhalt <= '0';"),
 'live-write':("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'", "EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'")
}
for name,(old,new) in mutations.items():
 assert s.count(old)==1,(name,s.count(old))
 Path(name+'.vhd').write_text(s.replace(old,new))
PYCODE
for mutation in missing-if partial-ready erase-registers lost-irq live-write; do
 mkdir "negative-$mutation"
 cp irq-negative.state "negative-$mutation/irq.state"
 cp irq-negative.trace "negative-$mutation/irq.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" "/test/$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_irq_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO=3 tb_nds_checkpoint_irq_restore
 if nvc --std=2008 -r tb_nds_checkpoint_irq_restore --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2; exit 1
 fi
 grep -E 'IRQ restored word differs|incomplete IRQ restore accepted|complete IRQ restore never|checkpoint modified a running IRQ controller' "$mutation.log" || { cat "$mutation.log"; exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
