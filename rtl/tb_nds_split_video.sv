// SPDX-License-Identifier: GPL-3.0-or-later
// Real scanout + real DDR line cache; tagged memory and variable bus latency.
`timescale 1ns/1ps
module tb_nds_split_video #(parameter MATCHED=0);
    localparam [27:1] FB_BASE=27'h7f00000, EXT_BASE=27'h7ec0000;
    reg clk=0, dclk=0;
    always #5 clk=~clk;
    always #3 dclk=~dclk;
    reg reset=1, session_reset=1;
    reg [1:0] layout=2, gap=0;
    reg order=0, analog_screen=1, split=1;
    reg external_enable=1, touch_pressed=0;
    reg published=0, external_toggle=0, external_screen=1;
    reg [1:0] normal_bank=0, external_bank=1;
    wire split_frame_toggle;
    wire split_active, analog_active, pf_tgl,pf_scr,pf_bank,pf_external,pf_slot,pf_ticket;
    wire [7:0] pf_line;
    wire [1:0] pf_frame_bank;
    wire [3:0] pf_completed,lb_acquire,lb_hold,lb_selected_slot;
    wire [8:0] lb_raddr;
    wire [35:0] lb_q;
    wire lb_valid,ce,de,hs,vs,ace,ade,ahs,avs;
    wire [7:0] r,g,b,ar,ag,ab;
    wire [27:1] read_addr;
    wire read_req;
    reg [63:0] read_data=0;
    reg read_valid=0,read_ready=0;

    nds_nitro_video_scanout dut (
        .clk_video(clk),.reset,.session_reset,.layout_select(layout),
        .screen_order_select(order),.gap_select(gap),.fps_select(1'b0),.crt_select(1'b1),
        .split_select(split),.analog_screen_select(analog_screen),
        .split_active,.analog_screen_active(analog_active),.crt_active(),
        .touch_pressed,.touch_x(8'd128),.touch_y(8'd96),
        .layout_active(),.screen_order_active(),.gap_active(),.fps_active(),
        .pf_tgl,.pf_scr,.pf_line,.pf_bank,.pf_frame_bank,.pf_external,.pf_slot,.pf_ticket,.split_frame_toggle,
        .pf_completed,.lb_acquire,.lb_hold,.lb_selected_slot,
        .published_frame_toggle(published),.published_frame_bank(normal_bank),
        .external_screen_toggle(external_toggle),.external_screen_bank(external_bank),
        .external_screen_select(external_screen),.external_screen_adopted_toggle(),
        .external_enable,.external_quiescent(),.effective_3d_frame_toggle(1'b0),
        .lb_raddr,.lb_q,.lb_valid,.ce_pixel(ce),.de,.hsync(hs),.vsync(vs),
        .red(r),.green(g),.blue(b),.analog_ce(ace),.analog_de(ade),
        .analog_hs(ahs),.analog_vs(avs),.analog_r(ar),.analog_g(ag),.analog_b(ab)
    );
    nds_nitro_fb_ddr3 #(.FB_HW_BASE(FB_BASE),.ENGINE_B_HW_BASE(EXT_BASE),
                           .FB_BURST(128),.RUNTIME_TELEMETRY(0)) fb (
        .clk_sys(dclk),.CLK_VIDEO(clk),.reset_sys(session_reset),.reset_video(reset),
        .reset_read(reset),.external_enable,.external_quiescent(),
        .pix_x(8'd0),.pix_y(8'd0),.pix_d(18'd0),.pix_we(1'b0),
        .pixb_x(8'd0),.pixb_y(8'd0),.pixb_d(18'd0),.pixb_we(1'b0),
        .source_fault(1'b0),.telemetry_session(32'd0),
        .external_frame_mode(MATCHED!=0),.external_frame_publish(1'b0),
        .external_frame_bank(2'd0),.external_frame_adopted(),
        .dbg0(18'd0),.dbg1(18'd0),.dbg2(18'd0),.dbg3(18'd0),
        .dbg4(18'd0),.dbg5(18'd0),.dbg6(18'd0),.dbg7(18'd0),
        .dbg8(18'd0),.dbg9(18'd0),.dbg10(18'd0),.dbg11(18'd0),
        .pf_tgl,.pf_scr,.pf_line,.pf_bank,.pf_frame_bank,.pf_external,
        .split_mode(split_active),.pf_slot,.pf_ticket,.split_frame_toggle,.pf_completed,
        .lb_acquire,.lb_hold,.lb_selected_slot,.lb_raddr,.lb_q,.lb_valid,
        .published_frame_toggle(),.published_frame_bank(),.scanout_late_count(),
        .runtime_fault_flags(),.bank_diagnostic(),
        .fb5_addr(),.fb5_din(),.fb5_req(),.fb5_next(1'b0),.fb5_ready(1'b0),
        .fb6_addr(read_addr),.fb6_req(read_req),.fb6_dout(read_data),
        .fb6_valid(read_valid),.fb6_ready(read_ready)
    );

    function automatic [17:0] pixel(input integer x,y,scr,bank,ext);
        pixel={ext[0],bank[0],scr[0],y[7:6],1'b1,y[5:0],x[5:0]};
    endfunction
    function automatic [23:0] rgb(input [17:0] p);
        rgb={p[5:0],p[5:4],p[11:6],p[11:10],p[17:12],p[17:16]};
    endfunction
    integer beat=0,delay_count=0,requests=0,inject_stall=0;
    integer mx,my,ms,mb,me;
    reg bus_busy=0;
    reg [27:1] offset;
    always @(posedge dclk) begin
        read_valid<=0;read_ready<=0;
        if (reset) bus_busy=0;
        else if (read_req) begin
            if(bus_busy) $fatal(1,"overlapping DDR bursts");
            bus_busy=1;beat=0;
            me=fb.rexternal;
            offset=read_addr-(me ? EXT_BASE : FB_BASE);
            mx=2*((offset>>2)&127); my=(offset>>9)&255;
            ms=me ? fb.rscr : (offset>>17)&1;
            mb=me ? (offset>>17)&1 : (offset>>18)&3;
            delay_count=inject_stall ? inject_stall : 16+(requests%23);
            inject_stall=0;requests=requests+1;
        end else if(bus_busy) begin
            if(delay_count) delay_count=delay_count-1;
            else begin
                read_data<={14'd0,pixel(mx+beat*2+1,my,ms,mb,me),
                            14'd0,pixel(mx+beat*2,my,ms,mb,me)};
                read_valid<=1;read_ready<=beat==127;
                if(beat==127) bus_busy=0;
                else begin
                    beat=beat+1;
                    if(beat%13==0) delay_count=2;
                end
            end
        end
    end

    reg checking=0, exact=1;
    integer comparisons=0,clock_count=0,last_analog_frame=0,analog_frames=0;
    reg [15:0] line_tag[0:2];
    reg line_black[0:2];
    task automatic check_pixel(input integer consumer,x,y,scr,input [23:0] actual);
        reg [23:0] wanted;
        integer dx,dy;
        begin
            wanted=rgb(pixel(x,y,scr,dut.active_screen_bank[scr],dut.active_screen_external[scr]));
            dx=x-128;dy=y-96;
            if(scr==1 && touch_pressed) begin
                if((dx==0 && dy>=-4 && dy<=4) || (dy==0 && dx>=-4 && dx<=4)) wanted=24'hff0000;
                else if((dx>=-1 && dx<=1 && dy>=-5 && dy<=5) ||
                        (dy>=-1 && dy<=1 && dx>=-5 && dx<=5)) wanted=0;
            end
            if(exact && actual!==wanted)
                $fatal(1,"pixel c=%0d layout=%0d x=%0d y=%0d scr=%0d actual=%h wanted=%h hc=%0d vc=%0d slot=%b busy=%b",
                    consumer,layout,x,y,scr,actual,wanted,dut.hcount,dut.vcount,lb_selected_slot,lb_hold);
            if(x==0) begin
                line_tag[consumer]=actual[15:0];
                line_black[consumer]=actual==0;
            end
            if(!exact && (actual[15:0]!==line_tag[consumer] ||
                (line_black[consumer] ? actual!=0 : actual[23:16]!==wanted[23:16])))
                $fatal(1,"partial line exposed c=%0d x=%0d y=%0d actual=%h tag=%h",consumer,x,y,actual,line_tag[consumer]);
            comparisons=comparisons+1;
        end
    endtask
    integer x,y,scr,sx,sy,second_x,second_y;
    reg in_panel;
    reg [1:0] stalled_context;
    reg stalled_slot, stalled_ticket, before_request;
    always @(negedge clk) begin
        clock_count=clock_count+1;
        if(split_active && dut.analog_hcount==0 && dut.analog_vcount==0 && dut.analog_divider==0) begin
            if(checking && last_analog_frame && clock_count-last_analog_frame!=3840*262)
                $fatal(1,"analog frame duration %0d",clock_count-last_analog_frame);
            last_analog_frame=clock_count;
            analog_frames=analog_frames+1;
        end
        // Writer and visible slots may never alias while a split burst owns DDR.
        if(split_active && fb.rbusy && fb.r_split && !fb.r_session_cancel &&
           (fb.rslot==lb_selected_slot[{fb.rbank,fb.rscr}] ||
            (fb.active_line_valid[{fb.rbank,fb.rscr}] &&
             fb.rslot==fb.active_line_slot[{fb.rbank,fb.rscr}])) && checking)
            $fatal(1,"visible line slot overwritten");
        if(checking && ce) begin
            x=dut.hcount==0 ? dut.horizontal_total-1 : dut.hcount-1;
            y=dut.hcount==0 ? (dut.vcount==0 ? dut.vertical_total+dut.frame_extra-1 : dut.vcount-1) : dut.vcount;
            in_panel=0;sx=0;sy=0;scr=0;
            second_x=256+8*dut.gap_active;
            second_y=192+8*dut.gap_active;
            if(dut.crt_active) begin
                in_panel=x>=32 && x<288 && y>=24 && y<216;
                sx=x-32;sy=y-24;
                scr=dut.screen_order_active ^ (dut.layout_active==3);
            end else if(dut.layout_active==0) begin
                in_panel=y<192 && (x<256 || (x>=second_x && x<second_x+256));
                sx=x<256 ? x : x-second_x;sy=y;
                scr=dut.screen_order_active ^ (x>=second_x);
            end else begin
                in_panel=x<256 && (y<192 || (y>=second_y && y<second_y+192));
                sx=x;sy=y<192 ? y : y-second_y;
                scr=dut.screen_order_active ^ (y>=second_y);
            end
            if(in_panel) check_pixel(scr,sx,sy,scr,{r,g,b});
            else if({r,g,b}!==0) $fatal(1,"digital border not black");
        end
        if(checking && ace) begin
            x=dut.analog_hcount==0 ? 383 : dut.analog_hcount-1;
            y=dut.analog_hcount==0 ? (dut.analog_vcount==0 ? 261 : dut.analog_vcount-1) : dut.analog_vcount;
            if(x>=32 && x<288 && y>=24 && y<216)
                check_pixel(2,x-32,y-24,analog_active,{ar,ag,ab});
            else if({ar,ag,ab}!==0) $fatal(1,"analog border not black");
            if(ade!==(x<320 && y<240) || ahs!==!(x>=328 && x<356) || avs!==!(y>=243 && y<246))
                $fatal(1,"analog sync/DE changed with digital layout");
        end
    end
    task automatic frame;
        begin
            @(negedge clk);
            while(!(dut.hcount==0 && dut.vcount==0 && dut.pixel_divider==0)) @(negedge clk);
        end
    endtask
    initial begin
        repeat(12) @(negedge clk); reset=0;session_reset=0;published=1;
        for(integer k=0;k<16;k=k+1) begin
            checking=0;
            layout=k%4;analog_screen=(k/4)%2;order=k/8;gap=k%2 ? 3 : 0;
            frame();frame();frame();
            checking=1;frame();checking=0;
            $display("PASS layout=%0d analog=%0d order=%0d gap=%0d",layout,analog_screen,order,gap);
        end
        // Publish AFTER the shared h=0 adoption edge but BEFORE h=16
        // prefetch. Neither normal nor external pending data may be consumed
        // early, even though the request is on the final raster line.
        layout=0;order=0;gap=0;normal_bank=0;published=~published;
        frame();frame();frame();
        for(integer k=0;k<2;k=k+1) begin
            while(!(dut.frame_end && dut.hcount==1 && dut.pixel_divider==0)) @(negedge clk);
            before_request=pf_tgl;
            if(k==0) begin normal_bank=1;published=~published;end
            else begin external_screen=0;external_bank=1;external_toggle=~external_toggle;end
            wait(pf_tgl!=before_request);@(negedge clk);
            if(pf_external!==dut.active_screen_external[pf_scr] ||
               pf_frame_bank!==dut.active_screen_bank[pf_scr])
                $fatal(1,"unadopted publication used for first digital row, kind=%0d",k);
            frame();frame();frame();checking=1;frame();checking=0;
        end
        $display("PASS normal/external late publications wait for shared adoption");

        // Late responses must hold a complete line, never a partially replaced
        // row. Repeat in the two digital geometries with concurrent source rows.
        for(integer k=0;k<2;k=k+1) begin
            layout=k;gap=0;frame();frame();frame();
            exact=0;checking=1;inject_stall=9000;
            while(dut.analog_vcount!=100) @(negedge clk);
            inject_stall=18000;
            frame();frame();checking=0;exact=1;frame();checking=1;frame();checking=0;
        end
        // Delay one accepted read beyond the next publication and simulate its
        // source bank being recycled before the response. It must drain without
        // promoting that row; both consumers then recover on the new frame.
        layout=0;order=0;normal_bank=0;published=~published;
        frame();frame();frame();
        while(dut.analog_vcount!=100) @(negedge clk);
        exact=0;checking=1;inject_stall=2000000;
        wait(delay_count>1000000);
        @(negedge dclk);
        stalled_context={fb.rbank,fb.rscr};stalled_slot=fb.rslot;stalled_ticket=fb.r_ticket;
        normal_bank=1;published=~published;
        wait(fb.split_frame_change);@(posedge dclk);@(negedge dclk);
        if(!fb.r_obsolete) $fatal(1,"old frame read did not expire");
        // Poison this response as though the renderer overwrote its source.
        ms=ms^1;mb=mb^1;
        wait(read_ready);repeat(2) @(negedge dclk);
        if(fb.active_line_slot[stalled_context]==stalled_slot ||
           pf_completed[stalled_context]!==stalled_ticket)
            $fatal(1,"old frame read promoted or failed to release ticket");
        frame();frame();checking=0;exact=1;frame();checking=1;frame();checking=0;
        $display("PASS frame-spanning DDR stall discarded and recovered");

        // A completed external plane can move between physical DS screens.
        for(integer k=0;k<2;k=k+1) begin
            external_screen=k;external_toggle=~external_toggle;
            normal_bank=1;published=~published;
            frame();frame();frame();checking=1;frame();checking=0;
        end
        layout=0;analog_screen=1;touch_pressed=1;
        frame();frame();frame();checking=1;frame();checking=0;touch_pressed=0;

        // The accepted release uses matched external-frame mode. Session
        // withdrawal must drain its outstanding work and clear both readers.
        wait(fb.rbusy);
        @(negedge clk);session_reset=1;external_enable=0;
        frame();frame();
        if(!fb.external_quiescent || !dut.external_quiescent || fb.rbusy || |fb.split_pending)
            $fatal(1,"split session failed to quiesce");
        repeat(4000) begin
            @(negedge clk);
            if((ce && {r,g,b}!=0) || (ace && {ar,ag,ab}!=0)) $fatal(1,"old session pixel survived");
        end
        session_reset=0;external_enable=1;normal_bank=0;published=~published;
        frame();frame();frame();checking=1;frame();checking=0;

        // Change the cache interpretation while a deliberately late final-row
        // request still owns DDR. Returning to split mode must make progress.
        while(!(dut.frame_end && dut.hcount==0 && dut.pixel_divider==0)) @(negedge clk);
        inject_stall=9000;split=0;
        frame();frame();
        if(split_active) $fatal(1,"split mode did not disable");
        split=1;layout=1;
        frame();frame();frame();checking=1;frame();checking=0;
        $display("PASS split video: %0d pixel comparisons, %0d DDR lines, %0d fixed analog frames",comparisons,requests,analog_frames);
        $finish;
    end
    initial begin #2000000000; $fatal(1,"timeout"); end
endmodule
