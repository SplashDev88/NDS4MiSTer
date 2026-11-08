#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/../.."
docker run --rm -v "$PWD:/work" -w /work --entrypoint bash nds4mister-rtl-verilator:24.04 -c '
set -eu
verilator --cc --exe --build -j 3 -Wno-fatal --top-module nds_fpga3d_mix_test --Mdir build-fpga3d/mix-sim -CFLAGS "-O2 -std=c++17" rtl/nds_fpga3d_pixels.sv tools/fpga3d/mix_tb.sv /work/tools/fpga3d/mix_test.cpp > build-fpga3d/mix-build.log 2>&1
build-fpga3d/mix-sim/Vnds_fpga3d_mix_test
'
