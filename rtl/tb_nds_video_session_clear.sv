// SPDX-License-Identifier: GPL-3.0-or-later
// Old DDR pixels are deliberately nonzero throughout this test.
`timescale 1ns/1ps
module tb_nds_video_session_clear;
    reg clk_video=0; always #5 clk_video=~clk_video;
    reg reset=1, session_reset=1;
    reg [1:0] layout_select=0, gap_select=0;
    reg screen_order_select=0, fps_select=0, touch_pressed=0;
    reg [7:0] touch_x=128, touch_y=96;
    wire [1:0] layout_active, gap_active;
    wire screen_order_active,fps_active,pf_tgl,pf_scr,pf_bank,pf_external;
    wire [7:0] pf_line;
    wire [1:0] pf_frame_bank;
    reg published_frame_toggle=0, external_screen_toggle=0;
    reg [1:0] published_frame_bank=0, external_screen_bank=1;
    reg external_screen_select=1, external_enable=0;
    reg effective_3d_frame_toggle=0;
    wire external_screen_adopted_toggle,external_quiescent;
    wire [8:0] lb_raddr;
    reg [35:0] lb_q={18'h3ffff,18'h3ffff};
    reg lb_valid=1;
    wire ce_pixel,de,hsync,vsync;
    wire [7:0] red,green,blue;
    nds_nitro_video_scanout dut(.*);
    integer pixels=0,requests=0;
    reg old_pf=0;
    always @(negedge clk_video) if(!reset) begin
        if(ce_pixel) pixels=pixels+1;
        if(pf_tgl!=old_pf) requests=requests+1;
        old_pf=pf_tgl;
    end
    task boundary;
        // Position immediately before the real end-of-frame adoption edge.
        @(negedge clk_video);
        dut.hcount=0; dut.vcount=dut.vertical_total-1+dut.frame_extra;
        dut.pixel_divider=dut.pixel_divider_limit;
        repeat(2) @(negedge clk_video);
    endtask
    task visible;
        @(negedge clk_video);
        dut.hcount=32; dut.vcount=32;
        dut.pixel_divider=dut.pixel_divider_limit;
        repeat(4) @(negedge clk_video);
    endtask
    task expect_black;
        visible();
        if({red,green,blue}!==24'd0) $fatal(1,"stale image exposed: %h",{red,green,blue});
    endtask
    task fresh;
        @(negedge clk_video);
        published_frame_bank=published_frame_bank+1'b1;
        published_frame_toggle=~published_frame_toggle;
        repeat(8) @(negedge clk_video);
        boundary(); visible();
        if({red,green,blue}!==24'hffffff) $fatal(1,"fresh frame not displayed");
    endtask
    integer before_pixels,before_requests;
    initial begin
        repeat(8) @(negedge clk_video); reset=0;
        repeat(8) @(negedge clk_video);
        expect_black();
        session_reset=0;
        repeat(8) @(negedge clk_video); boundary(); expect_black();
        if(requests!=0) $fatal(1,"unpublished DDR was fetched on startup");
        fresh();
        // A complete frame publication does not make an unfetched line valid.
        // The RAM deliberately retains white data while its valid bit is low.
        lb_valid=0; expect_black();
        lb_valid=1; visible();
        if({red,green,blue}!==24'hffffff)
            $fatal(1,"valid line did not recover without extra pixel latency");
        for(integer mode=0;mode<2;mode=mode+1) begin
            external_enable=mode!=0;
            external_screen_toggle=~external_screen_toggle;
            repeat(8) @(negedge clk_video); boundary();
            @(negedge clk_video); session_reset=1; external_enable=0;
            // The old writer clears its toggle and bank after the reset edge.
            repeat(4) @(negedge clk_video);
            published_frame_toggle=0; published_frame_bank=0;
            external_screen_toggle=0;
            repeat(8) @(negedge clk_video);
            before_pixels=pixels; before_requests=requests;
            repeat(300) @(negedge clk_video);
            if(pixels-before_pixels<40 || requests!=before_requests)
                $fatal(1,"session clear stopped raster or fetched old content");
            expect_black(); boundary(); expect_black();
            @(negedge clk_video); session_reset=0; external_enable=mode!=0;
            repeat(8) @(negedge clk_video); boundary(); expect_black();
            if(dut.normal_frame_valid || dut.active_external_valid)
                $fatal(1,"reset toggle mistaken for fresh publication");
            fresh();
        end
        $display("PASS: Off/On session reset blanks retained pixels, rejects reset/stale toggles, preserves raster, and displays only fresh frames");
        $finish;
    end
    initial begin #1000000; $fatal(1,"timeout"); end
endmodule
