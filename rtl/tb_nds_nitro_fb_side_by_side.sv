// SPDX-License-Identifier: GPL-3.0-or-later
// Prove that both screens and both row parities occupy distinct read banks.
`timescale 1ns/1ps

module tb_nds_nitro_fb_side_by_side;
    localparam [27:1] FB_BASE = 27'h7f00000;
    localparam [27:1] ENGINE_B_BASE = 27'h7ec0000;
    logic clk_sys = 0, clk_video = 0;
    always #8.333 clk_sys = ~clk_sys;
    always #7 clk_video = ~clk_video;

    logic reset_sys = 1, reset_video = 1;
    logic pf_tgl = 0, pf_scr = 0, pf_bank = 0;
    logic [1:0] pf_frame_bank = 0;
    logic pf_external = 0;
    logic [7:0] pf_line = 0;
    logic [8:0] lb_raddr = 0;
    wire [35:0] lb_q;
    wire [27:1] fb6_addr;
    wire fb6_req;
    wire published_frame_toggle;
    wire [1:0] published_frame_bank;
    wire [7:0] scanout_late_count;
    logic external_frame_mode = 0;
    logic external_frame_publish = 0;
    logic [1:0] external_frame_bank = 0;
    wire external_frame_adopted;
    logic [63:0] fb6_dout = 0;
    logic fb6_valid = 0, fb6_ready = 0;

    nds_nitro_fb_ddr3 #(
        .FB_HW_BASE(FB_BASE), .FB_BURST(8'd128),
        .RUNTIME_TELEMETRY(1'b0)
    ) dut (
        .clk_sys, .CLK_VIDEO(clk_video), .reset_sys, .reset_video,
        .pix_x(8'd0), .pix_y(8'd0), .pix_d(18'd0), .pix_we(1'b0),
        .pixb_x(8'd0), .pixb_y(8'd0), .pixb_d(18'd0), .pixb_we(1'b0),
        .source_fault(1'b0), .telemetry_session(32'd0),
        .external_frame_mode, .external_frame_publish,
        .external_frame_bank, .external_frame_adopted,
        .dbg0(18'd0), .dbg1(18'd0), .dbg2(18'd0), .dbg3(18'd0),
        .dbg4(18'd0), .dbg5(18'd0), .dbg6(18'd0), .dbg7(18'd0),
        .dbg8(18'd0), .dbg9(18'd0), .dbg10(18'd0), .dbg11(18'd0),
        .pf_tgl, .pf_scr, .pf_line, .pf_bank, .pf_frame_bank,
        .pf_external,
        .published_frame_toggle, .published_frame_bank,
        .scanout_late_count, .lb_raddr, .lb_q,
        .fb5_addr(), .fb5_din(), .fb5_req(),
        .fb5_next(1'b0), .fb5_ready(1'b0),
        .fb6_addr, .fb6_req, .fb6_dout, .fb6_valid, .fb6_ready
    );

    function automatic [17:0] tagged_pixel;
        input logic [1:0] tag;
        input logic [6:0] pair_index;
        input logic half;
        tagged_pixel = {tag, pair_index, half, 8'h5a};
    endfunction

    task automatic load_line(
        input logic screen,
        input logic bank,
        input logic [1:0] frame_bank,
        input logic [7:0] line_number,
        input logic [1:0] tag
    );
        integer index;
        logic [27:1] expected_addr;
        begin
            expected_addr = FB_BASE + {frame_bank, screen, line_number, 9'd0};
            @(negedge clk_video);
            pf_scr = screen;
            pf_bank = bank;
            pf_frame_bank = frame_bank;
            pf_line = line_number;
            pf_tgl = ~pf_tgl;
            wait (fb6_req);
            #1;
            if (fb6_addr !== expected_addr)
                $fatal(1, "read address mismatch got=%h expected=%h",
                       fb6_addr, expected_addr);
            for (index = 0; index < 128; index = index + 1) begin
                @(negedge clk_sys);
                fb6_dout = 64'd0;
                fb6_dout[17:0] = tagged_pixel(tag, index[6:0], 1'b0);
                fb6_dout[49:32] = tagged_pixel(tag, index[6:0], 1'b1);
                fb6_valid = 1;
                fb6_ready = (index == 127);
            end
            @(negedge clk_sys);
            fb6_valid = 0;
            fb6_ready = 0;
            wait (!dut.rbusy);
            repeat (4) @(posedge clk_video);
        end
    endtask

    task automatic load_engine_b_line(
        input logic screen,
        input logic bank,
        input logic engine_b_bank,
        input logic [7:0] line_number,
        input logic [1:0] tag
    );
        integer index;
        logic [27:1] expected_addr;
        begin
            expected_addr = ENGINE_B_BASE +
                {engine_b_bank, line_number, 9'd0};
            @(negedge clk_video);
            pf_scr = screen;
            pf_bank = bank;
            pf_frame_bank = {1'b0, engine_b_bank};
            pf_line = line_number;
            pf_external = 1'b1;
            pf_tgl = ~pf_tgl;
            wait (fb6_req);
            #1;
            if (fb6_addr !== expected_addr)
                $fatal(1, "Engine-B address mismatch got=%h expected=%h",
                       fb6_addr, expected_addr);
            for (index = 0; index < 128; index = index + 1) begin
                @(negedge clk_sys);
                fb6_dout = 64'd0;
                fb6_dout[17:0] = tagged_pixel(tag, index[6:0], 1'b0);
                fb6_dout[49:32] = tagged_pixel(tag, index[6:0], 1'b1);
                fb6_valid = 1;
                fb6_ready = (index == 127);
            end
            @(negedge clk_sys);
            fb6_valid = 0;
            fb6_ready = 0;
            pf_external = 1'b0;
            wait (!dut.rbusy);
            repeat (4) @(posedge clk_video);
        end
    endtask

    task automatic request_line(
        input logic screen,
        input logic bank,
        input logic [1:0] frame_bank,
        input logic [7:0] line_number
    );
        begin
            @(negedge clk_video);
            pf_scr = screen;
            pf_bank = bank;
            pf_frame_bank = frame_bank;
            pf_line = line_number;
            pf_tgl = ~pf_tgl;
        end
    endtask

    task automatic expect_request_and_serve(
        input logic screen,
        input logic [1:0] frame_bank,
        input logic [7:0] line_number,
        input logic [1:0] tag
    );
        integer index;
        logic [27:1] expected_addr;
        begin
            expected_addr = FB_BASE + {frame_bank, screen, line_number, 9'd0};
            wait (fb6_req);
            #1;
            if (fb6_addr !== expected_addr)
                $fatal(1,
                       "queued read order mismatch got=%h expected=%h line=%0d",
                       fb6_addr, expected_addr, line_number);
            for (index = 0; index < 128; index = index + 1) begin
                @(negedge clk_sys);
                fb6_dout = 64'd0;
                fb6_dout[17:0] = tagged_pixel(tag, index[6:0], 1'b0);
                fb6_dout[49:32] = tagged_pixel(tag, index[6:0], 1'b1);
                fb6_valid = 1;
                fb6_ready = (index == 127);
            end
            @(negedge clk_sys);
            fb6_valid = 0;
            fb6_ready = 0;
            wait (!dut.rbusy);
        end
    endtask

    task automatic check_pair(
        input logic bank,
        input logic screen,
        input logic [6:0] pair_index,
        input logic [1:0] tag
    );
        logic [35:0] expected;
        begin
            expected = {tagged_pixel(tag, pair_index, 1'b1),
                        tagged_pixel(tag, pair_index, 1'b0)};
            @(negedge clk_video);
            // x=0 is the atomic line-slot adoption boundary.
            lb_raddr = {bank, screen, 7'd0};
            @(posedge clk_video);
            @(negedge clk_video);
            lb_raddr = {bank, screen, pair_index};
            @(posedge clk_video);
            #1;
            if (lb_q !== expected)
                $fatal(1,
                       "line-buffer alias bank=%0d screen=%0d pair=%0d got=%h expected=%h",
                       bank, screen, pair_index, lb_q, expected);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk_sys);
        reset_sys = 0;
        reset_video = 0;

        load_line(1'b0, 1'b0, 2'd0, 8'd20, 2'd0);
        load_line(1'b1, 1'b0, 2'd1, 8'd20, 2'd1);
        load_line(1'b0, 1'b1, 2'd2, 8'd21, 2'd2);
        load_line(1'b1, 1'b1, 2'd3, 8'd21, 2'd3);

        check_pair(1'b0, 1'b0, 7'd0,   2'd0);
        check_pair(1'b0, 1'b0, 7'd127, 2'd0);
        check_pair(1'b0, 1'b1, 7'd0,   2'd1);
        check_pair(1'b0, 1'b1, 7'd127, 2'd1);
        check_pair(1'b1, 1'b0, 7'd0,   2'd2);
        check_pair(1'b1, 1'b0, 7'd127, 2'd2);
        check_pair(1'b1, 1'b1, 7'd0,   2'd3);
        check_pair(1'b1, 1'b1, 7'd127, 2'd3);

        // Engine B owns a separate two-bank DDR window but still lands in
        // the physical screen/parity line-buffer slot requested by scanout.
        load_engine_b_line(1'b1, 1'b0, 1'b1, 8'd22, 2'd2);
        check_pair(1'b0, 1'b1, 7'd0,   2'd2);
        check_pair(1'b0, 1'b1, 7'd127, 2'd2);

        // A delayed Engine-B fetch must remain invisible until its final
        // pair arrives. The former direct-to-live line buffer exposed a new
        // left half and an old right half here, matching the vertical-band
        // corruption seen on hardware under DDR contention.
        request_line(1'b1, 1'b0, 2'd0, 8'd24);
        pf_external = 1'b1;
        wait (fb6_req);
        #1;
        if (fb6_addr !== ENGINE_B_BASE + {1'b0, 8'd24, 9'd0})
            $fatal(1, "delayed Engine-B request address mismatch");
        for (integer index = 0; index < 64; index = index + 1) begin
            @(negedge clk_sys);
            fb6_dout = 64'd0;
            fb6_dout[17:0] = tagged_pixel(2'd3, index[6:0], 1'b0);
            fb6_dout[49:32] = tagged_pixel(2'd3, index[6:0], 1'b1);
            fb6_valid = 1;
            fb6_ready = 0;
        end
        @(negedge clk_sys);
        fb6_valid = 0;
        check_pair(1'b0, 1'b1, 7'd0,   2'd2);
        check_pair(1'b0, 1'b1, 7'd127, 2'd2);
        for (integer index = 64; index < 128; index = index + 1) begin
            @(negedge clk_sys);
            fb6_dout = 64'd0;
            fb6_dout[17:0] = tagged_pixel(2'd3, index[6:0], 1'b0);
            fb6_dout[49:32] = tagged_pixel(2'd3, index[6:0], 1'b1);
            fb6_valid = 1;
            fb6_ready = (index == 127);
        end
        @(negedge clk_sys);
        fb6_valid = 0;
        fb6_ready = 0;
        pf_external = 1'b0;
        wait (!dut.rbusy);
        repeat (4) @(posedge clk_video);
        check_pair(1'b0, 1'b1, 7'd0,   2'd3);
        check_pair(1'b0, 1'b1, 7'd127, 2'd3);

        // A full DDR read may overlap more than one 32 us scanout request
        // under product contention.  Once line 32 is requested, queued line
        // 31 has missed its row-parity deadline and must not be replayed over
        // the bank that scanout now needs for line 32.
        request_line(1'b0, 1'b0, 2'd1, 8'd30);
        wait (fb6_req);
        #1;
        if (fb6_addr !== FB_BASE + {2'd1, 1'b0, 8'd30, 9'd0})
            $fatal(1, "contention first request mismatch");
        request_line(1'b1, 1'b1, 2'd2, 8'd31);
        repeat (5) @(posedge clk_sys);
        request_line(1'b0, 1'b0, 2'd3, 8'd32);
        repeat (5) @(posedge clk_sys);
        for (integer index = 0; index < 128; index = index + 1) begin
            @(negedge clk_sys);
            fb6_dout = 64'd0;
            fb6_dout[17:0] = tagged_pixel(2'd0, index[6:0], 1'b0);
            fb6_dout[49:32] = tagged_pixel(2'd0, index[6:0], 1'b1);
            fb6_valid = 1;
            fb6_ready = (index == 127);
        end
        @(negedge clk_sys);
        fb6_valid = 0;
        fb6_ready = 0;
        wait (!dut.rbusy);
        if (scanout_late_count != 8'd2)
            $fatal(1, "late scanout read count mismatch got=%0d expected=2",
                   scanout_late_count);
        expect_request_and_serve(1'b0, 2'd3, 8'd32, 2'd2);

        // Both screens for one still-current target row remain ordered while
        // an older read is active.
        request_line(1'b0, 1'b0, 2'd0, 8'd40);
        wait (fb6_req);
        request_line(1'b0, 1'b1, 2'd1, 8'd41);
        repeat (5) @(posedge clk_sys);
        request_line(1'b1, 1'b1, 2'd1, 8'd41);
        for (integer index = 0; index < 128; index = index + 1) begin
            @(negedge clk_sys);
            fb6_dout = 64'd0;
            fb6_valid = 1;
            fb6_ready = (index == 127);
        end
        @(negedge clk_sys);
        fb6_valid = 0;
        fb6_ready = 0;
        wait (!dut.rbusy);
        expect_request_and_serve(1'b0, 2'd1, 8'd41, 2'd1);
        expect_request_and_serve(1'b1, 2'd1, 8'd41, 2'd2);

        // A complete ARM-rendered bank becomes visible only after the normal
        // scanout prefetch handshake adopts it; this pulse gates HPS reuse.
        @(negedge clk_sys);
        external_frame_mode = 1;
        external_frame_bank = 2'd3;
        external_frame_publish = 1;
        @(negedge clk_sys);
        external_frame_publish = 0;
        if (published_frame_bank != 2'd3 ||
            published_frame_toggle != 1'b1)
            $fatal(1, "external framebuffer publication was not retained");
        request_line(1'b0, 1'b0, 2'd3, 8'd42);
        wait (external_frame_adopted);
        if (dut.scanout_frame_bank != 2'd3)
            $fatal(1, "scanout adoption acknowledged the wrong frame bank");

        $display("PASS: framebuffer keeps banks distinct, expires late rows, retains both current-row screens, and safely adopts ARM frame banks");
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "side-by-side framebuffer timeout");
    end
endmodule
