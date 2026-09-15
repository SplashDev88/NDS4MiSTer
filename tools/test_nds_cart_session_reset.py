#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Simulate the actual in-island cartridge bridge across guest reset epochs."""
from pathlib import Path
import argparse, subprocess, tempfile
p=argparse.ArgumentParser();p.add_argument('--source',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
source=(a.source or root/'rtl/nds_nitro_console_island.sv').read_text()
start=source.index('wire card_ena;');end=source.index('// Direct HLE boot still probes SPI firmware.',start)
bridge=source[start:end]
# The isolated fixture drives the real product power-up reset externally.
bridge=bridge.replace("logic h3d_fabric_boot_reset = 1'b1;\n", "")
for old,new in [('wire card_ena;','wire card_ena = source_request;'),('wire [24:0] card_addr;','wire [24:0] card_addr = source_address;'),('wire cd_ready;','wire cd_ready = response_ready;'),('wire [31:0] cd_dout;','wire [31:0] cd_dout = response_data;')]:
    assert old in bridge;bridge=bridge.replace(old,new)
wrapper='''module cart_bridge_under_test(
 input clk1x,ddr_clk,console_reset_1x,console_reset_ddr,
 input bridge_reset_ddr,h3d_fabric_boot_reset,
 input [1:0] cart_state,
 input cart_download_ddr,cart_download_d,cart_download_raw,
 input source_request,input [24:0] source_address,
 input response_ready,input [31:0] response_data,
 output request,output [24:0] address,
 output done,output [31:0] data,output logic flush_complete
);
localparam [1:0] CART_EMPTY=0,CART_DOWNLOAD=1,CART_FLUSH=2,CART_READY=3;
'''+bridge+'''
assign request=cd_req;assign address=cd_addr;assign done=card_done;assign data=card_din;
endmodule
'''
with tempfile.TemporaryDirectory(prefix='nds-cart-session-') as tmp:
    t=Path(tmp);(t/'bridge.sv').write_text(wrapper)
    subprocess.run(['iverilog','-g2012','-DNDS_HYBRID_3D','-s','tb_nds_cart_session_reset','-o',str(t/'test.vvp'),str(t/'bridge.sv'),str(root/'rtl/tb_nds_cart_session_reset.sv')],check=True)
    subprocess.run(['vvp',str(t/'test.vvp')],check=True)
