// SPDX-License-Identifier: GPL-3.0-or-later
// Full-pair publications live in the normal framebuffer address range, but
// those reads still own HPS memory and must drain before session replacement.
`timescale 1ns/1ps
module tb_nds_matched_display_quiesce;
    logic clk=0;
    always #5 clk=~clk;
    logic reset_sys=1, reset_read=1, reset_video=1, external_enable=0;
    logic publish=0, pf_tgl=0, pf_scr=0;
    logic [1:0] bank=1;
    wire quiescent, adopted, req;
    wire [27:1] addr;
    logic valid=0, ready=0;
    integer requests=0, adoptions=0;
    wire [35:0] pixels;
    wire pixels_valid;
    nds_nitro_fb_ddr3 #(.FB_BURST(128), .RUNTIME_TELEMETRY(0)) dut (
        .clk_sys(clk), .CLK_VIDEO(clk), .reset_sys, .reset_read, .reset_video,
        .external_enable, .external_quiescent(quiescent),
        .pix_x(8'd0), .pix_y(8'd0), .pix_d(18'h3ffff), .pix_we(1'b1),
        .pixb_x(8'd0), .pixb_y(8'd0), .pixb_d(18'h3ffff), .pixb_we(1'b1),
        .source_fault(1'b0), .telemetry_session(32'd0),
        .external_frame_mode(1'b1), .external_frame_publish(publish),
        .external_frame_bank(bank), .external_frame_adopted(adopted),
        .dbg0(18'd0), .dbg1(18'd0), .dbg2(18'd0), .dbg3(18'd0),
        .dbg4(18'd0), .dbg5(18'd0), .dbg6(18'd0), .dbg7(18'd0),
        .dbg8(18'd0), .dbg9(18'd0), .dbg10(18'd0), .dbg11(18'd0),
        .pf_tgl, .pf_scr, .pf_line(8'd0), .pf_bank(1'b0),
        .pf_frame_bank(bank), .pf_external(1'b0),
        .published_frame_toggle(), .published_frame_bank(),
        .scanout_late_count(), .runtime_fault_flags(), .bank_diagnostic(),
        .lb_raddr({1'b0,pf_scr,7'd0}), .lb_q(pixels), .lb_valid(pixels_valid),
        .fb5_addr(), .fb5_din(), .fb5_req(), .fb5_next(1'b0), .fb5_ready(1'b0),
        .fb6_addr(addr), .fb6_req(req),
        .fb6_dout(64'h00001234_00002345), .fb6_valid(valid), .fb6_ready(ready)
    );
    always @(posedge clk) begin
        if (req) requests=requests+1;
        if (adopted) adoptions=adoptions+1;
        if (quiescent && dut.rbusy) $fatal(1,"paired read falsely quiescent");
        if (dut.fb5_req) $fatal(1,"native pixels overwrote paired bank");
    end
    task automatic publish_pair;
        @(negedge clk); publish=1;
        @(negedge clk); publish=0;
    endtask
    task automatic request_line;
        @(negedge clk); pf_tgl=~pf_tgl;
        repeat(8) @(negedge clk);
    endtask
    task automatic respond;
        repeat(128) begin @(negedge clk); valid=1; end
        ready=1;
        @(negedge clk); valid=0; ready=0;
        repeat(8) @(negedge clk);
    endtask
    initial begin
        repeat(8) @(negedge clk);
        reset_sys=0; reset_read=0; reset_video=0;
        request_line();
        if(requests!=0 || !quiescent) $fatal(1,"disabled full pair read escaped");
        external_enable=1;
        publish_pair(); request_line();
        if(requests!=1 || !dut.rbusy || adoptions!=1)
            $fatal(1,"paired publication was not adopted exactly once");
        // Outstanding pulse stays owned across guest reset and disabled path.
        external_enable=0; reset_sys=1;
        repeat(20) @(negedge clk);
        if(quiescent || !dut.rbusy) $fatal(1,"unanswered pair read lost ownership");
        respond();
        if(!quiescent || pixels_valid) $fatal(1,"old pair survived session clear");
        reset_sys=0; external_enable=1; bank=2;
        publish_pair(); request_line(); respond();
        if(!pixels_valid || pixels!=={18'h01234,18'h02345})
            $fatal(1,"fresh top screen failed after drain");
        pf_scr=1;
        request_line(); respond();
        if(!pixels_valid || pixels!=={18'h01234,18'h02345} || adoptions!=2)
            $fatal(1,"fresh bottom screen or duplicate adoption failed");
        if(addr != 27'h7f00000 + {bank,1'b1,8'd0,9'd0})
            $fatal(1,"full-pair bottom used wrong physical bank");
        $display("PASS: full-pair bank addressing, one ACK, native write exclusion, pending-read reset drain");
        $finish;
    end
    initial begin #100000; $fatal(1,"paired quiesce timeout"); end
endmodule
