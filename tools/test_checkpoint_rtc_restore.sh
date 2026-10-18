#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-rtc-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show '574ec665ed0302647727fda8a3369b873df982ad:rtl/nds_nitro_rtc.vhd' > "$test_tmp/baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_rtc_restore.sh --inside
 exit
fi
python3 - <<'PY'
from pathlib import Path
import re
s=Path('baseline.vhd').read_text();Path('reference.vhd').write_text(re.sub(r'\bnds_nitro_rtc\b','nds_nitro_rtc_reference',s))
PY
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" reference.vhd "$repo/rtl/nds_nitro_rtc.vhd" "$repo/rtl/tb_nds_checkpoint_rtc_restore.vhd"
for scenario in {0..19};do
 nvc --std=2008 -e -gSCENARIO="$scenario" tb_nds_checkpoint_rtc_restore
 nvc --std=2008 -r tb_nds_checkpoint_rtc_restore --ieee-warnings=off --exit-severity=error
 cp rtc.state "rtc-$scenario.state";cp rtc.trace "rtc-$scenario.trace"
 for gap in 0 7;do
  nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gGAP="$gap" tb_nds_checkpoint_rtc_restore
  nvc --std=2008 -r tb_nds_checkpoint_rtc_restore --ieee-warnings=off --exit-severity=error
 done
done
echo 'PASS:40 fresh-process RTC restores, partial serial commands, coherent fractional calendar, seed phases and ordinary reset'
python3 - "$repo/rtl/nds_nitro_rtc.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-input':('in_byte <= checkpoint_write_data(23 downto 16);',"in_byte <= (others => '0');"),
 'lost-output':('out_buf(i) <= checkpoint_write_data(i*8+7 downto i*8);',"out_buf(i) <= (others => '0');"),
 'lost-alarm':('alarm1(i) <= checkpoint_write_data(i*8+7 downto i*8);',"alarm1(i) <= (others => '0');"),
 'lost-status':('status2 <= checkpoint_write_data(28 downto 21);',"status2 <= (others => '0');"),
 'lost-fraction':('sec_div <= to_integer(unsigned(checkpoint_write_data));','sec_div <= 0;'),
 'lost-notification':('date_toggle <= checkpoint_write_data(31);',"date_toggle <= '0';"),
 'lost-seed-valid':('seed_valid <= checkpoint_write_data(30);',"seed_valid <= '0';"),
 'lost-free':('freereg <= checkpoint_write_data(31 downto 24);','freereg <= x"00";'),
 'lost-order':('checkpoint_address = restore_count and','true and'),
 'bad-range':('when 1 => return unsigned(d(12 downto 10)) < 7;','when 1 => return true;'),
 'wrong-phase':("restore_count = 9 and checkpoint_write = '0' and seed_settled = '1' and restore_quiet = 3", "restore_count = 9 and checkpoint_write = '0'"),
 'live-write':("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'"),
}
for n,(a,b) in mutations.items():
 assert s.count(a)==1,(n,s.count(a));Path(n+'.vhd').write_text(s.replace(a,b))
PY
for mutation in lost-input lost-output lost-alarm lost-status lost-fraction lost-notification lost-seed-valid lost-free lost-order bad-range wrong-phase live-write;do
 scenario=6;check_image=false
 case "$mutation" in
  lost-input) scenario=3;;lost-alarm|lost-status) scenario=8;;lost-notification) scenario=5;;
  lost-order|bad-range|wrong-phase|live-write) check_image=true;;
 esac
 mkdir "negative-$mutation";cp "rtc-$scenario.state" "negative-$mutation/rtc.state";cp "rtc-$scenario.trace" "negative-$mutation/rtc.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" /test/reference.vhd "/test/$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_rtc_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gCHECK_IMAGE="$check_image" tb_nds_checkpoint_rtc_restore
 if nvc --std=2008 -r tb_nds_checkpoint_rtc_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'RTC continuation mismatch|RTC restored word mismatch|RTC invalid restore accepted|RTC live restore|RTC unmatched seed phase|RTC advanced during restore|outside of INTEGER range' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
