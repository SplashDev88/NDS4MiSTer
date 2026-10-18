#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-gx-owner-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 for name in nds_h3d_gx_readback_owner nds_h3d_gx_status;do
  git -C "$repo" show "7ae587bbe157aaf71b224bdc55897ebb4b57e40e:rtl/$name.vhd" > "$test_tmp/$name-baseline.vhd"
 done
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_gx_owner_restore.sh --inside
 exit
fi
python3 - <<'PY'
from pathlib import Path
import re
for name in ['nds_h3d_gx_readback_owner','nds_h3d_gx_status']:
 s=Path(name+'-baseline.vhd').read_text();Path(name+'-reference.vhd').write_text(re.sub(r'\b'+name+r'\b',name+'_reference',s))
PY
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
compile() {
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" /test/nds_h3d_gx_readback_owner-reference.vhd /test/nds_h3d_gx_status-reference.vhd "$1" "$2" "$repo/rtl/tb_nds_checkpoint_gx_owner_restore.vhd"
}
compile "$repo/rtl/nds_h3d_gx_readback_owner.vhd" "$repo/rtl/nds_h3d_gx_status.vhd"
for scenario in {0..15};do
 nvc --std=2008 -e -gSCENARIO="$scenario" tb_nds_checkpoint_gx_owner_restore
 nvc --std=2008 -r tb_nds_checkpoint_gx_owner_restore --ieee-warnings=off --exit-severity=error
 for ext in state cache trace;do cp "gx.$ext" "gx-$scenario.$ext";done
 for gap in 0 7;do
  nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gGAP="$gap" tb_nds_checkpoint_gx_owner_restore
  nvc --std=2008 -r tb_nds_checkpoint_gx_owner_restore --ieee-warnings=off --exit-severity=error
 done
done
echo 'PASS:32 fresh-process GX query/status restores with partial commands, cache generations and non-reused request IDs'
python3 - "$repo/rtl" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);q=(r/'nds_h3d_gx_readback_owner.vhd').read_text();s=(r/'nds_h3d_gx_status.vhd').read_text()
mutations={
 'q-lost-sequence':(q,'request_sequence<=unsigned(checkpoint_write_data);',"request_sequence<=(others=>'0');"),
 'q-lost-status':(q,'cached_status<=checkpoint_write_data;',"cached_status<=(others=>'0');"),
 'q-lost-commands':(q,'packed_commands<=checkpoint_write_data;',"packed_commands<=(others=>'0');"),
 'q-lost-progress':(q,'parameters_left<=to_integer(unsigned(checkpoint_write_data(20 downto 15)));','parameters_left<=0;'),
 'q-lost-test-bits':(q,'test_bits<=checkpoint_write_data(11 downto 10);','test_bits<="00";'),
 'q-lost-test-dirty':(q,'test_dirty<=checkpoint_write_data(7);',"test_dirty<='0';"),
 's-lost-irq':(s,'irq_mode<=checkpoint_write_data(16 downto 15);','irq_mode<="00";'),
 's-lost-display':(s,'disp3dcnt<=checkpoint_write_data(14 downto 0);',"disp3dcnt<=(others=>'0');"),
 'q-lost-order':(q,'checkpoint_address=restore_count and','true and'),
 'q-partial-ready':(q,'restore_count=6 and','restore_count>0 and'),
 'q-missing-cache':(q,"(cached_valid='0' or checkpoint_cache_ready='1') and",'true and'),
 'q-bad-reserved':(q,'unsigned(d(31 downto 21))=0 and','true and'),
 'q-live-write':(q,"EXPERIMENTAL_CHECKPOINT and reset='1' and checkpoint_restore='1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore='1' else '0'"),
 's-bad-mask':(s,'and x"FFFE3000"','and x"FFFE2000"'),
}
for n,(src,a,b) in mutations.items():
 assert src.count(a)==1,(n,src.count(a));Path(n+'.vhd').write_text(src.replace(a,b))
PY
for mutation in q-lost-sequence q-lost-status q-lost-commands q-lost-progress q-lost-test-bits q-lost-test-dirty s-lost-irq s-lost-display q-lost-order q-partial-ready q-missing-cache q-bad-reserved q-live-write s-bad-mask;do
 scenario=1;check_image=false
 case "$mutation" in
  q-lost-sequence)scenario=13;;q-lost-status)scenario=2;;q-lost-commands|q-lost-progress)scenario=8;;q-lost-test-bits)scenario=6;;q-lost-test-dirty)scenario=4;;s-lost-irq|s-lost-display)scenario=5;;
  q-lost-order|q-partial-ready|q-missing-cache|q-bad-reserved|q-live-write|s-bad-mask)check_image=true;;
 esac
 mkdir "negative-$mutation";for ext in state cache trace;do cp "gx-$scenario.$ext" "negative-$mutation/gx.$ext";done
 pushd "negative-$mutation" >/dev/null
 if [[ $mutation == q-* ]];then compile "/test/$mutation.vhd" "$repo/rtl/nds_h3d_gx_status.vhd";else compile "$repo/rtl/nds_h3d_gx_readback_owner.vhd" "/test/$mutation.vhd";fi
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gCHECK_IMAGE="$check_image" tb_nds_checkpoint_gx_owner_restore
 if nvc --std=2008 -r tb_nds_checkpoint_gx_owner_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then echo "FAIL: $mutation negative control passed" >&2;exit 1;fi
 grep -E 'GX owner continuation mismatch|GX restored word mismatch|GX status restored word mismatch|GX invalid restore accepted|GX status invalid restore accepted|GX partial restore accepted|GX missing cache generation accepted|GX live restore accepted' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control";popd >/dev/null
done
