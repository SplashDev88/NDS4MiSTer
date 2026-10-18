#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-display-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show 'ef7e26520626c3206bb2ab9321abc7c0f01031c1:rtl/nds_gpu2d_register_shadow.vhd' > "$test_tmp/baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_display_restore.sh --inside
 exit
fi
python3 - <<'PY'
from pathlib import Path
import re
s=Path('baseline.vhd').read_text();Path('reference.vhd').write_text(re.sub(r'\bnds_gpu2d_register_shadow\b','nds_gpu2d_register_shadow_reference',s))
PY
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" reference.vhd "$repo/rtl/nds_gpu2d_register_shadow.vhd" "$repo/rtl/tb_nds_checkpoint_display_restore.vhd"
for engine in false true;do
 for scenario in {0..5};do
  nvc --std=2008 -e -gENGINE_B="$engine" -gSCENARIO="$scenario" tb_nds_checkpoint_display_restore
  nvc --std=2008 -r tb_nds_checkpoint_display_restore --ieee-warnings=off --exit-severity=error
  cp display.state "display-$engine-$scenario.state";cp display.trace "display-$engine-$scenario.trace"
  for gap in 0 7;do
   nvc --std=2008 -e -gRESTORING=true -gENGINE_B="$engine" -gSCENARIO="$scenario" -gGAP="$gap" tb_nds_checkpoint_display_restore
   nvc --std=2008 -r tb_nds_checkpoint_display_restore --ieee-warnings=off --exit-severity=error
  done
 done
done
echo 'PASS:24 fresh-process display register restores across both product engine banks'
python3 - "$repo/rtl/nds_gpu2d_register_shadow.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();mutations={}
for name in ['disp_cnt','bg01_cnt','bg23_cnt','win_cnt','blend_cnt']:
 mutations['lost-'+name]=(name+' <= checkpoint_write_data;',name+" <= (others => '0');")
mutations['lost-bright']=('master_bright <= checkpoint_write_data(15 downto 0);',"master_bright <= (others => '0');")
mutations.update({
 'lost-order':('checkpoint_address = restore_count and','true and'),
 'bad-window':('when 3 => return (d and not x"3F3F3F3F")','when 3 => return (d and not x"3F3F3F7F")'),
 'partial-ready':('restore_count = 6 and','restore_count > 0 and'),
 'live-write':("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'"),
})
for n,(a,b) in mutations.items():
 assert s.count(a)==1,(n,s.count(a));Path(n+'.vhd').write_text(s.replace(a,b))
PY
for mutation in lost-disp_cnt lost-bg01_cnt lost-bg23_cnt lost-win_cnt lost-blend_cnt lost-bright lost-order bad-window partial-ready live-write;do
 check_image=false
 case "$mutation" in lost-order|bad-window|partial-ready|live-write) check_image=true;;esac
 mkdir "negative-$mutation";cp display-true-5.state "negative-$mutation/display.state";cp display-true-5.trace "negative-$mutation/display.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" /test/reference.vhd "/test/$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_display_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO=5 -gCHECK_IMAGE="$check_image" tb_nds_checkpoint_display_restore
 if nvc --std=2008 -r tb_nds_checkpoint_display_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then echo "FAIL: $mutation negative control passed" >&2;exit 1;fi
 grep -E 'display continuation mismatch|display restored word mismatch|display invalid restore accepted|display live restore accepted|display partial restore accepted' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control";popd >/dev/null
done
