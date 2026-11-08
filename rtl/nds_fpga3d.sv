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
 localparam [31:0] MAGIC=32'h32443346;
 typedef enum logic[5:0] {INIT,INIT_WAIT,READY,POLL_DELAY,POLL,POLL_WAIT,
 HEADER,HEADER_WAIT,FETCH,FETCH_WAIT,DECODE,CLEAR_LINE,
 TEX_READ,TEX_WAIT,
 FLUSH_LOAD,FLUSH_WAIT,FLUSH_WRITE,NEXT_COMMAND,COMPLETE,CACHE_CLEAR,PIPE_RUN,RESOLVE_RUN} state_t;
 state_t state;
 logic [31:0] cmd[0:31];
 logic [31:0] seq,seen,count,index,status,epoch;
 logic [15:0] poll;
 logic [3:0] beat;
 logic [8:0] x,last,dx,line_y,flush_x;
 logic [9:0] span_width;
 logic line_open,flush_inflight;
 wire [6:0] flush_read=(state==FLUSH_WRITE && accepted)?flush_x[7:1]+7'd1:flush_x[7:1];
 wire [63:0] flush_pair;
 logic [31:0] line_config,fog_color,fog_offset;
 logic [3:0] fog_shift;
 logic [271:0] fog_table;
 logic fog_configured;
 logic [1:0] resolve_mode;
 wire pixels_pending;
 logic [15:0] w0,w1;
 logic signed [31:0] av[0:4],delta[0:4],steps[0:4];
 logic [15:0] rems[0:4],rsteps[0:4];
 logic [16:0] sums[0:4];
 logic [13:0] zsum;
 logic [12:0] zrem,zrstep;
 logic signed [31:0] zstep,zlinear;
 logic [28:0] tex_addr;

 // Pipelined opaque path; descriptors remain constant until the span drains.
 logic [12:0] p_valid;
 logic [31:0] p_rem[0:9],p_den[0:9];
 logic [8:0] p_f[0:9],p_x[0:12];
 logic signed [31:0] p_av[0:12][0:4];
 logic [31:0] p_z[0:12];
 logic [28:0] p_addr[11:12];
 logic p_half[11:12],p_pass[11:12];
 logic [15:0] p_ts,p_tt;
 logic [19:0] p_index;
 logic [31:0] p_texel,p_color;
 logic [12:0] p_mr,p_mg,p_mb;
 logic [11:0] p_ma;
 logic p_ce,p_hit,p_miss,p_bad_alpha,p_override;
 logic [63:0] p_override_data;
 logic [8:0] p_clear_index;
 (* ramstyle = "M10K" *) logic [63:0] p_cache_data[0:511];
 (* ramstyle = "M10K" *) logic [20:0] p_cache_tags[0:511];
 logic [63:0] p_cache_q;
 logic [20:0] p_tag_q;
 integer i;

 function automatic [15:0] texture_coord(input logic signed [15:0] value,
    input logic [3:0] shift,input logic repeat_mode,input logic flip_mode);
   logic signed [15:0] coord;
   logic [15:0] size,mask;
   begin
    coord=value>>>4;size=16'd1<<shift;mask=size-1'b1;
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
 function automatic [31:0] p_interpolate_z(input [31:0] base_value,end_value,input [8:0] factor);
  logic signed [32:0] delta_value;logic signed [42:0] product_value;
  begin delta_value=$signed({1'b0,end_value})-$signed({1'b0,base_value});
   product_value=delta_value*$signed({1'b0,factor});
   p_interpolate_z=base_value+32'(product_value>>>8);end
 endfunction
 always_comb begin
  p_ts=texture_coord(p_av[10][3][15:0],cmd[14][3:0],cmd[14][8],cmd[14][10]);
  p_tt=texture_coord(p_av[10][4][15:0],cmd[14][7:4],cmd[14][9],cmd[14][11]);
  p_index=(20'(p_tt)<<cmd[14][3:0])+20'(p_ts);
  p_hit=p_override || p_tag_q=={1'b1,p_addr[12][28:9]};
  p_texel=p_override ? (p_half[12]?p_override_data[63:32]:p_override_data[31:0]) :
                       (p_half[12]?p_cache_q[63:32]:p_cache_q[31:0]);
  p_mr=({1'b0,p_texel[5:0]}+7'd1)*({1'b0,p_av[12][0][8:3]}+7'd1)-13'd1;
  p_mg=({1'b0,p_texel[13:8]}+7'd1)*({1'b0,p_av[12][1][8:3]}+7'd1)-13'd1;
  p_mb=({1'b0,p_texel[21:16]}+7'd1)*({1'b0,p_av[12][2][8:3]}+7'd1)-13'd1;
  p_ma=({1'b0,p_texel[28:24]}+6'd1)*({1'b0,cmd[31][4:0]}+6'd1)-12'd1;
  p_color=cmd[2][2]?{3'd0,p_ma[9:5],2'd0,p_mb[11:6],2'd0,p_mg[11:6],2'd0,p_mr[11:6]}:
             {3'd0,cmd[31][4:0],2'd0,p_av[12][2][8:3],2'd0,p_av[12][1][8:3],2'd0,p_av[12][0][8:3]};
  p_miss=p_valid[12] && p_pass[12] && cmd[2][2] && !p_hit;
  p_bad_alpha=p_valid[12] && p_pass[12] && cmd[2][2] && p_hit && p_texel[31:24]>31;
  p_ce=state==PIPE_RUN && !reset && enable && !p_miss && !p_bad_alpha;
 end
 always_ff @(posedge clk)begin
  if(state==CACHE_CLEAR)p_cache_tags[p_clear_index]<=0;
  else if(state==TEX_WAIT && dout_ready)begin
   p_cache_tags[tex_addr[8:0]]<={1'b1,tex_addr[28:9]};
   p_cache_data[tex_addr[8:0]]<=dout;
  end
  if(p_ce)begin
   p_cache_q<=p_cache_data[p_addr[11][8:0]];
   p_tag_q<=p_cache_tags[p_addr[11][8:0]];
  end
  if(reset || !enable || state==DECODE)begin p_valid<=0;p_override<=0;end
  else begin
   if(state==TEX_WAIT && dout_ready)begin p_override<=1;p_override_data<=dout;end
   if(p_ce)begin
    p_override<=0;p_valid<={p_valid[11:0],x<last};
    p_x[0]<=x;p_z[0]<=zlinear;
    p_rem[0]<=32'(dx)*32'(w0)<<8;
    p_den[0]<=32'(dx)*32'(w0)+(32'(span_width)-32'(dx))*32'(w1);
    p_f[0]<=0;
    for(integer a=0;a<5;a=a+1)p_av[0][a]<=av[a];
    for(integer k=1;k<=9;k=k+1)begin
     p_x[k]<=p_x[k-1];p_z[k]<=p_z[k-1];
     p_den[k]<=p_den[k-1];p_rem[k]<=p_rem[k-1];p_f[k]<=p_f[k-1];
     for(integer a=0;a<5;a=a+1)p_av[k][a]<=p_av[k-1][a];
     if((!cmd[2][0] || cmd[2][1]) && p_den[k-1]!=0 && p_rem[k-1]>=(p_den[k-1]<<(9-k)))begin
      p_rem[k]<=p_rem[k-1]-(p_den[k-1]<<(9-k));p_f[k]<=p_f[k-1]|(9'd1<<(9-k));
     end
    end
    p_x[10]<=p_x[9];
    p_z[10]<=cmd[2][1]?p_interpolate_z(cmd[15],cmd[26],p_f[9]):p_z[9];
    for(integer a=0;a<5;a=a+1)
     p_av[10][a]<=cmd[2][0]?p_av[9][a]:p_interpolate($signed({{16{cmd[8+a][15]}},cmd[8+a][15:0]}),delta[a],p_f[9]);
    p_x[11]<=p_x[10];p_z[11]<=p_z[10];p_pass[11]<=1'b1;
    p_addr[11]<=29'(cmd[13]>>3)+29'(p_index>>1);p_half[11]<=p_index[0];
    p_x[12]<=p_x[11];p_z[12]<=p_z[11];p_pass[12]<=p_pass[11];
    p_addr[12]<=p_addr[11];p_half[12]<=p_half[11];
    for(integer a=0;a<3;a=a+1)begin p_av[11][a]<=p_av[10][a];p_av[12][a]<=p_av[11][a];end
   end
  end
 end
 always_comb begin
  rd=0;wr=0;burst=1;addr=MB;din=0;be=8'hff;
  case(state)
   INIT,POLL:begin rd=1;addr=MB;end
   READY:begin wr=1;addr=MB+3;din={epoch,MAGIC};end
   HEADER:begin rd=1;addr=MB+1;end
   FETCH:begin rd=1;burst=16;addr=CM+(index<<4);end
   TEX_READ:begin rd=1;addr=tex_addr;end
   FLUSH_WRITE:begin wr=1;burst=128;addr=OUT+(line_y<<7);din=flush_pair;end
   COMPLETE:begin wr=1;addr=MB+2;din={status,seq};end
   default:begin end
  endcase
  // Finish any physical row burst already accepted by the fabric before
  // obeying enable loss. Reset also resets the complete shared fabric.
  if(reset || (!enable && !flush_inflight))begin rd=0;wr=0;end
  for(integer k=0;k<5;k=k+1)sums[k]={1'b0,rems[k]}+{1'b0,rsteps[k]};
  zsum={1'b0,zrem}+{1'b0,zrstep};
 end
 nds_fpga3d_pixels pixels(
  .clk,.reset(reset || (!enable && !flush_inflight)),
  .ce(p_ce || (state==RESOLVE_RUN && enable && !reset)),
  .clear_we(state==CLEAR_LINE && enable && !reset),.clear_x(x[7:0]),
  .clear_color(cmd[1]),.clear_depth(cmd[2]),.clear_attr(cmd[5]|(cmd[3][0]?32'd16:32'd0)),
  .span_start(state==DECODE && cmd[0]==2),.flags(cmd[2][5:0]),
  .poly_attr(cmd[27]),.left_cov(cmd[28]),.right_cov(cmd[29]),
  .left_end(cmd[30][8:0]),.right_begin(cmd[30][24:16]),.y_edge(cmd[31][9:6]),
  .antialias(line_config[4]),.blend_enable(line_config[3]),.translucent_depth_write(cmd[31][5]),
  .pixel_valid(p_ce && p_valid[12] && p_color[31:24]>cmd[2][12:8]),
  .resolve_valid(state==RESOLVE_RUN && x<256),.resolve_mode,
  .fog_color,.fog_offset,.fog_shift,.fog_table,.fog_alpha_only(line_config[6]),
  .pixel_x(state==RESOLVE_RUN?x[7:0]:p_x[12][7:0]),.pixel_color(p_color),.pixel_depth(p_z[12]),
  .pending(pixels_pending),
  .flush_en(state==FLUSH_LOAD || state==FLUSH_WAIT || (state==FLUSH_WRITE && accepted)),
  .flush_index(flush_read),.flush_pair
 );
 always_ff @(posedge clk)begin
  if(reset || (!enable && !flush_inflight))begin
   state<=INIT;seen<=0;seq<=0;index<=0;status<=0;epoch<=session;poll<=0;
   line_open<=0;line_y<=0;flush_x<=0;x<=0;flush_inflight<=0;line_config<=0;fog_configured<=0;resolve_mode<=0;
  end else begin
   if(state==FLUSH_WRITE && !busy)flush_inflight<=1;
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
     status<=0;index<=0;line_y<=0;line_open<=0;p_clear_index<=0;fog_configured<=0;
     count<=dout[31:0];
     if(dout[63:32]!=epoch || epoch!=session)begin status<=2;state<=COMPLETE;end
     else if(dout[31:0]==0 || dout[31:0]>4064)begin status<=1;state<=COMPLETE;end
     else state<=CACHE_CLEAR;
    end
    CACHE_CLEAR:if(p_clear_index==511)state<=FETCH;else p_clear_index<=p_clear_index+1'b1;
    FETCH:if(!busy)begin beat<=0;state<=FETCH_WAIT;end
    FETCH_WAIT:if(dout_ready)begin
     cmd[{beat,1'b0}]<=dout[31:0];cmd[{beat,1'b1}]<=dout[63:32];
     if(beat==15)state<=DECODE;else beat<=beat+1'b1;
    end
    DECODE:begin
     if(cmd[0]==4 && index==0 && !line_open && line_y==0 && cmd[3]<=15)begin
      fog_color<=cmd[1];fog_offset<=cmd[2];fog_shift<=cmd[3][3:0];
      for(integer f=0;f<34;f=f+1)fog_table[8*f+:8]<=cmd[4+f/4][8*(f%4)+:8];
      fog_configured<=1;state<=NEXT_COMMAND;
     end else if(cmd[0]==1 && !line_open && line_y<192 && cmd[4]==line_y &&
       (!cmd[6][7] || fog_configured))begin
      x<=0;line_open<=1;line_config<=cmd[6];state<=CLEAR_LINE;
     end else if(cmd[0]==3 && line_open && cmd[1]==line_y)begin
      flush_x<=0;x<=0;resolve_mode<=line_config[7]?2'd1:2'd3;
      state<=(line_config[4] || line_config[7])?RESOLVE_RUN:FLUSH_LOAD;
     end else if(cmd[0]==2 && line_open && cmd[1][15:0]<cmd[1][31:16] &&
       cmd[1][31:16]<=256 && cmd[30][15:0]<=cmd[30][31:16] && cmd[30][31:16]<=256 &&
       cmd[31][31:10]==0 && cmd[3][15:0]>0 && cmd[3][15:0]<=256 &&
       ({1'b0,cmd[3][31:16]}+{1'b0,cmd[1][31:16]}-{1'b0,cmd[1][15:0]})<={1'b0,cmd[3][15:0]} &&
       (!cmd[2][2] || (cmd[13]>=32'h3fd40000 && cmd[13][2:0]==0 &&
          cmd[14][3:0]>=3 && cmd[14][3:0]<=10 && cmd[14][7:4]>=3 && cmd[14][7:4]<=10 &&
          ({1'b0,cmd[13]}+(33'd4<<({1'b0,cmd[14][3:0]}+{1'b0,cmd[14][7:4]})))<=33'h03fe00000)))begin
      x<=cmd[1][8:0];last<=cmd[1][24:16];span_width<=cmd[3][9:0];dx<=cmd[3][24:16];
      w0<=cmd[4][15:0];w1<=cmd[4][31:16];
      zlinear<=$signed(cmd[5]);zstep<=$signed(cmd[6]);zrem<=cmd[7][12:0];zrstep<=cmd[7][28:16];
      for(i=0;i<5;i=i+1)begin
       av[i]<={{16{cmd[8+i][15]}},cmd[8+i][15:0]};
       delta[i]<=$signed({{16{cmd[8+i][31]}},cmd[8+i][31:16]})-$signed({{16{cmd[8+i][15]}},cmd[8+i][15:0]});
       steps[i]<=$signed(cmd[16+i]);rems[i]<=cmd[21+i][15:0];rsteps[i]<=cmd[21+i][31:16];
      end
      state<=PIPE_RUN;
     end else begin status<=1;state<=COMPLETE;end
    end
    CLEAR_LINE:if(x==255)state<=NEXT_COMMAND;else x<=x+1'b1;
    TEX_READ:if(!busy)state<=TEX_WAIT;
    TEX_WAIT:if(dout_ready)state<=PIPE_RUN;
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
    RESOLVE_RUN:begin
     if(x<256)x<=x+1'b1;
     else if(!pixels_pending)begin
      if(resolve_mode==1)begin resolve_mode<=2; x<=0;end
      else if(resolve_mode==2 && line_config[4])begin resolve_mode<=3;x<=0;end
      else state<=FLUSH_LOAD;
     end
    end
    FLUSH_LOAD:state<=FLUSH_WAIT;
    FLUSH_WAIT:state<=FLUSH_WRITE;
    FLUSH_WRITE:if(accepted)begin
     if(flush_x==254)begin flush_inflight<=0;line_open<=0;line_y<=line_y+1'b1;state<=NEXT_COMMAND;end
     else flush_x<=flush_x+2;
    end
    NEXT_COMMAND:if(index+1==count)begin
     if(line_open || line_y!=192)status<=1;
     state<=COMPLETE;
    end else begin index<=index+1'b1;state<=FETCH;end
    COMPLETE:if(!busy)begin poll<=0;state<=POLL_DELAY;end
    default:state<=INIT;
   endcase
  end
 end
endmodule
