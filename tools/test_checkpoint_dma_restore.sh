#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-dma-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_dma_restore.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$p/nds_dma7.vhd" "$p/nds_dma9.vhd" "$repo/rtl/tb_nds_checkpoint_dma_restore.vhd"
cases=0
for cpu in false true;do
 scenarios='0 1 2 5 6 7';if [[ $cpu == true ]];then scenarios='0 1 2 3 4 5 6 7';fi
 for latency in 2 7;do
  for scenario in $scenarios;do
   nvc --std=2008 -e -gARM9="$cpu" -gLATENCY="$latency" -gSCENARIO="$scenario" tb_nds_checkpoint_dma_restore
   nvc --std=2008 -r tb_nds_checkpoint_dma_restore --ieee-warnings=off --exit-severity=error
   cp dma.state "dma-$cpu-$latency-$scenario.state";cp dma.trace "dma-$cpu-$latency-$scenario.trace"
   for order in 0 1 2;do
    nvc --std=2008 -e -gARM9="$cpu" -gLATENCY="$latency" -gSCENARIO="$scenario" -gRESTORING=true -gWRITE_ORDER="$order" tb_nds_checkpoint_dma_restore
    nvc --std=2008 -r tb_nds_checkpoint_dma_restore --ieee-warnings=off --exit-severity=error
    cases=$((cases+1))
   done
  done
 done
done
echo "PASS: $cases fresh-process DMA restores and 16384-observation continuations"

python3 - "$p" <<'PYCODE'
from pathlib import Path
import sys
p=Path(sys.argv[1])
mutations={
 'lost-pending':[("ch(checkpoint_channel).pend <= checkpoint_write_data(31);","ch(checkpoint_channel).pend <= '0';")],
 'wrong-source':[("ch(checkpoint_channel).cur_src <= unsigned(checkpoint_write_data(27 downto 0));","ch(checkpoint_channel).cur_src <= (others => '0');")],
 'partial-ready':[],
 'live-write':[("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'"),
   ("if (reset = '1') then\n            if restore_active", "if (reset = '1' or restore_active = '1') then\n            if restore_active")],
 'invalid-remain':[("shape_valid and (checkpoint_write_data and not allowed)","(checkpoint_write_data and not allowed)")],
 'unstable-capture':[("trig_vblank = '0' and trig_card = '0' and mb_done = '0'", "true")],
 'lost-remain':[("ch(checkpoint_channel).remain <= unsigned(checkpoint_write_data(21 downto 0));","ch(checkpoint_channel).remain <= (others => '0');")],
 'lost-prefetch':[("when 31 => pf_data(31 downto 0) <= checkpoint_write_data;","when 31 => pf_data(31 downto 0) <= (others => '0');")],
 'lost-gx-history':[("trig_gx_d <= trig_gx_d; -- retain the image through reset-held load gaps","null; -- deliberately let the live source overwrite the image")],
}
for cpu in (7,9):
 for name,replacements in mutations.items():
  if cpu==7 and name in ('lost-remain','lost-prefetch','lost-gx-history'):continue
  source=(p/f'nds_dma{cpu}.vhd').read_text();d=Path(f'negative-{cpu}-{name}');d.mkdir()
  if name=='partial-ready':
   end=25 if cpu==7 else 36
   replacements=[(f"restore_loaded = ({end} downto 0 => '1')",f"restore_loaded /= ({end} downto 0 => '0')")]
  for old,new in replacements:
   assert source.count(old)==1,(cpu,name,source.count(old));source=source.replace(old,new)
  (d/f'nds_dma{cpu}.vhd').write_text(source)
PYCODE
for cpu in 7 9;do
 arm9=false;mutations='lost-pending wrong-source partial-ready live-write invalid-remain unstable-capture'
 if [[ $cpu == 9 ]];then arm9=true;mutations="$mutations lost-remain lost-prefetch lost-gx-history";fi
 for mutation in $mutations;do
  scenario=1
  if [[ $mutation == lost-remain || $mutation == lost-gx-history ]];then scenario=3;fi
  if [[ $mutation == lost-prefetch ]];then scenario=4;fi
  test_dir="negative-$cpu-$mutation"
  cp "dma-$arm9-2-$scenario.state" "$test_dir/dma.state";cp "dma-$arm9-2-$scenario.trace" "$test_dir/dma.trace"
  pushd "$test_dir" >/dev/null
  seven="$p/nds_dma7.vhd";nine="$p/nds_dma9.vhd"
  if [[ $cpu == 7 ]];then seven=nds_dma7.vhd;else nine=nds_dma9.vhd;fi
  nvc --std=2008 -a "$p/proc_bus_gba.vhd" "$seven" "$nine" "$repo/rtl/tb_nds_checkpoint_dma_restore.vhd"
  nvc --std=2008 -e -gARM9="$arm9" -gRESTORING=true -gSCENARIO="$scenario" tb_nds_checkpoint_dma_restore
  if nvc --std=2008 -r tb_nds_checkpoint_dma_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then
   echo "FAIL: DMA$cpu $mutation negative control passed" >&2;exit 1
  fi
  grep -E 'DMA restored word differs|incomplete DMA restore accepted|invalid DMA image accepted|DMA exposed unstable trigger capture|DMA continuation differs' "$mutation.log" || { cat "$mutation.log";exit 1; }
  echo "PASS: detected DMA$cpu $mutation negative control"
  popd >/dev/null
 done
done
