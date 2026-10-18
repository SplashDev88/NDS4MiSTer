#!/usr/bin/env bash
# Frozen audio state rotation, common-owner release guard and continuation tests.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-audio-rotation.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 python3 "$repo/tools/suspend_resume/prepare_audio_rotation_probe.py" --output "$test_tmp/probe"
 docker run --rm --network none -v "$test_tmp/probe:/test" -w /test/run \
  nds4mister-nvc-arm64:1.22.1 bash /test/source/tools/test_checkpoint_audio_rotation.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$p/proc_bus_gba.vhd" "$repo/rtl/tb_nds_sound_fetch_state_ram.vhd" "$repo/rtl/nds_checkpoint_audio_scan_guard.vhd" "$p/nds_sound.vhd" "$repo/rtl/tb_nds_checkpoint_sound_rotation.vhd"
cases=0;comparisons=0
for config in '1 0 0 4' '1 0 16 4' '1 0 17 4' '1 0 1023 13' '0 0 17 13' '1 1 17 1' '1 1 800 13' '1 2 16 4' '1 3 0 13' '1 4 17 4';do
 read -r table scenario slot latency <<< "$config"
 rotating=false
 nvc --std=2008 -L . -a sound-baseline.vhd "$repo/rtl/tb_nds_checkpoint_sound_rotation.vhd"
 nvc --std=2008 -L . -e -gROTATING="$rotating" -gTABLE_RAM="$table" -gSCENARIO="$scenario" -gSLOT="$slot" -gLATENCY="$latency" tb_nds_checkpoint_sound_rotation
 nvc --std=2008 -L . -r tb_nds_checkpoint_sound_rotation --ieee-warnings=off --exit-severity=error
 cp sound.state reference.state;cp sound.trace reference.trace;cp sound-first-step.state reference-first-step.state
 rotating=true
 nvc --std=2008 -L . -a "$p/nds_sound.vhd" "$repo/rtl/tb_nds_checkpoint_sound_rotation.vhd"
 nvc --std=2008 -L . -e -gROTATING="$rotating" -gTABLE_RAM="$table" -gSCENARIO="$scenario" -gSLOT="$slot" -gLATENCY="$latency" tb_nds_checkpoint_sound_rotation
 nvc --std=2008 -L . -r tb_nds_checkpoint_sound_rotation --ieee-warnings=off --exit-severity=error
 cmp sound.state reference.state;cmp sound.trace reference.trace;cmp sound-first-step.state reference-first-step.state
 comparisons=$((comparisons+1))
 cp sound.state "sound-$table-$scenario-$slot-$latency.state";cp sound.trace "sound-$table-$scenario-$slot-$latency.trace"
 cp sound-first-step.state "sound-$table-$scenario-$slot-$latency.first-step"
 for gaps in 0 1;do
  nvc --std=2008 -L . -e -gROTATING="$rotating" -gTABLE_RAM="$table" -gSCENARIO="$scenario" -gSLOT="$slot" -gLATENCY="$latency" -gRESTORING=true -gWRITE_GAPS="$gaps" tb_nds_checkpoint_sound_rotation
  nvc --std=2008 -L . -r tb_nds_checkpoint_sound_rotation --ieee-warnings=off --exit-severity=error
  cases=$((cases+1))
 done
done
echo "PASS: $comparisons pinned-source image and continuation comparisons"
echo "PASS: $cases fresh-process SPU restores and 65536-cycle continuations"


p=/test/source/third_party/Nitro_DarkSide/d2dabe/rtl
python3 - "$p/nds_sound.vhd" /test/source/rtl/nds_checkpoint_audio_scan_guard.vhd <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();g=Path(sys.argv[2]).read_text()
changes={
 'lost-word-rotation':('sound',"chan(i).nxtw <= chan((i+1) mod 16).nxtw;","chan(i).nxtw <= chan(i).nxtw;"),
 'early-release':('sound',"checkpoint_release_ready <= '1' when not EXPERIMENTAL_CHECKPOINT or rotate_index = 0 else '0';","checkpoint_release_ready <= '1';"),
 'stale-channel':('sound','if EXPERIMENTAL_CHECKPOINT and a < 270 and ram_ready and rotate_index = rotate_goal and','if EXPERIMENTAL_CHECKPOINT and a < 270 and ram_ready and'),
 'lost-restore-slot':('sound','chan(0).adval <= signed(checkpoint_write_data(15 downto 0));','chan(1).adval <= signed(checkpoint_write_data(15 downto 0));'),
 'guard-hold':('guard','device_hold <= capture_request or restore_active or not channel_order_ready;','device_hold <= capture_request or restore_active;'),
 'guard-permit':('guard','return_permission <= outer_return_permission and channel_order_ready and not restore_active;','return_permission <= outer_return_permission and not restore_active;'),
 'guard-acquisition':('guard',"when (capture_request='1' and capture_held='1') or restore_active='1'", "when capture_request='1' or restore_active='1'"),
 'guard-cleanup':('guard',"sound_address <= requested_address when (capture_request='1' and capture_held='1') or restore_active='1' else to_unsigned(256,9);",'sound_address <= requested_address;'),
}
for n,(kind,a,b) in changes.items():
 src=s if kind=='sound' else g;assert src.count(a)==1,(n,src.count(a));d=Path('guard-'+n);d.mkdir(exist_ok=True)
 (d/'nds_sound.vhd').write_text(s.replace(a,b) if kind=='sound' else s)
 (d/'nds_checkpoint_audio_scan_guard.vhd').write_text(g.replace(a,b) if kind=='guard' else g)
PY
for mutation in lost-word-rotation early-release stale-channel lost-restore-slot guard-hold guard-permit guard-acquisition guard-cleanup;do
 d="guard-$mutation"
 cp sound-1-0-17-4.state "$d/sound.state"
 cp sound-1-0-17-4.trace "$d/sound.trace"
 cp sound-1-0-17-4.first-step "$d/sound-first-step.state"
 pushd "$d" >/dev/null
 nvc --std=2008 --work=MEM -a /test/source/rtl/tb_mem_sync_ram_dual_byte_enable.vhd
 nvc --std=2008 -L . -a "$p/proc_bus_gba.vhd" /test/source/rtl/tb_nds_sound_fetch_state_ram.vhd nds_checkpoint_audio_scan_guard.vhd nds_sound.vhd /test/source/rtl/tb_nds_checkpoint_sound_rotation.vhd
 nvc --std=2008 -L . -e -gROTATING=true -gRESTORING=true tb_nds_checkpoint_sound_rotation
 if nvc --std=2008 -L . -r tb_nds_checkpoint_sound_rotation --ieee-warnings=off --exit-severity=error > fault.log 2>&1;then
  echo "FAIL: $mutation escaped" >&2;exit 1
 fi
 grep -E 'SPU restored word differs|SPU early rotation release|SPU advanced before rotation unwind|SPU first resumed state differs|SPU continuation differs|SPU scan guard released owners early|SPU rotated before common acquisition|SPU rotation cancellation did not drain' fault.log
 echo "PASS: detected $mutation fault"
 popd >/dev/null
done

echo "PASS: audio rotation 10 pinned comparisons, 20 fresh restores, 900 cancellation/owner-loss unwinds and eight faults"
