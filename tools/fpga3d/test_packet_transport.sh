#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build-fpga3d
iverilog -g2012 -s tb_nds_h3d_frame_packet_writer -o build-fpga3d/packet-writer-test \
  rtl/nds_h3d_frame_packet_writer.sv rtl/tb_nds_h3d_frame_packet_writer.sv \
  > build-fpga3d/packet-writer-build.log 2>&1
vvp build-fpga3d/packet-writer-test > build-fpga3d/packet-writer-test.log
iverilog -g2012 -s tb_nds_h3d_ddr_fabric -o build-fpga3d/ddr-fabric-test \
  rtl/nds_ddram_arbiter_4client.sv rtl/nds_h3d_ddr_fabric.sv rtl/tb_nds_h3d_ddr_fabric.sv \
  > build-fpga3d/ddr-fabric-build.log 2>&1
vvp build-fpga3d/ddr-fabric-test > build-fpga3d/ddr-fabric-test.log
cat build-fpga3d/packet-writer-test.log build-fpga3d/ddr-fabric-test.log
