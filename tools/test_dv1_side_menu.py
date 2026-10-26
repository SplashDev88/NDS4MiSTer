#!/usr/bin/env python3
"""Exercise the actual side-menu admission/metadata gate in every output mode."""
import argparse, os, re, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def run(out):
 out.mkdir(parents=True,exist_ok=True)
 source=(ROOT/'fpga/mister_nitro_console_island/sys/sys_top.v').read_text()
 start=source.index('`ifdef MISTER_HDMI_ONLY\nwire nds_dv1_native_osd')
 end=source.index('`ifndef MISTER_DUAL_SDRAM',start)
 gate=source[start:end]
 capability=re.search(r"if\(cmd == 'h46 && cnt == 2\) io_dout_sys <= (.*);",source).group(1)
 instance=source[source.index(') vga_osd'):source.index('wire vga_cs_osd;')]
 assert '.native_pixel_enable(nds_dv1_side_native_menu)' in instance
 assert '.buffer_pair_q(nds_osd_digital_pair_q)' in instance
 test='''`timescale 1ns/1ps
module tb;
reg [15:0] cfg;
reg vga_force_scaler,nds_split_active,vga_scaler,nds_dv1_rotated;
reg [9:0] tate_source_width,tate_source_height;
wire direct_video=cfg[10];
wire vga_fb=cfg[12] | vga_force_scaler;
wire nds_dv1_present;
'''+gate+'\nassign nds_dv1_present=nds_dv1_native_osd && nds_dv1_rotated;\nwire [15:0] capability='+capability+''';
integer count=0;
reg expected;
initial begin
 for(integer flags=0;flags<128;flags++) begin
  cfg=0;cfg[10]=flags[0];cfg[7]=flags[1];cfg[13]=flags[2];cfg[12]=flags[3];
  vga_force_scaler=flags[4];nds_split_active=flags[5];vga_scaler=flags[6];
  for(integer layout=0;layout<4;layout++) begin
   tate_source_width=layout==0?520:256;tate_source_height=layout==1?392:192;
   for(integer rotation=0;rotation<3;rotation++) begin
    nds_dv1_rotated=rotation!=0;#1;
    expected=flags[0] && !flags[1] && !flags[2] && !flags[3] && !flags[4] &&
             (flags[5] || flags[6]) && layout==0 && rotation==0;
`ifdef EXPECT_DISABLED
    expected=0;
`endif
    if(nds_dv1_side_native_menu!==expected || capability!==(expected?16'h4e51:16'h4e50))
     $fatal(1,"gate/capability mismatch flags%0d layout%0d rotation%0d",flags,layout,rotation);
    count++;
   end
  end
 end
 $display("PASS actual side-menu gate and metadata: %0d cases",count);$finish;
end
endmodule
'''
 (out/'gate.sv').write_text(test)
 variants={'native':['NDS_TATE'],'hdmi_only':['NDS_TATE','MISTER_HDMI_ONLY','EXPECT_DISABLED'],
           'scaler_only':['NDS_TATE','NDS_HDMI_SCALER_ONLY','EXPECT_DISABLED'],'no_tate':['EXPECT_DISABLED']}
 logs=[]
 for name,defines in variants.items():
  binary=out/(name+'.vvp')
  subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb',
    *['-D'+d for d in defines],'-o',str(binary),str(out/'gate.sv')],check=True)
  r=subprocess.run([os.environ.get('VVP','vvp'),str(binary)],text=True,capture_output=True,check=True)
  logs.append(name+': '+r.stdout)
 text=''.join(logs);(out/'test.log').write_text(text);print(text)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path);a=p.parse_args()
 if a.output:run(a.output.resolve())
 else:
  with tempfile.TemporaryDirectory(prefix='nds-side-menu-') as d:run(Path(d))
