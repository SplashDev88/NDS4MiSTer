#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]];then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-graphics-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show 'ef7e26520626c3206bb2ab9321abc7c0f01031c1:rtl/nds_h3d_console_event_gate.vhd' > "$test_tmp/baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_graphics_restore.sh --inside
 exit
fi
python3 - <<'PY'
from pathlib import Path
import re
s=Path('baseline.vhd').read_text();Path('reference.vhd').write_text(re.sub(r'\bnds_h3d_console_event_gate\b','nds_h3d_console_event_gate_reference',s))
PY
nvc --std=2008 -a "$repo/rtl/nds_hblank_run_queue.vhd" reference.vhd "$repo/rtl/nds_h3d_console_event_gate.vhd" "$repo/rtl/tb_nds_checkpoint_graphics_restore.vhd"
for mode in queued compressed sparse;do
 compressed=false;sparse=false
 if [[ $mode == compressed ]];then compressed=true;fi
 if [[ $mode == sparse ]];then sparse=true;fi
 for bits in 2 5;do
  for scenario in 0 1 2;do
   nvc --std=2008 -e -gCOMPRESS="$compressed" -gSPARSE="$sparse" -gQUEUE_BITS="$bits" -gSCENARIO="$scenario" tb_nds_checkpoint_graphics_restore
   nvc --std=2008 -r tb_nds_checkpoint_graphics_restore --ieee-warnings=off --exit-severity=error
   cp graphics.state "graphics-$mode-$bits-$scenario.state";cp graphics.trace "graphics-$mode-$bits-$scenario.trace"
   for gap in 0 7;do
    nvc --std=2008 -e -gRESTORING=true -gCOMPRESS="$compressed" -gSPARSE="$sparse" -gQUEUE_BITS="$bits" -gSCENARIO="$scenario" -gGAP="$gap" tb_nds_checkpoint_graphics_restore
    nvc --std=2008 -r tb_nds_checkpoint_graphics_restore --ieee-warnings=off --exit-severity=error
   done
  done
 done
done
echo 'PASS:36 fresh-process graphics epoch restores with reset-empty queues and unchanged valid delivery'
python3 - "$repo/rtl/nds_h3d_console_event_gate.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-time-low':('timestamp_counter(31 downto 0) <= unsigned(checkpoint_write_data);',"timestamp_counter(31 downto 0) <= (others => '0');",1),
 'lost-time-high':('timestamp_counter(63 downto 32) <= unsigned(checkpoint_write_data);',"timestamp_counter(63 downto 32) <= (others => '0');",1),
 'lost-frame':('when 2 => frame_counter <= unsigned(checkpoint_write_data);',"when 2 => frame_counter <= (others => '0');",1),
 'lost-lcd-frame':('hblank_frame_counter <= unsigned(checkpoint_write_data);',"hblank_frame_counter <= (others => '0');",1),
 'broken-gpu-empty':("gpu_write_pointer <= (others => '0');","gpu_write_pointer <= to_unsigned(1,gpu_write_pointer'length);",2),
 'broken-hblank-empty':("hblank_write_pointer <= (others => '0');","hblank_write_pointer <= to_unsigned(1,hblank_write_pointer'length);",3),
 'lost-order':('checkpoint_address = restore_count else','true else',1),
 'partial-ready':('restore_count = 4 and','restore_count > 0 and',1),
 'ignored-service':("checkpoint_producers_stopped = '1' and service_ready = '1' and restore_error", "checkpoint_producers_stopped = '1' and restore_error",1),
 'escaped-event':('service_active <= service_ready and not restore_active;','service_active <= service_ready;',1),
}
for n,(a,b,count) in mutations.items():
 assert s.count(a)==count,(n,s.count(a));Path(n+'.vhd').write_text(s.replace(a,b,1))
PY
for mutation in lost-time-low lost-time-high lost-frame lost-lcd-frame broken-gpu-empty broken-hblank-empty lost-order partial-ready ignored-service escaped-event;do
 check_image=false
 case "$mutation" in lost-order|partial-ready|ignored-service|escaped-event) check_image=true;;esac
 mkdir "negative-$mutation";cp graphics-queued-2-2.state "negative-$mutation/graphics.state";cp graphics-queued-2-2.trace "negative-$mutation/graphics.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$repo/rtl/nds_hblank_run_queue.vhd" /test/reference.vhd "/test/$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_graphics_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO=2 -gCHECK_IMAGE="$check_image" tb_nds_checkpoint_graphics_restore
 if nvc --std=2008 -r tb_nds_checkpoint_graphics_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then echo "FAIL: $mutation negative control passed" >&2;exit 1;fi
 grep -E 'graphics continuation mismatch|graphics restored epoch carry failed|graphics restored word mismatch|graphics invalid restore accepted|graphics partial restore accepted|graphics missing service accepted|graphics event escaped restore isolation' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control";popd >/dev/null
done
