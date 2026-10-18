#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-sound-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show "7e94517190a1328cf64fa46d964a530e0fdbfe1f:third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd" > "$test_tmp/sound-baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_sound_restore.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$p/proc_bus_gba.vhd" "$repo/rtl/tb_nds_sound_fetch_state_ram.vhd" "$p/nds_sound.vhd" "$repo/rtl/tb_nds_checkpoint_sound_restore.vhd"
cases=0;comparisons=0
for config in '1 0 0 4' '1 0 16 4' '1 0 17 4' '1 0 1023 13' '0 0 17 13' '1 1 17 1' '1 1 800 13' '1 2 16 4' '1 3 0 13' '1 4 17 4';do
 read -r table scenario slot latency <<< "$config"
 nvc --std=2008 -L . -a sound-baseline.vhd "$repo/rtl/tb_nds_checkpoint_sound_restore.vhd"
 nvc --std=2008 -L . -e -gTABLE_RAM="$table" -gSCENARIO="$scenario" -gSLOT="$slot" -gLATENCY="$latency" tb_nds_checkpoint_sound_restore
 nvc --std=2008 -L . -r tb_nds_checkpoint_sound_restore --ieee-warnings=off --exit-severity=error
 cp sound.state reference.state;cp sound.trace reference.trace;cp sound-first-step.state reference-first-step.state
 nvc --std=2008 -L . -a "$p/nds_sound.vhd" "$repo/rtl/tb_nds_checkpoint_sound_restore.vhd"
 nvc --std=2008 -L . -e -gTABLE_RAM="$table" -gSCENARIO="$scenario" -gSLOT="$slot" -gLATENCY="$latency" tb_nds_checkpoint_sound_restore
 nvc --std=2008 -L . -r tb_nds_checkpoint_sound_restore --ieee-warnings=off --exit-severity=error
 cmp sound.state reference.state;cmp sound.trace reference.trace;cmp sound-first-step.state reference-first-step.state
 comparisons=$((comparisons+1))
 cp sound.state "sound-$table-$scenario-$slot-$latency.state";cp sound.trace "sound-$table-$scenario-$slot-$latency.trace"
 cp sound-first-step.state "sound-$table-$scenario-$slot-$latency.first-step"
 for gaps in 0 1;do
  nvc --std=2008 -L . -e -gTABLE_RAM="$table" -gSCENARIO="$scenario" -gSLOT="$slot" -gLATENCY="$latency" -gRESTORING=true -gWRITE_GAPS="$gaps" tb_nds_checkpoint_sound_restore
  nvc --std=2008 -L . -r tb_nds_checkpoint_sound_restore --ieee-warnings=off --exit-severity=error
  cases=$((cases+1))
 done
done
echo "PASS: $comparisons pinned-source image and continuation comparisons"
echo "PASS: $cases fresh-process SPU restores and 65536-cycle continuations"

python3 - "$p/nds_sound.vhd" <<'PYCODE'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
changes={
 'lost-buffer':[("when 7 => chan(n).nxtw <= sample_write_data;","when 7 => chan(n).nxtw <= (others => '0');")],
 'lost-current-copy':[("if restore_curw_channel = i then chan(i).curw <= chan(i).nxtw; end if;","if restore_curw_channel = i then chan(i).curw <= (others => '0'); end if;")],
 'lost-decoder':[("chan(n).adval <= signed(checkpoint_write_data(15 downto 0));","chan(n).adval <= (others => '0');")],
 'lost-pointer':[("checkpoint_ram_data(24 downto 0) <= checkpoint_write_data(24 downto 0);","checkpoint_ram_data(24 downto 0) <= (others => '0');")],
 'lost-mix':[("when 264 => accl <= signed(checkpoint_write_data);","when 264 => accl <= (others => '0');")],
 'lost-pipeline':[("adstep_q(adstep_rr_d) <= to_integer(unsigned(adstep_effective_data));","adstep_q(adstep_rr_d) <= to_integer(unsigned(adstep_dout_v(14 downto 0)));")],
 'partial-ready':[("restore_next = 270 and restore_settle = 2", "restore_next /= 0")],
 'lost-order':[("a = to_integer(restore_next) and ","")],
 'invalid-index':[("shape and (checkpoint_write_data and not mask)","(checkpoint_write_data and not mask)"),
  ("to_integer(unsigned(checkpoint_write_data(22 downto 16)))","to_integer(unsigned(checkpoint_write_data(22 downto 16))) mod 89")],
 'stale-ram':[("ram_ready := checkpoint_ram_seen = '1' and checkpoint_ram_channel_d = c and checkpoint_ram_access = '1';","ram_ready := true;")],
 'live-write':[("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'","EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'")],
}
for name,replacements in changes.items():
 s=source;d=Path('negative-'+name);d.mkdir()
 for old,new in replacements:
  expected=2 if name=='invalid-index' and old.startswith('to_integer') else 1
  assert s.count(old)==expected,(name,s.count(old));s=s.replace(old,new)
 (d/'nds_sound.vhd').write_text(s)
PYCODE
for mutation in lost-buffer lost-current-copy lost-decoder lost-pointer lost-mix lost-pipeline partial-ready lost-order invalid-index stale-ram live-write;do
 config='1-0-17-4';scenario=0;latency=4;slot=17
 if [[ $mutation == lost-pipeline ]];then config='1-1-17-1';scenario=1;latency=1;fi
 test_dir="negative-$mutation"
 cp "sound-$config.state" "$test_dir/sound.state";cp "sound-$config.trace" "$test_dir/sound.trace"
 cp "sound-$config.first-step" "$test_dir/sound-first-step.state"
 pushd "$test_dir" >/dev/null
 nvc --std=2008 --work=MEM -a "$repo/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
 nvc --std=2008 -L . -a "$p/proc_bus_gba.vhd" "$repo/rtl/tb_nds_sound_fetch_state_ram.vhd" nds_sound.vhd "$repo/rtl/tb_nds_checkpoint_sound_restore.vhd"
 nvc --std=2008 -L . -e -gRESTORING=true -gSCENARIO="$scenario" -gLATENCY="$latency" -gSLOT="$slot" tb_nds_checkpoint_sound_restore
 if nvc --std=2008 -L . -r tb_nds_checkpoint_sound_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then
  echo "FAIL: SPU $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'SPU restored word differs|SPU continuation differs|SPU first resumed state differs|SPU incomplete image accepted|SPU invalid image accepted|SPU invalid restore order accepted|SPU stale RAM port accepted|[Ii]nteger.*range' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected SPU $mutation negative control"
 popd >/dev/null
done
