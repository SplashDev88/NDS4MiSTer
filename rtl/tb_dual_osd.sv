`timescale 1ns/1ps
module tb_dual_osd;
reg clk_sys=0, clk_video=0;
always #5 clk_sys=~clk_sys;
always #7 clk_video=~clk_video;
reg [31:0] gp_outr=0;
reg io_strobe=0;
reg [15:0] io_din=0;
// CORE_SELECT_DECODE
osd hdmi(.clk_sys,.io_osd(io_osd_hdmi),.io_strobe,.io_din,.clk_video,
 .din(24'b0),.de_in(1'b0),.vs_in(1'b0),.hs_in(1'b0));
osd #(.OSD_COUNTER_BITS(14)) analog_osd(.clk_sys,.io_osd(io_osd_vga),.io_strobe,.io_din,.clk_video,
 .din(24'b0),.de_in(1'b0),.vs_in(1'b0),.hs_in(1'b0));
integer trace_file,fields,video_option,crt,height,transactions,sel,command,words,data;
integer cases=0,pixels=0,x,y,source_x,source_y,expected_rotation;
reg [4095:0] trace_path;
reg [7:0] expected;
reg [1:0] old_hdmi,old_analog;
reg selected_hdmi,selected_analog;
function automatic [7:0] content(input integer col,row);
 content=(row*17)^col^(col>>3);
endfunction
task automatic tx(input [15:0] value);
 @(negedge clk_sys);io_din=value;io_strobe=1;
 repeat(2) @(negedge clk_sys);
 io_strobe=0;repeat(2) @(negedge clk_sys);
endtask
task automatic sample(input integer px,py,is_analog);
 @(negedge clk_video);
 if(is_analog) begin
  analog_osd.scan.osd_hcnt=px;analog_osd.scan.osd_hcnt2=px;analog_osd.scan.osd_vcnt=py;
  analog_osd.scan.h_cnt=10000;analog_osd.scan.h_osd_start=0;analog_osd.scan.deD=0;
 end else begin
  hdmi.scan.osd_hcnt=px;hdmi.scan.osd_hcnt2=px;hdmi.scan.osd_vcnt=py;
  hdmi.scan.h_cnt=10000;hdmi.scan.h_osd_start=0;hdmi.scan.deD=0;
 end
 // Expected geometry follows the image on each path, independently of commands.
 if(is_analog || video_option==0) begin source_x=px;source_y=py;end
 else if(video_option==1) begin source_x=255-py;source_y=px;end
 else begin source_x=py;source_y=height-1-px;end
 expected=content(source_x,source_y/8);
 @(posedge clk_video);#1;
 if((is_analog ? analog_osd.scan.osd_byte : hdmi.scan.osd_byte)!==expected)
  $fatal(1,"OSD BYTE output=%0d video=%0d crt=%0d xy=%0d,%0d",is_analog,video_option,crt,px,py);
 @(posedge clk_video);#1;
 if((is_analog ? analog_osd.osd_pixel : hdmi.osd_pixel)!==expected[source_y%8])
  $fatal(1,"OSD PIXEL output=%0d video=%0d crt=%0d xy=%0d,%0d",is_analog,video_option,crt,px,py);
 pixels=pixels+1;
endtask
initial begin
 force hdmi.ce_pix=1'b1;force analog_osd.ce_pix=1'b1;
 repeat(4) @(negedge clk_sys);
 if(!$value$plusargs("HOST_TRACE=%s",trace_path)) $fatal(1,"Host trace required");
 trace_file=$fopen(trace_path,"r");if(!trace_file) $fatal(1,"Cannot open trace");
 while(!$feof(trace_file)) begin
  fields=$fscanf(trace_file,"%d %d %d %d\n",video_option,crt,height,transactions);
  if(fields==4) begin
   if(video_option<0 || video_option>2 || (height!=64 && height!=128)) $fatal(1,"Bad trace header");
   for(integer t=0;t<transactions;t=t+1) begin
    fields=$fscanf(trace_file,"%d %d %d",sel,command,words);
    if(fields!=3 || words<0 || words>256) $fatal(1,"Bad transaction");
    old_hdmi=hdmi.rot;old_analog=analog_osd.rot;
    @(negedge clk_sys);gp_outr=sel;#1;
    selected_hdmi=io_osd_hdmi;selected_analog=io_osd_vga;
    if(io_fpga || io_uio || (!selected_hdmi && !selected_analog))
     $fatal(1,"Host OSD command selected unrelated SPI function");
    tx(command);
    for(integer word_index=0;word_index<words;word_index=word_index+1) begin
     fields=$fscanf(trace_file,"%d",data);if(fields!=1) $fatal(1,"Missing data");tx(data);
    end
    @(negedge clk_sys);gp_outr=0;repeat(4) @(negedge clk_sys);
    if(!selected_hdmi && hdmi.rot!==old_hdmi) $fatal(1,"Analog command changed HDMI rotation");
    if(!selected_analog && analog_osd.rot!==old_analog) $fatal(1,"HDMI command changed analog rotation");
    if(t==0 && (hdmi.osd_enable!==0 || analog_osd.osd_enable!==0 || hdmi.highres!==0 || analog_osd.highres!==0))
     $fatal(1,"Broadcast disable did not clear both OSDs");
   end
   expected_rotation=video_option==1 ? 3 : video_option==2 ? 1 : 0;
   if(hdmi.rot!==expected_rotation[1:0] || analog_osd.rot!==0) $fatal(1,"Independent OSD direction mismatch");
   if(hdmi.osd_enable!==1 || analog_osd.osd_enable!==1) $fatal(1,"Both menus must be enabled");
   if(hdmi.highres!==(height==128) || analog_osd.highres!==(height==128)) $fatal(1,"Row-height latch mismatch");
   if(hdmi.osd_status!==(height==128) || analog_osd.osd_status!==(height==128)) $fatal(1,"Menu/message status mismatch");
   for(y=0;y<(video_option==0?height:256);y=y+1)
    for(x=0;x<(video_option==0?256:height);x=x+1) sample(x,y,0);
   for(y=0;y<height;y=y+1)
    for(x=0;x<256;x=x+1) sample(x,y,1);
   cases=cases+1;
  end
 end
 $fclose(trace_file);
 if(cases!=12) $fatal(1,"Expected12 host cases, got%0d",cases);
 $display("PASS dual OSD actual host SPI, actual sys_top select decode, HDMI Off/CCW/CW and upright analog, CRT/standard,16/8-row menus/loading: %0d cases %0d pixels",cases,pixels);
 $finish;
end
endmodule
