// SPDX-License-Identifier: GPL-3.0-only
// Exercise the same nested arbitration used in the console with competing
// registered control, cartridge and priority scanout read bursts.
module nds_fpga3d_shared # (parameter POLL_CYCLES=8)(
 input clk,reset,enable,input [31:0] session,
 output rd,wr,output [7:0] burst,output [28:0] addr,output [63:0] din,output [7:0] be,
 input busy,input [63:0] dout,input dout_ready
);
 wire ar,aw,ab,av;wire [7:0] an,ae;wire [28:0] aa;wire [63:0] ai,ao;
 nds_fpga3d #(.POLL_CYCLES(POLL_CYCLES)) accelerator(clk,reset,enable,session,ar,aw,an,aa,ai,ae,ab,ao,av);
 wire cr,cb,cv;wire [63:0] co;
 wire lr,lb,lv;wire [63:0] lo;
 wire vr,vb,vv;wire [63:0] vo;
 fpga3d_peer #(.BEATS(1),.PAUSE(37)) ctl(clk,reset,cr,cb,co,cv);
 fpga3d_peer #(.BEATS(4),.PAUSE(31)) cart(clk,reset,lr,lb,lo,lv);
 fpga3d_peer #(.BEATS(8),.PAUSE(59)) video(clk,reset,vr,vb,vo,vv);
 wire mr,mw,mb,mv;wire [7:0] mn,me;wire [28:0] ma;wire [63:0] mi,mo;
 wire e1,e2;
 nds_ddram_arbiter_4client #(.CLIENT_ENABLE_MASK(4'b0101)) inner(
 .clk,.reset,
 .cpu_rd(cr),.cpu_we(1'b0),.cpu_burstcnt(8'd1),.cpu_addr(29'h07f80080),.cpu_din(64'd0),.cpu_be(8'hff),.cpu_busy(cb),.cpu_dout(co),.cpu_dout_ready(cv),.cpu_command_accepted(),
 .sound_rd(ar),.sound_we(aw),.sound_burstcnt(an),.sound_addr(aa),.sound_din(ai),.sound_be(ae),.sound_busy(ab),.sound_dout(ao),.sound_dout_ready(av),.sound_command_accepted(),
 .video_rd(1'b0),.video_we(1'b0),.video_burstcnt(8'd1),.video_addr(29'd0),.video_din(64'd0),.video_be(8'd0),.video_busy(),.video_dout(),.video_dout_ready(),.video_command_accepted(),
 .credit_rd(1'b0),.credit_we(1'b0),.credit_burstcnt(8'd1),.credit_addr(29'd0),.credit_din(64'd0),.credit_be(8'd0),.credit_busy(),.credit_dout(),.credit_dout_ready(),.credit_command_accepted(),
 .ddram_rd(mr),.ddram_we(mw),.ddram_burstcnt(mn),.ddram_addr(ma),.ddram_din(mi),.ddram_be(me),.ddram_busy(mb),.ddram_dout(mo),.ddram_dout_ready(mv),.epoch_quiescent(),.debug_state(),.protocol_error(e1));
 nds_ddram_arbiter_4client #(.CLIENT_ENABLE_MASK(4'b1011),.VIDEO_PRIORITY_GRANT(1),.VIDEO_PRIORITY_FAIR_CREDIT(1)) outer(
 .clk,.reset,
 .cpu_rd(lr),.cpu_we(1'b0),.cpu_burstcnt(8'd4),.cpu_addr(29'h07f80080),.cpu_din(64'd0),.cpu_be(8'hff),.cpu_busy(lb),.cpu_dout(lo),.cpu_dout_ready(lv),.cpu_command_accepted(),
 .video_rd(vr),.video_we(1'b0),.video_burstcnt(8'd8),.video_addr(29'h07f80080),.video_din(64'd0),.video_be(8'hff),.video_busy(vb),.video_dout(vo),.video_dout_ready(vv),.video_command_accepted(),
 .sound_rd(1'b0),.sound_we(1'b0),.sound_burstcnt(8'd1),.sound_addr(29'd0),.sound_din(64'd0),.sound_be(8'd0),.sound_busy(),.sound_dout(),.sound_dout_ready(),.sound_command_accepted(),
 .credit_rd(mr),.credit_we(mw),.credit_burstcnt(mn),.credit_addr(ma),.credit_din(mi),.credit_be(me),.credit_busy(mb),.credit_dout(mo),.credit_dout_ready(mv),.credit_command_accepted(),
 .ddram_rd(rd),.ddram_we(wr),.ddram_burstcnt(burst),.ddram_addr(addr),.ddram_din(din),.ddram_be(be),.ddram_busy(busy),.ddram_dout(dout),.ddram_dout_ready(dout_ready),.epoch_quiescent(),.debug_state(),.protocol_error(e2));
 always @(posedge clk)if(!reset && (e1 || e2))$fatal(1,"DDR protocol error");
endmodule
module fpga3d_peer #(parameter BEATS=1,PAUSE=40)(input clk,reset,output reg rd,input busy,input [63:0] dout,input valid);
 integer wait_cycles,remaining;
 always @(posedge clk)begin
  if(reset)begin rd<=0;wait_cycles<=PAUSE;remaining<=0;end
  else begin
   if(rd && !busy)begin rd<=0;remaining<=BEATS;end
   else if(remaining==0 && !rd)begin
    if(wait_cycles==0)rd<=1;
    else wait_cycles<=wait_cycles-1;
   end
   if(valid)begin
    if(remaining==0 || dout!==64'h0123456789abcdef)$fatal(1,"cross-client DDR response");
    remaining<=remaining-1;wait_cycles<=PAUSE;
   end
  end
 end
endmodule
