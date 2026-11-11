// SPDX-License-Identifier: GPL-3.0-only
// Experimental pipelined DS scanline rasterizer with two-layer AA and alpha blending. See tools/fpga3d/abi.h.
// All addresses are physical 64-bit DDR word addresses. Commands and textures
// are immutable until completion. This block never writes cartridge memory.
module nds_fpga3d #(
 parameter integer POLL_CYCLES=16384
)(
 input logic clk, reset, enable,
 input logic [31:0] session,
 output logic rd,wr,
 output logic [7:0] burst,
 output logic [28:0] addr,
 output logic [63:0] din,
 output logic [7:0] be,
 input logic busy,
 input logic [63:0] dout,
 input logic dout_ready,accepted
);
 localparam [28:0] MB=29'h07f90000,CM=29'h07f90200,OUT=29'h07fa0000;
 localparam [31:0] MAGIC=32'h37443346;
 typedef enum logic[5:0] {INIT,INIT_WAIT,READY,POLL_DELAY,POLL,POLL_WAIT,
 HEADER,HEADER_WAIT,PARAM,PARAM_WAIT,AVAILABLE,REFILL_DELAY,REFILL,REFILL_WAIT,FETCH,FETCH_WAIT,CMD_LOAD_FIRST,CMD_LOAD,UNPACK,DECODE,CLEAR_LINE,
 TEX_READ,TEX_WAIT,
 FLUSH_LOAD,FLUSH_WAIT,FLUSH_WRITE,NEXT_COMMAND,COMPLETE,CACHE_CLEAR,PIPE_RUN,RESOLVE_RUN,
 STENCIL_READ,STENCIL_WAIT,SEED_READ,SEED_WRITE,DUMP_READ,DUMP_PACK,DUMP_WRITE,
 RESOLVE_START,EDGE_READ,EDGE_CENTER,EDGE_NEIGHBOR,EDGE_APPLY,
 PALETTE_READ,PALETTE_WAIT} state_t;
 state_t state;
 logic [31:0] cmd[0:31];
 logic [8:0] stencil_index;
 logic [63:0] stencil_output_word;
 wire [1:0] stencil_dump_value;
 wire [511:0] packed_command;
 genvar packed_word;
 generate for(packed_word=0;packed_word<16;packed_word=packed_word+1)begin: pack_bus
 assign packed_command[32*packed_word+:32]=cmd[packed_word];
 end endgenerate
 logic [31:0] seq,seen,count,index,status,epoch;
 logic [31:0] command_base,texture_end;
 logic [13:0] capacity;
 logic producer_final;
 wire [31:0] param_base=dout[63:32];
 wire param_device=param_base==32'h3fc81000;
 wire param_padded=param_base==32'h3fe31000;
 wire param_wc=param_base>=32'h3fd40000 && param_base<32'h3fe00000 && param_base[5:0]==0;
 wire [31:0] param_space=(32'h3fe00000-param_base)>>6;
 wire [13:0] param_capacity=(param_device || param_padded)?14'd8128:(param_space>8128?14'd8128:14'(param_space));
 // The first 64 slots belong to telemetry. Every following group of 1024
 // slots is in the next plane's padding, never its 192 visible rows.
 wire [13:0] padded_slot=14'(index)+14'd64;
 wire [28:0] padded_address={11'h1ff,padded_slot[12:10],2'b11,padded_slot[9:0],3'd0};
 wire [28:0] command_address=command_base==32'h3fe31000 ? padded_address :
      29'(command_base>>3)+(index<<3);
 logic [15:0] poll;
 logic [3:0] beat;
 (* ramstyle="MLAB" *) logic [63:0] command_cache[0:127];
 logic [63:0] command_cache_q;
 logic [4:0] cached_commands;
 logic [3:0] cache_slot;
 logic [6:0] cache_fill_beat,cache_last_beat;
 // Keep each read inside one 4 KiB page even when the WC arena begins at
 // an arbitrary 64-byte boundary. Never prefetch an unpublished record.
 wire [5:0] command_page_index=command_base[11:6]+index[5:0];
 wire [6:0] page_commands=7'd64-{1'b0,command_page_index};
 wire [4:0] fetch_limit=page_commands>16?5'd16:page_commands[4:0];
 wire [4:0] fetch_commands=count-index>fetch_limit?fetch_limit:5'(count-index);
 wire [7:0] fetch_words={fetch_commands,3'b0};
 logic [63:0] next_descriptor[0:7];
 logic next_active,next_ready;
 logic [3:0] next_step;
 wire next_start=state==DECODE && cached_commands>1;
 wire normal_read=state==CMD_LOAD_FIRST || (state==CMD_LOAD && beat<7);
 wire cache_read_en=normal_read || next_start || (next_active && next_step<8) || state==SEED_READ;
 wire [3:0] next_slot=cache_slot+4'd1;
 wire [6:0] cache_normal_addr=state==CMD_LOAD_FIRST?{cache_slot,3'd0}:
                             {cache_slot,3'd0}+7'(beat)+7'd1;
 wire [6:0] cache_next_addr={next_slot,3'd0}+(next_start?7'd0:7'(next_step));
 wire [6:0] cache_read_addr=state==SEED_READ?{1'b0,stencil_index[8:3]}:normal_read?cache_normal_addr:cache_next_addr;
 always_ff @(posedge clk)begin
  if((state==FETCH_WAIT || state==STENCIL_WAIT) && dout_ready)command_cache[cache_fill_beat]<=dout;
  if(cache_read_en)command_cache_q<=command_cache[cache_read_addr];
  if(reset || !enable || state==UNPACK || state==FETCH ||
     (state==NEXT_COMMAND && !next_ready))begin
   next_active<=0;next_ready<=0;next_step<=0;
  end else if(next_start)begin
   next_active<=1;next_step<=1;
  end else if(next_active)begin
   next_descriptor[next_step-1'b1]<=command_cache_q;
   if(next_step==8)begin next_active<=0;next_ready<=1;end
   else next_step<=next_step+1'b1;
  end
 end
 logic [8:0] x,last,dx,line_y,flush_x;
 logic [9:0] span_width;
 logic line_open,flush_inflight;
 logic coverage_valid;
 wire [6:0] flush_read=(state==FLUSH_WRITE && accepted)?flush_x[7:1]+7'd1:flush_x[7:1];
 wire [63:0] flush_pair;
 logic [31:0] line_config,fog_color,fog_offset;
 logic [3:0] fog_shift;
 logic [271:0] fog_table;
 logic fog_configured;
 logic edge_configured;
 logic [1:0] toon_configured;
 logic [511:0] toon_table;
 logic [127:0] edge_table;
 logic [31:0] edge_border_attr,edge_border_depth;
 logic [1:0] render_bank,output_bank,edge_bank,edge_phase;
 logic [8:0] output_y;
 logic [31:0] row_config[0:2],output_config;
 logic [8:0] row_first[0:2],row_end[0:2],output_first,output_end;
 wire [8:0] command_first=cmd[2][31]?cmd[2][8:0]:9'd0;
 wire [8:0] command_end=cmd[2][31]?cmd[2][24:16]:9'd256;
 wire output_active=state==RESOLVE_START || state==RESOLVE_RUN ||
     state==EDGE_READ || state==EDGE_CENTER || state==EDGE_NEIGHBOR || state==EDGE_APPLY ||
     state==FLUSH_LOAD || state==FLUSH_WAIT || state==FLUSH_WRITE;
 wire [31:0] pixel_config=output_active?output_config:line_config;
 function automatic [1:0] next_bank(input logic [1:0] b);next_bank=b==2?2'd0:b+2'd1;endfunction
 function automatic [1:0] prev_bank(input logic [1:0] b);prev_bank=b==0?2'd2:b-2'd1;endfunction
 logic [7:0] edge_x;
 wire [31:0] edge_attr,edge_depth,edge_color;
 logic [31:0] edge_center_attr,edge_center_depth,edge_center_color;
 logic edge_hit;
 wire edge_border=(edge_phase==0 && x==0) || (edge_phase==1 && x==255) ||
     (edge_phase==2 && output_y==0) || (edge_phase==3 && output_y==191);
 wire [31:0] neighbor_attr=edge_border?edge_border_attr:edge_attr;
 wire [31:0] neighbor_depth=edge_border?edge_border_depth:edge_depth;
 wire [15:0] edge_rgb555=edge_table[16*int'(edge_center_attr[29:27])+:16];
 function automatic [5:0] expand5(input logic [4:0] c);expand5={c,1'b0}+6'(c!=0);endfunction
 wire [31:0] edge_result={edge_center_color[31:24],2'd0,expand5(edge_rgb555[14:10]),
     2'd0,expand5(edge_rgb555[9:5]),2'd0,expand5(edge_rgb555[4:0])};
 always_comb begin
  edge_bank=output_bank;edge_x=x[7:0];
  if(state==EDGE_CENTER)edge_x=x[7:0]-8'd1;
  else if(state==EDGE_NEIGHBOR)case(edge_phase)
   0:edge_x=x[7:0]+8'd1;
   1:edge_bank=prev_bank(output_bank);
   2:edge_bank=next_bank(output_bank);
   default:begin end
  endcase
 end
 logic [1:0] resolve_mode;
 wire pixels_pending,p_depth_pass;
 logic [15:0] w0,w1;
 logic signed [31:0] av[0:4],delta[0:4],steps[0:4];
 logic [15:0] rems[0:4],rsteps[0:4];
 logic [16:0] sums[0:4];
 logic [13:0] zsum;
 logic [12:0] zrem,zrstep;
 logic signed [31:0] zstep,zlinear;
 logic [28:0] tex_addr;

 // Pipelined opaque path; descriptors remain constant until the span drains.
 logic [13:0] p_valid;
 logic [31:0] p_rem[0:9];
 logic [23:0] p_den[0:9];
 logic [8:0] p_f[0:9],p_x[0:13];
 logic signed [15:0] p_av[0:13][0:4];
 logic [31:0] p_z[0:13];
 logic [28:0] p_addr[11:12];
 logic p_half[11:12],p_pass[11:13];
 logic [2:0] p_byte[11:12];
 // Palette reads are consumed only after the complete load has drained.
 // No pixel observes the read-during-write value; permit native MLAB RAMs.
 (* ramstyle="MLAB, no_rw_check" *) logic [31:0] palette_even[0:127],palette_odd[0:127];
 logic [31:0] palette_base;
 logic palette_valid;
 logic [6:0] palette_word;
 wire [63:0] texture_word=p_override?p_override_data:p_cache_q;
 wire [7:0] palette_index=texture_word[8*int'(p_byte[12])+:8];
 logic [15:0] p_ts,p_tt,tex_size_s,tex_size_t,tex_mask_s,tex_mask_t;
 logic [19:0] p_index;
 // Cut the indexed-cache -> palette -> color arithmetic path. The extra
 // stage advances with the same global stall enable as its metadata.
 logic [31:0] p_texel,p_texel_q,p_color;
 logic [15:0] toon_rgb555_q;
 logic [12:0] p_mr,p_mg,p_mb;
 logic [5:0] p_vr,p_vg,p_vb;
 wire [15:0] toon_rgb555=toon_table[16*int'(p_av[12][0][8:4])+:16];
 function automatic [5:0] add_saturate6(input logic [5:0] a,b);
  logic [6:0] sum;
  begin sum={1'b0,a}+{1'b0,b};add_saturate6=sum[6]?6'd63:sum[5:0];end
 endfunction
 logic [11:0] p_ma;
 logic p_ce,p_hit,p_miss,p_bad_alpha,p_override;
 logic [63:0] p_override_data;
 logic [4:0] p_clear_index;
 logic [2:0] tex_beat;
 // Indexed texels need one quarter of the old RGBA cache footprint. Use
 // 32 complete 64-byte lines; the six freed M10Ks hold pixel attributes
 // instead of consuming scarce logic blocks as distributed memory.
 (* ramstyle = "M10K" *) logic [63:0] p_cache_data[0:255];
 (* ramstyle = "M10K" *) logic [21:0] p_cache_tags[0:31];
 logic [63:0] p_cache_q;
 logic [21:0] p_tag_q;
 integer i;

 function automatic [15:0] texture_coord(input logic signed [15:0] value,
    input logic [15:0] size,mask,input logic repeat_mode,input logic flip_mode);
   logic signed [15:0] coord;
   begin
    coord=value>>>4;
    if(repeat_mode)texture_coord=(flip_mode && ((coord&size)!=0))?mask-(coord&mask):(coord&mask);
    else if(coord<0)texture_coord=0;
    else if(coord>$signed(mask))texture_coord=mask;
    else texture_coord=coord;
   end
 endfunction

 function automatic signed [31:0] p_interpolate(input signed [31:0] base_value,
  input signed [31:0] delta_value,input [8:0] factor);
  logic signed [41:0] product_value;
  begin product_value=delta_value*$signed({1'b0,factor});
   p_interpolate=base_value+32'(product_value>>>8);end
 endfunction
 function automatic [5:0] decal_channel(input logic [5:0] texel,vertex,input logic [4:0] alpha);
  logic signed [7:0] difference;
  logic signed [14:0] product_value,total;
  begin
   difference=$signed({2'b00,texel})-$signed({2'b00,vertex});
   product_value=difference*$signed({1'b0,alpha});
   total=$signed({4'd0,vertex,5'd0})-$signed({9'd0,vertex})+product_value;
   decal_channel=alpha==0?vertex:alpha==31?texel:total[10:5];
  end
 endfunction
 function automatic [31:0] p_interpolate_z(input [31:0] base_value,end_value,input [8:0] factor);
  logic signed [32:0] delta_value;logic signed [42:0] product_value;
  begin delta_value=$signed({1'b0,end_value})-$signed({1'b0,base_value});
   product_value=delta_value*$signed({1'b0,factor});
   p_interpolate_z=base_value+32'(product_value>>>8);end
 endfunction
 always_comb begin
  p_ts=texture_coord(p_av[10][3][15:0],tex_size_s,tex_mask_s,cmd[14][8],cmd[14][10]);
  p_tt=texture_coord(p_av[10][4][15:0],tex_size_t,tex_mask_t,cmd[14][9],cmd[14][11]);
  p_index=(20'(p_tt)<<cmd[14][3:0])+20'(p_ts);
  p_hit=p_override || p_tag_q=={1'b1,p_addr[12][28:8]};
  p_texel=cmd[14][12]?(palette_index[0]?palette_odd[palette_index[7:1]]:palette_even[palette_index[7:1]]):
                       (p_half[12]?texture_word[63:32]:texture_word[31:0]);
  p_vr=p_av[13][0][8:3];p_vg=p_av[13][1][8:3];p_vb=p_av[13][2][8:3];
  if(cmd[31][12])begin
   if(line_config[1])begin p_vg=p_vr;p_vb=p_vr;end
   else begin p_vr=expand5(toon_rgb555_q[4:0]);p_vg=expand5(toon_rgb555_q[9:5]);p_vb=expand5(toon_rgb555_q[14:10]);end
  end
  p_mr=({1'b0,p_texel_q[5:0]}+7'd1)*({1'b0,p_vr}+7'd1)-13'd1;
  p_mg=({1'b0,p_texel_q[13:8]}+7'd1)*({1'b0,p_vg}+7'd1)-13'd1;
  p_mb=({1'b0,p_texel_q[21:16]}+7'd1)*({1'b0,p_vb}+7'd1)-13'd1;
  p_ma=({1'b0,p_texel_q[28:24]}+6'd1)*({1'b0,cmd[31][4:0]}+6'd1)-12'd1;
  p_color=cmd[2][2]?{3'd0,p_ma[9:5],2'd0,p_mb[11:6],2'd0,p_mg[11:6],2'd0,p_mr[11:6]}:
             {3'd0,cmd[31][4:0],2'd0,p_vb,2'd0,p_vg,2'd0,p_vr};
  if(cmd[2][2] && cmd[31][10])p_color={3'd0,cmd[31][4:0],
      2'd0,decal_channel(p_texel_q[21:16],p_av[13][2][8:3],p_texel_q[28:24]),
      2'd0,decal_channel(p_texel_q[13:8],p_av[13][1][8:3],p_texel_q[28:24]),
      2'd0,decal_channel(p_texel_q[5:0],p_av[13][0][8:3],p_texel_q[28:24])};
  if(cmd[31][12] && line_config[1])p_color={p_color[31:24],
      2'd0,add_saturate6(p_color[21:16],expand5(toon_rgb555_q[14:10])),
      2'd0,add_saturate6(p_color[13:8],expand5(toon_rgb555_q[9:5])),
      2'd0,add_saturate6(p_color[5:0],expand5(toon_rgb555_q[4:0]))};
  p_miss=p_valid[12] && p_pass[12] && cmd[2][2] && !p_hit;
  p_bad_alpha=p_valid[12] && p_pass[12] && cmd[2][2] && p_hit && p_texel[31:24]>31;
  p_ce=state==PIPE_RUN && !reset && enable && !p_miss && !p_bad_alpha;
 end
 always_ff @(posedge clk)begin
  if(state==PALETTE_WAIT && dout_ready)begin
   palette_even[palette_word]<=dout[31:0];palette_odd[palette_word]<=dout[63:32];
  end
  if(state==CACHE_CLEAR)p_cache_tags[p_clear_index]<=0;
  else if(state==TEX_WAIT && dout_ready)begin
   if(tex_beat==7)p_cache_tags[tex_addr[7:3]]<={1'b1,tex_addr[28:8]};
   p_cache_data[{tex_addr[7:3],tex_beat}]<=dout;
  end
  if(p_ce)begin
   p_cache_q<=p_cache_data[p_addr[11][7:0]];
   p_tag_q<=p_cache_tags[p_addr[11][7:3]];
  end
  if(reset || !enable || state==DECODE)begin p_valid<=0;p_override<=0;end
  else begin
   if(state==TEX_WAIT && dout_ready)begin if(tex_beat==7)p_override<=1; if(tex_beat==tex_addr[2:0])p_override_data<=dout;end
   if(p_ce)begin
    p_override<=0;p_valid<={p_valid[12:0],x<last};
    p_x[0]<=x;p_z[0]<=zlinear;
    p_rem[0]<=32'(dx)*32'(w0)<<8;
    p_den[0]<=32'(dx)*32'(w0)+(32'(span_width)-32'(dx))*32'(w1);
    p_f[0]<=0;
    for(integer a=0;a<5;a=a+1)p_av[0][a]<=av[a];
    for(integer k=1;k<=9;k=k+1)begin
     p_x[k]<=p_x[k-1];p_z[k]<=p_z[k-1];
     p_den[k]<=p_den[k-1];p_rem[k]<=p_rem[k-1];p_f[k]<=p_f[k-1];
     for(integer a=0;a<5;a=a+1)p_av[k][a]<=p_av[k-1][a];
     if((!cmd[2][0] || cmd[2][1]) && p_den[k-1]!=0 && p_rem[k-1]>=(32'(p_den[k-1])<<(9-k)))begin
      p_rem[k]<=p_rem[k-1]-(32'(p_den[k-1])<<(9-k));p_f[k]<=p_f[k-1]|(9'd1<<(9-k));
     end
    end
    p_x[10]<=p_x[9];
    p_z[10]<=cmd[2][1] && !cmd[31][13]?p_interpolate_z(cmd[15],cmd[26],p_f[9]):p_z[9];
    for(integer a=0;a<5;a=a+1)
     p_av[10][a]<=cmd[2][0]?p_av[9][a]:p_interpolate($signed({{16{cmd[8+a][15]}},cmd[8+a][15:0]}),delta[a],p_f[9]);
    p_x[11]<=p_x[10];p_z[11]<=p_z[10];p_pass[11]<=1'b1;
    p_addr[11]<=29'(cmd[13]>>3)+(cmd[14][12]?29'd128+29'(p_index>>3):29'(p_index>>1));
    p_half[11]<=p_index[0];p_byte[11]<=p_index[2:0];
    p_x[12]<=p_x[11];p_z[12]<=p_z[11];p_pass[12]<=p_depth_pass;
    p_addr[12]<=p_addr[11];p_half[12]<=p_half[11];p_byte[12]<=p_byte[11];
    p_x[13]<=p_x[12];p_z[13]<=p_z[12];p_pass[13]<=p_pass[12];
    p_texel_q<=p_texel;toon_rgb555_q<=toon_rgb555;
    for(integer a=0;a<3;a=a+1)p_av[13][a]<=p_av[12][a];
    for(integer a=0;a<3;a=a+1)begin p_av[11][a]<=p_av[10][a];p_av[12][a]<=p_av[11][a];end
   end
  end
 end
 always_comb begin
  rd=0;wr=0;burst=1;addr=MB;din=0;be=8'hff;
  case(state)
   INIT,POLL:begin rd=1;addr=MB;end
   READY:begin wr=1;addr=MB+3;din={epoch,MAGIC};end
   HEADER,REFILL:begin rd=1;addr=MB+1;end
   PARAM:begin rd=1;addr=MB+7;end
   FETCH:begin rd=1;burst=fetch_words;addr=command_address;end
   STENCIL_READ:begin rd=1;burst=64;addr=29'h07f901c0;end
   DUMP_WRITE:begin wr=1;addr=OUT+29'h6000+29'(stencil_index[8:3]);din=stencil_output_word;end
   TEX_READ:begin rd=1;burst=8;addr={tex_addr[28:3],3'd0};end
   PALETTE_READ:begin rd=1;burst=8;addr=29'(cmd[13]>>3)+29'(palette_word);end
   FLUSH_WRITE:begin wr=1;burst=128;addr=OUT+(output_y<<7);din=flush_pair;end
   COMPLETE:begin wr=1;addr=MB+2;din={status,seq};end
   default:begin end
  endcase
  // Finish any physical row burst already accepted by the fabric before
  // obeying enable loss. Reset also resets the complete shared fabric.
  if(reset || (!enable && !flush_inflight))begin rd=0;wr=0;end
  for(integer k=0;k<5;k=k+1)sums[k]={1'b0,rems[k]}+{1'b0,rsteps[k]};
  zsum={1'b0,zrem}+{1'b0,zrstep};
 end
 nds_fpga3d_pixels #(.RASTER_DELAY(3)) pixels(
  .clk,.reset(reset || (!enable && !flush_inflight)),
  .bank(output_active?output_bank:render_bank),
  .color_bank(output_active?output_y[0]:line_y[0]),
  .edge_read(enable && !reset && (state==EDGE_READ || state==EDGE_CENTER || (state==EDGE_NEIGHBOR && edge_phase<3))),
  .edge_bank,.edge_x,.edge_attr,.edge_depth,.edge_color,
  .edge_write(enable && !reset && state==EDGE_APPLY && edge_hit && edge_center_attr[3:0]!=0),
  .edge_write_x(x[7:0]),.edge_write_color(edge_result),
  .edge_write_attr((edge_center_attr&32'hffffe0ff)|32'h00001000),
  .ce(p_ce || (state==RESOLVE_RUN && enable && !reset)),
  .clear_we(state==CLEAR_LINE && enable && !reset),.clear_x(x[7:0]),
  .clear_color(cmd[1]),.clear_depth(cmd[2]),.clear_attr(cmd[5]|(cmd[3][0]?32'd16:32'd0)),
  .span_start(state==DECODE && cmd[0]==2 && !cmd[31][14]),.flags(cmd[2][5:0]),
  .poly_attr(cmd[27]),.left_cov(cmd[28]),.right_cov(cmd[29]),
  .left_end(cmd[30][8:0]),.right_begin(cmd[30][24:16]),.y_edge(cmd[31][9:6]),
  .antialias(pixel_config[4]),.blend_enable(pixel_config[3]),.translucent_depth_write(cmd[31][5]),
  .precheck_valid(p_valid[10]),.precheck_x(p_x[10][7:0]),.precheck_depth(p_z[10]),.precheck_pass(p_depth_pass),
  .pixel_valid(p_ce && p_valid[13] && p_pass[13] && p_color[31:24]>cmd[2][12:8]),
  .resolve_valid(state==RESOLVE_RUN && x<output_end),.resolve_mode,
  .shadow_mode(cmd[31][11:10]),.stencil_row(line_y[0]),
  .stencil_frame_start(state==CACHE_CLEAR && p_clear_index==0),
  .stencil_clear(state==DECODE && cmd[0]==5 && line_open && cmd[1]==line_y),
  .stencil_seed_we(state==SEED_WRITE),.stencil_seed_index(stencil_index),
  .stencil_seed_bits(command_cache_q[8*int'(stencil_index[2:0])+:2]),
  .stencil_dump_en(state==DUMP_READ),.stencil_dump_index(stencil_index),.stencil_dump_value,
  .fog_color,.fog_offset,.fog_shift,.fog_table,.fog_alpha_only(pixel_config[6]),
  .pixel_x(state==RESOLVE_RUN?x[7:0]:p_x[13][7:0]),.pixel_color(p_color),.pixel_depth(p_z[13]),
  .pending(pixels_pending),
  .flush_en(state==FLUSH_LOAD || state==FLUSH_WAIT || (state==FLUSH_WRITE && accepted)),
  .flush_index(flush_read),.flush_pair
 );
 always_ff @(posedge clk)begin
  if(reset || (!enable && !flush_inflight))begin
   state<=INIT;seen<=0;seq<=0;index<=0;status<=0;epoch<=session;poll<=0;
   line_open<=0;line_y<=0;flush_x<=0;x<=0;flush_inflight<=0;line_config<=0;fog_configured<=0;resolve_mode<=0;
   edge_configured<=0;render_bank<=0;output_bank<=0;output_y<=0;output_config<=0;edge_hit<=0;edge_phase<=0;
   palette_valid<=0;palette_word<=0;
   toon_configured<=0;
   coverage_valid<=0;
   output_first<=0;output_end<=256;
  end else begin
   if((state==FLUSH_WRITE || state==DUMP_WRITE) && !busy)flush_inflight<=1;
   case(state)
    INIT:if(!busy)begin epoch<=session;state<=INIT_WAIT;end
    INIT_WAIT:if(dout_ready)begin seen<=dout[63:32];state<=READY;end
    READY:if(!busy)begin poll<=0;state<=POLL_DELAY;end
    POLL_DELAY:if(poll==POLL_CYCLES-1)state<=POLL;else poll<=poll+1'b1;
    POLL:if(!busy)state<=POLL_WAIT;
    POLL_WAIT:if(dout_ready)begin
     if(dout[31:0]==MAGIC && dout[63:32]!=0 && dout[63:32]!=seen)begin
      seq<=dout[63:32];seen<=dout[63:32];state<=HEADER;
     end else begin poll<=0;state<=POLL_DELAY;end
    end
    HEADER:if(!busy)state<=HEADER_WAIT;
    HEADER_WAIT:if(dout_ready)begin
     status<=0;index<=0;cached_commands<=0;cache_slot<=0;line_y<=0;line_open<=0;p_clear_index<=0;fog_configured<=0;
     edge_configured<=0;render_bank<=0;
     palette_valid<=0;
     toon_configured<=0;
     count<={1'b0,dout[30:0]};producer_final<=dout[31];
     if(dout[63:32]!=epoch || epoch!=session)begin status<=2;state<=COMPLETE;end
     else if(dout[30:0]>8128)begin status<=1;state<=COMPLETE;end
     else state<=PARAM;
    end
    PARAM:if(!busy)state<=PARAM_WAIT;
    PARAM_WAIT:if(dout_ready)begin
     command_base<=param_base;texture_end<=(param_device || param_padded)?32'h3fe00000:param_base;capacity<=param_capacity;
     if((!param_device && !param_wc && !param_padded) || count>param_capacity)begin status<=1;state<=COMPLETE;end
     else state<=CACHE_CLEAR;
    end
    CACHE_CLEAR:if(p_clear_index==31)state<=STENCIL_READ;else p_clear_index<=p_clear_index+1'b1;
    STENCIL_READ:if(!busy)begin cache_fill_beat<=0;stencil_index<=0;state<=STENCIL_WAIT;end
    STENCIL_WAIT:if(dout_ready)begin
     if(cache_fill_beat==63)state<=SEED_READ;else cache_fill_beat<=cache_fill_beat+1'b1;
    end
    SEED_READ:state<=SEED_WRITE;
    SEED_WRITE:begin
     if(stencil_index==511)state<=AVAILABLE;
     else begin stencil_index<=stencil_index+1'b1;if(stencil_index[2:0]==7)state<=SEED_READ;end
    end
    AVAILABLE:begin
     if(index<count)begin
      if(cached_commands!=0 && next_ready)begin
       for(integer j=0;j<8;j=j+1)begin
        cmd[2*j]<=next_descriptor[j][31:0];cmd[2*j+1]<=next_descriptor[j][63:32];
       end
       state<=UNPACK;
      end else state<=cached_commands!=0?CMD_LOAD_FIRST:FETCH;
     end
     else if(producer_final)begin
      if(line_open || line_y!=192)begin status<=1;state<=COMPLETE;end
      else begin stencil_index<=0;stencil_output_word<=0;state<=DUMP_READ;end
     end else begin poll<=0;state<=REFILL_DELAY;end
    end
    REFILL_DELAY:if(poll==15)state<=REFILL;else poll<=poll+1'b1;
    REFILL:if(!busy)state<=REFILL_WAIT;
    REFILL_WAIT:if(dout_ready)begin
     if(dout[63:32]!=epoch || epoch!=session)begin status<=2;state<=COMPLETE;end
     else if(dout[30:0]<count || dout[30:0]>capacity)begin status<=1;state<=COMPLETE;end
     else begin count<={1'b0,dout[30:0]};producer_final<=dout[31];state<=AVAILABLE;end
    end
    FETCH:if(!busy)begin
     cached_commands<=fetch_commands;cache_slot<=0;cache_fill_beat<=0;cache_last_beat<=fetch_words-1'b1;state<=FETCH_WAIT;
    end
    FETCH_WAIT:if(dout_ready)begin
     if(cache_fill_beat==cache_last_beat)state<=CMD_LOAD_FIRST;else cache_fill_beat<=cache_fill_beat+1'b1;
    end
    CMD_LOAD_FIRST:begin beat<=0;state<=CMD_LOAD;end
    CMD_LOAD:begin
     cmd[{beat,1'b0}]<=command_cache_q[31:0];cmd[{beat,1'b1}]<=command_cache_q[63:32];
     if(beat==7)state<=UNPACK;else beat<=beat+1'b1;
    end
    UNPACK:begin
     for(integer k=0;k<32;k=k+1)cmd[k]<=0;
     state<=DECODE;
     if(packed_command[511])cmd[0]<=99;
     else if(packed_command[2:0]==2)begin
      cmd[0]<=2;
      cmd[1]<={7'd0,(packed_command[11+:8]==0?9'd256:{1'b0,packed_command[11+:8]}),8'd0,packed_command[3+:8]};
      cmd[2]<={19'd0,packed_command[41+:5],2'd0,packed_command[35+:6]};
      cmd[3]<={8'd0,packed_command[27+:8],7'd0,(packed_command[19+:8]==0?9'd256:{1'b0,packed_command[19+:8]})};
      cmd[4]<=packed_command[102+:32];
      cmd[5]<={packed_command[500]?packed_command[501+:8]:8'd0,packed_command[54+:24]};
      cmd[6]<={{8{packed_command[101]}},packed_command[78+:24]};
      cmd[7]<={3'd0,packed_command[482+:13],3'd0,packed_command[469+:13]};
      cmd[13]<=32'h3fd40000+{12'd0,packed_command[134+:17],3'd0};
      cmd[14]<={19'd0,packed_command[497],packed_command[157+:4],(4'd3+{1'b0,packed_command[154+:3]}),(4'd3+{1'b0,packed_command[151+:3]})};
      cmd[15]<={8'd0,packed_command[54+:24]};cmd[26]<={8'd0,packed_command[78+:24]};
      cmd[27]<={2'd0,packed_command[161+:6],8'd0,packed_command[168],10'd0,packed_command[167],4'd0};
      cmd[28]<={packed_command[189],9'd0,packed_command[179+:10],2'd0,packed_command[169+:10]};
      cmd[29]<={packed_command[210],9'd0,packed_command[200+:10],2'd0,packed_command[190+:10]};
      cmd[30]<={7'd0,packed_command[220+:9],7'd0,packed_command[211+:9]};
      cmd[31]<={17'd0,packed_command[499],packed_command[500],packed_command[498],packed_command[495+:2],packed_command[52+:2],2'd0,packed_command[51],packed_command[46+:5]};
      cmd[8]<=packed_command[35]?{16'd0,packed_command[229+:16]}:packed_command[229+:32];
      cmd[16]<={{16{packed_command[260]}},packed_command[245+:16]};
      cmd[21]<={8'd0,packed_command[397+:8],8'd0,packed_command[389+:8]};
      cmd[9]<=packed_command[35]?{16'd0,packed_command[261+:16]}:packed_command[261+:32];
      cmd[17]<={{16{packed_command[292]}},packed_command[277+:16]};
      cmd[22]<={8'd0,packed_command[413+:8],8'd0,packed_command[405+:8]};
      cmd[10]<=packed_command[35]?{16'd0,packed_command[293+:16]}:packed_command[293+:32];
      cmd[18]<={{16{packed_command[324]}},packed_command[309+:16]};
      cmd[23]<={8'd0,packed_command[429+:8],8'd0,packed_command[421+:8]};
      cmd[11]<=packed_command[35]?{16'd0,packed_command[325+:16]}:packed_command[325+:32];
      cmd[19]<={{16{packed_command[356]}},packed_command[341+:16]};
      cmd[24]<={8'd0,packed_command[445+:8],8'd0,packed_command[437+:8]};
      cmd[12]<=packed_command[35]?{16'd0,packed_command[357+:16]}:packed_command[357+:32];
      cmd[20]<={{16{packed_command[388]}},packed_command[373+:16]};
      cmd[25]<={8'd0,packed_command[461+:8],8'd0,packed_command[453+:8]};
     end else if(packed_command[31:0]==1)begin
      for(integer k=0;k<7;k=k+1)cmd[k]<=packed_command[32*k+:32];
     end else if(packed_command[31:0]==3 || packed_command[31:0]==5)begin
      cmd[0]<=packed_command[31:0];cmd[1]<=packed_command[32+:32];cmd[2]<=packed_command[64+:32];
     end else if(packed_command[31:0]==4)begin
      for(integer k=0;k<13;k=k+1)cmd[k]<=packed_command[32*k+:32];
     end else if(packed_command[31:0]==6)begin
      for(integer k=0;k<7;k=k+1)cmd[k]<=packed_command[32*k+:32];
     end else if(packed_command[31:0]==7)begin
      for(integer k=0;k<10;k=k+1)cmd[k]<=packed_command[32*k+:32];
     end else cmd[0]<=99;
    end
    DECODE:begin
     if(cmd[0]==4 && !fog_configured && !line_open && line_y==0 && cmd[3]<=15)begin
      fog_color<=cmd[1];fog_offset<=cmd[2];fog_shift<=cmd[3][3:0];
      for(integer f=0;f<34;f=f+1)fog_table[8*f+:8]<=cmd[4+f/4][8*(f%4)+:8];
      fog_configured<=1;state<=NEXT_COMMAND;
     end else if(cmd[0]==6 && !edge_configured && !line_open && line_y==0)begin
      edge_border_depth<=cmd[1];edge_border_attr<=cmd[2];
      for(integer e=0;e<4;e=e+1)edge_table[32*e+:32]<=cmd[3+e];
      edge_configured<=1;state<=NEXT_COMMAND;
     end else if(cmd[0]==7 && cmd[1]<=1 && !toon_configured[cmd[1][0]] && !line_open && line_y==0)begin
      for(integer t=0;t<8;t=t+1)toon_table[256*int'(cmd[1][0])+32*t+:32]<=cmd[2+t];
      toon_configured[cmd[1][0]]<=1;state<=NEXT_COMMAND;
     end else if(cmd[0]==5 && line_open && cmd[1]==line_y)begin
      state<=NEXT_COMMAND;
     end else if(cmd[0]==1 && !line_open && line_y<192 && cmd[4]==line_y &&
       (!cmd[6][7] || fog_configured) && (!cmd[6][5] || edge_configured))begin
      x<=0;line_open<=1;line_config<=cmd[6];row_config[render_bank]<=cmd[6];coverage_valid<=0;state<=CLEAR_LINE;
     end else if(cmd[0]==3 && line_open && cmd[1]==line_y &&
       (cmd[2]==0 || (cmd[2][31] && cmd[2][15:0]<={1'b0,cmd[2][30:16]} && cmd[2][30:16]<=256)))begin
      row_first[render_bank]<=command_first;row_end[render_bank]<=command_end;
      if(edge_configured && line_y==0)begin
       line_open<=0;line_y<=1;render_bank<=next_bank(render_bank);state<=NEXT_COMMAND;
      end else begin
       output_bank<=edge_configured?prev_bank(render_bank):render_bank;
       output_y<=edge_configured?line_y-9'd1:line_y;
       output_config<=edge_configured?row_config[prev_bank(render_bank)]:line_config;
       output_first<=edge_configured?row_first[prev_bank(render_bank)]:command_first;
       output_end<=edge_configured?row_end[prev_bank(render_bank)]:command_end;
       state<=RESOLVE_START;
      end
     end else if(cmd[0]==2 && line_open && cmd[1][15:0]<cmd[1][31:16] &&
       cmd[1][31:16]<=256 && cmd[30][15:0]<=cmd[30][31:16] && cmd[30][31:16]<=256 &&
       cmd[31][31:15]==0 && cmd[31][12:10]<=4 && (!cmd[31][12] || toon_configured==3) &&
       (!cmd[31][14] || coverage_valid) &&
       (!cmd[31][13] || (cmd[3]==1 && cmd[1][31:16]==cmd[1][15:0]+16'd1 && cmd[2][0])) &&
       cmd[3][15:0]>0 && cmd[3][15:0]<=256 &&
       ({1'b0,cmd[3][31:16]}+{1'b0,cmd[1][31:16]}-{1'b0,cmd[1][15:0]})<={1'b0,cmd[3][15:0]} &&
       (!cmd[2][2] || (cmd[13]>=32'h3fd40000 && cmd[13][2:0]==0 &&
          cmd[14][3:0]>=3 && cmd[14][3:0]<=10 && cmd[14][7:4]>=3 && cmd[14][7:4]<=10 &&
          (!cmd[14][12] || cmd[13][5:0]==0) &&
          ({1'b0,cmd[13]}+(cmd[14][12]?
             33'd1024+(33'd1<<({1'b0,cmd[14][3:0]}+{1'b0,cmd[14][7:4]})):
             (33'd4<<({1'b0,cmd[14][3:0]}+{1'b0,cmd[14][7:4]}))))<={1'b0,texture_end})))begin
      x<=cmd[1][8:0];last<=cmd[1][24:16];span_width<=cmd[3][9:0];dx<=cmd[3][24:16];
      coverage_valid<=1;
      w0<=cmd[4][15:0];w1<=cmd[4][31:16];
      tex_size_s<=16'd1<<cmd[14][3:0];tex_mask_s<=(16'd1<<cmd[14][3:0])-16'd1;
      tex_size_t<=16'd1<<cmd[14][7:4];tex_mask_t<=(16'd1<<cmd[14][7:4])-16'd1;
      zlinear<=$signed(cmd[5]);zstep<=$signed(cmd[6]);zrem<=cmd[7][12:0];zrstep<=cmd[7][28:16];
      for(i=0;i<5;i=i+1)begin
       av[i]<={{16{cmd[8+i][15]}},cmd[8+i][15:0]};
       delta[i]<=$signed({{16{cmd[8+i][31]}},cmd[8+i][31:16]})-$signed({{16{cmd[8+i][15]}},cmd[8+i][15:0]});
       steps[i]<=$signed(cmd[16+i]);rems[i]<=cmd[21+i][15:0];rsteps[i]<=cmd[21+i][31:16];
      end
      if(cmd[2][2] && cmd[14][12] && (!palette_valid || palette_base!=cmd[13]))begin
       palette_word<=0;palette_valid<=0;state<=PALETTE_READ;
      end else state<=PIPE_RUN;
     end else begin status<=1;state<=COMPLETE;end
    end
    CLEAR_LINE:if(x==255)state<=NEXT_COMMAND;else x<=x+1'b1;
    TEX_READ:if(!busy)begin tex_beat<=0;state<=TEX_WAIT;end
    TEX_WAIT:if(dout_ready)begin if(tex_beat==7)state<=PIPE_RUN;else tex_beat<=tex_beat+1'b1;end
    PALETTE_READ:if(!busy)state<=PALETTE_WAIT;
    PALETTE_WAIT:if(dout_ready)begin
     palette_word<=palette_word+1'b1;
     if(palette_word==127)begin palette_base<=cmd[13];palette_valid<=1;state<=PIPE_RUN;end
     else if(palette_word[2:0]==7)state<=PALETTE_READ;
    end
    PIPE_RUN:begin
     if(p_bad_alpha)begin status<=3;state<=COMPLETE;end
     else if(p_miss)begin tex_addr<=p_addr[12];state<=TEX_READ;end
     else if(p_ce)begin
      if(x<last)begin
       x<=x+1'b1;dx<=dx+1'b1;
       zlinear<=zlinear+zstep+32'(zsum>=8192);zrem<=zsum[12:0];
       if(cmd[2][0])for(i=0;i<5;i=i+1)begin
        av[i]<=av[i]+steps[i]+32'(sums[i]>={7'd0,span_width});
        rems[i]<=16'(sums[i]>={7'd0,span_width}?sums[i]-{7'd0,span_width}:sums[i]);
       end
      end else if(p_valid==0 && !pixels_pending)state<=NEXT_COMMAND;
     end
    end
    RESOLVE_START:begin
     x<=output_first;flush_x<=0;resolve_mode<=output_config[7]?2'd1:2'd3;
     state<=output_first==output_end?FLUSH_LOAD:output_config[5]?EDGE_READ:(output_config[4] || output_config[7])?RESOLVE_RUN:FLUSH_LOAD;
    end
    EDGE_READ:state<=EDGE_CENTER;
    EDGE_CENTER:begin
     edge_center_attr<=edge_attr;edge_center_depth<=edge_depth;edge_center_color<=edge_color;
     edge_phase<=0;edge_hit<=0;state<=EDGE_NEIGHBOR;
    end
    EDGE_NEIGHBOR:begin
     if(edge_center_attr[31:24]!=neighbor_attr[31:24] && edge_center_depth<neighbor_depth)edge_hit<=1;
     if(edge_phase==3)state<=EDGE_APPLY;else edge_phase<=edge_phase+1'b1;
    end
    EDGE_APPLY:begin
     if(x+9'd1==output_end)begin x<=output_first;state<=(output_config[4] || output_config[7])?RESOLVE_RUN:FLUSH_LOAD;end
     else begin x<=x+1'b1;state<=EDGE_READ;end
    end
    RESOLVE_RUN:begin
     if(x<output_end)x<=x+1'b1;
     else if(!pixels_pending)begin
      if(resolve_mode==1)begin resolve_mode<=2; x<=output_first;end
      else if(resolve_mode==2 && output_config[4])begin resolve_mode<=3;x<=output_first;end
      else state<=FLUSH_LOAD;
     end
    end
    FLUSH_LOAD:state<=FLUSH_WAIT;
    FLUSH_WAIT:state<=FLUSH_WRITE;
    FLUSH_WRITE:if(accepted)begin
     if(flush_x==254)begin
      flush_inflight<=0;
      if(edge_configured && line_y==191 && output_y==190)begin
       output_bank<=render_bank;output_y<=191;output_config<=line_config;state<=RESOLVE_START;
       output_first<=row_first[render_bank];output_end<=row_end[render_bank];
      end else begin
       line_open<=0;line_y<=line_y+1'b1;render_bank<=next_bank(render_bank);state<=NEXT_COMMAND;
      end
     end
     else flush_x<=flush_x+2;
    end
    DUMP_READ:state<=DUMP_PACK;
    DUMP_PACK:begin
     stencil_output_word[8*int'(stencil_index[2:0])+:8]<={6'd0,stencil_dump_value};
     if(stencil_index[2:0]==7)state<=DUMP_WRITE;
     else begin stencil_index<=stencil_index+1'b1;state<=DUMP_READ;end
    end
    DUMP_WRITE:if(accepted)begin
     flush_inflight<=0;
     if(stencil_index==511)state<=COMPLETE;
     else begin stencil_index<=stencil_index+1'b1;state<=DUMP_READ;end
    end
    NEXT_COMMAND:begin index<=index+1'b1;cached_commands<=cached_commands-1'b1;cache_slot<=cache_slot+1'b1;state<=AVAILABLE;end
    COMPLETE:if(!busy)begin poll<=0;state<=POLL_DELAY;end
    default:state<=INIT;
   endcase
  end
 end
endmodule
