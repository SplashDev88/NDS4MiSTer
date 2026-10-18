#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-irq-ipc.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 # Freeze the reference at the last revision before these observers.
 for unit in nds_irq nds_ipc; do
  git -C "$repo" show "eb7580c9c8cfa619d7db48a5a36b4b2a8287da62:third_party/Nitro_DarkSide/d2dabe/rtl/$unit.vhd" > "$test_tmp/$unit-baseline.vhd"
 done
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_irq_ipc.sh --inside
 exit
fi
rtl="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
python3 - <<'PYCODE'
from pathlib import Path
import re
for name in ('nds_irq','nds_ipc'):
 s=Path(name+'-baseline.vhd').read_text()
 s=re.sub(r'\b'+name+r'\b',name+'_reference',s)
 # Keep the baseline register package independent too.
 s=s.replace('pReg_nds_irq','pReg_nds_irq_reference')
 Path(name+'-reference.vhd').write_text(s)
PYCODE
nvc --std=2008 -a "$rtl/proc_bus_gba.vhd" nds_irq-reference.vhd nds_ipc-reference.vhd "$rtl/nds_irq.vhd" "$rtl/nds_ipc.vhd" "$repo/rtl/tb_nds_checkpoint_irq_ipc.vhd"
for seed in 1 29 137; do
 nvc --std=2008 -e -gSEED=$seed tb_nds_checkpoint_irq_ipc
 nvc --std=2008 -r tb_nds_checkpoint_irq_ipc --ieee-warnings=off --exit-severity=error
done

python3 - "$rtl" <<'PYCODE'
from pathlib import Path
import sys
root=Path(sys.argv[1])
irq=(root/'nds_irq.vhd').read_text();ipc=(root/'nds_ipc.vhd').read_text()
mutations=[
 ('irq-input',irq,'(irq_in and not IRPFLags) = x"00000000"','true'),
 ('irq-output',irq,'cpu_unhalt = expected_unhalt and cpu_irq = expected_irq','true'),
 ('ipc-edge',ipc,'p7_sendemp = sendemp7 and p9_sendemp = sendemp9 and\n         p7_recvpend = recvpend7 and p9_recvpend = recvpend9','true'),
 ('ipc-pulse',ipc,"irq7_sync = '0' and irq9_sync = '0' and\n         irq7_sendempty = '0' and irq9_sendempty = '0' and\n         irq7_recv = '0' and irq9_recv = '0'",'true'),
]
for name,s,old,new in mutations:
 assert s.count(old)==1,(name,s.count(old))
 Path(name+'.vhd').write_text(s.replace(old,new))
PYCODE
for mutation in irq-input irq-output ipc-edge ipc-pulse; do
 nvc --std=2008 -a "$rtl/nds_irq.vhd" "$rtl/nds_ipc.vhd" "$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_irq_ipc.vhd"
 nvc --std=2008 -e tb_nds_checkpoint_irq_ipc
 if nvc --std=2008 -r tb_nds_checkpoint_irq_ipc --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'new IRQ bit falsely settled|IRQ idle preceded|IME output latency falsely idle|IPC enabled edge falsely idle|IPC emitted pulse falsely idle|IPC idle preceded' "$mutation.log"
 echo "PASS: detected $mutation negative control"
done
