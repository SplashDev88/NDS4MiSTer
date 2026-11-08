#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
docker run --rm -v "$PWD:/work" -w /work --entrypoint bash nds4mister-rtl-verilator:24.04 -c '
set -eu
verilator --cc --exe --build -j 4 -Wno-fatal -Werror-UNOPTFLAT --top-module nds_fpga3d_shared -GREAL_CONTROL=1 -GPOLL_CYCLES=8 --Mdir build-fpga3d/real-control -CFLAGS "-DREAL_CONTROL -DSHARED_FABRIC -O2 -std=c++17 -I/work/tools/fpga3d" rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv rtl/nds_fpga3d_port_mux.sv rtl/nds_ddram_arbiter_4client.sv rtl/nds_h3d_control_init.sv tools/fpga3d/shared_tb.sv /work/tools/fpga3d/sim.cpp > build-fpga3d/real-control-build.log 2>&1
build-fpga3d/real-control/Vnds_fpga3d_shared > build-fpga3d/real-control-test.log
build-fpga3d/real-control/Vnds_fpga3d_shared build-fpga3d/fixtures 221 > build-fpga3d/real-control-production-test.log
echo "PASS actual packet-mode control initializer with shared accelerator traffic"
'
