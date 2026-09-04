#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d /tmp/nds-audio-headroom.XXXXXX)
trap 'rm -rf -- "$temp_dir"' EXIT

if command -v iverilog >/dev/null 2>&1; then
    iverilog -g2012 \
        -s tb_nds_audio_headroom \
        -o "$temp_dir/tb.vvp" \
        "$repo_dir/rtl/nds_audio_headroom.sv" \
        "$repo_dir/rtl/tb_nds_audio_headroom.sv"
    vvp "$temp_dir/tb.vvp"
elif command -v verilator >/dev/null 2>&1; then
    verilator --binary --timing \
        --top-module tb_nds_audio_headroom \
        --Mdir "$temp_dir/obj" \
        "$repo_dir/rtl/nds_audio_headroom.sv" \
        "$repo_dir/rtl/tb_nds_audio_headroom.sv"
    "$temp_dir/obj/Vtb_nds_audio_headroom"
else
    echo "SKIP: install iverilog or verilator to run the NDS audio-headroom test" >&2
    exit 77
fi
