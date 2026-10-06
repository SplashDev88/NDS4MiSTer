// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_crt_video;
    reg clk_video=0; always #5 clk_video=~clk_video;
    reg reset=1, session_reset=0, crt_select=1;
    reg [1:0] layout_select=2, gap_select=1;
    reg screen_order_select=0, fps_select=0, touch_pressed=0;
    reg [7:0] touch_x=128, touch_y=96;
    wire [1:0] layout_active, gap_active;
    wire crt_active,screen_order_active,fps_active,pf_tgl,pf_scr,pf_bank,pf_external;
    wire [7:0] pf_line;
    wire [1:0] pf_frame_bank;
    reg published_frame_toggle=0, external_screen_toggle=0;
    reg [1:0] published_frame_bank=0, external_screen_bank=1;
    reg external_screen_select=1, external_enable=1;
    reg effective_3d_frame_toggle=0;
    wire external_screen_adopted_toggle,external_quiescent;
    wire [8:0] lb_raddr;
    // Screen identity, pixel address and pointer placement can all be checked
    // independently of the DDR reader using two solid-color physical panels.
    wire [35:0] lb_q = lb_raddr[7] ? {18'h00fc0,18'h00fc0} : {18'h0003f,18'h0003f};
    reg lb_valid=1;
    wire ce_pixel,de,hsync,vsync;
    wire [7:0] red,green,blue;
    nds_nitro_video_scanout dut(.*);
    integer ticks=0, previous_hs=0;
    reg old_hs=1, monitor=0;
    always @(negedge clk_video) begin
        ticks=ticks+1;
        if(monitor && old_hs && !hsync) begin
            if(previous_hs && ticks-previous_hs != 3840)
                $fatal(1,"CRT line period is not 64 us at the 60 MHz shell clock");
            previous_hs=ticks;
        end
        old_hs=hsync;
    end
    task frame(input bit touch);
        integer dots,painted,requests, x,y,first_tick;
        reg old_pf;
        begin
            @(negedge vsync);
            dots=0; painted=0; requests=0; old_pf=pf_tgl;
            x=0; y=0; first_tick=ticks;
            @(negedge clk_video);
            while(vsync==0) @(negedge clk_video);
            while(vsync==1) begin
                @(negedge clk_video);
                if(pf_tgl != old_pf) begin
                    if(pf_scr !== touch || pf_line > 191)
                        $fatal(1,"CRT fetched wrong physical panel/row");
                    requests=requests+1; old_pf=pf_tgl;
                end
                if(ce_pixel && de) begin
                    if((x>=32 && x<288) && (y>=24 && y<216)) begin
                        if({red,green,blue} !== (touch ? 24'h00ff00 : 24'hff0000))
                            $fatal(1,"panel pixel mismatch at %0d,%0d: %h",x,y,{red,green,blue});
                        painted=painted+1;
                    end else if({red,green,blue} !== 0)
                        $fatal(1,"nonblack CRT border at %0d,%0d",x,y);
                    dots=dots+1;
                    if(x==319) begin x=0; y=y+1; end else x=x+1;
                end
            end
            if(dots != 320*240 || painted != 256*192 || requests != 192)
                $fatal(1,"CRT frame geometry/fetch mismatch: %0d %0d %0d",dots,painted,requests);
            if(ticks-first_tick != 3840*261 && ticks-first_tick != 3840*262)
                $fatal(1,"wrong CRT frame cadence %0d",ticks-first_tick);
        end
    endtask
    initial begin
        repeat(8) @(negedge clk_video); reset=0;
        published_frame_toggle=1;
        wait(crt_active); repeat(2) @(negedge vsync);
        monitor=1;
        frame(0);
        // Switch while visible. Selection must not change before blanking.
        wait(de); layout_select=3;
        if(layout_active != 2) $fatal(1,"non-atomic panel selection");
        wait(layout_active==3); frame(1);
        // Screen Order reverses the physical panel, not touch coordinates.
        screen_order_select=1; wait(screen_order_active); frame(0);
        // A stale Top/Bottom setting must still produce a 15 kHz single panel.
        layout_select=1; wait(layout_active==2); frame(1);
        monitor=0; crt_select=0; layout_select=0;
        wait(!crt_active);
        @(negedge clk_video);
        if(dut.horizontal_total != 640 || dut.pixel_divider_limit != 5)
            $fatal(1,"normal raster not restored");
        $display("PASS: CRT240p cadence, centered pixels, both panels, screen order, stale stack and normal-mode restore");
        $finish;
    end
    initial begin #200000000; $fatal(1,"CRT test timeout"); end
endmodule
