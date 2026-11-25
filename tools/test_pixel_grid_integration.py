#!/usr/bin/env python3
"""Compile production command decode and grid/OSD ordering for the NDS feature."""
from pathlib import Path
import argparse
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
def run(out):
    out.mkdir(parents=True,exist_ok=True)
    source=(ROOT/'fpga/mister_nitro_console_island/sys/sys_top.v').read_text()
    mode=re.search(r'wire nds_pixel_grid_mode = .*?;',source,re.S).group()
    signature=next(line for line in source.splitlines() if 'Pixel Grid ABI v1' in line)
    decode=re.search(r"if\(cmd == 'h4A && cnt == 0\) begin.*?end",source,re.S).group()
    # Ensure the simulation's connection matches the production OSD input.
    assert '.dout(hdmi_data_mask), .hs_out(hdmi_hs_mask)' in source
    osd=source[source.index('osd hdmi_osd'):source.index('wire hdmi_cs_osd;')]
    assert '.din(hdmi_data_mask)' in osd and '.de_in(hdmi_de_mask)' in osd
    tb='''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg direct_video=0,HDMI_PR=0;reg[11:0]WIDTH=1920,HEIGHT=1080;
reg[1:0]nds_pixel_grid_strength=0;
reg io_enable=0,io_strobe=0,has_cmd=0;
reg[15:0]io_din=0,io_dout_sys=0;reg[7:0]cmd=0,cnt=0;
wire[15:0]rtc_dout;wire rtc_override;
wire[15:0]reply=io_dout_sys | (rtc_override?rtc_dout:16'd0);
nds_rtc_host_bridge rtc(.clk(clk),.rtc_clk(clk),.rtc_datetime(56'h59592304311226),.rtc_date_written(1'b0),
 .io_enable(io_enable),.io_strobe(io_strobe),.io_din(io_din),.io_override(rtc_override),.io_dout(rtc_dout));
'''+mode+'''
always @(posedge clk)begin
 if(!io_enable)begin has_cmd<=0;cnt<=0;io_dout_sys<=0;end
 else if(io_strobe)begin
  io_dout_sys<=0;
  if(!has_cmd)begin has_cmd<=1;cmd<=io_din[7:0];cnt<=0;
'''+signature+'''
  end else begin cnt<=cnt+1'b1;
'''+decode+'''
  end
 end
end
task word(input[15:0]value,output[15:0]response);
 @(negedge clk);io_din=value;io_strobe=1;
 @(negedge clk);io_strobe=0;response=reply;
endtask
task finish;
 @(negedge clk);io_enable=0;repeat(3)@(negedge clk);
endtask
reg[15:0]r;reg expected;integer cases=0;
initial begin
 repeat(3)@(negedge clk);
 if(nds_pixel_grid_strength!=0)$fatal(1,"not default Off");
 for(integer mode=0;mode<6;mode++)for(integer flags=0;flags<4;flags++)begin
  WIDTH=mode==0?1280:mode==1?1920:mode==2?2560:mode==3?1920:mode==4?1280:640;
  HEIGHT=mode==0?720:mode==1?1080:mode<5?1440:480;
  direct_video=flags[0];HDMI_PR=flags[1];expected=mode<2 && flags==0;
  io_enable=1;word(16'h4a,r);if(r!=16'h5047 || rtc_override)$fatal(1,"grid signature");
  word(0,r);if(r!==(16'h100|expected))$fatal(1,"mode gate");finish();cases++;
 end
 for(integer level=0;level<4;level++)begin
  io_enable=1;word(16'h4a,r);word(16'h5040|level,r);
  if(nds_pixel_grid_strength!=level)$fatal(1,"strength write");
  word(16'h5040|((level+1)%4),r);
  if(nds_pixel_grid_strength!=level)$fatal(1,"accepted extra payload");finish();
 end
 io_enable=1;word(16'h4a,r);word(16'h5044,r);finish();
 if(nds_pixel_grid_strength!=3)$fatal(1,"accepted malformed payload");
 io_enable=1;word(16'h47,r);if(r!=16'h5254)$fatal(1,"grid contaminated RTC");
 word(1,r);finish();repeat(20)@(negedge clk);
 io_enable=1;word(16'h47,r);word(0,r);if(r!=16'h101)$fatal(1,"RTC not ready");finish();
 if(nds_pixel_grid_strength!=3)$fatal(1,"RTC changed grid");
 $display("PASS production grid command: %0d mode/transport gates, strength writes, malformed/extra payloads and shared RTC",cases);$finish;
end
endmodule
'''
    (out/'control.sv').write_text(tb)
    subprocess.run(['iverilog','-g2012','-s','tb','-o',str(out/'control'),str(out/'control.sv'),str(ROOT/'rtl/nds_rtc_host_bridge.sv')],check=True)
    r=subprocess.run(['vvp',str(out/'control')],capture_output=True,text=True)
    (out/'control.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr,end='');r.check_returncode()
    osd=(ROOT/'fpga/mister_nitro_console_island/sys/osd.v').read_text()
    before='always @(posedge clk_video) begin\n\treg        deD;'
    assert osd.count(before)==1
    (out/'osd.v').write_text(osd.replace(before,'always @(posedge clk_video) begin : scan\n\treg        deD;'))
    subprocess.run(['iverilog','-g2012','-s','tb_nds_pixel_grid_osd','-o',str(out/'osd-test'),str(out/'osd.v'),str(ROOT/'rtl/nds_pixel_grid.sv'),str(ROOT/'rtl/tb_nds_pixel_grid_osd.sv')],check=True)
    r=subprocess.run(['vvp',str(out/'osd-test')],capture_output=True,text=True)
    (out/'osd.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr,end='');r.check_returncode()
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
    run(p.parse_args().output.resolve())
