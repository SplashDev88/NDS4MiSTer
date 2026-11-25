`timescale 1ns/1ps
// Real HDMI OSD after both Off and Strong grid pipelines. Letter strokes and
// menu geometry must survive, while the normal translucent background remains.
module tb_nds_pixel_grid_osd;
reg clk=0;always #5 clk=~clk;
reg reset=1,hs=0,vs=0,de=0,brd=1;
reg io_osd=0,io_strobe=0;reg[15:0]io_din=0;
wire[23:0]rgb[0:1],result[0:1];
wire[2:0]control[0:1],out_control[0:1];
genvar g;
generate for(g=0;g<2;g=g+1)begin: path
 nds_pixel_grid grid(.clk(clk),.reset(reset),.ce(1'b1),.enable_async(1'b1),
  .strength_async(g==0?2'd0:2'd3),.source_width(12'd256),.source_height(12'd192),
  .image_width(12'd768),.image_height(12'd576),.raster_width(12'd1280),.raster_height(12'd720),
  .din(24'h404040),.hs_in(hs),.vs_in(vs),.de_in(de),.brd_in(brd),
  .dout(rgb[g]),.hs_out(control[g][2]),.vs_out(control[g][1]),.de_out(control[g][0]));
 osd menu(.clk_sys(clk),.io_osd(io_osd),.io_strobe(io_strobe),.io_din(io_din),
  .clk_video(clk),.din(rgb[g]),.hs_in(control[g][2]),.vs_in(control[g][1]),.de_in(control[g][0]),
  .dout(result[g]),.hs_out(out_control[g][2]),.vs_out(out_control[g][1]),.de_out(out_control[g][0]));
end endgenerate
task tx(input[15:0]value);
 @(negedge clk);io_din=value;io_strobe=1;
 repeat(2)@(negedge clk);io_strobe=0;repeat(2)@(negedge clk);
endtask
task begin_cmd(input[15:0]value);
 @(negedge clk);io_osd=0;repeat(2)@(negedge clk);io_osd=1;tx(value);
endtask
task end_cmd;
 @(negedge clk);io_osd=0;repeat(3)@(negedge clk);
endtask
reg checking=0;
integer letters=0,backgrounds=0,game_changes=0,checked=0;
always @(posedge clk)begin
 #1;
 if(checking)begin
  if(out_control[0]!==out_control[1])$fatal(1,"menu sync moved");
  if(out_control[0][0])begin
   checked++;
   if(result[0]!=24'h404040)begin
    if({result[0][23:21],result[0][15:13],result[0][7:5]}!==
       {result[1][23:21],result[1][15:13],result[1][7:5]})
      $fatal(1,"grid attenuated menu stroke/color %h %h",result[0],result[1]);
    if(result[0][23])letters++;else backgrounds++;
   end else if(result[0]!=result[1])game_changes++;
  end
 end
end
initial begin
 path[0].menu.scan.f1=0;path[1].menu.scan.f1=0;
 repeat(6)@(negedge clk);reset=0;
 begin_cmd('h40);tx(0);tx(0);tx(0);tx(0);tx(0);end_cmd();
 for(integer row=0;row<16;row++)begin
  begin_cmd('h20|row);
  for(integer col=0;col<256;col++)tx((row*17)^col^(col>>3));
  end_cmd();
 end
 begin_cmd('h41);end_cmd();
 for(integer frame=0;frame<7;frame++)begin
  checking=frame>=5;
  for(integer y=0;y<750;y++)for(integer x=0;x<1650;x++)begin
   @(negedge clk);
   de=x<1280 && y<720;hs=x>=1390 && x<1430;vs=y>=725 && y<730;
   brd=!(x>=256 && x<1024 && y>=72 && y<648);
  end
 end
 checking=0;
 if(letters<1000 || backgrounds<1000 || game_changes<1000)$fatal(1,"test did not cover menu and game");
 $display("PASS HDMI grid before real OSD: %0d pixels, %0d letter pixels, %0d menu background pixels, %0d changed game pixels",checked,letters,backgrounds,game_changes);
 $finish;
end
endmodule
