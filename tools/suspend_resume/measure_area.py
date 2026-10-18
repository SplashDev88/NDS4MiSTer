#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Map isolated CPU probes with Quartus 17; no full-core fit or timing claim."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True, help='Quartus 17.0.2 installation')
    parser.add_argument('--udev-shim', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New directory outside the source checkout')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output == repo or repo in output.parents:
        parser.error('Put generated projects outside the source checkout')
    runtime = args.runtime.resolve(); shim = args.udev_shim.resolve()
    if not (runtime/'quartus/bin/quartus_map').is_file() or not shim.is_file():
        parser.error('Quartus runtime or udev shim is missing')
    output.mkdir(parents=True, exist_ok=False)
    (output/'source').mkdir()
    files = ['third_party/Nitro_DarkSide/d2dabe/rtl/' + name for name in
             ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','nds_cpu9.vhd','gba_cpu.vhd']]
    files.append('tools/suspend_resume/area_probe.vhd')
    manifest = {}
    for name in files:
        source = repo/name
        shutil.copy2(source, output/'source'/source.name)
        manifest[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    (output/'SOURCE.json').write_text(json.dumps(manifest, indent=2)+'\n')
    results = {}
    for arm9 in [True, False]:
        for enabled in [False, True]:
            variant = ('arm9' if arm9 else 'arm7') + ('-checkpoint' if enabled else '-baseline')
            project = output/variant; project.mkdir()
            settings = '''set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7
set_global_assignment -name TOP_LEVEL_ENTITY checkpoint_area_probe
set_global_assignment -name VHDL_INPUT_VERSION VHDL_2008
set_global_assignment -name NUM_PARALLEL_PROCESSORS 1
set_global_assignment -name OPTIMIZATION_TECHNIQUE AREA
set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF
set_instance_assignment -name VIRTUAL_PIN ON -to *
'''
            settings += ''.join('set_global_assignment -name VHDL_FILE ../source/'+Path(n).name+'\n' for n in files)
            settings += 'set_parameter -name ARM9 '+str(arm9).lower()+'\n'
            settings += 'set_parameter -name CHECKPOINTS '+str(enabled).lower()+'\n'
            (project/'probe.qsf').write_text(settings)
            (project/'probe.qpf').write_text('PROJECT_REVISION = "probe"\n')
            with (project/'map.log').open('w') as log:
                subprocess.run(['docker','run','--rm','--network','none','--platform','linux/amd64',
                    '-v',str(output)+':/probe','-v',str(runtime)+':/quartus-runtime:ro',
                    '-v',str(shim)+':/usr/lib/x86_64-linux-gnu/libudev.so.1:ro',
                    '-e','LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libudev.so.1','-w','/probe/'+variant,
                    '--entrypoint','/quartus-runtime/quartus/bin/quartus_map',
                    'nds4mister-quartus-runtime:17.0.2','probe','--write_settings_files=off'],
                    stdout=log,stderr=subprocess.STDOUT,check=True)
            summary = (project/'probe.map.summary').read_text()
            log = (project/'map.log').read_text()
            if 'Analysis & Synthesis Status : Successful' not in summary:
                raise RuntimeError('Mapper did not complete: '+variant)
            results[variant] = {'registers':int(re.search(r'Total registers : (\d+)',summary)[1]),
                               'logic_cells':int(re.search(r'Implemented (\d+) logic cells',log)[1]),
                               'dsp_blocks':int(re.search(r'Total DSP Blocks : (\d+)',summary)[1])}
            (output/'COUNTS.json').write_text(json.dumps(results,indent=2)+'\n')
            print(variant, results[variant], flush=True)


if __name__ == '__main__':
    main()
