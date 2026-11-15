#!/usr/bin/env python3
"""Check real legacy/fabric traffic, local progress, and failing controls."""
from pathlib import Path
import argparse
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'rtl/nds_h3d_ddr_fabric.sv').read_text()
    expression = 'legacy_port_busy &&\n                         (legacy_read || legacy_write || !epoch_quiescent)'
    assert expression in source
    results = []
    for name, fabric, events, expected in [
        ('normal', source, 0, None),
        ('events', source, 1, None),
        ('blocked-idle', source.replace(expression, 'legacy_port_busy'), 0,
         'empty legacy port blocked local cache work'),
        ('lost-backpressure', source.replace(expression, '!epoch_quiescent'), 1,
         'SCANOUT_DEADLINE_MISSED')]:
        path = output / (name + '.sv')
        path.write_text(fabric)
        binary = output / (name + '.vvp')
        with (output / (name + '.compile.log')).open('w') as log:
            subprocess.run(['iverilog', '-g2012', '-s', 'tb_nds_cart_local_progress',
                            '-Ptb_nds_cart_local_progress.EVENTS=' + str(events),
                            '-o', str(binary), str(ROOT / 'rtl/tb_nds_cart_local_progress.sv'),
                            str(path), str(ROOT / 'rtl/nds_ddram_arbiter_4client.sv'),
                            str(ROOT / 'third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv')],
                           stdout=log, stderr=log, check=True)
        result = subprocess.run(['vvp', str(binary)], capture_output=True, text=True, timeout=40)
        text = result.stdout + result.stderr
        (output / (name + '.log')).write_text(text)
        if expected:
            assert result.returncode != 0 and expected in text, text
        else:
            assert result.returncode == 0 and 'PASS scanout deadlines' in text, text
        results.append(dict(name=name, events=events, exit_code=result.returncode,
                            expected_failure=bool(expected), log=name + '.log'))
        print(name, 'fault detected' if expected else 'passed', flush=True)
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    run(args.output.resolve())
