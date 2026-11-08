#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build-fpga3d
# Existing local toolchain; the test has no network dependency.
docker run --rm -v "$PWD:/work" -w /work --entrypoint bash nds4mister-rtl-verilator:24.04 -c \
 'verilator --cc --exe --build -j 4 -Wno-fatal --top-module nds_fpga3d -GPOLL_CYCLES=8 --Mdir build-fpga3d/sim -CFLAGS "-O2 -std=c++17 -I/work/tools/fpga3d" rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv /work/tools/fpga3d/sim.cpp > build-fpga3d/compile.log 2>&1 && build-fpga3d/sim/Vnds_fpga3d'
