// SPDX-License-Identifier: GPL-3.0-or-later
// Raster, atomic-menu, integer-scale and FPS proof for the menu scanout.
`timescale 1ns/1ps

module tb_nds_nitro_video_scanout;
    logic clk_video = 1'b0;
    always #8.333 clk_video = ~clk_video; // retained 60 MHz shell clock
    logic reset = 1'b1;
    logic [1:0] layout_select = 2'd0;
    logic screen_order_select = 1'b0;
    logic [1:0] gap_select = 2'd0;
    logic fps_select = 1'b0;
    logic touch_pressed = 1'b0;
    logic [7:0] touch_x = 8'd128;
    logic [7:0] touch_y = 8'd96;
    wire [1:0] layout_active;
    wire screen_order_active;
    wire [1:0] gap_active;
    wire fps_active;
    wire pf_tgl, pf_scr, pf_bank;
    wire [1:0] pf_frame_bank;
    wire [7:0] pf_line;
    wire [8:0] lb_raddr;
    logic [35:0] lb_q = 36'h123456789;
    logic published_frame_toggle = 1'b0;
    logic [1:0] published_frame_bank = 2'd0;
    logic effective_3d_frame_toggle = 1'b0;
    wire ce_pixel, de, hsync, vsync;
    wire [7:0] red, green, blue;

    nds_nitro_video_scanout #(.FPS_WINDOW_FRAMES(2)) dut (.*);

    logic [1:0] scale_layout = 0;
    logic [1:0] scale_gap = 0;
    logic scale_fps = 0;
    logic [11:0] hdmi_width = 0;
    logic [11:0] hdmi_height = 0;
    wire [12:0] video_arx, video_ary;
    nds_nitro_integer_scale scale (
        .hdmi_width, .hdmi_height, .layout(scale_layout), .gap(scale_gap),
        .fps_enabled(scale_fps), .video_arx, .video_ary
    );

    longint clocks_total = 0;
    longint ce_total = 0;
    longint active_total = 0;
    longint prefetch_total = 0;
    logic old_pf_tgl = 0;

    always @(negedge clk_video) begin
        if (reset) begin
            old_pf_tgl = pf_tgl;
        end else begin
            clocks_total = clocks_total + 1;
            if (ce_pixel) ce_total = ce_total + 1;
            if (ce_pixel && de) active_total = active_total + 1;
            if (pf_tgl != old_pf_tgl) begin
                prefetch_total = prefetch_total + 1;
                old_pf_tgl = pf_tgl;
                if (pf_scr !== 1'b0)
                    $fatal(1, "first-beta scanout requested Engine B");
                if (pf_line > 8'd191 || pf_bank !== pf_line[0])
                    $fatal(1, "bad prefetch line=%0d bank=%0d", pf_line, pf_bank);
            end
            if (lb_raddr !== {dut.local_y[0],1'b0,dut.local_x[7:1]})
                $fatal(1, "line-buffer coordinate mapping mismatch");
        end
    end

    task automatic check_complete_frame(
        input integer expected_width,
        input integer expected_height,
        input integer expected_vtotal,
        input integer expected_divisor,
        input integer expected_prefetches
    );
        longint c0, p0, a0, f0;
        longint frame_ce, frame_clocks;
        begin
            @(negedge vsync);
            c0 = ce_total;
            p0 = prefetch_total;
            a0 = active_total;
            f0 = clocks_total;
            @(negedge vsync);
            frame_ce = ce_total - c0;
            frame_clocks = clocks_total - f0;
            if (frame_ce != 640*expected_vtotal &&
                frame_ce != 640*(expected_vtotal+1))
                $fatal(1, "CE count %0d not %0d/%0d", frame_ce,
                       640*expected_vtotal, 640*(expected_vtotal+1));
            if (frame_clocks != frame_ce*expected_divisor)
                $fatal(1, "pixel divisor mismatch clocks=%0d ce=%0d divisor=%0d",
                       frame_clocks, frame_ce, expected_divisor);
            if (active_total-a0 != expected_width*expected_height)
                $fatal(1, "active pixels %0d expected %0d",
                       active_total-a0, expected_width*expected_height);
            if (prefetch_total-p0 != expected_prefetches)
                $fatal(1, "prefetches %0d expected %0d",
                       prefetch_total-p0, expected_prefetches);
        end
    endtask

    task automatic select_layout(
        input logic [1:0] requested_layout,
        input logic requested_order,
        input logic [1:0] requested_gap,
        input logic requested_fps
    );
        logic [5:0] old_config;
        begin
            wait (dut.vcount == 10'd100 && dut.hcount == 10'd100);
            old_config = {fps_active,gap_active,screen_order_active,
                          layout_active};
            layout_select = requested_layout;
            screen_order_select = requested_order;
            gap_select = requested_gap;
            fps_select = requested_fps;
            while ({fps_active,gap_active,screen_order_active,layout_active} ==
                   old_config) begin
                @(negedge clk_video);
            end
            if (dut.vcount != 0 || dut.hcount > 1)
                $fatal(1, "video configuration did not commit at frame boundary");
            if ({fps_active,gap_active,screen_order_active,layout_active} !==
                {requested_fps,requested_gap,requested_order,requested_layout})
                $fatal(1, "latched video configuration mismatch");
        end
    endtask

    task automatic wait_pointer_pixel(
        input integer output_x,
        input integer output_y,
        input logic expected_white,
        input logic expected_red
    );
        begin
            while (!(dut.hcount == output_x && dut.vcount == output_y))
                @(negedge clk_video);
            #1;
            if (dut.pointer_white_pixel !== expected_white ||
                dut.pointer_red_pixel !== expected_red)
                $fatal(1, "pointer mismatch at output (%0d,%0d) local=(%0d,%0d) white=%0d red=%0d",
                       output_x,output_y,dut.local_x,dut.local_y,
                       dut.pointer_white_pixel,dut.pointer_red_pixel);
        end
    endtask

    task automatic move_pointer_at_next_frame(
        input logic [7:0] requested_x,
        input logic [7:0] requested_y
    );
        begin
            touch_x = requested_x;
            touch_y = requested_y;
            while (!(dut.frame_end && dut.hcount == 10'd639 &&
                     dut.pixel_divider == dut.pixel_divider_limit))
                @(negedge clk_video);
            @(posedge clk_video);
            #1;
            if (!dut.pointer_visible)
                $fatal(1, "stick movement did not make pointer visible");
        end
    endtask

    initial begin
        // Integer scaler: default, gapped side, stacked, and both single modes.
        #1;
        if (video_arx !== 13'd512 || video_ary !== 13'd192)
            $fatal(1, "small-output ratio fallback failed");
        hdmi_width = 12'd1920; hdmi_height = 12'd1080; #1;
        if (video_arx !== 13'h1600 || video_ary !== 13'h1240)
            $fatal(1, "1080p default side-by-side 3x request failed");
        scale_gap = 3; scale_fps = 1; #1;
        if (video_arx !== 13'h1648 || video_ary !== 13'h1252)
            $fatal(1, "1080p gapped/FPS side-by-side request failed");
        scale_layout = 1; #1;
        if (video_arx !== 13'h1200 || video_ary !== 13'h133c)
            $fatal(1, "1080p stacked 2x request failed");
        scale_layout = 2; #1;
        if (video_arx !== 13'h1500 || video_ary !== 13'h13de)
            $fatal(1, "1080p single-screen FPS 5x request failed");
        scale_layout = 3; scale_gap = 0; scale_fps = 0;
        hdmi_width = 12'd3840; hdmi_height = 12'd2160; #1;
        if (video_arx !== 13'h1b00 || video_ary !== 13'h1840)
            $fatal(1, "4K single-screen 11x request failed");

        repeat (8) @(negedge clk_video);
        reset = 1'b0;
        check_complete_frame(512,192,261,6,192);

        // Source-coordinate overlay must appear on both Engine-A aliases.
        move_pointer_at_next_frame(8'd50,8'd60);
        wait_pointer_pixel(50,60,1'b1,1'b0);
        wait_pointer_pixel(306,60,1'b1,1'b0);

        select_layout(2'd1,1'b1,2'd3,1'b1);
        wait_pointer_pixel(50,66,1'b1,1'b0);
        wait_pointer_pixel(50,282,1'b1,1'b0);
        check_complete_frame(256,414,522,3,384);

        select_layout(2'd2,1'b0,2'd2,1'b1);
        wait_pointer_pixel(50,66,1'b1,1'b0);
        check_complete_frame(256,198,261,6,192);

        select_layout(2'd3,1'b1,2'd0,1'b0);
        wait_pointer_pixel(50,60,1'b1,1'b0);
        check_complete_frame(256,192,261,6,192);

        select_layout(2'd0,1'b0,2'd3,1'b1);
        check_complete_frame(536,198,261,6,192);

        // Reset the shortened two-frame FPS sample window. Deliver one new
        // HPS 3D descriptor during each raster and verify the BCD overlay
        // reports 02. Ordinary 2D framebuffer publication is deliberately
        // independent and must not inflate the effective 3D rate.
        reset = 1'b1;
        layout_select = 2'd2;
        gap_select = 0;
        screen_order_select = 0;
        fps_select = 1;
        repeat (8) @(negedge clk_video);
        reset = 1'b0;
        repeat (2) begin
            wait (dut.vcount == 10'd50 && dut.hcount == 10'd100);
            published_frame_bank = published_frame_bank + 1'b1;
            published_frame_toggle = ~published_frame_toggle;
            wait (dut.vcount == 10'd100 && dut.hcount == 10'd100);
            published_frame_bank = published_frame_bank + 1'b1;
            published_frame_toggle = ~published_frame_toggle;
            effective_3d_frame_toggle = ~effective_3d_frame_toggle;
            wait (dut.frame_end && dut.hcount == 10'd639);
            wait (dut.vcount == 0 && dut.hcount == 0);
            @(negedge clk_video);
        end
        if (dut.fps_display_tens !== 0 || dut.fps_display_ones !== 2)
            $fatal(1, "FPS sample is %0d%0d expected 02",
                   dut.fps_display_tens,dut.fps_display_ones);
        wait (fps_active && dut.vcount == 0 && dut.hcount == 0);
        if (!dut.fps_font_pixel)
            $fatal(1, "FPS glyph is not visible above the screen");

        $display("PASS: live side/stack/single layouts, gaps, screen order, integer scale, and FPS overlay");
        $finish;
    end

    initial begin
        #2500000000;
        $fatal(1, "menu scanout timeout");
    end
endmodule
