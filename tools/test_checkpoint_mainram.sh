#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-mainram.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_mainram.sh --inside
 exit
fi
rtl="$repo/third_party/Nitro_DarkSide/d2dabe/rtl/nds_mainram.vhd"
nvc --std=2008 -a "$rtl" "$repo/rtl/tb_nds_checkpoint_mainram.vhd"
for ratio in 1 3; do
 for phase in 0 2; do
  for latency in 1 4 17; do
   for priority in false true; do
    nvc --std=2008 -e -gMEM_RATIO=$ratio -gPHASE_NS=$phase -gLATENCY=$latency -gPRIORITY7=$priority tb_nds_checkpoint_mainram
    nvc --std=2008 -r tb_nds_checkpoint_mainram --ieee-warnings=off --exit-severity=error
   done
  done
 done
done

python3 - "$rtl" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old="checkpoint_idle_sync = '1' and mem9_ena = '0' and mem7_ena = '0' and"
assert s.count(old)==1
Path('stale-admission.vhd').write_text(s.replace(old,"checkpoint_idle_sync = '1' and"))
old="state = MR_IDLE and\n      lock_pair = '0' and"
assert s.count(old)==1
Path('unlocked-gap.vhd').write_text(s.replace(old,"(state = MR_IDLE or state = MR_LOCKWAIT) and"))
PYCODE
for mutation in stale-admission unlocked-gap; do
 nvc --std=2008 -a "$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_mainram.vhd"
 nvc --std=2008 -e tb_nds_checkpoint_mainram
 if nvc --std=2008 -r tb_nds_checkpoint_mainram --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'fresh main-RAM admission retained stale idle|main-RAM idle preceded transaction/response retirement|SWP gap falsely idle' "$mutation.log"
 echo "PASS: detected $mutation negative control"
done
