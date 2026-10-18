#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-graphics.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_graphics.sh --inside
 exit
fi
compile() {
 nvc --std=2008 -a "$repo/rtl/nds_hblank_run_queue.vhd" "$1" "$repo/rtl/tb_nds_checkpoint_graphics.vhd"
}
compile "$repo/rtl/nds_h3d_console_event_gate.vhd"
for enabled in true false; do
 for mode in queued compressed sparse; do
  compressed=false; sparse=false
  if [[ $mode == compressed ]]; then compressed=true; fi
  if [[ $mode == sparse ]]; then sparse=true; fi
  for bits in 2 5; do
   for delay in 1 7; do
    nvc --std=2008 -e -gENABLE="$enabled" -gCOMPRESS="$compressed" -gSPARSE="$sparse" \
     -gQUEUE_BITS="$bits" -gDELAY="$delay" tb_nds_checkpoint_graphics
    nvc --std=2008 -r tb_nds_checkpoint_graphics --exit-severity=error
   done
  done
 done
done
python3 - "$repo/rtl/nds_h3d_console_event_gate.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'running-clock':("if checkpoint_clock_hold = '0' then",'if true then'),
 'early-clock':("and checkpoint_producers_stopped = '1' and","and"),
 'missing-frame':('and frame_pending_count = 0 and','and'),
 'missing-hblank':('and unsigned(hblank_run_pending) = 0',''),
 'lost-service':("if service_ready = '0' then checkpoint_invalid <= '1'; end if;","null;"),
 'ignored-fault':('source_fault_reason_i = "00" and hblank_run_fault = \'0\'',"true"),
 'destructive-pause':("if (service_ready = '0') then","if (service_ready = '0' or checkpoint_request = '1') then"),
}
for name,(old,new) in mutations.items():
 assert s.count(old)==1,(name,s.count(old))
 Path(name+'.vhd').write_text(s.replace(old,new))
PY
for mutation in running-clock early-clock missing-frame missing-hblank lost-service ignored-fault destructive-pause; do
 mkdir "negative-$mutation"; pushd "negative-$mutation" >/dev/null
 compile "/test/$mutation.vhd"
 compressed=false
 if [[ $mutation == missing-frame || $mutation == ignored-fault ]]; then sparse=true; else sparse=false; fi
 if [[ $mutation == missing-hblank ]]; then compressed=true; fi
 nvc --std=2008 -e -gCOMPRESS="$compressed" -gSPARSE="$sparse" tb_nds_checkpoint_graphics
 if nvc --std=2008 -r tb_nds_checkpoint_graphics --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2; exit 1
 fi
 grep -E 'graphics clock moved|graphics clock stopped before|pending queues falsely stopped|pending frame queue falsely|pending HBlank queue falsely|service loss reopened|faulted graphics stream falsely|unexpected GPU event|GPU record order|accepted graphics records lost|cancel discarded|CPU posting completed' "$mutation.log" || { cat "$mutation.log"; exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
echo 'PASS: 24 graphics checkpoint configurations and 7 negative controls'
