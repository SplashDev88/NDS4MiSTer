// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_dv1_rotate_read;
    reg clk=0,avl_clk=0,reset=1,enable=0,fb_enable=0;
    always #8 clk=~clk;
    always #5 avl_clk=~avl_clk;
    reg [9:0] fb_width=256,fb_height=192;
    reg [31:0] fb_base=32'h24000000;
    reg [13:0] fb_stride=1024;
    reg [1:0] fb_rotation=1;
    wire frame_boundary,active,ce,de,hs,vs,underrun,rd;
    wire [1:0] rotation;
    wire [23:0] rgb;
    wire [27:0] rd_address;
    wire [7:0] rd_count;
    reg rd_wait=0,rd_valid=0,block_ddr=0;
    reg [127:0] rd_data=0;
    nds_dv1_rotate_read dut(.*);
    reg [4:0] par_num=0;
    wire [15:0] measurement;
    video_calc metadata(.clk_100(avl_clk),.clk_vid(clk),.clk_sys(clk),
        .ce_pix(ce),.de,.hs,.vs,.vs_hdmi(vs),.f1(1'b0),.new_vmode(1'b0),
        .video_rotated(1'b0),.par_num,.dout(measurement));
    function automatic [23:0] pattern(input integer x,y);
        reg [5:0] r,g,b;
        begin
            r=6'(x^y);g=6'(y+23);b=6'(x+17*y);
            pattern={r,r[5:4],g,g[5:4],b,b[5:4]};
        end
    endfunction
    integer pending=0,addr=0,beat=0,accepted=0,delivered=0;
    reg [31:0] random_state=32'h32a52e61;
    reg held=0;
    reg [35:0] held_request;
    always @(negedge avl_clk) begin : memory_model
        integer i,word_index,px,py;
        reg [23:0] color;
        random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        rd_wait=block_ddr || random_state[3:0]==0;
        rd_valid=pending!=0 && !block_ddr && random_state[6:4]!=0;
        for(i=0;i<4;i=i+1) begin
            word_index=(addr-28'h2400000)*4+beat*4+i;
            py=word_index/(fb_stride/4);px=word_index%(fb_stride/4);
            color=pattern(px,py);
            rd_data[i*32+:32]={8'd0,color[7:0],color[15:8],color[23:16]};
        end
    end
    always @(posedge avl_clk) if(!reset) begin
        if(held && (!rd || {rd_address,rd_count}!==held_request))
            $fatal(1,"native read changed under waitrequest");
        held=rd && rd_wait;held_request={rd_address,rd_count};
        if(rd && !rd_wait) begin
            if(pending!=0 || rd_count==0 || rd_count>128) $fatal(1,"bad read ownership/count");
            addr=rd_address;beat=0;pending=rd_count;accepted=accepted+1;
        end
        if(rd_valid) begin
            if(pending==0) $fatal(1,"unexpected response");
            pending=pending-1;beat=beat+1;delivered=delivered+1;
        end
    end
    integer px=0,py=0,frame_pixels=0,checked=0,frames=0;
    reg old_de=0,old_vs=0,checking=0;
    always @(negedge clk) if(ce) begin
        if(vs && !old_vs) begin
            if(checking && frame_pixels!=fb_width*fb_height)
                $fatal(1,"frame size got%0d want%0d",frame_pixels,fb_width*fb_height);
            frame_pixels=0;px=0;py=0;frames=frames+1;
        end
        if(de) begin
            if(!old_de) px=0;
            if(checking) begin
                if(rgb!==pattern(px,py))
                    $fatal(1,"pixel %0d,%0d got%h want%h, size%0dx%0d",px,py,rgb,pattern(px,py),fb_width,fb_height);
                checked=checked+1;
            end
            px=px+1;frame_pixels=frame_pixels+1;
        end
        if(old_de && !de) begin
            if(checking && px!=fb_width) $fatal(1,"line width%0d expected%0d",px,fb_width);
            py=py+1;
        end
        old_de=de;old_vs=vs;
    end
    task automatic test_mode(input integer w,h,rot);
        checking=0;enable=1;fb_enable=1;fb_width=w;fb_height=h;
        fb_stride=((w+3)/4)*16;fb_rotation=rot;
        repeat(4) @(posedge vs);
        @(negedge vs);checking=1;
        repeat(2) @(posedge vs);
        @(negedge clk);checking=0;
        if(!active || rotation!=rot || underrun) $fatal(1,"rotation/underrun");
        par_num=2;repeat(3)@(negedge clk);
        if(measurement!=w)$fatal(1,"DV1 metadata width%0d expected%0d",measurement,w);
        par_num=4;repeat(3)@(negedge clk);
        if(measurement!=h)$fatal(1,"DV1 metadata height%0d expected%0d",measurement,h);
        par_num=16;repeat(3)@(negedge clk);
        if(measurement!=(h>500?2:h>256?3:6))$fatal(1,"DV1 metadata pixel repetition");
        par_num=17;repeat(3)@(negedge clk);
        if(measurement==0 || measurement>=8192)$fatal(1,"DV1 horizontal crop offset");
        par_num=18;repeat(3)@(negedge clk);
        if(measurement>=256)$fatal(1,"DV1 vertical crop offset");
        $display("PASS reader %0dx%0d rotation%0d",w,h,rot);
    endtask
    initial begin
        repeat(6) @(negedge clk);reset=0;
        test_mode(392,256,1);test_mode(414,256,2);
        test_mode(240,320,1);test_mode(192,520,2);
        test_mode(198,536,1);test_mode(192,256,2);
        // A stalled transaction must pin its framebuffer even in blanking.
        checking=0;
        @(negedge vs);block_ddr=1;
        @(posedge vs);repeat(20) @(negedge clk);
        if(frame_boundary || !underrun) $fatal(1,"undrained native frame was released");
        block_ddr=0;
        repeat(3) @(posedge vs);
        enable=0;repeat(2) @(posedge vs);
        if(active) $fatal(1,"native path did not turn off");
        $display("PASS %0d exact pixels, %0d reads, %0d beats, late reads pin descriptor; Off drains",checked,accepted,delivered);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"reader timeout"); end
endmodule
