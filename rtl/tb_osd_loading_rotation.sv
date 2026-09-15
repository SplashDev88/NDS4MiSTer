`timescale 1ns/1ps
module tb_osd_loading_rotation;
reg clk_sys=0, clk_video=0;
always #5 clk_sys=~clk_sys;
always #7 clk_video=~clk_video;
reg io_osd=0, io_strobe=0;
reg [15:0] io_din=0;
wire [23:0] dout;
wire de_out,vs_out,hs_out,osd_status;
osd dut(.clk_sys,.io_osd,.io_strobe,.io_din,.clk_video,
 .din(24'h000000),.de_in(1'b0),.vs_in(1'b0),.hs_in(1'b0),
 .dout,.de_out,.vs_out,.hs_out,.osd_status);
integer errors=0, checks=0, mode, height, width, x,y,sx,sy,i;
reg [7:0] expected;
function automatic [7:0] content(input integer col, row);
 content=((row*17) ^ col ^ (col>>3));
endfunction
task automatic tx(input [15:0] word_in);
 @(negedge clk_sys); io_din=word_in; io_strobe=1;
 repeat(2) @(negedge clk_sys);
 io_strobe=0;
 repeat(2) @(negedge clk_sys);
endtask
task automatic start_command(input [15:0] command);
 @(negedge clk_sys); io_osd=0;
 repeat(2) @(negedge clk_sys);
 io_osd=1; tx(command);
endtask
task automatic finish_command;
 @(negedge clk_sys); io_osd=0;
 repeat(3) @(negedge clk_sys);
endtask
task automatic setup(input integer rotation, rows);
 // Same sequence as frontend: disable resets highres, set rotation, write
 // the chosen row count, then show an ordinary OSD_MSG loading dialog.
 start_command(16'h40); tx(0);tx(0);tx(0);tx(0);tx(rotation); finish_command();
 for(integer row=0;row<rows;row=row+1) begin
  start_command(16'h20|row);
  for(integer col=0;col<256;col=col+1) tx(content(col,row));
  finish_command();
 end
 start_command(16'h49); finish_command();
endtask
task automatic sample(input integer px,py,rot,h,w,is_info);
 // Drive raster coordinates at the real OSD RAM/pixel pipeline boundary.
 // All memory/control traffic uses the real SPI decoder. Only anonymous
 // always blocks are named in the evidence copy for stable test references.
 @(negedge clk_video);
 dut.scan.osd_hcnt=px;
 dut.scan.osd_hcnt2=px+((is_info && rot==1)?128-h:0);
 dut.scan.osd_vcnt=py+((is_info && rot==3)?256-w:0);
 dut.scan.h_cnt=10000;
 dut.scan.h_osd_start=0;
 dut.scan.deD=0;
 if(rot==0) begin sx=px;sy=py;end
 else if(rot==1) begin sx=py;sy=h-1-px;end
 else begin sx=w-1-py;sy=px;end
 expected=content(sx,sy/8);
 @(posedge clk_video); #1;
 if(dut.scan.osd_byte !== expected) begin
  if(errors<4) $display("BAD BYTE rot=%0d height=%0d xy=%0d,%0d actual=%h expected=%h source=%0d,%0d",rot,h,px,py,dut.scan.osd_byte,expected,sx,sy);
  errors=errors+1;
 end
 @(posedge clk_video); #1;
 if(dut.osd_pixel !== expected[sy%8]) begin
  if(errors<4) $display("BAD PIXEL rot=%0d height=%0d xy=%0d,%0d",rot,h,px,py);
  errors=errors+1;
 end
 checks=checks+1;
endtask
initial begin
 force dut.ce_pix=1'b1;
 // Seed all16 file-list rows. The subsequent8-row message overwrites only
 // its own rows, leaving distinguishable old file-list data in rows8..15.
 repeat(4) @(negedge clk_sys);
 setup(0,16);
 for(mode=0;mode<4;mode=mode+1) if(mode!=2) begin
  for(height=64;height<=128;height=height+64) begin
   setup(mode,height/8);
   for(y=0;y<(mode==0?height:256);y=y+1)
    for(x=0;x<(mode==0?256:height);x=x+1)
     sample(x,y,mode,height,256,0);
  end
  // Cropped information windows use a separate origin convention. Exercise
  // their existing rotations too so the low-resolution fix cannot alter them.
  setup(mode,16);
  start_command(16'h40);finish_command();
  for(height=32;height<=128;height=height+32) begin
   width=160;
   start_command(16'h45);tx(20);tx(10);tx(width/8);tx(height/8);finish_command();
   for(y=0;y<(mode==0?height:width);y=y+1)
    for(x=0;x<(mode==0?width:height);x=x+1)
     sample(x,y,mode,height,width,1);
  end
 end
 if(errors) $fatal(1,"OSD rotation failures=%0d across%0d pixels",errors,checks);
 $display("PASS OSD8/16-row dialogs, menus and info windows, Off/90CW/90CCW: %0d pixels",checks);
 $finish;
end
endmodule
