`timescale 1ns/1ps

module tb_nds_arm_video_event_capture;
    logic clk = 0;
    logic reset = 1;
    logic gpu_valid, gpu_ready;
    logic [31:0] gpu_address, gpu_data, gpu_frame;
    logic [1:0] gpu_access;
    logic [3:0] gpu_byte_enable;
    logic [63:0] gpu_timestamp;
    logic palette_valid, palette_ready;
    logic [31:0] palette_address, palette_data, palette_frame;
    logic [1:0] palette_access;
    logic [3:0] palette_byte_enable;
    logic [63:0] palette_timestamp;
    logic oam_valid, oam_ready;
    logic [31:0] oam_address, oam_data, oam_frame;
    logic [1:0] oam_access;
    logic [3:0] oam_byte_enable;
    logic [63:0] oam_timestamp;
    logic hblank_valid, hblank_ready;
    logic [8:0] hblank_line;
    logic [31:0] hblank_frame;
    logic [63:0] hblank_timestamp;
    logic event_valid, event_ready;
    logic [127:0] event_record;
    logic [31:0] event_frame;
    logic [63:0] event_timestamp;

    nds_arm_video_event_capture dut (.*);
    always #5 clk = ~clk;

    task automatic step;
        @(posedge clk);
        #1;
    endtask

    task automatic expect_event(
        input logic [7:0] kind,
        input logic [1:0] access,
        input logic [3:0] be,
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [31:0] frame,
        input logic [63:0] timestamp
    );
        begin
            if (!event_valid || event_record[7:0] !== kind ||
                event_record[15:8] !== {6'd0, access} ||
                event_record[19:16] !== be ||
                event_record[31:20] !== 0 ||
                event_record[63:32] !== address ||
                event_record[95:64] !== data ||
                event_record[127:96] !== 0 ||
                event_frame !== frame || event_timestamp !== timestamp)
                $fatal(1, "event payload mismatch kind=%0d", kind);
        end
    endtask

    initial begin
        gpu_valid = 0;
        palette_valid = 0;
        oam_valid = 0;
        hblank_valid = 0;
        event_ready = 0;
        gpu_address = 0;
        gpu_access = 0;
        gpu_byte_enable = 0;
        gpu_data = 0;
        gpu_frame = 0;
        gpu_timestamp = 0;
        palette_address = 0;
        palette_access = 0;
        palette_byte_enable = 0;
        palette_data = 0;
        palette_frame = 0;
        palette_timestamp = 0;
        oam_address = 0;
        oam_access = 0;
        oam_byte_enable = 0;
        oam_data = 0;
        oam_frame = 0;
        oam_timestamp = 0;
        hblank_line = 0;
        hblank_frame = 0;
        hblank_timestamp = 0;

        repeat (3) step();
        reset = 0;

        // All sources held: globally oldest palette record wins first.
        gpu_valid = 1;
        gpu_address = 32'h04000018;
        gpu_access = 1;
        gpu_byte_enable = 4'h3;
        gpu_data = 32'h00000123;
        gpu_frame = 7;
        gpu_timestamp = 64'd30;
        palette_valid = 1;
        palette_address = 32'h05000020;
        palette_access = 2;
        palette_byte_enable = 4'hf;
        palette_data = 32'h44332211;
        palette_frame = 7;
        palette_timestamp = 64'd20;
        oam_valid = 1;
        oam_address = 32'h07000040;
        oam_access = 2;
        oam_byte_enable = 4'hf;
        oam_data = 32'h88776655;
        oam_frame = 7;
        oam_timestamp = 64'd40;
        #1;
        if (!palette_ready || gpu_ready || oam_ready || hblank_ready)
            $fatal(1, "oldest source was not selected");
        step();
        palette_valid = 0;
        #1;
        expect_event(8'd6, 2, 4'hf, 32'h05000020,
                     32'h44332211, 7, 20);

        // Backpressure must hold every field stable even though an older new
        // source appears after the event is already presented.
        hblank_valid = 1;
        hblank_line = 9'd33;
        hblank_frame = 7;
        hblank_timestamp = 64'd10;
        repeat (3) begin
            step();
            expect_event(8'd6, 2, 4'hf, 32'h05000020,
                         32'h44332211, 7, 20);
        end

        event_ready = 1;
        #1;
        if (!hblank_ready) $fatal(1, "HBlank was not selected on turnover");
        step();
        hblank_valid = 0;
        gpu_valid = 0;
        oam_valid = 0;
        #1;
        expect_event(8'd8, 0, 0, 33, 7, 7, 10);
        step();
        if (event_valid) $fatal(1, "turnover event did not drain");

        // Equal timestamp ordering is HBlank, GPU, palette, OAM.
        event_ready = 1;
        gpu_timestamp = 64'd50;
        palette_timestamp = 64'd50;
        oam_timestamp = 64'd50;
        hblank_timestamp = 64'd50;
        hblank_line = 9'd34;
        gpu_valid = 1;
        palette_valid = 1;
        oam_valid = 1;
        hblank_valid = 1;
        #1;
        if (!hblank_ready || gpu_ready || palette_ready || oam_ready)
            $fatal(1, "equal-timestamp HBlank priority failed");
        step();
        hblank_valid = 0;
        #1;
        expect_event(8'd8, 0, 0, 34, 7, 7, 50);
        if (!gpu_ready || palette_ready || oam_ready)
            $fatal(1, "equal-timestamp GPU priority failed");
        step();
        gpu_valid = 0;
        #1;
        expect_event(8'd5, 1, 4'h3, 32'h04000018,
                     32'h00000123, 7, 50);
        if (!palette_ready || oam_ready)
            $fatal(1, "equal-timestamp palette priority failed");
        step();
        palette_valid = 0;
        #1;
        expect_event(8'd6, 2, 4'hf, 32'h05000020,
                     32'h44332211, 7, 50);
        if (!oam_ready) $fatal(1, "OAM did not drain last");
        step();
        oam_valid = 0;
        #1;
        expect_event(8'd7, 2, 4'hf, 32'h07000040,
                     32'h88776655, 7, 50);
        step();
        if (event_valid) $fatal(1, "event remained valid after drain");

        $display("ARM video event capture test");
        $display("timestamp_ordering: passed");
        $display("hblank_tie_precedence: passed");
        $display("backpressure_stability: passed");
        $display("turnover_without_bubble: passed");
        $finish;
    end
endmodule
