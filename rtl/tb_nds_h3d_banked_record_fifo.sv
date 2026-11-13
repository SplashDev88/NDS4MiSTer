// Cycle-for-cycle banked/linear FIFO comparison with independent input scoreboard.
`timescale 1ns/1ps
module tb_nds_h3d_banked_record_fifo;
 parameter integer LGDEPTH=12;
 parameter bit COMPACT=1;
 localparam integer DEPTH=1<<LGDEPTH;
 logic clk=0,reset=1; always #5 clk=~clk;
 logic rv=0,bv=0,fe=0;logic [127:0] rec=0;logic [31:0] frame=1,bframe=1;
 logic rr0,rr1,br0,br1,orv0,orv1,obv0,obv1,ofe0,ofe1;
 logic ordy=0,obdy=0;logic [127:0] out0,out1;logic [31:0] ofr0,ofr1,obf0,obf1;
 nds_h3d_record_fifo #(.LGDEPTH(LGDEPTH),.RECONSTRUCT_FRAME(COMPACT)) full_fifo(
  .clk,.reset,.in_record_valid(rv),.in_record_ready(rr0),.in_record(rec),.in_record_frame(frame),.in_record_frame_end(fe),.in_boundary_valid(bv),.in_boundary_ready(br0),.in_boundary_frame(bframe),.out_record_valid(orv0),.out_record_ready(ordy),.out_record(out0),.out_record_frame(ofr0),.out_record_frame_end(ofe0),.out_boundary_valid(obv0),.out_boundary_ready(obdy),.out_boundary_frame(obf0));
 nds_h3d_record_fifo #(.LGDEPTH(LGDEPTH),.RECONSTRUCT_FRAME(COMPACT),.BANKED_RAM(1)) compact_fifo(
  .clk,.reset,.in_record_valid(rv),.in_record_ready(rr1),.in_record(rec),.in_record_frame(frame),.in_record_frame_end(fe),.in_boundary_valid(bv),.in_boundary_ready(br1),.in_boundary_frame(bframe),.out_record_valid(orv1),.out_record_ready(ordy),.out_record(out1),.out_record_frame(ofr1),.out_record_frame_end(ofe1),.out_boundary_valid(obv1),.out_boundary_ready(obdy),.out_boundary_frame(obf1));
 logic [161:0] expected[0:65535];
 integer written=0,read_count=0,total=0,checks=0,full_seen=0,max_live=0,resets=0;
 logic [31:0] input_cursor=1,rng=32'h83a17d01;
 integer mode=0;
 integer bank_edges=0;
 always @(posedge clk) if(!reset && compact_fifo.fetch && compact_fifo.rptr[LGDEPTH-2:0]==0) bank_edges=bank_edges+1;
 function automatic [31:0] advance(input [31:0] x);
  advance={x[30:0],x[31]^x[21]^x[1]^x[0]};
 endfunction
 always @(negedge clk) begin
  rng=advance(rng);rng=advance(rng);
  ordy=(mode==2)||((mode==1)&&rng[3]);
  obdy=(mode==2)||((mode==1)&&rng[5]);
  if(reset)begin rv=0;bv=0;end
  else if(mode==2)begin rv=0;bv=0;end
  else if(!(rv||bv) || (rv?rr0:br0))begin
   rv=(mode==0)||rng[0];bv=(mode==0)?0:(rng[1]||rng[2]);
   rec={rng^32'hc137f512,~rng,rng+32'h123477ff,rng};
   fe=(rng[10:7]==0);frame=input_cursor;
   // Explicit boundaries can jump to any32-bit value; normal frames must
   // follow ends and boundaries, including wrap. No small-delta assumption.
   case(rng[12:11])
    0:bframe=32'hfffffffe;
    1:bframe=32'hffffffff;
    2:bframe=0;
    3:bframe=rng;
   endcase
  end
 end
 always @(posedge clk)begin
  if(reset)begin written=0;read_count=0;input_cursor=1;end
  else begin
   checks=checks+1;
   if({rr0,br0,orv0,obv0}!=={rr1,br1,orv1,obv1})$fatal(1,"cycle-level handshake mismatch");
   if(orv0 && {out0,ofr0,ofe0}!=={out1,ofr1,ofe1})$fatal(1,"record differs while valid/held");
   if(obv0 && {out0,obf0,ofe0}!=={out1,obf1,ofe1})$fatal(1,"boundary differs while valid/held");
   if((orv1&&ordy)||(obv1&&obdy))begin
    if(read_count==written)$fatal(1,"unexpected output");
    if({obv1,obv1?obf1:ofr1,ofe1,out1}!==expected[read_count&65535])$fatal(1,"independent input scoreboard mismatch at%0d",total);
    read_count=read_count+1;total=total+1;
   end
   if((rv&&rr0)||(!rv&&bv&&br0))begin
    if(rv)begin
     expected[written&65535]={1'b0,frame,fe,rec};
     if(frame!==input_cursor)$fatal(1,"invalid producer stimulus");
     if(fe)input_cursor=input_cursor+1'b1;
    end else begin
     expected[written&65535]={1'b1,bframe,1'b0,128'd0};input_cursor=bframe+1'b1;
    end
    written=written+1;
    if(written-read_count>max_live)max_live=written-read_count;
   end
   if(mode==0 && !rr0)full_seen=full_seen+1;
  end
 end
 initial begin
  repeat(4)@(negedge clk);#1;reset=0;
  repeat(DEPTH+16)@(negedge clk);
  if(!full_seen || max_live!=DEPTH+1)$fatal(1,"full capacity changed max=%0d expected=%0d",max_live,DEPTH+1);
  #1;mode=1;
  repeat(100000)@(negedge clk);
  #1;mode=2;
  repeat(DEPTH+10)@(negedge clk);
  if(written!=read_count)$fatal(1,"drain incomplete");
  // Abort each pipeline position with queued data and restart a fresh epoch.
  for(integer cut=1;cut<=24;cut=cut+1)begin
   #1;reset=1;resets=resets+1;repeat(3)@(negedge clk);
   #1;reset=0;mode=1;repeat(cut)@(negedge clk);
  end
  #1;reset=1;resets=resets+1;repeat(3)@(negedge clk);
  #1;reset=0;mode=1;repeat(4000)@(negedge clk);
  #1;mode=2;repeat(DEPTH+10)@(negedge clk);
  if(written!=read_count)$fatal(1,"postreset drain incomplete");
  if(bank_edges<4)$fatal(1,"bank/wrap traversal not exercised");
  $display("BANK_TRAVERSALS=%0d COMPACT=%0d",bank_edges,COMPACT);
  $display("BANKED_FIFO_EQUIVALENCE_PASS depth=%0d checks=%0d outputs=%0d max_live=%0d resets=%0d",DEPTH,checks,total,max_live,resets);$finish;
 end
 initial begin #5000000;$fatal(1,"timeout");end
endmodule
