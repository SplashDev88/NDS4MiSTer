#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real dual-output scanout/DDR-cache regression, with both publication modes."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def run(output):
    root = Path(__file__).resolve().parents[1]
    output.mkdir(parents=True, exist_ok=True)
    docker = ['docker', 'run', '--rm', '--network', 'none',
              '-v', str(root) + ':/work:ro', '-v', str(output) + ':/out',
              '-w', '/out', os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')]
    for matched in (0, 1):
        stem = 'split-matched-' + str(matched)
        with (output / (stem + '.compile.log')).open('w') as log:
            result = subprocess.run(docker + [
                'verilator', '--binary', '--timing', '-Wno-fatal',
                '--top-module', 'tb_nds_split_video', '-GMATCHED=' + str(matched),
                '--Mdir', '/out/' + stem,
                '/work/rtl/nds_nitro_video_scanout.sv',
                '/work/rtl/nds_nitro_fb_ddr3.sv', '/work/rtl/tb_nds_split_video.sv'],
                stdout=log, stderr=log)
        if result.returncode:
            print((output / (stem + '.compile.log')).read_text())
            result.check_returncode()
        result = subprocess.run(docker + ['/out/' + stem + '/Vtb_nds_split_video'],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (output / (stem + '.test.log')).write_text(result.stdout)
        print(result.stdout, flush=True)
        result.check_returncode()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Keep binaries and logs here')
    args = parser.parse_args()
    if args.output:
        run(args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='nds-split-video-') as directory:
            run(Path(directory))
