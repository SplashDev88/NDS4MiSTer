// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_dv1_rotation_pipeline;
    reg clk=0,avl_clk=0,o_clk=0,reset=1;
    always #8 clk=~clk;always #5 avl_clk=~avl_clk;always #7 o_clk=~o_clk;
    reg i_ce=0,i_de=0,i_vs=1,o_vbl=0,n_enable=1;
    reg [23:0] i_rgb=0;
    reg [1:0] rotation=1;
    wire fb_enable,n_fb_enable;
    wire [1:0] rotation_applied,n_rotation_applied;
    wire [9:0] fb_width,fb_height,n_fb_width,n_fb_height;
    wire [31:0] fb_base,n_fb_base;
    wire [13:0] fb_stride,n_fb_stride;
    wire [27:0] wr_address;
    wire [127:0] wr_data;
    wire wr_valid,overflow,frame_boundary;
    reg wr_ready=1;
    nds_tate_video #(.NATIVE_READER(1)) writer(
        .reset,.i_clk(clk),.i_ce,.i_de,.i_vs,.i_rgb,.rotation,
        .source_width(10'd256),.source_height(10'd198),.avl_clk,.o_clk,.o_vbl,
        .n_clk(clk),.n_vbl(frame_boundary),.n_enable,
        .fb_enable,.rotation_applied,.fb_width,.fb_height,.fb_base,.fb_stride,
        .n_fb_enable,.n_rotation_applied,.n_fb_width,.n_fb_height,.n_fb_base,.n_fb_stride,
        .wr_address,.wr_data,.wr_valid,.wr_ready,.overflow);
    wire active,ce,de,hs,vs,underrun,rd;
    wire [1:0] applied;
    wire [23:0] rgb;
    wire [27:0] rd_address;
    wire [7:0] rd_count;
    reg rd_wait=0,rd_valid=0;
    reg [127:0] rd_data=0;
    nds_dv1_rotate_read reader(
        .reset,.clk,.avl_clk,.enable(n_enable),.fb_enable(n_fb_enable),
        .fb_width(n_fb_width),.fb_height(n_fb_height),.fb_base(n_fb_base),
        .fb_stride(n_fb_stride),.fb_rotation(n_rotation_applied),
        .frame_boundary,.active,.rotation(applied),.ce,.de,.hs,.vs,.rgb,.underrun,
        .rd,.rd_address,.rd_count,.rd_wait,.rd_valid,.rd_data);
    reg [31:0] memory [0:1048575];
    integer pending=0,address=0,beat=0,display_clock=0;
    reg [31:0] random_state=32'h64b71593;
    always @(negedge o_clk) begin
        display_clock=display_clock+1;
        if(display_clock==13000)o_vbl=1;
        if(display_clock==14000)begin display_clock=0;o_vbl=0;end
    end
    always @(negedge avl_clk) begin
        random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        wr_ready=random_state[2:0]!=0;rd_wait=random_state[5:3]==0;
        rd_valid=pending!=0 && random_state[8:6]!=0;
        for(integer i=0;i<4;i=i+1)rd_data[i*32+:32]=memory[address+beat*4+i];
    end
    always @(posedge avl_clk) if(!reset) begin
        if(wr_valid && wr_ready) begin
            if((fb_enable && wr_address[17:16]==writer.display_fb) ||
               (n_fb_enable && wr_address[17:16]==writer.native_fb))
                $fatal(1,"overwriting a displayed buffer");
            for(integer i=0;i<4;i=i+1)memory[(wr_address-28'h2400000)*4+i]=wr_data[i*32+:32];
        end
        if(rd && !rd_wait)begin
            if(pending!=0)$fatal(1,"overlapping native reads");
            if(rd_address[17:16]!=writer.native_fb)$fatal(1,"reader fetched an unowned bank");
            pending=rd_count;address=(rd_address-28'h2400000)*4;beat=0;
        end
        if(rd_valid)begin pending=pending-1;beat=beat+1;end
    end
    task automatic tick(input bit blank,input [23:0] color);
        @(negedge clk);i_ce=1;i_de=!blank;i_rgb=color;
        @(negedge clk);i_ce=0;
        repeat(4)@(negedge clk);
    endtask
    function automatic [23:0] color(input integer x,y,id);
        reg [5:0] r,g,b;
        begin r=6'(id);g=6'(x);b=6'(y);color={r,r[5:4],g,g[5:4],b,b[5:4]};end
    endfunction
    task automatic source_frame(input integer id);
        i_vs=0;tick(1,0);i_vs=1;tick(1,0);
        for(integer y=0;y<198;y=y+1)begin
            for(integer x=0;x<256;x=x+1)tick(0,color(x,y,id));
            repeat(20)tick(1,0);
        end
        repeat(256)tick(1,0);
    endtask
    integer px=0,py=0,id=0,checked=0,frames=0;
    reg previous_de=0,previous_vs=0,checking=0;
    reg [1:0] frame_mode=0;
    always @(negedge clk) if(ce)begin
        if(vs && !previous_vs)begin px=0;py=0;end
        if(de && active)begin
            if(!previous_de)px=0;
            if(px==0 && py==0)begin id=rgb[23:18];frame_mode=applied;checking=id!=0;end
            if(checking)begin
                if(rgb !== (frame_mode==1 ? color(py,197-px,id) : color(255-py,px,id)))
                    $fatal(1,"torn/misrotated frame mode%0d id%0d pixel%0d,%0d rgb%h",frame_mode,id,px,py,rgb);
                checked=checked+1;
            end
            px=px+1;
        end
        if(previous_de && !de)begin py=py+1;if(py==256 && checking)frames=frames+1;end
        previous_de=de;previous_vs=vs;
    end
    initial begin
        repeat(5)@(negedge clk);reset=0;
        for(integer i=1;i<=12;i=i+1)source_frame(i);
        rotation=2;
        for(integer i=13;i<=24;i=i+1)source_frame(i);
        if(frames<4 || underrun || overflow)$fatal(1,"insufficient full frames/underrun/overflow: %0d %b %b",frames,underrun,overflow);
        $display("PASS full transpose + native reader: %0d pixels in %0d untorn frames, both directions, four-buffer ownership",checked,frames);
        $finish;
    end
    initial begin #400000000;$fatal(1,"pipeline timeout");end
endmodule
