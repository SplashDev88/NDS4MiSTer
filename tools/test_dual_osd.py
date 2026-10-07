#!/usr/bin/env python3
"""Replay real host transactions into both OSDs using sys_top's actual selects."""
from pathlib import Path
import argparse
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host-trace', required=True, type=Path)
args = parser.parse_args()
source = (root / 'fpga/mister_nitro_console_island/sys/osd.v').read_text()
for before, after in [
    ('always@(posedge clk_sys) begin\n', 'always@(posedge clk_sys) begin : control\n'),
    ('always @(posedge clk_video) begin\n\treg        deD;',
     'always @(posedge clk_video) begin : scan\n\treg        deD;'),
]:
    assert source.count(before) == 1, 'Review OSD test adapter'
    source = source.replace(before, after)
top = (root / 'fpga/mister_nitro_console_island/sys/sys_top.v').read_text()
decode = []
for name in ('io_ss0', 'io_ss1', 'io_ss2', 'io_osd_hdmi', 'io_osd_vga', 'io_fpga', 'io_uio'):
    expressions = re.findall(r'wire\s+' + name + r'\s*=\s*([^;]+);', top)
    assert len(expressions) == 1, name
    decode.append('wire ' + name + ' = ' + expressions[0] + ';')
bench = (root / 'rtl/tb_dual_osd.sv').read_text().replace('// CORE_SELECT_DECODE', '\n'.join(decode))
with tempfile.TemporaryDirectory(prefix='nds-dual-osd-') as temp:
    temp = Path(temp)
    (temp / 'osd.v').write_text(source)
    (temp / 'tb.sv').write_text(bench)
    binary = temp / 'test.vvp'
    subprocess.run([os.environ.get('IVERILOG', 'iverilog'), '-g2012', '-s', 'tb_dual_osd',
                    '-o', str(binary), str(temp / 'osd.v'), str(temp / 'tb.sv')], check=True)
    subprocess.run([os.environ.get('VVP', 'vvp'), str(binary),
                    '+HOST_TRACE=' + str(args.host_trace.resolve())], check=True)
