#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-cdc-restore.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
iv=${IVERILOG:-iverilog};vv=${VVP:-vvp}
compile() {
 "$iv" -g2012 -s tb_nds_checkpoint_cdc_restore \
  -Ptb_nds_checkpoint_cdc_restore.DDR_HALF="$2" -Ptb_nds_checkpoint_cdc_restore.SPARSE="$3" \
  -o "$test_tmp/test" "$repo/rtl/nds_h3d_event_async_fifo.sv" \
  "$repo/rtl/nds_gx_fifo_packet_frontend.sv" "$1" \
  "$repo/rtl/tb_nds_checkpoint_cdc_restore.sv" 2> "$test_tmp/compile.log" || { cat "$test_tmp/compile.log";return 1; }
}
cd "$test_tmp"
for half in 3 7;do
 for sparse in 0 1;do
  compile "$repo/rtl/nds_h3d_frame_record_cdc.sv" "$half" "$sparse"
  for scenario in {0..21};do
   "$vv" ./test +scenario="$scenario"
   cp cdc.state "cdc-$half-$sparse-$scenario.state"
   cp cdc-source.trace "cdc-source-$half-$sparse-$scenario.trace"
   cp cdc-ddr.trace "cdc-ddr-$half-$sparse-$scenario.trace"
   for gap in 0 7;do "$vv" ./test +restore +scenario="$scenario" +gap="$gap";done
  done
 done
done
echo 'PASS:176 fresh-process CDC/frontend restores, both clock ratios and sparse/full phase modes'
python3 - "$repo/rtl/nds_h3d_frame_record_cdc.sv" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-frame':('logical_frame <= checkpoint_write_data;',"logical_frame <= 32'd1;"),
 'lost-power':('geometry_enabled <= checkpoint_write_data[0];',"geometry_enabled <= 1'b1;"),
 'lost-reset-guard':('EXPERIMENTAL_CHECKPOINT && checkpoint_loaded &&',"1'b0 && checkpoint_loaded &&"),
 'lost-delivery-owner':('checkpoint_delivery_lost <= 1;',"checkpoint_delivery_lost <= 0;"),
 'early-tail':('gx_pack_count == 0 && !checkpoint_ddr_ack','!checkpoint_ddr_ack'),
 'stale-ack':('gx_pack_count == 0 && !checkpoint_ddr_ack','gx_pack_count == 0'),
 'early-cancel':('CP_WAIT_HIGH: if (checkpoint_ack_sync)', 'CP_WAIT_HIGH: if (checkpoint_ack_sync || !checkpoint_request)'),
 'early-ack-low':('CD_DRAIN: if (!checkpoint_ddr_ack) checkpoint_ddr_phase <= CD_IDLE;', 'CD_DRAIN: checkpoint_ddr_phase <= CD_IDLE;'),
 'lost-owner-poison':('if (checkpoint_request) checkpoint_phase <= CP_WAIT_REQUEST_LOW;', 'if (checkpoint_request) checkpoint_phase <= CP_IDLE;'),
 'partial-ready':('checkpoint_restore_count == 265 && checkpoint_front_restore_ready','checkpoint_restore_count > 0'),
 'no-tail-flush':('''end else if (async_read_valid) begin
                // Preserve order by draining the tail''','''end else if (async_read_valid && !async_head_checkpoint) begin
                // Preserve order by draining the tail'''),
 'marker-leak':('''                    async_read_ready = checkpoint_ddr_phase == CD_REQUEST &&''','''                    record_valid = 1'b1;
                    record = 0;
                    async_read_ready = checkpoint_ddr_phase == CD_REQUEST &&'''),
}
for n,(a,b) in mutations.items():
 assert s.count(a)==1,(n,s.count(a));Path(n+'.sv').write_text(s.replace(a,b))
PY
for mutation in lost-frame lost-power lost-reset-guard early-tail stale-ack early-cancel early-ack-low lost-owner-poison partial-ready no-tail-flush marker-leak lost-delivery-owner;do
 scenario=0;mode=(+capture);args=(+image-check)
 case "$mutation" in
  lost-frame|lost-reset-guard) mode=(+restore);args=(+no-image-check);;
  lost-power) scenario=5;mode=(+restore);args=(+no-image-check);;
  early-tail) scenario=9;;
  stale-ack) scenario=10;;
  early-cancel) scenario=11;;
  early-ack-low) scenario=17;;
  lost-owner-poison) scenario=14;;
  lost-delivery-owner) scenario=21;;
  partial-ready) mode=(+restore);;
 esac
 cp "cdc-7-1-$scenario.state" cdc.state
 cp "cdc-source-7-1-$scenario.trace" cdc-source.trace
 cp "cdc-ddr-7-1-$scenario.trace" cdc-ddr.trace
 compile "$mutation.sv" 7 1
 if "$vv" ./test "${mode[@]}" +scenario="$scenario" "${args[@]}" > "$mutation.log" 2>&1;then
  echo "FAIL:CDC mutation survived:$mutation";exit 1
 fi
 case "$mutation" in
  lost-frame|lost-power|lost-reset-guard) pattern='CDC (source|DDR) continuation mismatch';;
  early-tail) pattern='CDC tail falsely drained under backpressure';;
  stale-ack) pattern='CDC stale ACK qualified new capture';;
  early-cancel) pattern='CDC cancelled before marker receipt';;
  early-ack-low) pattern='CDC owner released before external ACK low';;
  lost-owner-poison) pattern='CDC owner loss reused same request';;
  lost-delivery-owner) pattern='CDC lost downstream owner qualified old capture';;
  partial-ready) pattern='CDC partial image qualified';;
  no-tail-flush) pattern='CDC acquire exceeded bound';;
  marker-leak) pattern='CDC checkpoint marker leaked to renderer ABI';;
 esac
 grep -Eq "$pattern" "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS:CDC fault detected:$mutation"
done
