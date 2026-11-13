// SPDX-License-Identifier: GPL-3.0-only
// Exercise the console fabric with a busy-dependent control request (as used
// by nds_h3d_control_init), cartridge and priority scanout reads plus checked event write bursts.
module nds_fpga3d_shared # (parameter POLL_CYCLES=8,REAL_CONTROL=0,FAIR_PROBE_INTERVAL=8,parameter bit ENABLE_SEGMENTED_EXPERIMENT=0, parameter integer TEX_CACHE_INDEX_BITS=8)(
 input clk,reset,enable,input [31:0] session,
 output rd,wr,output [7:0] burst,output [28:0] addr,output [63:0] din,output [7:0] be,
 input busy,input [63:0] dout,input dout_ready
);
 wire ar,aw,ab,av,aaccept;wire [7:0] an,ae;wire [28:0] aa;wire [63:0] ai,ao;
 wire released,control_fault;wire [31:0] control_fault_bits;
 nds_fpga3d #(.POLL_CYCLES(POLL_CYCLES),.ENABLE_SEGMENTED_EXPERIMENT(ENABLE_SEGMENTED_EXPERIMENT),.TEX_CACHE_INDEX_BITS(TEX_CACHE_INDEX_BITS)) accelerator(clk,reset,enable&&released,session,ar,aw,an,aa,ai,ae,ab,ao,av,aaccept);
 wire cr,cw,cb,cv;wire [63:0] co,ci;wire [28:0] cc;wire [7:0] cn,ce;
 wire lr,lb,lv;wire [63:0] lo;
 wire vr,vb,vv;wire [63:0] vo;
 generate if(REAL_CONTROL)begin: real_ctl
  nds_h3d_control_init #(.BASE_WORD(29'h07f80000),.PACKET_MODE(1),.DIAGNOSTIC_HOLD_ENABLE(0)) ctl(
   .clk,.reset,.requested_session(32'd1),.engine_b_pixels_enable(1'b1),.video_quiescent(1'b1),
   .external_fault_bits(32'd0),.fpga_heartbeat_value(32'd123),.fpga_telemetry_value(32'd0),
   .telemetry_index(),.diagnostic_hold(),.active(),.initialized(),.console_release(released),.active_session(),
   .fault(control_fault),.fault_bits(control_fault_bits),
   .ddram_read(cr),.ddram_write(cw),.ddram_burst_count(cn),.ddram_address(cc),.ddram_write_data(ci),.ddram_byte_enable(ce),
   .ddram_busy(cb),.ddram_command_accepted(ca),.ddram_read_data(co),.ddram_read_data_ready(cv));
 end else begin: peer_ctl
  fpga3d_control_peer ctl(clk,reset,cr,cw,cb,ca,co,cv);
  assign cn=1;assign cc=29'h07f8008f;assign ci=64'h0123456789abcdef;assign ce=8'hff;
  assign released=1;assign control_fault=0;assign control_fault_bits=0;
 end endgenerate
 fpga3d_peer #(.BEATS(4),.PAUSE(0)) cart(clk,reset,lr,lb,lo,lv);
 fpga3d_peer #(.BEATS(8),.PAUSE(0)) video(clk,reset,vr,vb,vo,vv);
 wire mr,mw,mb,mv;wire [7:0] mn,me;wire [28:0] ma;wire [63:0] mi,mo;
 wire e1,e2,ma_accept,ca;
 wire er,ew,eb,ev,ea;wire [63:0] eo,ei;
 fpga3d_event_peer events(clk,reset,er,ew,ei,eb,ea,eo,ev);
 nds_fpga3d_port_mux inner(
 .clk,.reset,
 .c_rd(cr),.c_wr(cw),.c_burst(cn),.c_addr(cc),.c_din(ci),.c_be(ce),.c_busy(cb),.c_dout(co),.c_valid(cv),.c_accepted(ca),
 .a_rd(ar),.a_wr(aw),.a_burst(an),.a_addr(aa),.a_din(ai),.a_be(ae),.a_busy(ab),.a_dout(ao),.a_valid(av),.a_accepted(aaccept),
 .rd(mr),.wr(mw),.burst(mn),.addr(ma),.din(mi),.be(me),.busy(mb),.dout(mo),.valid(mv),.accepted(ma_accept),.protocol_error(e1));
 nds_ddram_arbiter_4client #(.CLIENT_ENABLE_MASK(4'b1111),.VIDEO_PRIORITY_GRANT(1),.VIDEO_PRIORITY_FAIR_CREDIT(1),.FAIR_PROBE_INTERVAL(FAIR_PROBE_INTERVAL)) outer(
 .clk,.reset,
 .cpu_rd(lr),.cpu_we(1'b0),.cpu_burstcnt(8'd4),.cpu_addr(29'h07f80080),.cpu_din(64'd0),.cpu_be(8'hff),.cpu_busy(lb),.cpu_dout(lo),.cpu_dout_ready(lv),.cpu_command_accepted(),
 .video_rd(vr),.video_we(1'b0),.video_burstcnt(8'd8),.video_addr(29'h07f80080),.video_din(64'd0),.video_be(8'hff),.video_busy(vb),.video_dout(vo),.video_dout_ready(vv),.video_command_accepted(),
 .sound_rd(er),.sound_we(ew),.sound_burstcnt(8'd16),.sound_addr(29'h07f800a0),.sound_din(ei),.sound_be(8'hff),.sound_busy(eb),.sound_dout(eo),.sound_dout_ready(ev),.sound_command_accepted(ea),
 .credit_rd(mr),.credit_we(mw),.credit_burstcnt(mn),.credit_addr(ma),.credit_din(mi),.credit_be(me),.credit_busy(mb),.credit_dout(mo),.credit_dout_ready(mv),.credit_command_accepted(ma_accept),
 .ddram_rd(rd),.ddram_we(wr),.ddram_burstcnt(burst),.ddram_addr(addr),.ddram_din(din),.ddram_be(be),.ddram_busy(busy),.ddram_dout(dout),.ddram_dout_ready(dout_ready),.epoch_quiescent(),.debug_state(),.protocol_error(e2));
 always @(posedge clk)if(!reset)begin
  if(e1 || e2)$fatal(1,"DDR protocol error");
  if(ca && !ma_accept)$fatal(1,"control acceptance preceded physical acceptance");
  if(control_fault)$fatal(1,"real control initializer fault %h",control_fault_bits);
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

// Retain beat zero through local enqueue and physical acceptance, then stream
// all 16 beats without gaps. Read back each burst with a sequence/beat oracle.
module fpga3d_event_peer(input clk,reset,output rd,wr,output [63:0] din,
 input busy,accepted,input [63:0] dout,input valid);
 reg [2:0] state;
 reg [31:0] serial;
 reg stream_started;
 integer beat,pause_cycles,age;
 function automatic [63:0] payload(input [31:0] seqno,input integer beatno);
  payload=64'hca7e000000000000|({32'd0,seqno}<<16)|64'(beatno);
 endfunction
 assign rd=state==3 && !busy;
 assign wr=state==1 && (stream_started || !busy);
 assign din=payload(serial,beat);
 always @(posedge clk)begin
  if(reset)begin state<=0;serial<=0;stream_started<=0;beat<=0;pause_cycles<=23;age<=0;end
  else begin
   age<=age+1;
   if(age>10000)$fatal(1,"event burst client starved");
   case(state)
    0:if(pause_cycles==0)begin state<=1;beat<=0;end else pause_cycles<=pause_cycles-1;
    1:if(accepted)begin
      stream_started<=1;
      if(beat==15)begin state<=2;beat<=0;stream_started<=0;end else beat<=beat+1;
     end
    2:state<=3;
    3:if(!busy)state<=4;
    4:if(valid)begin
      if(dout!==payload(serial,beat))$fatal(1,"event burst data lost/duplicated/reordered: seq=%0d beat=%0d got=%h",serial,beat,dout);
      if(beat==15)begin state<=0;serial<=serial+1;pause_cycles<=23;age<=0;end
      else beat<=beat+1;
     end
    default:$fatal(1,"bad event peer state");
   endcase
   if(valid && state!=4)$fatal(1,"event read response without owner");
   if(accepted && state!=1 && state!=4)$fatal(1,"event acceptance without transaction");
  end
 end
endmodule
