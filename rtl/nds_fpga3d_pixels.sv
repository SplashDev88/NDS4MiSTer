// SPDX-License-Identifier: GPL-3.0-only
// Two-layer DS pixel store. Scanline commands retain their attributes until
// the input pipeline and this synchronous RAM stage have both drained.
module nds_fpga3d_pixels #(parameter integer RASTER_DELAY=2)(
 input logic clk,reset,ce,
 input logic [1:0] bank,
 input logic color_bank,
 input logic edge_read,input logic [1:0] edge_bank,input logic [7:0] edge_x,
 output wire [31:0] edge_attr,edge_depth,edge_color,
 input logic edge_write,input logic [7:0] edge_write_x,
 input logic [31:0] edge_write_color,edge_write_attr,
 input logic clear_we,input logic [7:0] clear_x,
 input logic [31:0] clear_color,clear_depth,clear_attr,
 input logic span_start,input logic [5:0] flags,
 input logic [31:0] poly_attr,left_cov,right_cov,
 input logic [8:0] left_end,right_begin,input logic [3:0] y_edge,
 input logic antialias,blend_enable,translucent_depth_write,
 input logic pixel_valid,resolve_valid,input logic [1:0] resolve_mode,
 input logic [1:0] shadow_mode,
 input logic stencil_frame_start,stencil_row,stencil_clear,
 input logic stencil_seed_we,input logic [8:0] stencil_seed_index,input logic [1:0] stencil_seed_bits,
 input logic stencil_dump_en,input logic [8:0] stencil_dump_index,output wire [1:0] stencil_dump_value,
 input logic precheck_valid,input logic [7:0] precheck_x,input logic [31:0] precheck_depth,
 output wire precheck_pass,
 input logic [31:0] fog_color,fog_offset,input logic [3:0] fog_shift,
 input logic [271:0] fog_table,input logic fog_alpha_only,
 input logic [7:0] pixel_x,
 input logic [31:0] pixel_color,pixel_depth,
 output logic pending,
 input logic flush_en,input logic [6:0] flush_index,
 output wire [63:0] flush_pair
);
 // Three top-metadata rows retain both neighbors for edge marking. Colors
 // and the lower layer need only two rows. Attribute stores use the six
 // M10Ks released by the indexed-texel cache, preserving logic capacity.
 (* ramstyle="M10K" *) logic [31:0] color0_even[0:255],color0_odd[0:255];
 (* ramstyle="M10K" *) logic [31:0] color1[0:511];
 (* ramstyle="M10K" *) logic [31:0] attr0[0:767];
 (* ramstyle="M10K" *) logic [31:0] depth0[0:767],depth1[0:511];
 (* ramstyle="M10K" *) logic [31:0] attr1[0:511];
 logic [31:0] c0e,c0o,c1;
 // Generation tags make a mask-group clear constant-time. A bounded frame
 // has at most 8128 commands, so 14-bit generations cannot wrap in one job.
 (* ramstyle="M10K" *) logic [15:0] stencil_memory[0:511];
 logic [13:0] stencil_generation[0:1];
 logic [15:0] stencil_q;
 logic stencil_read_row;
 wire stencil_read_en=stencil_dump_en || (ce && pixel_valid);
 wire [8:0] stencil_read_addr=stencil_dump_en?stencil_dump_index:{stencil_row,pixel_x};
 wire [1:0] stencil_bits=stencil_q[15:2]==stencil_generation[stencil_read_row]?stencil_q[1:0]:2'd0;
 assign stencil_dump_value=stencil_bits;
 wire [1:0] mask_bits=(pass0?stencil_bits:2'd1) | ((old_a0[3:0]!=0 && !pass1)?2'd2:2'd0);
 wire stencil_we=stencil_seed_we || (!reset && ce && pixel_pending && resolve_q==0 && shadow_mode==2);
 wire [8:0] stencil_write_addr=stencil_seed_we?stencil_seed_index:{stencil_row,x_q};
 wire [15:0] stencil_write_data=stencil_seed_we?{14'd1,stencil_seed_bits}:{stencil_generation[stencil_row],mask_bits};
 always_ff @(posedge clk)begin
  if(stencil_read_en)begin stencil_q<=stencil_memory[stencil_read_addr];stencil_read_row<=stencil_read_addr[8];end
  if(stencil_we)stencil_memory[stencil_write_addr]<=stencil_write_data;
  if(reset || stencil_frame_start)begin stencil_generation[0]<=1;stencil_generation[1]<=1;end
  else if(stencil_clear)stencil_generation[stencil_row]<=stencil_generation[stencil_row]+1'b1;
 end
 logic [31:0] a0_mem,a1_mem,d0_mem,d1_mem,precheck_z;
 logic edge_read_odd;
 assign edge_attr=a0_mem;
 assign edge_depth=d0_mem;
 assign edge_color=edge_read_odd?c0o:c0e;
 logic [31:0] a0_delay[0:RASTER_DELAY-1],a1_delay[0:RASTER_DELAY-1],d0_delay[0:RASTER_DELAY-1],d1_delay[0:RASTER_DELAY-1];
 // Raster depth tests always consume the aligned precheck pipeline. Resolve
 // passes use their synchronous RAM outputs directly; avoid putting their
 // mode selector on every depth-comparison and pixel-store write path.
 wire [31:0] a0=a0_delay[RASTER_DELAY-1];
 wire [31:0] a1=a1_delay[RASTER_DELAY-1];
 wire [31:0] d0=d0_delay[RASTER_DELAY-1];
 wire [31:0] d1=d1_delay[RASTER_DELAY-1];
 // Register the exact raster depth decisions alongside depth_q. Their
 // operands are the preceding metadata stage and the incoming pixel depth,
 // so the write stage sees the same comparison without a long comparator
 // followed by all target/attribute/color muxes in one cycle. Stalls retain
 // both the decision and its pixel; resolve and precheck timing are unchanged.
 wire [31:0] compare_a0,compare_a1,compare_d0,compare_d1;
 generate if(RASTER_DELAY==1)begin: direct_comparison
  assign compare_a0=a0_mem;assign compare_a1=a1_mem;
  assign compare_d0=d0_mem;assign compare_d1=d1_mem;
 end else begin: delayed_comparison
  assign compare_a0=a0_delay[RASTER_DELAY-2];assign compare_a1=a1_delay[RASTER_DELAY-2];
  assign compare_d0=d0_delay[RASTER_DELAY-2];assign compare_d1=d1_delay[RASTER_DELAY-2];
 end endgenerate
 logic raster_pass0_q,raster_pass1_q,raster_shadow1_q;
 wire [7:0] depth_read_x=resolve_valid?pixel_x:precheck_x;
 logic [7:0] x_q;
 logic [31:0] color_q,depth_q;
 logic [1:0] resolve_q;
 logic pixel_pending;
 logic [3:0] fog_valid,fog_layer,fog_apply;
 logic [7:0] fog_x[0:3];
 logic [31:0] fog_source[0:3];
 logic [31:0] fog_delta,fog_scaled;
 logic [7:0] fog_table0,fog_table1,fog_density;
 logic [16:0] fog_fraction;
 wire [5:0] fog_index=fog_scaled[31:17]>=32?6'd32:{1'b0,fog_scaled[21:17]};
 wire [25:0] fog_interpolated=26'(fog_table0)*(26'h20000-26'(fog_fraction))+26'(fog_table1)*26'(fog_fraction);
 wire [31:0] fog_z=resolve_q==2?d1_mem:d0_mem;
 assign pending=pixel_pending || |fog_valid;
 logic [18:0] left_count,right_count;
 wire [7:0] read_pair={color_bank,edge_read?edge_x[7:1]:flush_en?flush_index:pixel_x[7:1]};
 wire [9:0] metadata_read=edge_read?{edge_bank,edge_x}:{bank,depth_read_x};
 wire [31:0] old_c0=x_q[0]?c0o:c0e;
 wire [31:0] old_c1=c1;
 wire [31:0] old_a0=a0;
 assign flush_pair={c0o,c0e};

 function automatic logic depth_pass(input logic [31:0] z,prior,attr);
  logic [31:0] diff;
  begin
   diff=prior-z;
   if(flags[5])begin
    if(flags[1])depth_pass=(diff+32'd255)<=32'd510;
    else depth_pass=(diff+32'd512)<=32'd1024;
   end else depth_pass=$signed(z)<$signed(prior) || (flags[3] && attr[4] && !attr[22] && z==prior);
  end
 endfunction
 assign precheck_pass=shadow_mode[1] || depth_pass(precheck_z,d0_mem,a0_mem) ||
       (a0_mem[3:0]!=0 && depth_pass(precheck_z,d1_mem,a1_mem));
 function automatic [31:0] translucent_attr(input logic [31:0] prior);
  logic [31:0] value;
  begin
   value=(prior&32'hff001f0f)|(poly_attr&32'h0000e0f0)|((poly_attr>>24)<<16)|32'h00400000;
   if(!prior[15])value[15]=0;
   translucent_attr=value;
  end
 endfunction
 // A convex blend can use one signed product: dest + ((src-dest)*w >> n).
 // This is bit-exact for negative deltas and avoids a pair of cascaded DSPs.
 function automatic [5:0] mix6(input logic [5:0] source,dest,input logic [7:0] weight,input integer shift);
  logic signed [7:0] delta;
  logic signed [16:0] product_value;
  logic signed [17:0] result_value;
  begin
   delta=$signed({2'b00,source})-$signed({2'b00,dest});
   product_value=delta*$signed({1'b0,weight});
   result_value=$signed({1'b0,dest})+(product_value>>>shift);
   mix6=result_value[5:0];
  end
 endfunction
 function automatic [31:0] blend_color(input logic [31:0] source,dest);
  logic [7:0] weight;
  logic [4:0] a;
  begin
   weight={3'd0,source[28:24]}+8'd1;
   a=source[28:24]>dest[28:24]?source[28:24]:dest[28:24];
   if(dest[28:24]==0)blend_color=source;
   else if(blend_enable)blend_color={3'd0,a,
       2'd0,mix6(source[21:16],dest[21:16],weight,5),
       2'd0,mix6(source[13:8],dest[13:8],weight,5),
       2'd0,mix6(source[5:0],dest[5:0],weight,5)};
   else blend_color={3'd0,a,source[23:0]};
  end
 endfunction
 // Fog is a separate pipelined scanline pass before antialiasing.  The
 // 32-bit shift deliberately wraps exactly as in the native DS renderer.
 function automatic [31:0] fogged_color(input logic [31:0] source,input logic [7:0] density);
  logic [5:0] a;
  begin
   a=mix6({1'b0,fog_color[28:24]},{1'b0,source[28:24]},density,7);
   fogged_color=fog_alpha_only?{3'd0,a[4:0],source[23:0]}:
       {3'd0,a[4:0],2'd0,mix6(fog_color[21:16],source[21:16],density,7),
        2'd0,mix6(fog_color[13:8],source[13:8],density,7),
        2'd0,mix6(fog_color[5:0],source[5:0],density,7)};
  end
 endfunction
 function automatic [31:0] resolve_color(input logic [31:0] top,bottom,attr);
  logic [4:0] cov;
  logic [7:0] weight;
  logic [5:0] a;
  begin
   cov=attr[12:8];weight={3'd0,cov}+8'd1;
   a=mix6({1'b0,top[28:24]},{1'b0,bottom[28:24]},weight,5);
   if(attr[3:0]==0 || cov==31)resolve_color=top;
   else if(cov==0)resolve_color=bottom;
   else if(bottom[28:24]==0)resolve_color={3'd0,a[4:0],top[23:0]};
   else resolve_color={3'd0,a[4:0],2'd0,mix6(top[21:16],bottom[21:16],weight,5),
        2'd0,mix6(top[13:8],bottom[13:8],weight,5),
        2'd0,mix6(top[5:0],bottom[5:0],weight,5)};
  end
 endfunction

 logic color_we0,color_we1,attr_we0,attr_we1,depth_we0,depth_we1;
 logic [31:0] new_c0,new_c1,new_a0,new_a1,new_d0,new_d1;
 logic [7:0] color_write_x;
 logic pass0,pass1,target0,target1,advance_left,advance_right;
 logic [3:0] edge_bits;
 logic [4:0] coverage;
 logic [31:0] opaque_attr,trans_attr0,trans_attr1;
 always_comb begin
  color_write_x=x_q;
  color_we0=0;color_we1=0;attr_we0=0;attr_we1=0;depth_we0=0;depth_we1=0;
  new_c0=old_c0;new_c1=old_c1;new_a0=old_a0;new_a1=a1;new_d0=d0;new_d1=d1;
  pass0=raster_pass0_q;pass1=raster_pass1_q;
  target0=pass0;target1=!pass0 && old_a0[3:0]!=0 && pass1;
  if(shadow_mode==3)begin
   target0=stencil_bits[0] && pass0;
   // Native direct selection of the lower stencil layer retains the top
   // attribute for its first depth test; a failed-top fallback uses a1.
   target1=stencil_bits[1] && ((!stencil_bits[0] && raster_shadow1_q) ||
             (stencil_bits[0] && !pass0 && old_a0[3:0]!=0 && pass1));
  end
  edge_bits=y_edge;coverage=31;advance_left=0;advance_right=0;
  if({1'b0,x_q}<left_end)begin
   edge_bits=edge_bits|4'd1;
   coverage=left_cov[31]?(left_count[18:5]>31?5'd31:left_count[9:5]):left_cov[4:0];
  end else if({1'b0,x_q}>=right_begin)begin
   edge_bits=edge_bits|4'd2;
   coverage=right_cov[31]?(right_count[18:5]>31?5'd0:5'd31-right_count[9:5]):right_cov[4:0];
  end
  opaque_attr=poly_attr|{28'd0,edge_bits};
  if(antialias && edge_bits!=0)opaque_attr=opaque_attr|{19'd0,coverage,8'd0};
  trans_attr0=translucent_attr(old_a0);trans_attr1=translucent_attr(a1);
  if(pixel_pending && ce && !reset && !clear_we)begin
   if(resolve_q==3)begin
    color_we0=1;new_c0=resolve_color(old_c0,old_c1,a0_mem);
   end else if(resolve_q==0 && shadow_mode!=2 && (target0 || target1))begin
    if(color_q[28:24]==31)begin
     if(antialias && edge_bits!=0)begin
      if({1'b0,x_q}<left_end && left_cov[31])advance_left=1;
      else if({1'b0,x_q}>=right_begin && right_cov[31])advance_right=1;
      if(target0)begin
       color_we1=1;attr_we1=1;depth_we1=1;
       new_c1=old_c0;new_a1=old_a0;new_d1=d0;
      end
     end
     if(target0)begin
      color_we0=1;attr_we0=1;depth_we0=1;
      new_c0=color_q;new_a0=opaque_attr;new_d0=depth_q;
     end else begin
      color_we1=1;attr_we1=1;depth_we1=1;
      new_c1=color_q;new_a1=opaque_attr;new_d1=depth_q;
     end
    end else begin
     if(target0 && (shadow_mode==3 && !old_a0[22]?
            old_a0[29:24]!=poly_attr[29:24]:old_a0[22:16]!=trans_attr0[22:16]))begin
      color_we0=1;attr_we0=1;depth_we0=translucent_depth_write && !depth_q[31];
      new_c0=blend_color(color_q,old_c0);new_a0=trans_attr0;new_d0=depth_q;
     end
     // Native DS blending also visits the lower layer below an existing
     // edge, without a second depth test, even if its top ID was rejected.
     if((target1 || (target0 && old_a0[3:0]!=0 && (shadow_mode!=3 || stencil_bits[1]))) &&
          (shadow_mode==3 && !a1[22]?a1[29:24]!=poly_attr[29:24]:a1[22:16]!=trans_attr1[22:16]))begin
      color_we1=1;attr_we1=1;depth_we1=translucent_depth_write && !depth_q[31];
      new_c1=blend_color(color_q,old_c1);new_a1=trans_attr1;new_d1=depth_q;
     end
    end
   end
  end
  if(fog_valid[3] && fog_apply[3] && ce && !reset && !clear_we)begin
   color_write_x=fog_x[3];
   if(fog_layer[3])begin color_we1=1;new_c1=fogged_color(fog_source[3],fog_density);end
   else begin color_we0=1;new_c0=fogged_color(fog_source[3],fog_density);end
  end
 end
 always_ff @(posedge clk)begin
  if(edge_read || flush_en || (ce && (pixel_valid || resolve_valid)))begin
   c0e<=color0_even[read_pair];c0o<=color0_odd[read_pair];
   c1<=color1[{color_bank,pixel_x}];
   edge_read_odd<=edge_x[0];

  end
  if(edge_read || (ce && (precheck_valid || resolve_valid)))begin
   a0_mem<=attr0[metadata_read];a1_mem<=attr1[{color_bank,depth_read_x}];
   d0_mem<=depth0[metadata_read];d1_mem<=depth1[{color_bank,depth_read_x}];
   precheck_z<=precheck_depth;
  end
  if(ce)begin
   a0_delay[0]<=a0_mem;a1_delay[0]<=a1_mem;d0_delay[0]<=d0_mem;d1_delay[0]<=d1_mem;
   for(integer stage=1;stage<RASTER_DELAY;stage=stage+1)begin
    a0_delay[stage]<=a0_delay[stage-1];a1_delay[stage]<=a1_delay[stage-1];
    d0_delay[stage]<=d0_delay[stage-1];d1_delay[stage]<=d1_delay[stage-1];
   end
  end
  if(clear_we)begin
   if(clear_x[0])begin
    color0_odd[{color_bank,clear_x[7:1]}]<=clear_color;
   end else begin
    color0_even[{color_bank,clear_x[7:1]}]<=clear_color;
   end
   color1[{color_bank,clear_x}]<=clear_color;attr0[{bank,clear_x}]<=clear_attr;
   depth0[{bank,clear_x}]<=clear_depth;depth1[{color_bank,clear_x}]<=clear_depth;attr1[{color_bank,clear_x}]<=clear_attr;
  end else if(edge_write)begin
   if(edge_write_x[0])color0_odd[{color_bank,edge_write_x[7:1]}]<=edge_write_color;
   else color0_even[{color_bank,edge_write_x[7:1]}]<=edge_write_color;
   attr0[{bank,edge_write_x}]<=edge_write_attr;
  end else begin
   if(color_we0)begin
    if(color_write_x[0])color0_odd[{color_bank,color_write_x[7:1]}]<=new_c0;else color0_even[{color_bank,color_write_x[7:1]}]<=new_c0;
   end
   if(color_we1)begin
    color1[{color_bank,color_write_x}]<=new_c1;
   end
   if(attr_we0)begin
    attr0[{bank,x_q}]<=new_a0;
   end
   if(attr_we1)attr1[{color_bank,x_q}]<=new_a1;
   if(depth_we0)depth0[{bank,x_q}]<=new_d0;
   if(depth_we1)depth1[{color_bank,x_q}]<=new_d1;
  end
  if(reset || clear_we)begin pixel_pending<=0;resolve_q<=0;fog_valid<=0;end
  else if(ce)begin
   pixel_pending<=pixel_valid || resolve_valid;resolve_q<=resolve_valid?resolve_mode:2'd0;
   fog_valid<={fog_valid[2:0],pixel_pending && (resolve_q==1 || resolve_q==2)};
   fog_x[0]<=x_q;fog_layer[0]<=resolve_q==2;
   fog_source[0]<=resolve_q==2?old_c1:old_c0;
   fog_apply[0]<=resolve_q==2?(a0_mem[3:0]!=0 && a1_mem[15]):a0_mem[15];
   fog_delta<=fog_z<fog_offset?32'd0:fog_z-fog_offset;
   fog_scaled<=(fog_delta>>2)<<fog_shift;
   fog_table0<=fog_table[8*int'(fog_index)+:8];
   fog_table1<=fog_table[8*(int'(fog_index)+1)+:8];
   fog_fraction<=fog_scaled[31:17]>=32?17'd0:fog_scaled[16:0];
   fog_density<=fog_interpolated[25:17]>=127?8'd128:fog_interpolated[24:17];
   for(integer f=1;f<4;f=f+1)begin
    fog_x[f]<=fog_x[f-1];fog_source[f]<=fog_source[f-1];
    fog_layer[f]<=fog_layer[f-1];fog_apply[f]<=fog_apply[f-1];
   end
   raster_pass0_q<=depth_pass(pixel_depth,compare_d0,compare_a0);
   raster_pass1_q<=depth_pass(pixel_depth,compare_d1,compare_a1);
   raster_shadow1_q<=depth_pass(pixel_depth,compare_d1,compare_a0);
   x_q<=pixel_x;color_q<=pixel_color;depth_q<=pixel_depth;
  end
  if(reset)begin left_count<=0;right_count<=0;end
  else if(span_start)begin
   left_count<=left_cov[21:12]==1023?19'd0:{9'd0,left_cov[21:12]};
   right_count<=right_cov[21:12]==1023?19'd0:{9'd0,right_cov[21:12]};
  end else begin
   if(advance_left)left_count<=left_count+19'(left_cov[9:0]);
   if(advance_right)right_count<=right_count+19'(right_cov[9:0]);
  end
 end
endmodule
