// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_dv1_rotation_latency #(parameter ALIGN_CAPTURE_PHASE=1);
    integer source_width=256, source_height=392, source_total=524, source_repeat=3, source_line=640;
    integer source_id=0, write_jitter=0, pause_left=0, paused_id=0;
    reg clk=0,avl_clk=0,o_clk=0,reset=1;
    always #8.333 clk=~clk;
    always #5 avl_clk=~avl_clk;
    always #3.367 o_clk=~o_clk;
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
        .source_width(10'(source_width)),.source_height(10'(source_height)),.avl_clk,.o_clk,.o_vbl,
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
    nds_dv1_rotate_read #(.ALIGN_CAPTURE_PHASE(ALIGN_CAPTURE_PHASE)) reader(
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
        if(display_clock==2470000)o_vbl=1;
        if(display_clock==2475000)begin display_clock=0;o_vbl=0;end
    end
    always @(negedge avl_clk) begin
        random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        wr_ready=random_state[2:0]!=0 && pause_left==0;rd_wait=random_state[5:3]==0;
        rd_valid=pending!=0 && random_state[8:6]!=0;
        for(integer i=0;i<4;i=i+1)rd_data[i*32+:32]=memory[address+beat*4+i];
    end
    always @(posedge avl_clk) if(!reset) begin
        if(write_jitter>0 && writer.state==1 && writer.strip_last && paused_id!=source_id) begin
            paused_id=source_id; pause_left=(source_id*7919)%write_jitter;
        end else if(pause_left>0) pause_left=pause_left-1;
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
        repeat(source_repeat-2)@(negedge clk);
    endtask
    function automatic [23:0] color(input integer x,y,id);
        reg [5:0] r,g,b;
        begin r=6'(id);g=6'(x ^ ((y>>6)*13));b=6'(y ^ ((x>>6)*31));color={r,r[5:4],g,g[5:4],b,b[5:4]};end
    endfunction
    task automatic source_frame(input integer id);
        source_id=id; i_vs=0;tick(1,0);i_vs=1;tick(1,0);
        for(integer y=0;y<source_height;y=y+1)begin
            for(integer x=0;x<source_width;x=x+1)tick(0,color(x,y,id));
            repeat(source_line-source_width)tick(1,0);
        end
        // Every source layout has the same 1,006,080-clock frame period.
        repeat(source_line*(source_total-source_height)-2)tick(1,0);
    endtask
    realtime first_capture[0:63];
    real minimum_age=1e30,maximum_age=0,total_age=0,age;
    integer age_count=0,sx,sy;
    always @(posedge clk) if(!reset && writer.starting) first_capture[i_rgb[23:18]]=$realtime;
    integer px=0,py=0,id=0,checked=0,frames=0,unique_frames=0,last_id=0;
    integer seen[0:63];
    integer cycle=0,previous_sync=0,syncs=0;
    always @(posedge clk) cycle=cycle+1;
    reg previous_de=0,previous_vs=0,checking=0;
    reg [1:0] frame_mode=0;
    always @(negedge clk) if(ce)begin
        if(vs && !previous_vs)begin
            px=0;py=0;
            if(active) begin
                if(syncs>=2 && cycle-previous_sync !=
                    (1006080-(ALIGN_CAPTURE_PHASE ? 0 : (source_width>500 ? 1 : source_width>250 ? 2 : 5))))
                    $fatal(1,"rotation changed steady refresh: %0d clocks",cycle-previous_sync);
                previous_sync=cycle;syncs=syncs+1;
            end
        end
        if(de && active)begin
            if(!previous_de)px=0;
            if(px==0 && py==0)begin id=rgb[23:18];frame_mode=applied;checking=id!=0;end
            if(checking)begin
                if(rgb !== (frame_mode==1 ? color(py,source_height-1-px,id) : color(source_width-1-py,px,id)))
                    $fatal(1,"torn/misrotated frame mode%0d id%0d pixel%0d,%0d rgb%h",frame_mode,id,px,py,rgb);
                checked=checked+1;
                if((id>=3 && id<=22) || (id>=27 && id<=46))begin
                    sx=frame_mode==1 ? py : source_width-1-py;
                    sy=frame_mode==1 ? source_height-1-px : px;
                    age=$realtime-(first_capture[id]+(sy*source_line+sx)*source_repeat*16.666);
                    if(age<minimum_age)minimum_age=age;
                    if(age>maximum_age)maximum_age=age;
                    total_age+=age;age_count++;
                end
            end
            px=px+1;
        end
        if(previous_de && !de)begin
            py=py+1;
            if(py==source_width && checking)begin
                seen[id]=seen[id]+1;
                frames=frames+1;
                if(id!=last_id)unique_frames=unique_frames+1;
                last_id=id;
            end
        end
        previous_de=de;previous_vs=vs;
    end
    integer start_cycles=0;
    initial begin
        if($value$plusargs("SOURCE_DELAY_CLOCKS=%d",start_cycles)) begin end
        if($value$plusargs("SOURCE_WIDTH=%d",source_width)) begin end
        if($value$plusargs("SOURCE_HEIGHT=%d",source_height)) begin end
        if($value$plusargs("WRITE_JITTER=%d",write_jitter)) begin end
        if($value$plusargs("SEED=%d",random_state)) begin end
        source_total=source_height>250 ? 524 : 262;
        source_repeat=source_height>250 ? 3 : 6;
        if(source_width==320 && source_height==240) begin
            source_line=384; source_repeat=10;
        end
        if(source_width<192 || source_width>536 || source_height<192 || source_height>414)
            $fatal(1,"unsupported test geometry");
        for(integer i=0;i<64;i=i+1) seen[i]=0;
        repeat(5)@(negedge clk);reset=0;
        repeat(start_cycles)@(negedge clk);
        for(integer i=1;i<=24;i=i+1)source_frame(i);
        rotation=2;
        for(integer i=25;i<=48;i=i+1)source_frame(i);
        repeat(2*1006080)@(negedge clk);
        if(underrun || overflow)$fatal(1,"underrun/overflow: %b %b",underrun,overflow);
        if(ALIGN_CAPTURE_PHASE) begin
            for(integer i=3;i<=46;i=i+1)
                if((i<=22 || i>=27) && seen[i]!=1)
                    $fatal(1,"steady frame %0d shown %0d times",i,seen[i]);
            if(age_count!=40*source_width*source_height)
                $fatal(1,"incomplete steady frames: %0d pixels",age_count);
        end
        $display("PASS latency %0dx%0d phase%0d jitter%0d align%0d: %0d unique / %0d complete frames; %0d exact pixels; no tears/underruns/overflow; fixed refresh",
            source_width,source_height,start_cycles,write_jitter,ALIGN_CAPTURE_PHASE,unique_frames,frames,checked);
        $display("ROTATION_PIXEL_AGE_NS min=%f mean=%f max=%f samples=%0d",minimum_age,total_age/age_count,maximum_age,age_count);
        $finish;
    end
    initial begin #1500000000;$fatal(1,"pipeline timeout");end
endmodule
