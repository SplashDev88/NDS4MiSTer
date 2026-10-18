#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-rtc.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show '62a5907ed2417f394c00720f8924604abd32d142:rtl/nds_nitro_rtc.vhd' > "$test_tmp/rtc-baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_rtc_inputs.sh --inside
 exit
fi
python3 - <<'PYCODE'
from pathlib import Path
import re
s=Path('rtc-baseline.vhd').read_text()
Path('rtc-reference.vhd').write_text(re.sub(r'\bnds_nitro_rtc\b','nds_nitro_rtc_reference',s))
PYCODE
nvc --std=2008 -a "$repo/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" rtc-reference.vhd "$repo/rtl/nds_nitro_rtc.vhd" "$repo/rtl/nds_checkpoint_inputs.vhd" "$repo/rtl/tb_nds_checkpoint_rtc.vhd" "$repo/rtl/tb_nds_checkpoint_inputs.vhd"
for second in 4096 8192; do
 for phase in 0 2 5; do
  nvc --std=2008 -e -gSECOND_CLOCKS=$second -gSEED_PHASE=$phase tb_nds_checkpoint_rtc
  nvc --std=2008 -r tb_nds_checkpoint_rtc --ieee-warnings=off --exit-severity=error
 done
done
nvc --std=2008 -e tb_nds_checkpoint_inputs
nvc --std=2008 -r tb_nds_checkpoint_inputs --ieee-warnings=off --exit-severity=error
python3 - "$repo/rtl" <<'PYCODE'
from pathlib import Path
import sys
r=Path(sys.argv[1]);s=(r/'nds_nitro_rtc.vhd').read_text()
for name,old,new in [
 ('stopped-clock',"if ce = '1' then", "if ce = '1' and checkpoint_request = '0' then"),
 ('moving-snapshot',"elsif valid = '0' then",'else'),
 ('torn-fraction','to_unsigned(sec_div, 32)','to_unsigned((sec_div + 1) mod CYCLES_PER_SECOND, 32)'),
]:
 assert s.count(old)==1,name
 Path(name+'.vhd').write_text(s.replace(old,new))
s=(r/'nds_checkpoint_inputs.vhd').read_text();old="elsif valid = '0' then captured <= live; valid <= '1'; end if;";assert s.count(old)==1
Path('moving-input.vhd').write_text(s.replace(old,"else captured <= live; valid <= '1'; end if;"))
PYCODE
for mutation in stopped-clock moving-snapshot torn-fraction moving-input; do
 nvc --std=2008 -a "$repo/rtl/nds_nitro_rtc.vhd" "$repo/rtl/nds_checkpoint_inputs.vhd" "$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_rtc.vhd" "$repo/rtl/tb_nds_checkpoint_inputs.vhd"
 top=tb_nds_checkpoint_rtc
 if [[ $mutation == moving-input ]]; then top=tb_nds_checkpoint_inputs; fi
 nvc --std=2008 -e "$top"
 if nvc --std=2008 -r "$top" --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'RTC checkpoint changed|RTC snapshot changed|RTC calendar/subsecond snapshot was torn|input hold or disabled path changed' "$mutation.log"
 echo "PASS: detected $mutation negative control"
done
