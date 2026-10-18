#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-arm7.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_arm7_memory.sh --inside
 exit
fi
rtl="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$rtl/proc_bus_gba.vhd" "$rtl/nds_membus7.vhd" "$rtl/nds_wram.vhd" "$repo/rtl/tb_nds_checkpoint_arm7.vhd" "$repo/rtl/tb_nds_membus7_wifi.vhd"
nvc --std=2008 -L . -e tb_nds_checkpoint_arm7
nvc --std=2008 -L . -r tb_nds_checkpoint_arm7 --ieee-warnings=off --exit-severity=error
nvc --std=2008 -L . -e tb_nds_membus7_wifi
nvc --std=2008 -L . -r tb_nds_membus7_wifi --ieee-warnings=off --exit-severity=error

python3 - "$rtl" <<'PYCODE'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=(p/'nds_membus7.vhd').read_text()
old="checkpoint_idle <= '1' when reset = '0' and state = IDLE and"
assert s.count(old)==1
Path('pending-io.vhd').write_text(s.replace(old,"checkpoint_idle <= '1' when reset = '0' and (state = IDLE or state = W_IO_ALIGN) and"))
s=(p/'nds_wram.vhd').read_text()
old='not (arm9_ena or arm7_ena or arm9_done or arm7_done)'
assert s.count(old)==1
Path('wram-completion.vhd').write_text(s.replace(old,'not (arm9_ena or arm7_ena)'))
PYCODE
for mutation in pending-io wram-completion; do
 nvc --std=2008 -L . -a "$rtl/nds_membus7.vhd" "$rtl/nds_wram.vhd" "$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_arm7.vhd"
 nvc --std=2008 -L . -e tb_nds_checkpoint_arm7
 if nvc --std=2008 -L . -r tb_nds_checkpoint_arm7 --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'ARM7 pending IO falsely idle|shared-WRAM idle overlapped admission/completion' "$mutation.log"
 echo "PASS: detected $mutation negative control"
done
