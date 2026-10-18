#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-ipc-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_ipc_restore.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/nds_irq.vhd" "$p/nds_ipc.vhd" "$repo/rtl/tb_nds_checkpoint_ipc_restore.vhd"
cases=0
for seed in 1 29 137; do
 scenarios=6;if [[ $seed == 1 ]]; then scenarios='0 1 2 3 4 5 6';fi
 for scenario in $scenarios; do
  nvc --std=2008 -e -gSCENARIO="$scenario" -gSEED="$seed" tb_nds_checkpoint_ipc_restore
  nvc --std=2008 -r tb_nds_checkpoint_ipc_restore --ieee-warnings=off --exit-severity=error
  cp ipc.state "ipc-$seed-$scenario.state";cp ipc.trace "ipc-$seed-$scenario.trace"
  for order in 0 1 2; do
   nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gSEED="$seed" -gWRITE_ORDER="$order" tb_nds_checkpoint_ipc_restore
   nvc --std=2008 -r tb_nds_checkpoint_ipc_restore --ieee-warnings=off --exit-severity=error
   cases=$((cases+1))
  done
 done
done
echo "PASS: $cases fresh-process IPC/IRQ restores and 4106-observation continuations"

python3 - "$p/nds_ipc.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-queue':[("fifo79(to_integer(checkpoint_address)-4) <= checkpoint_write_data;","fifo79(to_integer(checkpoint_address)-4) <= (others => '0');")],
 'lost-last':[("when 2 => last7 <= checkpoint_write_data;","when 2 => last7 <= (others => '0');")],
 'wrong-pointer':[("rd79 <= to_integer(unsigned(checkpoint_write_data(13 downto 10)));","rd79 <= 0;")],
 'partial-ready':[("restore_loaded = (35 downto 0 => '1')","restore_loaded /= (35 downto 0 => '0')")],
 'new-wakeup':[("p7_sendemp <= expected_sendemp7; p9_sendemp <= expected_sendemp9;","p7_sendemp <= '0'; p9_sendemp <= '0';"),
   ("p7_sendemp = expected_sendemp7 and p9_sendemp = expected_sendemp9 and","true and")],
 'live-write':[("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'"),
   ("if (reset = '1') then","if (reset = '1' or restore_active = '1') then")],
 'retained-coverage':[("restore_loaded <= (others => '0'); restore_error <= '0';","restore_error <= '0';")],
 'invalid-ring':[("to_integer(unsigned(v(17 downto 14))) = (to_integer(unsigned(v(13 downto 10)))+n79) mod 16 and", "true and")],
}
for name,replacements in mutations.items():
 d=Path('negative-'+name);d.mkdir();source=s
 for old,new in replacements:
  assert source.count(old)==1,(name,source.count(old));source=source.replace(old,new)
 (d/'nds_ipc.vhd').write_text(source)
# An image that zeroes currently empty FIFO storage passes structural checks
# and readback. Only the actual resumed same-edge send/pop exposes the loss.
d=Path('negative-empty-cells');d.mkdir();(d/'nds_ipc.vhd').write_text(s)
image=Path('ipc-1-2.state').read_text().splitlines()
for i in range(4,36):image[i]='00000000'
(d/'ipc.state').write_text('\n'.join(image)+'\n')
PYCODE
for mutation in lost-queue lost-last wrong-pointer partial-ready new-wakeup live-write retained-coverage invalid-ring empty-cells; do
 scenario=0
 if [[ $mutation == wrong-pointer ]];then scenario=1;fi
 if [[ $mutation == new-wakeup || $mutation == empty-cells ]];then scenario=2;fi
 if [[ $mutation != empty-cells ]];then cp "ipc-1-$scenario.state" "negative-$mutation/ipc.state";fi
 cp "ipc-1-$scenario.trace" "negative-$mutation/ipc.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/nds_irq.vhd" nds_ipc.vhd "$repo/rtl/tb_nds_checkpoint_ipc_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" tb_nds_checkpoint_ipc_restore
 if nvc --std=2008 -r tb_nds_checkpoint_ipc_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'IPC/IRQ restored word differs|incomplete IPC restore accepted|complete IPC/IRQ restore never|invalid IPC restore was not rejected|fresh IPC attempt retained coverage|IPC continuation mismatch' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
