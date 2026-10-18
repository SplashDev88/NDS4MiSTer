#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-card.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show '372cba7ec2895140775b6e5e889d7001db50973a:third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd' > "$test_tmp/card-baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_card.sh --inside
 exit
fi
rtl="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
python3 - <<'PYCODE'
from pathlib import Path
import re
s=Path('card-baseline.vhd').read_text()
Path('card-reference.vhd').write_text(re.sub(r'\bnds_card\b','nds_card_reference',s))
PYCODE
nvc --std=2008 -a "$rtl/proc_bus_gba.vhd" card-reference.vhd "$rtl/nds_card.vhd" "$repo/rtl/tb_nds_checkpoint_card.vhd"
for owner in 0 1; do
 for prefetch in 1 4 7; do
  for latency in 1 17 97; do
   for paused in false true; do
    nvc --std=2008 -e -gOWNER=$owner -gPREFETCH=$prefetch -gLATENCY=$latency -gEXERCISE_STOP=$paused tb_nds_checkpoint_card
    nvc --std=2008 -r tb_nds_checkpoint_card --ieee-warnings=off --exit-severity=error
   done
  done
 done
done
python3 - "$rtl/nds_card.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
for name,old,new in [
 ('running-pacing',"if stop_card = '0' or v_pop = '1' then",'if true then'),
 ('running-prefetch',"if (stop_card = '0' and busy = '1'", "if (busy = '1'"),
 ('lost-response',"if (card_done = '1' and pf_inflt = '1') then", "if (card_done = '1' and pf_inflt = '1' and stop_card = '0') then"),
 ('running-erase',"if (erase_active = '1' and backup_cache_ready = '1' and stop_card = '0') then", "if (erase_active = '1' and backup_cache_ready = '1') then"),
]:
 assert s.count(old)==1,name
 Path(name+'.vhd').write_text(s.replace(old,new))
PYCODE
for mutation in running-pacing running-prefetch lost-response running-erase; do
 nvc --std=2008 -a "$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_card.vhd"
 nvc --std=2008 -e tb_nds_checkpoint_card
 if nvc --std=2008 -r tb_nds_checkpoint_card --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'held card pacing/prefetch/erase changed|held register start was lost|card accepted work did not drain|card acknowledged outstanding work|card issued prefetch while stopped|card issued erase byte while stopped' "$mutation.log"
 echo "PASS: detected $mutation negative control"
done
