// SPDX-License-Identifier: GPL-3.0-or-later
// Checks the real SDRAM pins, not controller internals. A physical write must
// have the expected column/data/byte masks; ready follows the final halfword.
`timescale 1ns/1ps
module tb_nds_sdram_wide;
 reg clk=0,init=1; always #4 clk=~clk;
 tri [15:0] dq;wire [12:0] a;wire [1:0] ba;
 wire ml,mh,ncs,nwe,nras,ncas,ready;
 reg req=0,wide=0,refresh=0;reg [26:1] addr=0;
 reg [31:0] lo=0,hi=0;reg [3:0] be=0,behi=0;
 sdram #(.CAS_LATENCY(3),.TRCD_WAIT(2)) dut(
  .init(init),.clk(clk),.SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),
  .SDRAM_DQML(ml),.SDRAM_DQMH(mh),.SDRAM_nCS(ncs),.SDRAM_nWE(nwe),.SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),
  .refresh_req(refresh),.ch1_addr(26'd0),.ch1_din(16'd0),.ch1_req(1'b0),.ch1_rnw(1'b1),
  .ch2_addr(addr),.ch2_din(lo),.ch2_din_hi(hi),.ch2_be(be),.ch2_be_hi(behi),.ch2_req(req),.ch2_rnw(1'b0),
  .ch2_wide(wide),.ch2_cancel(1'b0),.ch2_ready(ready),
  .ch3_addr(24'd0),.ch3_din(16'd0),.ch3_req(1'b0),.ch3_rnw(1'b1));
 reg active=0;integer beats=0,expected_beats=0,total=0;
 reg [8:0] col;reg [1:0] bank;reg [12:0] row;
 reg [63:0] data64;reg [7:0] masks;
 always @(negedge clk) begin
  if(!init && active) begin
   if(!ncs && {nras,ncas,nwe}==3'b011) begin
    if(ba!==bank || a!==row)$fatal(1,"row/bank mismatch");
   end
   if(!ncs && {nras,ncas,nwe}==3'b100) begin
    if(beats>=expected_beats)$fatal(1,"extra physical WRITE");
    if(a[8:0]!==col+beats || ba!==bank)$fatal(1,"WRITE column/bank beat %0d",beats);
    if(dq!==data64[beats*16+:16])$fatal(1,"WRITE data beat %0d got %h",beats,dq);
    if({mh,ml}!==~masks[beats*2+:2])$fatal(1,"WRITE masks beat %0d",beats);
    if(a[10] !== (beats==expected_beats-1))$fatal(1,"auto-precharge beat %0d",beats);
    beats=beats+1; total=total+1;
   end
   if(ready && beats!=expected_beats)$fatal(1,"ready before final WRITE");
  end
 end
 integer w,m,k,cycles,cases=0;
 initial begin
  repeat(4)@(posedge clk);@(negedge clk);init=0;
  repeat(13000)@(posedge clk);
  for(w=0;w<2;w=w+1)begin
   for(m=0;m<256;m=m+1)begin
    @(posedge clk);#1;
    wide=w; addr=(26'h10200+(m*8)+(w?0:((m&1)*2)));
    col=addr[9:1];row=addr[22:10];bank=addr[24:23];
    lo=32'h98123456 ^ (m*32'hABCDE1); hi=32'h7890FEDC ^ (m*32'hABCDE1);
    be=m[3:0];behi=m[7:4];data64={hi,lo};masks={behi,be};
    expected_beats=w?4:2;beats=0;active=1;req=1;
    // Refresh can delay acceptance, but the lower attributes must be latched.
    refresh=(m%13==0);
    @(posedge clk);#1;req=0;refresh=0;addr=26'h123456;lo=0;be=0;wide=0;
    cycles=0;
    while(!ready)begin @(posedge clk);#1;cycles=cycles+1;if(cycles>200)$fatal(1,"timeout");end
    @(negedge clk);#1;
    if(beats!=expected_beats)$fatal(1,"missing writes");
    active=0;cases=cases+1;
    // High payload remains live through ready; changing it now is safe.
    hi=0;behi=0;
    repeat(2)@(posedge clk);
   end
  end
  $display("PASS: SDRAM 32/64-bit writes: %0d transactions, %0d pin writes, all byte masks, refresh stalls",cases,total);
  $finish;
 end
 initial begin #10000000;$fatal(1,"watchdog");end
endmodule
// Behavioral model of the fixed 0/1 DDR clock output used by this controller.
// All data/command logic above is the unmodified production SDRAM controller.
module altddio_out #(
 parameter extend_oe_disable="OFF", intended_device_family="Cyclone V",invert_output="OFF",lpm_hint="UNUSED",lpm_type="altddio_out",oe_reg="UNREGISTERED",power_up_high="OFF",width=1
)(input [width-1:0] datain_h,datain_l,input outclock,aclr,aset,oe,outclocken,sclr,sset,output [width-1:0] dataout);
 assign dataout=outclock?datain_h:datain_l;
endmodule
