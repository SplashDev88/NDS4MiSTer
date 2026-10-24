#!/usr/bin/env python3
"""Exhaust the actual sys_top mode gate, including both HDMI-only builds."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'fpga/mister_nitro_console_island/sys/sys_top.v').read_text()
    source = source.split('reg        cfg_set      = 0;', 1)[1]
    declarations = source.split('wire       audio_96k', 1)[0]
    gate = source.split('wire       csync_en     = cfg[3];', 1)[1].split(
        '`ifndef MISTER_DUAL_SDRAM', 1)[0]
    for mode in ('normal', 'MISTER_HDMI_ONLY', 'NDS_HDMI_SCALER_ONLY'):
        case = output / mode
        case.mkdir(exist_ok=True)
        text = ('' if mode == 'normal' else '`define ' + mode + '\n')
        text += '''module tb_dv1_osd_gate;
reg [15:0] cfg;
reg vga_force_scaler, nds_split_active, vga_scaler;
reg expected;
integer checked;
'''
        text += declarations + gate
        text += '''initial begin
checked = 0;
for (integer flags = 0; flags < 65536; flags = flags + 1)
for (integer outputs = 0; outputs < 8; outputs = outputs + 1) begin
    cfg = 16'(flags);
    {vga_force_scaler, nds_split_active, vga_scaler} = 3'(outputs);
    #1;
    expected = 0;
'''
        if mode == 'normal':
            text += '''    // HDMI DV1 with metadata, native digital timing and separate analog.
    if ((flags & 'h0400) != 0 && (flags & 'h3080) == 0)
        if (!vga_force_scaler)
            if (nds_split_active || vga_scaler) expected = 1;
'''
        text += '''    assert (nds_dv1_native_osd === expected)
        else $fatal(1, "mode gate flags=%h outputs=%d", cfg, outputs);
    checked = checked + 1;
end
$display("PASS: %0d mode gate combinations", checked);
$finish;
end
endmodule
'''
        (case / 'gate.sv').write_text(text)
        docker = ['docker', 'run', '--rm', '--network', 'none', '-v',
                  str(case)+':/out', '-w', '/out',
                  os.environ.get('VERILATOR_IMAGE', 'nds4mister-rtl-verilator:24.04')]
        with (case / 'compile.log').open('w') as log:
            subprocess.run(docker + ['verilator', '--binary', '--timing', '--assert',
                '-Wno-fatal', '--top-module', 'tb_dv1_osd_gate', '-j', '2',
                '--Mdir', '/out/obj', '/out/gate.sv'], stdout=log, stderr=log,
                check=True)
        result = subprocess.run(docker + ['/out/obj/Vtb_dv1_osd_gate'],
                                capture_output=True, text=True, check=True)
        (case / 'test.log').write_text(result.stdout)
        print(mode + ': ' + result.stdout, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.output:
        run(args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='nds-dv1-mode-gate-') as directory:
            run(Path(directory))
