// SPDX-License-Identifier: GPL-3.0-only
// Exercise the console fabric with a busy-dependent control request (as used
// by nds_h3d_control_init), cartridge, event and priority scanout read bursts.
module nds_fpga3d_shared # (parameter POLL_CYCLES=8)(
 input clk,reset,enable,input [31:0] session,
 output rd,wr,output [7:0] burst,output [28:0] addr,output [63:0] din,output [7:0] be,
 input busy,input [63:0] dout,input dout_ready
);
 wire ar,aw,ab,av;wire [7:0] an,ae;wire [28:0] aa;wire [63:0] ai,ao;
 nds_fpga3d #(.POLL_CYCLES(POLL_CYCLES)) accelerator(clk,reset,enable,session,ar,aw,an,aa,ai,ae,ab,ao,av);
 wire cr,cw,cb,cv;wire [63:0] co;
 wire lr,lb,lv;wire [63:0] lo;
 wire vr,vb,vv;wire [63:0] vo;
 fpga3d_control_peer ctl(clk,reset,cr,cw,cb,ca,co,cv);
 fpga3d_peer #(.BEATS(4),.PAUSE(31)) cart(clk,reset,lr,lb,lo,lv);
 fpga3d_peer #(.BEATS(8),.PAUSE(59)) video(clk,reset,vr,vb,vo,vv);
 wire mr,mw,mb,mv;wire [7:0] mn,me;wire [28:0] ma;wire [63:0] mi,mo;
 wire e1,e2,ma_accept,ca;
 wire er,eb,ev;wire [63:0] eo;
 fpga3d_peer #(.BEATS(16),.PAUSE(23)) events(clk,reset,er,eb,eo,ev);
 nds_fpga3d_port_mux inner(
 .clk,.reset,
 .c_rd(cr),.c_wr(cw),.c_burst(8'd1),.c_addr(29'h07f8008f),.c_din(64'h0123456789abcdef),.c_be(8'hff),.c_busy(cb),.c_dout(co),.c_valid(cv),.c_accepted(ca),
 .a_rd(ar),.a_wr(aw),.a_burst(an),.a_addr(aa),.a_din(ai),.a_be(ae),.a_busy(ab),.a_dout(ao),.a_valid(av),
 .rd(mr),.wr(mw),.burst(mn),.addr(ma),.din(mi),.be(me),.busy(mb),.dout(mo),.valid(mv),.accepted(ma_accept),.protocol_error(e1));
 nds_ddram_arbiter_4client #(.CLIENT_ENABLE_MASK(4'b1111),.VIDEO_PRIORITY_GRANT(1),.VIDEO_PRIORITY_FAIR_CREDIT(1)) outer(
 .clk,.reset,
 .cpu_rd(lr),.cpu_we(1'b0),.cpu_burstcnt(8'd4),.cpu_addr(29'h07f80080),.cpu_din(64'd0),.cpu_be(8'hff),.cpu_busy(lb),.cpu_dout(lo),.cpu_dout_ready(lv),.cpu_command_accepted(),
 .video_rd(vr),.video_we(1'b0),.video_burstcnt(8'd8),.video_addr(29'h07f80080),.video_din(64'd0),.video_be(8'hff),.video_busy(vb),.video_dout(vo),.video_dout_ready(vv),.video_command_accepted(),
 .sound_rd(er),.sound_we(1'b0),.sound_burstcnt(8'd16),.sound_addr(29'h07f80080),.sound_din(64'd0),.sound_be(8'hff),.sound_busy(eb),.sound_dout(eo),.sound_dout_ready(ev),.sound_command_accepted(),
 .credit_rd(mr),.credit_we(mw),.credit_burstcnt(mn),.credit_addr(ma),.credit_din(mi),.credit_be(me),.credit_busy(mb),.credit_dout(mo),.credit_dout_ready(mv),.credit_command_accepted(ma_accept),
 .ddram_rd(rd),.ddram_we(wr),.ddram_burstcnt(burst),.ddram_addr(addr),.ddram_din(din),.ddram_be(be),.ddram_busy(busy),.ddram_dout(dout),.ddram_dout_ready(dout_ready),.epoch_quiescent(),.debug_state(),.protocol_error(e2));
 always @(posedge clk)if(!reset)begin
  if(e1 || e2)$fatal(1,"DDR protocol error");
  if(ca && !ma_accept)$fatal(1,"control acceptance preceded physical acceptance");
 end
endmodule
// Separate local enqueue from physical acceptance exactly as the initializer
// does. Alternate writes and reads, including immediately adjacent requests.
module fpga3d_control_peer(input clk,reset,output rd,wr,input busy,accepted,input [63:0] dout,input valid);
 reg pending,issued,physical,writing;
 integer pause_cycles,age,completed;
 assign rd=!reset && pending && !writing && !issued && !busy;
 assign wr=!reset && pending && writing && !issued && !busy;
 always @(posedge clk)begin
  if(reset)begin pending<=0;issued<=0;physical<=0;writing<=0;pause_cycles<=37;age<=0;completed<=0;end
  else begin
   if(!pending)begin
    if(pause_cycles==0)begin pending<=1;age<=0;end
    else pause_cycles<=pause_cycles-1;
   end else begin
    age<=age+1;
    if(age>10000)$fatal(1,"control requester starved");
   end
   if(rd || wr)issued<=1;
   if(accepted)begin
    if(!pending || !issued || physical)$fatal(1,"invalid physical control acceptance");
    physical<=1;
   end
   if(valid)begin
    if(!pending || !issued || writing || (!physical && !accepted) || dout!==64'h0123456789abcdef)$fatal(1,"invalid control response");
   end
   if((accepted && writing) || valid)begin
    pending<=0;issued<=0;physical<=0;writing<=!writing;completed<=completed+1;
    pause_cycles<=completed%4==0?37:0;
   end
  end
 end
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
