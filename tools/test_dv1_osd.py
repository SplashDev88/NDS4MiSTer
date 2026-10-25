#!/usr/bin/env python3
"""Check native DV1 pixels and compare other paths with the pre-fix OSD."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(output, compact=False):
    output.mkdir(parents=True, exist_ok=True)
    # This is the released implementation, not a reference generated from
    # the candidate. Keep the assertion independent of the new raster logic.
    reference = subprocess.check_output([
        'git', 'show', '25dfd0f35f84f0dd954d959b3cfc3734e21b306c:'
        'fpga/mister_nitro_console_island/sys/osd.v'], cwd=ROOT, text=True)
    reference = reference.replace('module osd\n', 'module osd_reference\n', 1)
    (output / 'osd_reference.v').write_text(reference)
    docker = ['docker', 'run', '--rm', '--network', 'none',
              '-v', str(ROOT)+':/work:ro', '-v', str(output)+':/out', '-w', '/out',
              os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')]
    with (output / 'compile.log').open('w') as log:
        r = subprocess.run(docker + ['verilator', '--binary', '--timing', '--assert',
            '-Wno-fatal', '--top-module', 'tb_dv1_osd', '-GCOMPACT='+str(int(compact)), '-j', '2', '--Mdir', '/out/obj',
            '/work/fpga/mister_nitro_console_island/sys/osd.v', '/out/osd_reference.v',
            '/work/rtl/nds_dv1_osd_raster.sv', '/work/rtl/nds_native_osd_memory.sv',
            '/work/rtl/tb_dv1_osd.sv'], stdout=log, stderr=log)
    if r.returncode:
        print((output / 'compile.log').read_text())
        r.check_returncode()
    r = subprocess.run(docker + ['/out/obj/Vtb_dv1_osd'], text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / 'test.log').write_text(r.stdout)
    print(r.stdout, flush=True)
    r.check_returncode()


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path)
    p.add_argument('--compact', action='store_true')
    args = p.parse_args()
    if args.output:
        run(args.output.resolve(), args.compact)
    else:
        with tempfile.TemporaryDirectory(prefix='nds-dv1-osd-') as d:
            run(Path(d), args.compact)
