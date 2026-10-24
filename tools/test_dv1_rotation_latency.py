#!/usr/bin/env python3
"""Measure simulated pixel age and verify tear-free DV1 phase acquisition.

This is not a controller-to-display latency benchmark. Both consumers, the
transpose writer, randomized DDR stalls and all native timing classes run.
The baseline parameter retains the previous reader's phase and counter wrap.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(output, quick=False):
    output.mkdir(parents=True, exist_ok=True)
    sources = output / 'sources'
    sources.mkdir()
    names = ['nds_tate_video.sv', 'nds_dv1_rotate_read.sv',
             'tb_nds_dv1_rotation_latency.sv']
    hashes = {}
    for name in names:
        data = (ROOT / 'rtl' / name).read_bytes()
        (sources / name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    (output / 'inputs.json').write_text(json.dumps(hashes, indent=2)+'\n')
    docker = ['docker', 'run', '--rm', '--network', 'none',
              '-v', str(ROOT) + ':/work:ro', '-v', str(output) + ':/out',
              '-w', '/out', os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')]
    top = 'tb_nds_dv1_rotation_latency'
    variants = (1,) if quick else (0, 1)
    for align in variants:
        with (output / f'compile-{align}.log').open('w') as log:
            subprocess.run(docker + ['verilator', '--binary', '--timing', '--assert',
                '-Wno-fatal', '--top-module', top, '-j', '2',
                '--Mdir', f'/out/align-{align}', f'-GALIGN_CAPTURE_PHASE={align}',
                *['/out/sources/' + name for name in names]],
                stdout=log, stderr=log, check=True)
    if quick:
        cases = [(1, 256, 392, 251520, 0), (1, 536, 192, 503040, 10000),
                 (1, 320, 240, 754560, 10000)]
    else:
        cases = [(a, 256, 392, p, 0) for a in variants
                 for p in (0, 125760, 251520, 377280, 503040, 628800, 754560, 880320)]
        cases += [(1, w, h, p, jitter) for w, h in ((536, 192), (320, 240))
                  for p, jitter in ((0, 0), (251520, 0), (503040, 10000), (754560, 10000))]
        cases += [(1, 256, h, 503040, 10000) for h in (384, 408, 414)]

    def measure(case):
        align, width, height, phase, jitter = case
        label = f'align{align}-{width}x{height}-phase{phase}-jitter{jitter}'
        result = subprocess.run(docker + [f'/out/align-{align}/V{top}',
            f'+SOURCE_WIDTH={width}', f'+SOURCE_HEIGHT={height}',
            f'+SOURCE_DELAY_CLOCKS={phase}', f'+WRITE_JITTER={jitter}'],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / (label + '.log')).write_text(result.stdout)
        result.check_returncode()
        values = re.search(r'ROTATION_PIXEL_AGE_NS min=([\d.]+) mean=([\d.]+) max=([\d.]+) samples=(\d+)', result.stdout)
        assert values, result.stdout
        row = dict(align=align, width=width, height=height, phase_clocks=phase,
                   write_jitter_max_clocks=jitter, samples=int(values[4]),
                   minimum_ms=float(values[1])/1e6, mean_ms=float(values[2])/1e6,
                   maximum_ms=float(values[3])/1e6, log=label+'.log')
        print(json.dumps(row), flush=True)
        return row

    # Separate simulations are independent; limit load while Quartus is running.
    with ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(measure, cases))
    report = dict(scope='Source-pixel capture to rotated-pixel emission in RTL simulation; excludes game, ARM renderer, scaler and display.',
                  frames_per_run=48, results=rows)
    (output / 'results.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--quick', action='store_true')
    args = parser.parse_args()
    run(args.output.resolve(), args.quick)
