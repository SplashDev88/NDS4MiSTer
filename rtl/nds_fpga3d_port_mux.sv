// SPDX-License-Identifier: GPL-3.0-only
// Share the H3D control port without adding a second command queue. The outer
// fabric owns registration/quarantine. Physical acceptance is forwarded only
// to the locked owner, never synthesized from local queue acceptance.
// Both clients use single-beat writes; reads may burst. With no accelerator
// request the control client's queue/acceptance/response timing is unchanged.
module nds_fpga3d_port_mux (
 input logic clk,reset,
 input logic c_rd,c_wr,input logic [7:0] c_burst,input logic [28:0] c_addr,
 input logic [63:0] c_din,input logic [7:0] c_be,
 output logic c_busy,c_accepted,output logic [63:0] c_dout,output logic c_valid,
 input logic a_rd,a_wr,input logic [7:0] a_burst,input logic [28:0] a_addr,
 input logic [63:0] a_din,input logic [7:0] a_be,
 output logic a_busy,output logic [63:0] a_dout,output logic a_valid,
 output logic rd,wr,output logic [7:0] burst,output logic [28:0] addr,
 output logic [63:0] din,output logic [7:0] be,
 input logic busy,accepted,input logic [63:0] dout,input logic valid,
 output logic protocol_error
);
 logic locked,owner,read_pending,prefer_accel;
 logic [7:0] remaining;
 wire c_request=c_rd||c_wr;
 wire a_request=a_rd||a_wr;
 wire selected=locked?owner:(a_request && (!c_request || prefer_accel));
 wire enqueued=!locked && (rd||wr) && !busy;
 always_comb begin
  rd=0;wr=0;burst=selected?a_burst:c_burst;addr=selected?a_addr:c_addr;
  din=selected?a_din:c_din;be=selected?a_be:c_be;
  c_busy=1;a_busy=1;
  if(!reset && !locked)begin
   rd=selected?a_rd:c_rd;wr=selected?a_wr:c_wr;
   if(selected)a_busy=busy;else c_busy=busy;
  end
  c_accepted=!reset && locked && !owner && accepted;
  c_valid=!reset && locked && !owner && read_pending && valid;
  a_valid=!reset && locked && owner && read_pending && valid;
  c_dout=dout;a_dout=dout;
 end
 always_ff @(posedge clk)begin
  if(reset)begin
   locked<=0;owner<=0;read_pending<=0;remaining<=0;prefer_accel<=0;protocol_error<=0;
  end else begin
   if(enqueued)begin
    locked<=1;owner<=selected;read_pending<=rd;remaining<=burst;
    if((wr && burst!=1) || (rd && wr) || burst==0)protocol_error<=1;
   end
   if(accepted && !locked)protocol_error<=1;
   if(valid && (!locked || !read_pending || remaining==0))protocol_error<=1;
   if(locked)begin
    if(read_pending && valid)begin
     remaining<=remaining-1'b1;
     if(remaining==1)begin locked<=0;prefer_accel<=!owner;end
    end else if(!read_pending && accepted)begin locked<=0;prefer_accel<=!owner;end
   end
  end
 end
endmodule
