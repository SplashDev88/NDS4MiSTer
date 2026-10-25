#!/usr/bin/env python3
"""Check dual-screen widening against a division-based legacy reference."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    # This is the released implementation, not a reference generated from
    # the candidate. Keep the assertion independent of the new raster logic.
    reference = subprocess.check_output([
        'git', 'show', '25dfd0f35f84f0dd954d959b3cfc3734e21b306c:'
        'fpga/mister_nitro_console_island/sys/osd.v'], cwd=ROOT, text=True)
    reference = reference.replace('module osd\n', 'module osd_reference\n', 1)
    # The original raster is retained. The independent width specification
    # uses integer division, rather than the candidate's shift/correction.
    reference=reference.replace('output reg    osd_status','input double_width, output reg    osd_status')
    needle="pixsz  <= (((cnt+1'b1) >> (9-rot[0])) > 1) ? (((cnt+1'b1) >> (9-rot[0])) - 1'd1) : 22'd0;"
    assert reference.count(needle)==1
    reference=reference.replace(needle, """begin : width_spec
            integer original_period, maximum_period, chosen_period;
            original_period=(cnt+1) / (rot[0] ? 256 : 512);
            if(original_period<1) original_period=1;
            chosen_period=original_period;
            maximum_period=(cnt+1)/264;
            if(double_width && !rot && cnt<4095 && maximum_period>original_period)
                chosen_period=(original_period*2<maximum_period)?original_period*2:maximum_period;
            pixsz <= chosen_period-1;
        end""")
    (output / 'osd_reference.v').write_text(reference)
    docker = ['docker', 'run', '--rm', '--network', 'none',
              '-v', str(ROOT)+':/work:ro', '-v', str(output)+':/out', '-w', '/out',
              os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')]
    with (output / 'compile.log').open('w') as log:
        r = subprocess.run(docker + ['verilator', '--binary', '--timing', '--assert',
            '-Wno-fatal', '--top-module', 'tb_dv1_legacy_width', '-j', '2', '--Mdir', '/out/obj',
            '/work/fpga/mister_nitro_console_island/sys/osd.v', '/out/osd_reference.v',
            '/work/rtl/nds_dv1_osd_raster.sv', '/work/rtl/nds_native_osd_memory.sv',
            '/work/rtl/tb_dv1_legacy_width.sv'], stdout=log, stderr=log)
    if r.returncode:
        print((output / 'compile.log').read_text())
        r.check_returncode()
    r = subprocess.run(docker + ['/out/obj/Vtb_dv1_legacy_width'], text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / 'test.log').write_text(r.stdout)
    print(r.stdout, flush=True)
    r.check_returncode()


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path)
    args = p.parse_args()
    if args.output:
        run(args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='nds-dv1-legacy-width-') as d:
            run(Path(d))
