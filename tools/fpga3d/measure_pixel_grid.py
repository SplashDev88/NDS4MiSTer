#!/usr/bin/env python3
"""Compare isolated Cyclone V grid resource use with the local Quartus 17 runtime.

These virtual-pin fits measure the module, not full-core routability. Pass the
previous RTL as --reference to measure both under identical constraints.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--reference', type=Path)
    p.add_argument('--shim', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if not args.shim.is_file():
        p.error('--shim must name the existing Quartus compatibility library')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    candidates = [('dsp', ROOT / 'rtl/nds_pixel_grid.sv')]
    if args.reference:
        candidates.insert(0, ('reference', args.reference.resolve()))
    results = {}
    for name, source in candidates:
        project = out / name
        project.mkdir(exist_ok=True)
        shutil.copyfile(source, project / 'grid.sv')
        (project / 'grid.qpf').write_text('PROJECT_REVISION = "grid"\n')
        (project / 'grid.qsf').write_text('''set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7
set_global_assignment -name TOP_LEVEL_ENTITY nds_pixel_grid
set_global_assignment -name SYSTEMVERILOG_FILE grid.sv
set_global_assignment -name SDC_FILE grid.sdc
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output
set_global_assignment -name NUM_PARALLEL_PROCESSORS 1
set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE AREA"
set_global_assignment -name OPTIMIZATION_TECHNIQUE AREA
set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF
set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC OFF
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING OFF
set_global_assignment -name SEED 8
set_instance_assignment -name VIRTUAL_PIN ON -to *
set_instance_assignment -name VIRTUAL_PIN OFF -to clk
''')
        (project / 'grid.sdc').write_text('''create_clock -name clk -period 6.734 [get_ports clk]
derive_clock_uncertainty
set_input_delay -clock clk 0 [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -clock clk 0 [all_outputs]
''')
        result = {'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'stages': {}}
        results[name] = result
        for stage in ['map', 'fit', 'sta']:
            cmd = ['docker', 'run', '--rm', '--network', 'none', '--platform', 'linux/amd64',
                   '-v', str(project) + ':/work',
                   '-v', 'nds4mister_quartus17_native:/quartus-runtime:ro',
                   '-v', str(args.shim.resolve()) + ':/usr/lib/x86_64-linux-gnu/libudev.so.1:ro',
                   '-e', 'LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libudev.so.1',
                   '-w', '/work', '--entrypoint', '/quartus-runtime/quartus/bin/quartus_' + stage,
                   'nds4mister-quartus-runtime:17.0.2', 'grid']
            print(name, stage, 'BEGIN', flush=True)
            with (project / (stage + '.log')).open('w') as log:
                r = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
            result['stages'][stage] = r.returncode
            (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            print(name, stage, 'END', r.returncode, flush=True)
            r.check_returncode()
        for kind in ['fit', 'sta']:
            summary = project / 'output' / ('grid.' + kind + '.summary')
            if summary.exists():
                result[kind + '_summary'] = summary.read_text()
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(result.get('fit_summary', ''), flush=True)


if __name__ == '__main__':
    main()
