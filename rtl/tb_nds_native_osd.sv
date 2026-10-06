`timescale 1ns/1ps
// Compare the resource-bounded native OSD with the unchanged generic HDMI
// implementation at the actual60MHz/6MHz,10MHz and20MHz raster ratios.
module tb_nds_native_osd;
reg clk_sys=0, clk_video=0;
always #5 clk_sys=~clk_sys;
always #7 clk_video=~clk_video;
reg io_osd=0,io_strobe=0;
reg [15:0] io_din=0;
reg de_in=0,hs_in=0,vs_in=0;
reg [23:0] din=24'h245678;
wire [23:0] full_rgb,small_rgb;
wire [3:0] full_ctl,small_ctl;
osd full(.clk_sys,.io_osd,.io_strobe,.io_din,.clk_video,.din,.de_in,.hs_in,.vs_in,
 .dout(full_rgb),.de_out(full_ctl[0]),.hs_out(full_ctl[1]),.vs_out(full_ctl[2]),.osd_status(full_ctl[3]));
osd #(.OSD_COUNTER_BITS(14)) bounded(.clk_sys,.io_osd,.io_strobe,.io_din,.clk_video,.din,.de_in,.hs_in,.vs_in,
 .dout(small_rgb),.de_out(small_ctl[0]),.hs_out(small_ctl[1]),.vs_out(small_ctl[2]),.osd_status(small_ctl[3]));
integer checks=0, pixels=0;
reg checking=0;
always @(posedge clk_video) begin
 #1;
 if(checking) begin
  if ({full_rgb,full_ctl} !== {small_rgb,small_ctl})
   $fatal(1,"native OSD mismatch at %0t full=%h/%h small=%h/%h",$time,full_rgb,full_ctl,small_rgb,small_ctl);
  if ((^small_rgb) === 1'bx) $fatal(1,"uninitialized OSD output");
  checks=checks+1;
  if(small_ctl[0] && small_rgb!=din) pixels=pixels+1;
 end
end
task automatic tx(input [15:0] value);
 @(negedge clk_sys); io_din=value;io_strobe=1;
 repeat(2) @(negedge clk_sys);io_strobe=0;
 repeat(2) @(negedge clk_sys);
endtask
task automatic begin_cmd(input [15:0] cmd);
 @(negedge clk_sys);io_osd=0;
 repeat(2) @(negedge clk_sys);io_osd=1;tx(cmd);
endtask
task automatic end_cmd;
 @(negedge clk_sys);io_osd=0;
 repeat(3) @(negedge clk_sys);
endtask
task automatic menu(input integer rotation);
 begin_cmd('h40);tx(0);tx(0);tx(0);tx(0);tx(rotation);end_cmd();
 for(integer row=0;row<16;row=row+1) begin
  begin_cmd('h20|row);
  for(integer col=0;col<256;col=col+1) tx((row*17)^col^(col>>3));
  end_cmd();
 end
 begin_cmd('h41);end_cmd();
endtask
task automatic raster(input integer width,height,total_h,total_v,divisor,rotation);
 checking=0;pixels=0;menu(rotation);
 for(integer frame=0;frame<8;frame=frame+1) begin
  checking=(frame>=6);
  for(integer y=0;y<total_v;y=y+1) begin
   for(integer x=0;x<total_h*divisor;x=x+1) begin
    @(negedge clk_video);
    de_in=(x<width*divisor && y<height);
    hs_in=(x>=(width+8)*divisor && x<(width+36)*divisor);
    vs_in=(y>=height+3 && y<height+6);
   end
  end
 end
 checking=0;
 if(pixels==0) $fatal(1,"menu never appeared");
 $display("PASS native OSD %0dx%0d /%0d rotation%0d (%0d menu samples)",width,height,divisor,rotation,pixels);
endtask
initial begin
 // Model the Cyclone V power-up value of the interlace field toggle.
 // The test runner only names the otherwise anonymous scan block.
 full.scan.f1=0; bounded.scan.f1=0;
 repeat(5) @(negedge clk_sys);
 raster(320,240,384,262,10,0);
 raster(320,240,384,261,10,1);
 raster(320,240,384,262,10,3);
 raster(512,192,640,261,6,0);
 raster(256,192,640,262,6,0);
 raster(256,408,640,523,3,0);
 $display("PASS native OSD equivalent across %0d samples",checks);
 $finish;
end
endmodule
