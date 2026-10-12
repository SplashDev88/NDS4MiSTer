#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise fixed CRT timing and the unchanged standard scanout in Verilator."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
image = os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')
with tempfile.TemporaryDirectory(prefix='nds-crt-video-') as directory:
    work = Path(directory)
    docker = ['docker', 'run', '--rm', '--network', 'none',
              '-v', str(root) + ':/work:ro', '-v', str(work) + ':/out',
              '-w', '/out', image]
    for top in ['tb_nds_crt_video', 'tb_nds_nitro_video_scanout',
                'tb_nds_video_session_clear']:
        rtl = '/work/rtl/nds_nitro_video_scanout.sv'
        with (work / (top + '.compile.log')).open('w') as log:
            result = subprocess.run(docker + [
                'verilator', '--binary', '--timing', '-Wno-fatal',
                '--top-module', top, '--Mdir', '/out/' + top,
                rtl, '/work/rtl/' + top + '.sv'], stdout=log, stderr=log)
        if result.returncode:
            print((work / (top + '.compile.log')).read_text())
            result.check_returncode()
        subprocess.run(docker + ['/out/' + top + '/V' + top], check=True)

# The framework's block-local initialized registers need Icarus semantics.
subprocess.run([sys.executable, str(root / 'tools/test_nds_native_osd.py')], check=True)
