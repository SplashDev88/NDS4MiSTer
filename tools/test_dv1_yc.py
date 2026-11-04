#!/usr/bin/env python3
"""Test the production DV1 mux, both encoders and HDMI porch reconstruction."""
from pathlib import Path
import argparse, os, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(out):
    out.mkdir(parents=True, exist_ok=True)
    source = (ROOT/'fpga/mister_nitro_console_island/sys/sys_top.v').read_text()
    # Compile the actual integration rather than a separately copied mux.
    delay = source[source.index('// These three-cycle delays'):source.index('`ifndef MISTER_DISABLE_YC', source.index('// These three-cycle delays'))]
    route = source[source.index('    nds_dv1_yc dv1_yc ('):source.index('`else', source.index('    nds_dv1_yc dv1_yc ('))]
    analog = source[source.index('\tyc_out yc_out'):source.index('`endif', source.index('\tyc_out yc_out'))]
    wrapper = '''module dv1_yc_test (
      input clk_vid, ce_pix, nds_dv1_present, nds_dv1_ce,
      input direct_video, vga_fb, vga_scaler, nds_dv1_crt_target,
      input nds_crt_active, nds_split_active, yc_en, cvbs, pal_en, csync_en,
      input [15:0] cfg,
      input [39:0] PhaseInc,
      input [16:0] ColorBurst_Range,
      input [23:0] vga_data_osd, native_analog_data,
      input vga_hs_osd, vga_vs_osd, vga_cs_osd, vga_de_osd,
      input native_analog_hs, native_analog_vs, native_analog_cs, native_analog_de,
      output [23:0] transport_data, analog_data, routed_data,
      output transport_hs, transport_vs, transport_de,
      output routed_hs, routed_vs, routed_cs
    );
    wire [23:0] yc_o;
    wire yc_hs, yc_vs, yc_cs, yc_de;
    ''' + analog + delay + route + '''
    assign transport_data = dv_data;
    assign transport_hs = dv_hs;
    assign transport_vs = dv_vs;
    assign transport_de = dv_de;
    assign analog_data = yc_o;
    assign {routed_data,routed_hs,routed_vs,routed_cs} =
           {dv_data_osd,dv_hs_osd,dv_vs_osd,dv_cs_osd};
    endmodule
    '''
    (out/'dv1_yc_test.sv').write_text(wrapper)
    docker = ['docker','run','--rm','--network','none',
              '-v',f'{ROOT}:/work:ro','-v',f'{out}:/out','-w','/out',
              os.environ.get('VERILATOR_IMAGE','nds4mister-rtl-verilator:24.04')]
    with (out/'compile.log').open('w') as log:
        p = subprocess.run(docker+['verilator','--cc','--exe','--build','-Wno-fatal',
            '--top-module','dv1_yc_test','--Mdir','/out/obj',
            '/out/dv1_yc_test.sv','/work/rtl/nds_dv1_yc.sv',
            '/work/fpga/mister_nitro_console_island/sys/yc_out.sv',
            '/work/tools/test_dv1_yc.cpp'],stdout=log,stderr=log)
    if p.returncode: print((out/'compile.log').read_text());p.check_returncode()
    p = subprocess.run(docker+['/out/obj/Vdv1_yc_test'],text=True,capture_output=True)
    (out/'test.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr);p.check_returncode()

if __name__ == '__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--output',type=Path);a=ap.parse_args()
    if a.output: run(a.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='nds-dv1-yc-') as d: run(Path(d))
