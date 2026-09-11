// SPDX-License-Identifier: GPL-3.0-or-later
// A normal framebuffer publication and an external Engine-B frame use
// distinct DDR windows.  Their numeric bank tags may overlap, but only a
// normal-source prefetch may acknowledge/release a normal publication.
`timescale 1ns/1ps

module tb_nds_nitro_fb_publication_source_ack;
    logic clk_sys = 1'b0;
    logic clk_video = 1'b0;
    always #8.333 clk_sys = ~clk_sys;
    always #7 clk_video = ~clk_video;

    logic reset_sys = 1'b1;
    logic reset_video = 1'b1;
    logic external_frame_mode = 1'b0;
    logic external_frame_publish = 1'b0;
    logic [1:0] external_frame_bank = 2'd0;
    logic pf_tgl = 1'b0;
    logic pf_external = 1'b0;
    logic [1:0] pf_frame_bank = 2'd0;

    nds_nitro_fb_ddr3 #(
        .RUNTIME_TELEMETRY(1'b0)
    ) dut (
        .reset_read(reset_sys), .external_enable(1'b1),
        .external_quiescent(),
        .clk_sys,
        .CLK_VIDEO(clk_video),
        .reset_sys,
        .reset_video,
        .pix_x(8'd0), .pix_y(8'd0), .pix_d(18'd0), .pix_we(1'b0),
        .pixb_x(8'd0), .pixb_y(8'd0), .pixb_d(18'd0), .pixb_we(1'b0),
        .source_fault(1'b0),
        .telemetry_session(32'd0),
        .external_frame_mode,
        .external_frame_publish,
        .external_frame_bank,
        .external_frame_adopted(),
        .dbg0(18'd0), .dbg1(18'd0), .dbg2(18'd0), .dbg3(18'd0),
        .dbg4(18'd0), .dbg5(18'd0), .dbg6(18'd0), .dbg7(18'd0),
        .dbg8(18'd0), .dbg9(18'd0), .dbg10(18'd0), .dbg11(18'd0),
        .pf_tgl,
        .pf_scr(1'b0),
        .pf_line(8'd0),
        .pf_bank(1'b0),
        .pf_frame_bank,
        .pf_external,
        .published_frame_toggle(),
        .published_frame_bank(),
        .scanout_late_count(),
        .runtime_fault_flags(),
        .bank_diagnostic(),
        .lb_raddr(9'd0),
        .lb_q(),
        .fb5_addr(), .fb5_din(), .fb5_req(),
        .fb5_next(1'b0), .fb5_ready(1'b0),
        .fb6_addr(), .fb6_req(),
        .fb6_dout(64'd0), .fb6_valid(1'b0), .fb6_ready(1'b0)
    );

    task automatic send_prefetch(
        input logic source_external,
        input logic [1:0] bank
    );
        begin
            @(negedge clk_sys);
            pf_external = source_external;
            pf_frame_bank = bank;
            pf_tgl = ~pf_tgl;
            // pf_tgl crosses the module's existing two-stage synchronizer.
            repeat (5) @(posedge clk_sys);
            #1;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk_sys);
        reset_sys = 1'b0;
        reset_video = 1'b0;

        // Use the module's public full-frame input to establish the exact
        // retained publication state, then return to normal local-frame mode.
        // The provenance of publication_pending is not encoded in state; this
        // is the same state produced by a completed local top+bottom pair.
        @(negedge clk_sys);
        external_frame_mode = 1'b1;
        external_frame_bank = 2'd1;
        external_frame_publish = 1'b1;
        @(negedge clk_sys);
        external_frame_publish = 1'b0;
        external_frame_mode = 1'b0;
        @(posedge clk_sys);
        #1;
        if (!dut.publication_pending || dut.published_frame_bank != 2'd1)
            $fatal(1, "failed to establish retained normal-bank publication");
        if (!dut.reserved_frame_banks[1])
            $fatal(1, "pending publication bank was not reserved");

        // Engine B has a different DDR base.  Its matching numeric tag must
        // neither ACK nor release the normal framebuffer publication.
        send_prefetch(1'b1, 2'd1);
        if (!dut.publication_pending)
            $fatal(1,
                "external Engine-B prefetch falsely acknowledged normal bank 1");
        if (!dut.reserved_frame_banks[1])
            $fatal(1,
                "external Engine-B prefetch released normal bank 1 for overwrite");

        // The real normal-source adoption of that same bank must still ACK.
        send_prefetch(1'b0, 2'd1);
        if (dut.publication_pending)
            $fatal(1, "normal framebuffer prefetch did not acknowledge bank 1");

        $display("PASS: publication ACK requires matching normal framebuffer source and bank");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "publication source-aware ACK timeout");
    end
endmodule
