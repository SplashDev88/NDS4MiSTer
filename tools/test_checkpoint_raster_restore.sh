#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-raster-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show 'd6e6d8c30f5b9e08f5cdda55af9706029403fb04:third_party/Nitro_DarkSide/d2dabe/rtl/nds_gpu_timing.vhd' > "$test_tmp/baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_raster_restore.sh --inside
 exit
fi
python3 - <<'PY'
from pathlib import Path
import re
s=Path('baseline.vhd').read_text();Path('reference.vhd').write_text(re.sub(r'\bnds_gpu_timing\b','nds_gpu_timing_reference',s))
PY
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/reg_nds_display.vhd" reference.vhd "$p/nds_gpu_timing.vhd" "$repo/rtl/tb_nds_checkpoint_raster_restore.vhd"
for scenario in {0..19};do
 nvc --std=2008 -e -gSCENARIO="$scenario" tb_nds_checkpoint_raster_restore
 nvc --std=2008 -r tb_nds_checkpoint_raster_restore --ieee-warnings=off --exit-severity=error
 cp raster.state "raster-$scenario.state";cp raster.trace "raster-$scenario.trace"
 for gap in 0 7;do
  nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gGAP="$gap" tb_nds_checkpoint_raster_restore
  nvc --std=2008 -r tb_nds_checkpoint_raster_restore --ieee-warnings=off --exit-severity=error
 done
done
echo 'PASS:40 fresh-process raster restores, exact event cadence, delayed VCOUNT, display flags and physical line state'
python3 - "$p/nds_gpu_timing.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-cycle':('cycles <= to_integer(unsigned(checkpoint_write_data(11 downto 0)));','cycles <= 0;'),
 'lost-line':('line <= to_integer(unsigned(checkpoint_write_data(20 downto 12)));','line <= 0;'),
 'lost-vcount':('vcnt <= unsigned(checkpoint_write_data(29 downto 21));',"vcnt <= (others => '0');"),
 'lost-pending':('vcnt_wr_pend <= checkpoint_write_data(0);',"vcnt_wr_pend <= '0';"),
 'lost-phase':('lcd_phase_line <= unsigned(checkpoint_write_data(20 downto 12));',"lcd_phase_line <= (others => '0');"),
 'lost-draw-counter':('linecounter_state <= to_integer(unsigned(checkpoint_write_data(7 downto 0)));','linecounter_state <= 0;'),
 'lost-dispstat9':('busses(c).Din <= checkpoint_write_data;','if c=0 then busses(c).Din <= (others => \'0\'); else busses(c).Din <= checkpoint_write_data; end if;'),
 'lost-dispstat7':('busses(c).Din <= checkpoint_write_data;','if c=1 then busses(c).Din <= (others => \'0\'); else busses(c).Din <= checkpoint_write_data; end if;'),
 'lost-order':('checkpoint_address = restore_count and','true and'),
 'bad-control':('and x"FFFF0047"','and x"FFFF0046"'),
 'partial-ready':('restore_count = 5 and','restore_count > 0 and'),
 'live-write':("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'"),
}
for n,(a,b) in mutations.items():
 assert s.count(a)==1,(n,s.count(a));Path(n+'.vhd').write_text(s.replace(a,b))
PY
for mutation in lost-cycle lost-line lost-vcount lost-pending lost-phase lost-draw-counter lost-dispstat9 lost-dispstat7 lost-order bad-control partial-ready live-write;do
 scenario=10;check_image=false
 case "$mutation" in lost-pending) scenario=16;;lost-order|bad-control|partial-ready|live-write) check_image=true;;esac
 mkdir "negative-$mutation";cp "raster-$scenario.state" "negative-$mutation/raster.state";cp "raster-$scenario.trace" "negative-$mutation/raster.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/reg_nds_display.vhd" /test/reference.vhd "/test/$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_raster_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gCHECK_IMAGE="$check_image" tb_nds_checkpoint_raster_restore
 if nvc --std=2008 -r tb_nds_checkpoint_raster_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'raster continuation mismatch|raster restored word mismatch|raster invalid restore accepted|raster live restore accepted|raster partial restore accepted' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
