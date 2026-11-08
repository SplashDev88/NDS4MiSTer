// SPDX-License-Identifier: GPL-3.0-only
// Experimental opaque DS scanline rasterizer. See tools/fpga3d/abi.h.
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
 input logic dout_ready
);
 localparam [28:0] MB=29'h07f90000,CM=29'h07f90200,OUT=29'h07fa0000;
 localparam [31:0] MAGIC=32'h31443346;
 typedef enum logic[5:0] {INIT,INIT_WAIT,READY,POLL_DELAY,POLL,POLL_WAIT,
 HEADER,HEADER_WAIT,FETCH,FETCH_WAIT,DECODE,CLEAR_LINE,
 PIXEL,PIXEL_WAIT,DIVIDE,ATTRS,DEPTH,TEX_ADDR,TEX_READ,TEX_WAIT,SHADE,NEXT_PIXEL,
 FLUSH_LOAD,FLUSH_WAIT,FLUSH_WRITE,NEXT_COMMAND,COMPLETE} state_t;
 state_t state;
 logic [31:0] cmd[0:31];
 logic [31:0] seq,seen,count,index,status,epoch;
 logic [15:0] poll;
 logic [3:0] beat;
 logic [8:0] x,last,width,dx,line_y,flush_x;
 logic [9:0] span_width;
 logic line_open;
 (* ramstyle = "M10K" *) logic [31:0] color_even[0:127],color_odd[0:127];
 (* ramstyle = "M10K" *) logic [32:0] depth_back[0:255];
 logic line_we;
 logic [31:0] line_color;
 logic [32:0] line_depth;
 logic [31:0] old_depth;
 logic old_back;
 logic [63:0] flush_pair;
 logic [15:0] w0,w1;
 logic [31:0] numerator,denominator,remain,trial;
 logic [8:0] f;
 logic [3:0] divbit;
 logic signed [31:0] av[0:4],delta[0:4],steps[0:4];
 logic [15:0] rems[0:4],rsteps[0:4];
 logic [16:0] sums[0:4];
 logic signed [40:0] products[0:4];
 logic [31:0] z;
 logic signed [32:0] zdelta;
 logic signed [42:0] zproduct;
 logic [13:0] zsum;
 logic [12:0] zrem,zrstep;
 logic signed [31:0] zstep,zlinear;
 logic [15:0] ts,tt;
 logic [19:0] tex_index;
 logic [28:0] tex_addr,cache_addr;
 logic tex_half,cache_valid;
 logic [63:0] cache_data;
 logic [31:0] texel,pixel_color;
 logic [12:0] mr,mg,mb;
 logic pass_depth;
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
 always_comb begin
  rd=0;wr=0;burst=1;addr=MB;din=0;be=8'hff;
  case(state)
   INIT,POLL:begin rd=1;addr=MB;end
   READY:begin wr=1;addr=MB+3;din={epoch,MAGIC};end
   HEADER:begin rd=1;addr=MB+1;end
   FETCH:begin rd=1;burst=16;addr=CM+(index<<4);end
   TEX_READ:begin rd=1;addr=tex_addr;end
   FLUSH_WRITE:begin wr=1;addr=OUT+(line_y<<7)+(flush_x>>1);din=flush_pair;end
   COMPLETE:begin wr=1;addr=MB+2;din={status,seq};end
   default:begin end
  endcase
  // Disabled/reset epochs must not place requests into the shared fabric.
  if(reset || !enable)begin rd=0;wr=0;end
  trial=denominator<<divbit;
  for(integer k=0;k<5;k=k+1)begin
   sums[k]={1'b0,rems[k]}+{1'b0,rsteps[k]};
   products[k]=$signed(delta[k])*$signed({1'b0,f});
  end
  zdelta=$signed({1'b0,cmd[26]})-$signed({1'b0,cmd[15]});
  zproduct=zdelta*$signed({1'b0,f});
  zsum={1'b0,zrem}+{1'b0,zrstep};
  ts=texture_coord(av[3][15:0],cmd[14][3:0],cmd[14][8],cmd[14][10]);
  tt=texture_coord(av[4][15:0],cmd[14][7:4],cmd[14][9],cmd[14][11]);
  tex_index=(20'(tt)<<cmd[14][3:0])+20'(ts);
  mr=({1'b0,texel[5:0]}+7'd1)*({1'b0,av[0][8:3]}+7'd1)-13'd1;
  mg=({1'b0,texel[13:8]}+7'd1)*({1'b0,av[1][8:3]}+7'd1)-13'd1;
  mb=({1'b0,texel[21:16]}+7'd1)*({1'b0,av[2][8:3]}+7'd1)-13'd1;
  pixel_color=cmd[2][2]?{texel[31:24],2'd0,mb[11:6],2'd0,mg[11:6],2'd0,mr[11:6]}:
                  {8'd31,2'd0,av[2][8:3],2'd0,av[1][8:3],2'd0,av[0][8:3]};
  if(cmd[2][5])begin
   if(cmd[2][1])pass_depth=({1'b0,z}+33'd255>={1'b0,old_depth})&&({1'b0,old_depth}+33'd255>={1'b0,z});
   else pass_depth=({1'b0,z}+33'd512>={1'b0,old_depth})&&({1'b0,old_depth}+33'd512>={1'b0,z});
  end else pass_depth=z<old_depth || (cmd[2][3] && old_back && z==old_depth);
  line_we=!reset && enable && ((state==CLEAR_LINE) ||
    (state==SHADE && pixel_color[31:24]>cmd[2][12:8] &&
      (!cmd[2][2] || texel[31:24]==31)));
  line_color=state==CLEAR_LINE?cmd[1]:pixel_color;
  line_depth=state==CLEAR_LINE?{cmd[3][0],cmd[2]}:{cmd[2][4],z};
 end
 always_ff @(posedge clk)begin
  // One write port per inferred RAM. Split even/odd colors so the flush
  // fetches a pair without demanding a third port or expanding to registers.
  if(line_we)begin
   if(x[0])color_odd[x[7:1]]<=line_color;
   else color_even[x[7:1]]<=line_color;
   depth_back[x[7:0]]<=line_depth;
  end
  {old_back,old_depth}<=depth_back[x[7:0]];
  flush_pair<={color_odd[flush_x[7:1]],color_even[flush_x[7:1]]};
  if(reset || !enable)begin
   state<=INIT;seen<=0;seq<=0;index<=0;status<=0;epoch<=session;poll<=0;
   cache_valid<=0;line_open<=0;line_y<=0;flush_x<=0;x<=0;
  end else begin
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
     status<=0;index<=0;line_y<=0;line_open<=0;cache_valid<=0;
     count<=dout[31:0];
     if(dout[63:32]!=epoch || epoch!=session)begin status<=2;state<=COMPLETE;end
     else if(dout[31:0]==0 || dout[31:0]>4064)begin status<=1;state<=COMPLETE;end
     else state<=FETCH;
    end
    FETCH:if(!busy)begin beat<=0;state<=FETCH_WAIT;end
    FETCH_WAIT:if(dout_ready)begin
     cmd[{beat,1'b0}]<=dout[31:0];cmd[{beat,1'b1}]<=dout[63:32];
     if(beat==15)state<=DECODE;else beat<=beat+1'b1;
    end
    DECODE:begin
     if(cmd[0]==1 && !line_open && line_y<192 && cmd[4]==line_y)begin
      x<=0;line_open<=1;state<=CLEAR_LINE;
     end else if(cmd[0]==3 && line_open && cmd[1]==line_y)begin
      flush_x<=0;state<=FLUSH_LOAD;
     end else if(cmd[0]==2 && line_open && cmd[1][15:0]<cmd[1][31:16] &&
       cmd[1][31:16]<=256 && cmd[3][15:0]>0 && cmd[3][15:0]<=256 &&
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
      state<=PIXEL;
     end else begin status<=1;state<=COMPLETE;end
    end
    CLEAR_LINE:if(x==255)state<=NEXT_COMMAND;else x<=x+1'b1;
    PIXEL:begin
     numerator<=32'(dx)*32'(w0)<<8;
     denominator<=32'(dx)*32'(w0)+(32'(span_width)-32'(dx))*32'(w1);
     state<=PIXEL_WAIT;
    end
    PIXEL_WAIT:begin
     remain<=numerator;f<=0;divbit<=8;
     if((!cmd[2][0] || cmd[2][1]) && denominator!=0)state<=DIVIDE;
     else state<=ATTRS;
    end
    DIVIDE:begin
     if(remain>=trial)begin remain<=remain-trial;f[divbit]<=1;end
     if(divbit==0)state<=ATTRS;else divbit<=divbit-1'b1;
    end
    ATTRS:begin
     if(!cmd[2][0])for(i=0;i<5;i=i+1)
      av[i]<=$signed({{16{cmd[8+i][15]}},cmd[8+i][15:0]})+32'(products[i]>>>8);
     z<=cmd[2][1]?cmd[15]+32'(zproduct>>>8):zlinear;
     state<=DEPTH;
    end
    DEPTH:if(pass_depth)begin if(cmd[2][2])state<=TEX_ADDR;else state<=SHADE;end else state<=NEXT_PIXEL;
    TEX_ADDR:begin
     tex_addr<=29'(cmd[13]>>3)+29'(tex_index>>1);tex_half<=tex_index[0];
     if(cache_valid && cache_addr==29'(cmd[13]>>3)+29'(tex_index>>1))begin
      texel<=tex_index[0]?cache_data[63:32]:cache_data[31:0];state<=SHADE;
     end else state<=TEX_READ;
    end
    TEX_READ:if(!busy)state<=TEX_WAIT;
    TEX_WAIT:if(dout_ready)begin
     cache_valid<=1;cache_addr<=tex_addr;cache_data<=dout;
     texel<=tex_half?dout[63:32]:dout[31:0];state<=SHADE;
    end
    SHADE:begin
     if(cmd[2][2] && texel[31:24]!=0 && texel[31:24]!=31)begin status<=3;state<=COMPLETE;end
     else state<=NEXT_PIXEL;
    end
    NEXT_PIXEL:begin
     x<=x+1'b1;dx<=dx+1'b1;
     zlinear<=zlinear+zstep+32'(zsum>=8192);zrem<=zsum[12:0];
     if(cmd[2][0])for(i=0;i<5;i=i+1)begin
      av[i]<=av[i]+steps[i]+32'(sums[i]>={7'd0,span_width});
      rems[i]<=16'(sums[i]>={7'd0,span_width}?sums[i]-{7'd0,span_width}:sums[i]);
     end
     if(x+1'b1==last)state<=NEXT_COMMAND;else state<=PIXEL;
    end
    FLUSH_LOAD:state<=FLUSH_WAIT;
    FLUSH_WAIT:state<=FLUSH_WRITE;
    FLUSH_WRITE:if(!busy)begin
     if(flush_x==254)begin line_open<=0;line_y<=line_y+1'b1;state<=NEXT_COMMAND;end
     else begin flush_x<=flush_x+2;state<=FLUSH_LOAD;end
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
