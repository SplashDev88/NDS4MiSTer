#!/usr/bin/env python3
"""Check session ownership and liveness with optional CPU diagnostics removed."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
rtl = root / 'rtl'
with tempfile.TemporaryDirectory(prefix='nds-minimal-telemetry-') as directory:
    work = Path(directory)

    def run(top, params, sources):
        output = work / (top + '.vvp')
        command = ['iverilog', '-g2012', '-s', top]
        command += ['-P' + top + '.' + k + '=' + str(v) for k, v in params.items()]
        command += ['-o', str(output), str(rtl / 'nds_h3d_control_init.sv')]
        command += [str(rtl / name) for name in sources + [top + '.sv']]
        compiled = subprocess.run(command, text=True, capture_output=True)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)
        print(top, params, flush=True)
        subprocess.run(['vvp', str(output)], check=True)

    for enabled in [0, 1]:
        for packet in [0, 1]:
            run('tb_nds_h3d_control_init',
                dict(DIAGNOSTIC_HOLD_ENABLE=enabled, PACKET_MODE=packet), [])
        for latency in [0, 1]:
            for matched in [0, 1]:
                run('tb_nds_h3d_session_policy',
                    dict(DIAGNOSTIC_HOLD_ENABLE=enabled, ZERO_LATENCY=latency,
                         MATCHED_DISPLAY_TEST=matched, MATCHED_ENGINE_B_OPTIONAL=matched),
                    ['nds_h3d_session_policy_latch.sv'])
