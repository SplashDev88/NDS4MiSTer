#!/usr/bin/env python3
"""Exercise the actual OSD SPI decoder and RAM/pixel path against geometric rotation."""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rtl', type=Path, default=root / 'fpga/mister_nitro_console_island/sys/osd.v')
args = parser.parse_args()
source = args.rtl.read_text()
# Name two anonymous blocks in a temporary copy solely for deterministic
# testbench references. No behavioral statement is changed by this adapter.
for before, after in [
    ('always@(posedge clk_sys) begin\n', 'always@(posedge clk_sys) begin : control\n'),
    ('always @(posedge clk_video) begin\n\treg        deD;',
     'always @(posedge clk_video) begin : scan\n\treg        deD;'),
]:
    if source.count(before) != 1:
        raise SystemExit('OSD block changed: review the test adapter before running.')
    source = source.replace(before, after)

with tempfile.TemporaryDirectory(prefix='nds-osd-rotation-') as directory:
    work = Path(directory)
    rtl = work / 'osd.v'
    binary = work / 'test.vvp'
    rtl.write_text(source)
    subprocess.run([os.environ.get('IVERILOG', 'iverilog'), '-g2012',
                    '-s', 'tb_osd_loading_rotation', '-o', str(binary),
                    str(rtl), str(root / 'rtl/tb_osd_loading_rotation.sv')], check=True)
    subprocess.run([os.environ.get('VVP', 'vvp'), str(binary)], check=True)
