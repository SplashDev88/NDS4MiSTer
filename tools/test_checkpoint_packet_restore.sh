#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-packet-restore.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
iv=${IVERILOG:-iverilog};vv=${VVP:-vvp}
git -C "$repo" show '60354e005f98db3f3643a1e67162888ae03fd07a:rtl/nds_gx_fifo_packet_frontend.sv' > "$test_tmp/baseline.sv"
python3 - "$test_tmp" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1]);s=(p/'baseline.sv').read_text();(p/'reference.sv').write_text(re.sub(r'\bnds_gx_fifo_packet_frontend\b','nds_gx_fifo_packet_frontend_reference',s))
PY
compile() {
 "$iv" -g2012 -s tb_nds_checkpoint_packet_restore -Ptb_nds_checkpoint_packet_restore.RETIRE="$2" \
  -o "$test_tmp/test" "$1" "$test_tmp/reference.sv" "$repo/rtl/tb_nds_checkpoint_packet_restore.sv" 2> "$test_tmp/compile.log" || { cat "$test_tmp/compile.log";return 1; }
}
cd "$test_tmp"
for retire in 0 1; do
 compile "$repo/rtl/nds_gx_fifo_packet_frontend.sv" "$retire"
 for scenario in {0..15};do
  "$vv" ./test +scenario="$scenario"
  cp packet.state "packet-$retire-$scenario.state";cp packet.trace "packet-$retire-$scenario.trace"
  for gap in 0 7;do "$vv" ./test +restore +scenario="$scenario" +gap="$gap";done
 done
done
echo 'PASS:64 fresh-process packet restores with pinned-source continuation, both retirement modes and complete protocol coverage'
python3 - "$repo/rtl/nds_gx_fifo_packet_frontend.sv" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-packed':('0: packed_commands <= checkpoint_write_data;',"0: packed_commands <= 32'd0;"),
 'lost-trigger':('1: packed_trigger_parameter <= checkpoint_write_data;',"1: packed_trigger_parameter <= 32'd0;"),
 'lost-frame':('2: packed_word_frame <= checkpoint_write_data;',"2: packed_word_frame <= 32'd0;"),
 'lost-timestamp':('4: packed_word_timestamp[63:32] <= checkpoint_write_data;',"4: packed_word_timestamp[63:32] <= 32'd0;"),
 'lost-parameters':('packed_parameters_remaining <= checkpoint_write_data[8:3];',"packed_parameters_remaining <= 6'd1;"),
 'lost-position':('pos_pointer <= checkpoint_write_data[16:11];',"pos_pointer <= 6'd0;"),
 'lost-error':('stack_error <= checkpoint_write_data[19];',"stack_error <= 1'b0;"),
 'lost-wait':('waiting_vblank <= checkpoint_write_data[25];',"waiting_vblank <= 1'b0;"),
 'lost-retirement':('swap_memory[checkpoint_cell] <= checkpoint_write_data[0];',"swap_memory[checkpoint_cell] <= 1'b0;"),
 'partial-ready':("restore_count == 9'd263 && !checkpoint_write",'restore_count > 0 && !checkpoint_write'),
 'lost-order':('checkpoint_address == restore_count && restore_value_valid','restore_value_valid'),
 'lost-tail-check':('checkpoint_write_data[15:8] == restored_tail',"1'b1"),
 'lost-range':('checkpoint_write_data[8:3] <= 32','checkpoint_write_data[8:3] <= 63'),
 'false-drain':('count == 0 && swap_count == 0',"1'b1"),
}
for n,(a,b) in mutations.items():
 assert s.count(a)==1,(n,s.count(a));Path(n+'.sv').write_text(s.replace(a,b))
PY
for mutation in lost-packed lost-trigger lost-frame lost-timestamp lost-parameters lost-position lost-error lost-wait lost-retirement partial-ready lost-order lost-tail-check lost-range false-drain;do
 scenario=3;args=(+no-image-check)
 case "$mutation" in
  lost-packed|lost-parameters) scenario=1;;
  lost-position) scenario=4;;
  lost-error) scenario=11;;
  lost-wait) scenario=5;;
  lost-retirement) scenario=6;;
  partial-ready|lost-order|lost-tail-check|lost-range) args=(+image-check);;
  false-drain) scenario=13;args=(+image-check);;
 esac
 cp "packet-1-$scenario.state" packet.state;cp "packet-1-$scenario.trace" packet.trace
 compile "$mutation.sv" 1
 mode=(+restore)
 if [[ $mutation == false-drain ]];then mode=(+capture);fi
 if "$vv" ./test "${mode[@]}" +scenario="$scenario" "${args[@]}" > "$mutation.log" 2>&1;then
  echo "FAIL:packet mutation survived:$mutation";exit 1
 fi
 if [[ $mutation == lost-* && $mutation != lost-order && $mutation != lost-tail-check && $mutation != lost-range ]];then
  grep -q 'packet continuation mismatch' "$mutation.log" || { cat "$mutation.log";exit 1; }
 else
  grep -Eq 'packet (partial image ready|invalid restore accepted|undelivered queue claimed stopped)' "$mutation.log" || { cat "$mutation.log";exit 1; }
 fi
 echo "PASS:packet fault detected:$mutation"
done
