#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
docker run --rm --network none -v "$PWD:/work" -w /work --entrypoint bash nds4mister-rtl-verilator:24.04 -c '
set -e
verilator --cc --exe --build -j 4 -Wno-fatal -Werror-UNOPTFLAT --top-module nds_fpga3d -GPOLL_CYCLES=8 --Mdir build-fpga3d/edge-sim -CFLAGS "-O2 -std=c++17 -I/work/tools/fpga3d" rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv /work/tools/fpga3d/edge_test.cpp > build-fpga3d/edge-build.log 2>&1
build-fpga3d/edge-sim/Vnds_fpga3d
'
