#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify active color and color burst through the real MiSTer YC encoder."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
qsf = (root / 'fpga/mister_nitro_console_island/NDS4MiSTer.qsf').read_text()
assert '"MISTER_DISABLE_YC=1"' not in qsf, 'Composite encoder is disabled'
pll = (root / 'fpga/mister_nitro_console_island/rtl/pll/pll_0002.v').read_text()
assert '.output_clock_frequency0("60.000000 MHz")' in pll, 'Review test clock'
image = os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')
with tempfile.TemporaryDirectory(prefix='nds-yc-') as temp:
    docker = ['docker', 'run', '--rm', '--network', 'none',
              '-v', str(root) + ':/work:ro', '-v', temp + ':/out', '-w', '/out', image]
    subprocess.run(docker + ['verilator', '--cc', '--exe', '--build', '-Wno-fatal',
                            '--top-module', 'yc_out', '--Mdir', '/out/obj_dir',
                            '/work/fpga/mister_nitro_console_island/sys/yc_out.sv',
                            '/work/tools/test_yc_color.cpp'], check=True)
    subprocess.run(docker + ['/out/obj_dir/Vyc_out'], check=True)
