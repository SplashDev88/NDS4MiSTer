#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the actual product cartridge bridge and DDR cache at ROM boundaries.

--source permits running the low-ROM benchmark against a retained baseline;
--low-only omits addresses outside the old 128 MiB port.
"""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--source', type=Path)
p.add_argument('--low-only', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
# Analysis alone accepts unconstrained port associations; explicitly cover
# the mixed-language wrapper that the isolated bridge simulation bypasses.
if not a.source:
    for relative, expected_ports in (
        ('third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd', 1),
        ('third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd', 1),
        ('rtl/nds_nitro_console_top.vhd', 3),
        ('rtl/nds_nitro_console_wrap.vhd', 1),
    ):
        ports = re.findall(
            r"(?:card_addr|cardm_addr|ld_card_addr)\s*:\s*(?:out\s+)?"
            r"std_logic_vector\((\d+)\s+downto\s+(\d+)\)",
            (root / relative).read_text())
        assert len(ports) == expected_ports, (relative, ports)
        assert all(int(high) - int(low) + 1 == 27 for high, low in ports), (relative, ports)
source = (a.source or root / 'rtl/nds_nitro_console_island.sv').read_text()
start = source.index('wire card_ena;')
end = source.index('// Direct HLE boot still probes SPI firmware.', start)
bridge = source[start:end]
# Retain the actual product word-to-halfword wiring, including its high bit.
ddr_address_expr = re.search(r"\.ch2_addr\(([^)]*cd_addr[^)]*)\)", source).group(1)
bank_port = re.search(r"\.ch2_altbank\(([^)]*)\)", source)
ddr_bank_expr = bank_port.group(1) if bank_port else "1'b0"
if not a.source:
    assert ddr_bank_expr == 'cd_altbank', ddr_bank_expr
bridge = bridge.replace("logic h3d_fabric_boot_reset = 1'b1;\n", '')
width = int(re.search(r'wire \[(\d+):0\] card_addr;', bridge).group(1)) + 1
replacements = [
    ('wire card_ena;', 'wire card_ena = source_request;'),
    (f'wire [{width - 1}:0] card_addr;',
     f'wire [{width - 1}:0] card_addr = source_address[{width - 1}:0];'),
    ('wire cd_ready;', 'wire cd_ready = response_ready;'),
    ('wire [31:0] cd_dout;', 'wire [31:0] cd_dout = response_data;'),
]
for old, new in replacements:
    assert old in bridge
    bridge = bridge.replace(old, new)
wrapper = '''module cart_bridge_under_test(
 input clk1x,ddr_clk,console_reset_1x,console_reset_ddr,
 input bridge_reset_ddr,h3d_fabric_boot_reset,
 input [1:0] cart_state,
 input cart_download_ddr,cart_download_d,cart_download_raw,
 input [15:0] ioctl_index,
 input source_request,input [26:0] source_address,
 input response_ready,input [31:0] response_data,
 output request,output [25:0] address,output [27:1] ddr_address,output altbank,
 output done,output [31:0] data,output logic flush_complete
);
localparam [1:0] CART_EMPTY=0,CART_DOWNLOAD=1,CART_FLUSH=2,CART_READY=3;
''' + bridge + '''
assign request=cd_req;assign address=cd_addr;assign done=card_done;assign data=card_din;
assign altbank=''' + ddr_bank_expr + ''';
assign ddr_address=''' + ddr_address_expr + ''';
endmodule
'''
with tempfile.TemporaryDirectory(prefix='nds-cart-large-rom-') as tmp:
    t = Path(tmp)
    (t / 'bridge.sv').write_text(wrapper)
    command = ['iverilog', '-g2012', '-DNDS_HYBRID_3D', '-s', 'tb_nds_cart_large_rom']
    if a.low_only:
        command += ['-DLOW_ONLY']
    command += ['-o', str(t / 'test.vvp'), str(t / 'bridge.sv'),
                str(root / 'third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv'),
                str(root / 'rtl/tb_nds_cart_large_rom.sv')]
    subprocess.run(command, check=True)
    subprocess.run(['vvp', str(t / 'test.vvp')], check=True)
