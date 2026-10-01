#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --network none -v "$repo_dir:/workspace:ro" \
    nds4mister-vhdl-sim:24.04 sh -lc '
    set -eu; mkdir /tmp/query-watch; cd /tmp/query-watch
    ghdl -a --std=08 /workspace/rtl/nds_h3d_query_watch.vhd /workspace/rtl/tb_nds_h3d_query_watch.vhd
    ghdl -e --std=08 tb_nds_h3d_query_watch
    ghdl -r --std=08 tb_nds_h3d_query_watch --assert-level=error
    '
docker run --rm --network none -v "$repo_dir:/workspace:ro" \
    nds4mister-rtl-sim:24.04 sh -lc '
    set -eu
    for c in 0 1 2; do
        iverilog -g2012 -Wall -s tb_nds_h3d_probe_cdc \
            -Ptb_nds_h3d_probe_cdc.CLOCK_CASE=$c -o /tmp/probe.vvp \
            /workspace/rtl/nds_h3d_probe_cdc.sv /workspace/rtl/tb_nds_h3d_probe_cdc.sv
        vvp /tmp/probe.vvp
    done
    '
