#!/usr/bin/env python3
"""Prove the fixed upright analog OSD matches the generic pixel pipeline."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'fpga/mister_nitro_console_island/sys/osd.v').read_text()
before = 'always @(posedge clk_video) begin\n\treg        deD;'
assert source.count(before) == 1
source = source.replace(before, 'always @(posedge clk_video) begin : scan\n\treg        deD;')
with tempfile.TemporaryDirectory(prefix='nds-fixed-osd-') as directory:
    work = Path(directory)
    rtl = work / 'osd.v'
    binary = work / 'test.vvp'
    rtl.write_text(source)
    subprocess.run([os.environ.get('IVERILOG', 'iverilog'), '-g2012',
                    '-s', 'tb_nds_fixed_analog_osd', '-o', str(binary),
                    str(rtl), str(root / 'rtl/tb_nds_fixed_analog_osd.sv')], check=True)
    subprocess.run([os.environ.get('VVP', 'vvp'), str(binary)], check=True)
