#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Isolated ARM7 mapping: equal guest buses, monitor ROM/RAM/transport included.

Freezes all sources before starting; does not fit, route or build a console.
Counts are not an estimate of savings in the full connected design.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--udev-shim', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output == repo or repo in output.parents:
        p.error('output must be a new directory outside source checkout')
    runtime, shim = args.runtime.resolve(), args.udev_shim.resolve()
    if not (runtime/'quartus/bin/quartus_map').is_file() or not shim.is_file():
        p.error('runtime or shim missing')
    (output/'source').mkdir(parents=True, exist_ok=False)
    files = ['third_party/Nitro_DarkSide/d2dabe/rtl/' + n for n in
             ['export.vhd', 'proc_bus_gba.vhd', 'reg_savestates.vhd', 'gba_cpu.vhd']]
    files += ['rtl/nds_arm7_monitor_rom.vhd', 'rtl/nds_arm7_monitor_probe.vhd',
              'tools/suspend_resume/arm7_monitor_area.vhd']
    manifest = {}
    for name in files + ['tools/suspend_resume/measure_arm7_monitor.py',
                         'tools/test_arm7_monitor.sh', 'rtl/tb_nds_arm7_monitor.vhd',
                         'tools/suspend_resume/arm7_monitor_rom.py',
                         'tools/suspend_resume/arm7_monitor_fixture.py']:
        shutil.copy2(repo/name, output/'source'/Path(name).name)
        manifest[name] = hashlib.sha256((repo/name).read_bytes()).hexdigest()
    (output/'SOURCE.json').write_text(json.dumps(manifest, indent=2)+'\n')
    results = {}
    for mode, variant in enumerate(['baseline', 'branch', 'branch-halt', 'monitor']):
        project = output/variant
        project.mkdir()
        settings = '''set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7
set_global_assignment -name TOP_LEVEL_ENTITY arm7_monitor_area
set_global_assignment -name VHDL_INPUT_VERSION VHDL_2008
set_global_assignment -name NUM_PARALLEL_PROCESSORS 1
set_global_assignment -name OPTIMIZATION_TECHNIQUE AREA
set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF
set_global_assignment -name SEED 7
set_instance_assignment -name VIRTUAL_PIN ON -to *
'''
        settings += ''.join('set_global_assignment -name VHDL_FILE ../source/'+Path(n).name+'\n' for n in files)
        settings += 'set_parameter -name MODE '+str(mode)+'\n'
        (project/'probe.qsf').write_text(settings)
        (project/'probe.qpf').write_text('PROJECT_REVISION = "probe"\n')
        with (project/'map.log').open('w') as log:
            subprocess.run(['docker', 'run', '--rm', '--network', 'none', '--platform', 'linux/amd64',
                            '-v', str(output)+':/probe', '-v', str(runtime)+':/quartus-runtime:ro',
                            '-v', str(shim)+':/usr/lib/x86_64-linux-gnu/libudev.so.1:ro',
                            '-e', 'LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libudev.so.1',
                            '-w', '/probe/'+variant, '--entrypoint',
                            '/quartus-runtime/quartus/bin/quartus_map',
                            'nds4mister-quartus-runtime:17.0.2', 'probe', '--write_settings_files=off'],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        summary = (project/'probe.map.summary').read_text()
        report = (project/'probe.map.rpt').read_text()
        if 'Analysis & Synthesis Status : Successful' not in summary:
            raise RuntimeError('mapping failed: '+variant)
        def count(label):
            return int(re.search(r'; '+re.escape(label)+r'\s*;\s*([\d,]+)', report)[1].replace(',', ''))
        results[variant] = {
            'estimated_alms': count('Estimate of Logic utilization (ALMs needed)'),
            'combinational_aluts': count('Combinational ALUT usage for logic'),
            'registers': int(re.search(r'Total registers : ([\d,]+)', summary)[1].replace(',', '')),
            'memory_bits': int(re.search(r'Total block memory bits : ([\d,]+)', summary)[1].replace(',', '')),
            'dsp_blocks': int(re.search(r'Total DSP Blocks : (\d+)', summary)[1]),
            'map_sha256': hashlib.sha256((project/'probe.map.rpt').read_bytes()).hexdigest()}
        (output/'COUNTS.json').write_text(json.dumps(results, indent=2)+'\n')
        print(variant, results[variant], flush=True)


if __name__ == '__main__':
    main()
