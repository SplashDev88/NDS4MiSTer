#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-h3p1.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
# Bind the simulated latch to the actual menu/reset boundary; toggling bit 10
# must not become another term in core_reset or reinterpret an existing bit.
grep -Fq '"O[10],Engine B (next Reset),Off,On;"' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '.engine_b_select(status[10])' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq 'wire core_reset=media_reset|status[0]|buttons[1];' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '"O[9:8],Screen Gap,8 Pixels,None,16 Pixels,24 Pixels;"' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq ".PACKET_MODE(1'b1), .SESSION_POLICY_ENABLE(1'b1)" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
run_tests() {
    for zero_latency in 0 1; do
        iverilog -g2012 -Wall -s tb_nds_h3d_session_policy \
            -Ptb_nds_h3d_session_policy.ZERO_LATENCY="$zero_latency" \
            -o "$2/policy.vvp" "$1/rtl/nds_h3d_control_init.sv" \
            "$1/rtl/nds_h3d_session_policy_latch.sv" \
            "$1/rtl/tb_nds_h3d_session_policy.sv"
        vvp "$2/policy.vvp"
    done
    for packet in 0 1; do
        iverilog -g2012 -Wall -s tb_nds_h3d_control_init \
            -Ptb_nds_h3d_control_init.PACKET_MODE="$packet" \
            -o "$2/control.vvp" "$1/rtl/nds_h3d_control_init.sv" \
            "$1/rtl/tb_nds_h3d_control_init.sv"
        vvp "$2/control.vvp"
    done
}
if command -v iverilog >/dev/null 2>&1; then
    run_tests "$repo_dir" "$test_tmp"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" -w /test "${IMAGE:-nds4mister-rtl-sim:24.04}" \
        bash -lc "set -e; $(declare -f run_tests); run_tests /workspace /test"
fi
