#!/usr/bin/env python3
"""Exercise the production Y/C command decode on a bus shared with the RTC."""
from pathlib import Path
import argparse,re,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
def run(out,collision=False):
    out.mkdir(parents=True,exist_ok=True)
    s=(ROOT/'fpga/mister_nitro_console_island/sys/sys_top.v').read_text()
    signature=next(l for l in s.splitlines() if 'YC target ABI v1' in l)
    decode=re.search(r"if\(cmd == 'h\w+ && cnt == 0 && io_din\[15:1\].*?nds_dv1_crt_target <= io_din\[0\];",s,re.S).group()
    if collision:
        signature=signature.replace("'h48","'h47")
        decode=decode.replace("'h48","'h47")
    # The system and emulation responses are ORed in the production top.
    # Compile the actual target decode and RTC mailbox, not a mock RTC reply.
    tb='''`timescale 1ns/1ps
module tb;
reg clk=0,rtc_clk=0;
always #5 clk=~clk;always #7 rtc_clk=~rtc_clk;
reg io_enable=0,io_strobe=0;reg [15:0] io_din=0;
reg [7:0] cmd=0;reg [7:0] cnt=0;reg [15:0] io_dout_sys=0;
reg nds_dv1_crt_target=0;
wire [15:0] rtc_dout;wire rtc_override;
wire [15:0] reply=io_dout_sys | (rtc_override ? rtc_dout : 16'd0);
nds_rtc_host_bridge rtc(.clk(clk),.rtc_clk(rtc_clk),
 .rtc_datetime(56'h59592304311226),.rtc_date_written(1'b0),
 .io_enable(io_enable),.io_strobe(io_strobe),.io_din(io_din),
 .io_override(rtc_override),.io_dout(rtc_dout));
always @(posedge clk) begin
 if(!io_enable)begin cmd<=0;cnt<=0;io_dout_sys<=0;end
 else if(io_strobe)begin
  if(cmd==0)begin cmd<=io_din[7:0];io_dout_sys<=0;
''' + signature + '''
  end else begin cnt<=cnt+1'b1;
''' + decode + '''
  end
 end
end
task word(input [15:0] data, output [15:0] value);
 begin @(negedge clk);io_din=data;io_strobe=1;
 @(negedge clk);io_strobe=0;value=reply;end
endtask
task finish;begin @(negedge clk);io_enable=0;repeat(3)@(negedge clk);end endtask
reg [15:0] v;reg [95:0] snapshot;integer i;
initial begin
 repeat(4)@(negedge clk);
 if(nds_dv1_crt_target)$fatal(1,"unsafe default");
 io_enable=1;word(16'h47,v);
 if(v!=16'h5254)$fatal(1,"RTC signature contaminated: %h",v);
 word(1,v);finish;repeat(20)@(negedge clk);
 io_enable=1;word(16'h48,v);
 if(v!=16'h5943 || rtc_override)$fatal(1,"Y/C signature or RTC ownership");
 word(16'h5941,v);if(!nds_dv1_crt_target)$fatal(1,"CRT write");
 word(16'h5940,v);if(!nds_dv1_crt_target)$fatal(1,"extra payload accepted");finish;
 io_enable=1;word(16'h47,v);
 if(v!=16'h5254)$fatal(1,"RTC unavailable after Y/C write");
 word(0,v);if(v!=16'h101)$fatal(1,"RTC snapshot not ready");
 for(i=0;i<6;i=i+1)begin word(0,v);snapshot[i*16+:16]=v;end
 if(snapshot!={32'd0,8'd0,56'h59592304311226})$fatal(1,"RTC snapshot changed");finish;
 if(!nds_dv1_crt_target)$fatal(1,"RTC changed Y/C target");
 io_enable=1;word(16'h48,v);word(16'h0000,v);finish;
 if(!nds_dv1_crt_target)$fatal(1,"invalid payload accepted");
 io_enable=1;word(16'h48,v);word(16'h5940,v);finish;
 if(nds_dv1_crt_target)$fatal(1,"Scaler write");
 $display("PASS shared IO bus: RTC snapshot, Y/C target, defaults and malformed/extra payloads");$finish;
end
endmodule
'''
    (out/'control.sv').write_text(tb)
    subprocess.run(['iverilog','-g2012','-s','tb','-o',str(out/'sim'),str(out/'control.sv'),str(ROOT/'rtl/nds_rtc_host_bridge.sv')],check=True)
    r=subprocess.run(['vvp',str(out/'sim')],text=True,capture_output=True)
    (out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr,end='')
    if collision:
        assert r.returncode and 'RTC signature contaminated' in r.stdout
        print('PASS negative control: rejected the original command collision')
    else:r.check_returncode()
if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
    run(a.output.resolve());run(a.output.resolve()/'negative-control',True)
