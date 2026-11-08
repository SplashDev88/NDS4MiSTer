#!/usr/bin/env python3
"""Verify display deadlines through both real DDR arbiters under contention."""
from pathlib import Path
import argparse
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    docker = ['docker', 'run', '--rm', '--network', 'none',
              '-v', str(ROOT) + ':/work:ro', '-v', str(output) + ':/out',
              '-w', '/out', os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')]
    top = 'tb_nds_scanout_contention'
    sources = ['rtl/' + top + '.sv', 'rtl/nds_h3d_ddr_fabric.sv',
               'rtl/nds_ddram_arbiter_4client.sv',
               'third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv']
    reports = []
    for inner, outer, events in [(1, 1, 0), (0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 1)]:
        name = f'inner{inner}-outer{outer}-events{events}'
        with (output / (name + '.compile.log')).open('w') as log:
            subprocess.run(docker + ['verilator', '--binary', '--timing', '--assert',
                '-Wno-fatal', '--top-module', top, '-j', '2', '--Mdir', '/out/' + name,
                '-GPRIORITY=' + str(inner), '-GOUTER_PRIORITY=' + str(outer),
                '-GEVENTS=' + str(events),
                *['/work/' + s for s in sources]], stdout=log, stderr=log, check=True)
        test = subprocess.run(docker + ['sh', '-c', f'ulimit -c 0; /out/{name}/V{top}'],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / (name + '.test.log')).write_text(test.stdout)
        if inner and outer:
            assert test.returncode == 0 and 'PASS scanout deadlines:' in test.stdout, test.stdout
        else:
            assert test.returncode != 0 and 'SCANOUT_DEADLINE_MISSED' in test.stdout, test.stdout
        reports.append(dict(inner=inner, outer=outer, events=events, exit_code=test.returncode,
                            expected_failure=not (inner and outer), log=name + '.test.log'))
        print(name, 'PASS' if inner and outer else 'deadline regression reproduced', flush=True)
    (output / 'results.json').write_text(json.dumps(reports, indent=2) + '\n')
    # The complete pixel path must recover as well, not merely its bus client.
    # Exercise all 16 layout/order/analog selections under the same pressure.
    top = 'tb_nds_scanout_integrated'
    sources[0] = 'rtl/' + top + '.sv'
    sources += ['rtl/nds_nitro_video_scanout.sv', 'rtl/nds_nitro_fb_ddr3.sv']
    for priority in (1, 0):
        name = 'integrated-' + str(priority)
        with (output / (name + '.compile.log')).open('w') as log:
            subprocess.run(docker + ['verilator', '--binary', '--timing', '--assert',
                '-Wno-fatal', '--top-module', top, '-j', '2', '--Mdir', '/out/' + name,
                '-GPRIORITY=' + str(priority), '-GOUTER_PRIORITY=' + str(priority),
                *['/work/' + s for s in sources]], stdout=log, stderr=log, check=True)
        test = subprocess.run(docker + ['sh', '-c', f'ulimit -c 0; /out/{name}/V{top}'],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / (name + '.test.log')).write_text(test.stdout)
        if priority:
            assert test.returncode == 0 and 'PASS integrated scanout' in test.stdout, test.stdout
        else:
            assert test.returncode != 0 and 'pixel c=' in test.stdout, test.stdout
        reports.append(dict(integrated=True, priority=priority, exit_code=test.returncode,
                            expected_failure=not priority, log=name + '.test.log'))
        print(name, 'PASS' if priority else 'pixel corruption reproduced', flush=True)
    (output / 'results.json').write_text(json.dumps(reports, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    run(args.output.resolve())
