// SPDX-License-Identifier: GPL-3.0-or-later
// Keep the real legacy ch6 owner alive across a guest/HPS session reset.
`timescale 1ns/1ps
module fb_external_quiesce_case #(parameter integer BURST = 128)(output logic done = 0);
    localparam [27:1] FB_BASE = 27'h7f00000;
    localparam [27:1] B_BASE = 27'h7ec0000;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset_sys = 1, reset_read = 1, reset_video = 1;
    logic external_enable = 0;
    wire external_quiescent;
    logic pf_tgl = 0, pf_scr = 0, pf_bank = 0, pf_external = 0;
    logic [7:0] pf_line = 0;
    logic [1:0] pf_frame_bank = 0;
    logic [8:0] lb_raddr = 0;
    wire [35:0] lb_q;
    wire [27:1] fb6_addr;
    wire fb6_req, fb6_valid, fb6_ready;
    wire [63:0] fb6_dout;
    nds_nitro_fb_ddr3 #(.FB_BURST(BURST), .RUNTIME_TELEMETRY(0)) fb (
        .clk_sys(clk), .CLK_VIDEO(clk), .reset_sys, .reset_read, .reset_video,
        .external_enable, .external_quiescent,
        .pix_x(8'd0), .pix_y(8'd0), .pix_d(18'd0), .pix_we(1'b0),
        .pixb_x(8'd0), .pixb_y(8'd0), .pixb_d(18'd0), .pixb_we(1'b0),
        .source_fault(1'b0), .telemetry_session(32'd0),
        .external_frame_mode(1'b0), .external_frame_publish(1'b0),
        .external_frame_bank(2'd0), .external_frame_adopted(),
        .dbg0(18'd0), .dbg1(18'd0), .dbg2(18'd0), .dbg3(18'd0),
        .dbg4(18'd0), .dbg5(18'd0), .dbg6(18'd0), .dbg7(18'd0),
        .dbg8(18'd0), .dbg9(18'd0), .dbg10(18'd0), .dbg11(18'd0),
        .pf_tgl, .pf_scr, .pf_line, .pf_bank, .pf_frame_bank, .pf_external,
        .published_frame_toggle(), .published_frame_bank(),
        .scanout_late_count(), .runtime_fault_flags(), .bank_diagnostic(),
        .lb_raddr, .lb_q,
        .fb5_addr(), .fb5_din(), .fb5_req(),
        .fb5_next(1'b0), .fb5_ready(1'b0),
        .fb6_addr, .fb6_req, .fb6_dout, .fb6_valid, .fb6_ready
    );

    logic ddr_busy = 0, response_hold = 0;
    wire [7:0] ddr_burst;
    wire [28:0] ddr_addr;
    wire ddr_read;
    logic [63:0] ddr_data = 0;
    logic ddr_valid = 0;
    ddram legacy (
        .DDRAM_CLK(clk), .DDRAM_BUSY(ddr_busy),
        .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr),
        .DDRAM_DOUT(ddr_data), .DDRAM_DOUT_READY(ddr_valid),
        .DDRAM_RD(ddr_read), .DDRAM_DIN(), .DDRAM_BE(), .DDRAM_WE(),
        .ch1_addr(27'd0), .ch1_dout(), .ch1_din(16'd0),
        .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_ready(),
        .ch2_addr(27'd0), .ch2_dout(), .ch2_din(32'd0),
        .ch2_req(1'b0), .ch2_rnw(1'b1), .ch2_ready(),
        .ch3_addr(27'd0), .ch3_dout(), .ch3_din(64'd0),
        .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_be(8'd0), .ch3_ready(),
        .ch4_addr(27'd0), .ch4_dout(), .ch4_din(64'd0),
        .ch4_req(1'b0), .ch4_rnw(1'b1), .ch4_be(8'd0), .ch4_ready(),
        .ch5_addr(27'd0), .ch5_din(64'd0), .ch5_req(1'b0),
        .ch5_burst(8'd128), .ch5_next(), .ch5_ready(),
        .ch6_addr(fb6_addr), .ch6_burst(BURST[7:0]), .ch6_req(fb6_req),
        .ch6_dout(fb6_dout), .ch6_valid(fb6_valid), .ch6_ready(fb6_ready)
    );

    logic response_active = 0, response_external = 0;
    integer response_left = 0;
    integer requests = 0, external_requests = 0;
    integer reads = 0, external_reads = 0, beats = 0, completions = 0;
    wire physical_external = ddr_addr >= {4'b0011, B_BASE[27:3]} &&
        ddr_addr < {4'b0011, FB_BASE[27:3]};
    always @(posedge clk) begin
        ddr_valid <= 0;
        if (fb6_req) begin
            requests = requests + 1;
            if (fb6_addr < FB_BASE) external_requests = external_requests + 1;
        end
        if (fb6_ready) completions = completions + 1;
        if (fb6_valid) beats = beats + 1;
        if (ddr_read && !ddr_busy) begin
            if (response_active) $fatal(1, "overlapping DDR read");
            reads = reads + 1;
            if (physical_external) external_reads = external_reads + 1;
            response_active <= 1;
            response_external <= physical_external;
            response_left <= ddr_burst;
        end else if (response_active && !response_hold) begin
            ddr_valid <= 1;
            ddr_data <= response_external ? 64'h0002a5a5_00015555 :
                                           64'h00001234_00002345;
            response_left <= response_left - 1;
            if (response_left == 1) response_active <= 0;
        end
        if (external_quiescent && (fb.rbusy && fb.rexternal))
            $fatal(1, "quiescence during owned external read");
    end

    task automatic request_line(input logic ext, input logic scr,
                                input logic [7:0] y);
        @(negedge clk);
        pf_external = ext;
        pf_scr = scr;
        pf_line = y;
        pf_bank = y[0];
        pf_frame_bank = ext ? 2'd1 : 2'd0;
        pf_tgl = ~pf_tgl;
        repeat (6) @(negedge clk);
    endtask

    task automatic idle;
        while (fb.rbusy || fb.pf_count != 0 || response_active || ddr_valid)
            @(negedge clk);
        repeat (6) @(negedge clk);
    endtask

    task automatic check_local(input logic scr, input logic parity);
        lb_raddr = {parity, scr, 7'd0};
        repeat (5) @(negedge clk);
        if (lb_q !== {18'h01234,18'h02345})
            $fatal(1, "old external data attached to new local line %h", lb_q);
        lb_raddr = {parity, scr, 7'd127};
        repeat (3) @(negedge clk);
        if (lb_q !== {18'h01234,18'h02345})
            $fatal(1, "local line truncated after external cancel");
    endtask

    integer before_requests, before_reads, before_beats;
    logic old_slot;
    initial begin
        repeat (5) @(negedge clk);
        reset_sys = 0; reset_read = 0; reset_video = 0;
        request_line(1, 1, 8'd2);
        repeat (12) @(negedge clk);
        if (requests != 0 || !external_quiescent)
            $fatal(1, "default Off issued B traffic");
        request_line(0, 0, 8'd2);
        idle();
        check_local(0, 0);

        // ch6 has latched the pulse while physical DDR is backpressured.
        // Queue B then A for the next row before withdrawing the session.
        external_enable = 1;
        ddr_busy = 1;
        request_line(1, 1, 8'd40);
        request_line(1, 1, 8'd41);
        request_line(0, 0, 8'd41);
        if (!fb.rbusy || !legacy.ch_rq[6] || fb.pf_count != 2)
            $fatal(1, "test failed to queue old ch6 ownership");
        if (fb.scanout_late_count == 0)
            $fatal(1, "reset test did not create a prior-session late read");
        // Seed all sticky diagnostic fields; these are observations, unlike
        // the queued/accepted transaction that must survive the same reset.
        fb.scanout_write_collision = 1;
        fb.published_write_collision = 1;
        fb.midframe_bank_switch = 1;
        fb.render_bank_split = 1;
        fb.source_frame_discard = 1;
        before_requests = requests;
        before_reads = reads;
        before_beats = beats;
        external_enable = 0;
        reset_sys = 1; // guest/HPS restart; neither raster nor fabric reset
        response_hold = 1;
        repeat (30) @(negedge clk);
        if (!fb.rbusy || external_quiescent || requests != before_requests ||
            reads != before_reads)
            $fatal(1, "session reset canceled an unaccepted legacy request");
        if ({fb.scanout_write_collision, fb.published_write_collision,
             fb.midframe_bank_switch, fb.render_bank_split,
             fb.source_frame_discard, fb.scanout_late_count} !== 13'd0)
            $fatal(1, "session reset retained prior diagnostic flags/count");
        ddr_busy = 0;
        wait (response_active);
        repeat (20) @(negedge clk);
        if (external_quiescent || !fb.rbusy)
            $fatal(1, "accepted delayed response reported quiescent");
        response_hold = 0;
        wait (fb6_ready);
        @(negedge clk);
        reset_sys = 0;
        idle();
        if (external_requests != 1 || external_reads != 1 ||
            beats-before_beats != BURST+128 || !external_quiescent)
            $fatal(1, "canceled queued B/chunks escaped or burst did not drain B=%0d/%0d beats=%0d", external_requests, external_reads, beats-before_beats);
        check_local(0, 1);

        // Cancel after physical acceptance and some response beats. Neither
        // the remaining old beats nor a disabled input may promote old B.
        external_enable = 1;
        request_line(1, 1, 8'd42);
        wait (fb.rwidx >= 8);
        @(negedge clk);
        response_hold = 1;
        old_slot = fb.active_line_slot[1];
        external_enable = 0;
        repeat (20) @(negedge clk);
        if (external_quiescent) $fatal(1, "partial burst reported quiescent");
        request_line(1, 1, 8'd43);
        response_hold = 0;
        idle();
        if (fb.active_line_slot[1] !== old_slot ||
            external_reads != 2 || external_requests != 2)
            $fatal(1, "old external response promoted or duplicated");

        // Fresh On requests still fetch every chunk and promote complete B.
        external_enable = 1;
        request_line(1, 1, 8'd44);
        idle();
        lb_raddr = {1'b0,1'b1,7'd0};
        repeat (5) @(negedge clk);
        if (lb_q !== {18'h2a5a5,18'h15555} ||
            external_reads != 2+128/BURST || requests != reads ||
            completions != reads)
            $fatal(1, "fresh On incomplete or duplicate/stale callbacks");
        $display("PASS: Engine-B quiesce burst=%0d reads=%0d B=%0d beats=%0d completions=%0d; queued/accepted DDR drains survive session reset, Off forbids new B, local and fresh On remain exact", BURST, reads, external_reads, beats, completions);
        done = 1;
    end
endmodule

module tb_nds_nitro_fb_external_quiesce;
    wire done128, done32;
    fb_external_quiesce_case #(.BURST(128)) full_burst(done128);
    fb_external_quiesce_case #(.BURST(32)) split_burst(done32);
    initial begin
        wait (done128 && done32);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "external quiesce timeout");
    end
endmodule
