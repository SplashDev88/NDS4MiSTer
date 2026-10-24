#!/usr/bin/env python3
"""Exercise DV1 readback, metadata, arbitration and the complete rotation path."""
import argparse
import os
import re
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'fpga/mister_nitro_console_island/sys/hps_io.sv').read_text()
    calc = 'module video_calc' + source.split('module video_calc', 1)[1].split('endmodule', 1)[0] + 'endmodule\n'
    # Keep the production logic, but spell its static declaration initializers
    # as explicit initial blocks. This avoids Verilator treating legacy
    # block-local initializers as assignments on every clock edge.
    initializers = []
    for clock, scope in (('clk_vid', 'video_history'), ('clk_100', 'period_history')):
        start = calc.index('always @(posedge ' + clock + ') begin')
        end = calc.index('\nend\n', start) + len('\nend\n')
        block = calc[start:end].replace(') begin', ') begin : ' + scope, 1)
        for line in re.findall(r'^\s*reg[^;]*;', block, re.M):
            names = re.findall(r'\b(\w+)\s*=\s*0\b', line)
            if names:
                block = block.replace(line, re.sub(r'\s*=\s*0\b', '', line), 1)
                initializers += [scope + '.' + name + '=0;' for name in names]
        calc = calc[:start] + block + calc[end:]
    assert len(initializers) == 10
    calc = calc.replace('endmodule', 'initial begin\n' + '\n'.join(initializers) + '\nend\nendmodule')
    declarations = re.findall(r'^reg[^;]*;\n', calc, re.M)
    for declaration in declarations:
        calc = calc.replace(declaration, '', 1)
    calc = calc.replace(');', ');\n' + ''.join(declarations), 1)
    (output / 'video_calc.sv').write_text(calc)
    docker = ['docker', 'run', '--rm', '--network', 'none',
              '-v', str(ROOT) + ':/work:ro', '-v', str(output) + ':/out', '-w', '/out',
              os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')]
    cases = (
        ('read_arbiter', ['nds_dv1_rotate_read.sv'], []),
        ('rotate_read', ['nds_dv1_rotate_read.sv'], ['/out/video_calc.sv']),
        ('rotation_pipeline', ['nds_tate_video.sv', 'nds_dv1_rotate_read.sv'], []),
    )
    for name, sources, extra in cases:
        top = 'tb_nds_dv1_' + name
        with (output / (name + '-compile.log')).open('w') as log:
            result = subprocess.run(docker + ['verilator', '--binary', '--timing', '--assert',
                '-Wno-fatal', '--top-module', top, '-j', '2', '--Mdir', '/out/' + name] +
                ['/work/rtl/' + file for file in sources + [top + '.sv']] + extra,
                stdout=log, stderr=log)
        result.check_returncode()
        result = subprocess.run(docker + ['/out/' + name + '/V' + top], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / (name + '-test.log')).write_text(result.stdout)
        print(result.stdout, flush=True)
        result.check_returncode()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.output:
        run(args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='nds-dv1-rotation-') as directory:
            run(Path(directory))
