// SPDX-License-Identifier: GPL-3.0-only
// Two-layer DS pixel store. Scanline commands retain their attributes until
// the input pipeline and this synchronous RAM stage have both drained.
module nds_fpga3d_pixels(
 input logic clk,reset,ce,
 input logic clear_we,input logic [7:0] clear_x,
 input logic [31:0] clear_color,clear_depth,clear_attr,
 input logic span_start,input logic [5:0] flags,
 input logic [31:0] poly_attr,left_cov,right_cov,
 input logic [8:0] left_end,right_begin,input logic [3:0] y_edge,
 input logic antialias,blend_enable,translucent_depth_write,
 input logic pixel_valid,resolve_valid,input logic [1:0] resolve_mode,
 input logic [31:0] fog_color,fog_offset,input logic [3:0] fog_shift,
 input logic [271:0] fog_table,input logic fog_alpha_only,
 input logic [7:0] pixel_x,
 input logic [31:0] pixel_color,pixel_depth,
 output logic pending,
 input logic flush_en,input logic [6:0] flush_index,
 output wire [63:0] flush_pair
);
 (* ramstyle="M10K" *) logic [31:0] color0_even[0:127],color0_odd[0:127];
 (* ramstyle="M10K" *) logic [31:0] color1[0:255];
 (* ramstyle="M10K" *) logic [31:0] attr0[0:255];
 (* ramstyle="M10K" *) logic [31:0] depth0[0:255],depth1[0:255],attr1[0:255];
 logic [31:0] c0e,c0o,c1,a0,d0,d1,a1;
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
 wire [31:0] fog_z=resolve_q==2?d1:d0;
 assign pending=pixel_pending || |fog_valid;
 logic [18:0] left_count,right_count;
 wire [6:0] read_pair=flush_en?flush_index:pixel_x[7:1];
 wire [31:0] old_c0=x_q[0]?c0o:c0e;
 wire [31:0] old_c1=c1;
 wire [31:0] old_a0=a0;
 assign flush_pair={c0o,c0e};

 function automatic logic depth_pass(input logic [31:0] z,prior,attr);
  begin
   if(flags[5])begin
    if(flags[1])depth_pass=({1'b0,z}+33'd255>={1'b0,prior})&&({1'b0,prior}+33'd255>={1'b0,z});
    else depth_pass=({1'b0,z}+33'd512>={1'b0,prior})&&({1'b0,prior}+33'd512>={1'b0,z});
   end else depth_pass=z<prior || (flags[3] && attr[4] && !attr[22] && z==prior);
  end
 endfunction
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
  pass0=depth_pass(depth_q,d0,old_a0);pass1=depth_pass(depth_q,d1,a1);
  target0=pass0;target1=!pass0 && old_a0[3:0]!=0 && pass1;
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
    color_we0=1;new_c0=resolve_color(old_c0,old_c1,old_a0);
   end else if(resolve_q==0 && (target0 || target1))begin
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
     if(target0 && old_a0[22:16]!=trans_attr0[22:16])begin
      color_we0=1;attr_we0=1;depth_we0=translucent_depth_write;
      new_c0=blend_color(color_q,old_c0);new_a0=trans_attr0;new_d0=depth_q;
     end
     // Native DS blending also visits the lower layer below an existing
     // edge, without a second depth test, even if its top ID was rejected.
     if((target1 || (target0 && old_a0[3:0]!=0)) && a1[22:16]!=trans_attr1[22:16])begin
      color_we1=1;attr_we1=1;depth_we1=translucent_depth_write;
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
  if(flush_en || (ce && (pixel_valid || resolve_valid)))begin
   c0e<=color0_even[read_pair];c0o<=color0_odd[read_pair];
   c1<=color1[pixel_x];
   a0<=attr0[pixel_x];
   d0<=depth0[pixel_x];d1<=depth1[pixel_x];a1<=attr1[pixel_x];
  end
  if(clear_we)begin
   if(clear_x[0])begin
    color0_odd[clear_x[7:1]]<=clear_color;
   end else begin
    color0_even[clear_x[7:1]]<=clear_color;
   end
   color1[clear_x]<=clear_color;attr0[clear_x]<=clear_attr;
   depth0[clear_x]<=clear_depth;depth1[clear_x]<=clear_depth;attr1[clear_x]<=clear_attr;
  end else begin
   if(color_we0)begin
    if(color_write_x[0])color0_odd[color_write_x[7:1]]<=new_c0;else color0_even[color_write_x[7:1]]<=new_c0;
   end
   if(color_we1)begin
    color1[color_write_x]<=new_c1;
   end
   if(attr_we0)begin
    attr0[x_q]<=new_a0;
   end
   if(attr_we1)attr1[x_q]<=new_a1;
   if(depth_we0)depth0[x_q]<=new_d0;
   if(depth_we1)depth1[x_q]<=new_d1;
  end
  if(reset || clear_we)begin pixel_pending<=0;resolve_q<=0;fog_valid<=0;end
  else if(ce)begin
   pixel_pending<=pixel_valid || resolve_valid;resolve_q<=resolve_valid?resolve_mode:2'd0;
   fog_valid<={fog_valid[2:0],pixel_pending && (resolve_q==1 || resolve_q==2)};
   fog_x[0]<=x_q;fog_layer[0]<=resolve_q==2;
   fog_source[0]<=resolve_q==2?old_c1:old_c0;
   fog_apply[0]<=resolve_q==2?(old_a0[3:0]!=0 && a1[15]):old_a0[15];
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
