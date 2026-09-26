#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-matched.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
iverilog -g2012 -i -DNDS_HYBRID_3D -DNDS_MATCHED_DISPLAY_TEST \
    -s tb_nds_engine_b_optional_island -o "$test_tmp/optional-island" \
    "$repo_dir/rtl/nds_nitro_console_island.sv" \
    "$repo_dir/rtl/tb_nds_engine_b_optional_island.sv"
vvp "$test_tmp/optional-island"
iverilog -g2012 -s tb_nds_matched_display_quiesce -o "$test_tmp/quiesce" \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
    "$repo_dir/rtl/tb_nds_matched_display_quiesce.sv"
vvp "$test_tmp/quiesce"
for latency in 0 1; do
  for optional_b in 0 1; do
    iverilog -g2012 -s tb_nds_h3d_session_policy \
        -Ptb_nds_h3d_session_policy.ZERO_LATENCY="$latency" \
        -Ptb_nds_h3d_session_policy.MATCHED_DISPLAY_TEST=1 \
        -Ptb_nds_h3d_session_policy.MATCHED_ENGINE_B_OPTIONAL="$optional_b" \
        -o "$test_tmp/policy" "$repo_dir/rtl/nds_h3d_control_init.sv" \
        "$repo_dir/rtl/nds_h3d_session_policy_latch.sv" \
        "$repo_dir/rtl/tb_nds_h3d_session_policy.sv"
    vvp "$test_tmp/policy"
  done
done
iverilog -g2012 -s tb_nds_h3d_frame_record_cdc -o "$test_tmp/cdc" \
    "$repo_dir/rtl/nds_h3d_event_async_fifo.sv" \
    "$repo_dir/rtl/nds_gx_fifo_packet_frontend.sv" \
    "$repo_dir/rtl/nds_h3d_frame_record_cdc.sv" \
    "$repo_dir/rtl/tb_nds_h3d_frame_record_cdc.sv"
vvp "$test_tmp/cdc"
# Build the service from this source first; the focused test opens no hardware.
"${H3D_MATCHED_HELPER:-$repo_dir/build-host/nds_hybrid_3d_service}" \
    --self-test-matched-display
"${H3D_MATCHED_HELPER:-$repo_dir/build-host/nds_hybrid_3d_service}" \
    --self-test-matched-catchup
"${H3D_MATCHED_HELPER:-$repo_dir/build-host/nds_hybrid_3d_service}" \
    --self-test-matched-full-rate
"${CXX:-c++}" -std=c++17 -O2 -I"$repo_dir/src" \
    "$repo_dir/tools/test_matched_display_admission.cpp" -o "$test_tmp/admission"
"$test_tmp/admission"
