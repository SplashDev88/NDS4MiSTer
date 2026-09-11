`timescale 1ns/1ps

// Negative product-interface regression for Engine-B scanline ordering.
//
// nds_h3d_console_event_gate can retain GPU writes in its 256-entry queue and
// ARM9/ARM7 VRAM writes in registered pending stages.  This bench models that
// retention explicitly: a write is posted while the LCD is on one scanline,
// then presented to nds_h3d_frame_record_cdc only after the LCD has advanced.
// The record must retain the posting line, not acquire the drain-time line.
module tb_nds_h3d_delayed_scanline_tag;
    logic source_clk = 0;
    logic ddr_clk = 0;
    always #5 source_clk = ~source_clk;
    always #7 ddr_clk = ~ddr_clk;

    logic reset = 1;
    logic session_flush = 0;

    logic gpu_valid = 0;
    logic gpu_ready;
    logic [27:0] gpu_address = 28'h0001000;
    logic [1:0] gpu_access = 2'b10;
    logic [3:0] gpu_byte_enable = 4'hf;
    logic [31:0] gpu_data = 32'h00010000;
    logic [63:0] gpu_timestamp = 0;
    logic [8:0] gpu_scanline = 0;

    logic arm9_vram_valid = 0;
    logic arm9_vram_ready;
    logic [27:0] arm9_vram_address = 28'h6000000;
    logic [1:0] arm9_vram_access = 2'b01;
    logic [3:0] arm9_vram_byte_enable = 4'h3;
    logic [31:0] arm9_vram_data = 32'h00001234;
    logic [63:0] arm9_vram_timestamp = 0;
    logic [8:0] arm9_vram_scanline = 0;

    logic arm7_vram_valid = 0;
    logic arm7_vram_ready;
    logic [27:0] arm7_vram_address = 28'h6000000;
    logic [1:0] arm7_vram_access = 2'b01;
    logic [3:0] arm7_vram_byte_enable = 4'h3;
    logic [31:0] arm7_vram_data = 32'h00005678;
    logic [63:0] arm7_vram_timestamp = 0;
    logic [8:0] arm7_vram_scanline = 0;

    logic hblank_valid = 0;
    logic hblank_ready;
    logic [8:0] hblank_line = 0;
    logic [31:0] hblank_frame = 32'd10;
    logic [63:0] hblank_timestamp = 0;

    logic frame_valid = 0;
    logic frame_ready;
    logic [31:0] frame_number = 0;
    logic [63:0] frame_timestamp = 0;

    logic source_active;
    logic ddr_active;
    logic source_fault;
    logic [3:0] source_fault_reason;
    logic ddr_fault;
    logic [3:0] ddr_fault_reason;
    logic [8:0] fifo_level;
    logic fifo_empty;
    logic fifo_below_half;
    logic fifo_full;
    logic record_valid;
    logic record_ready = 1;
    logic [127:0] record;
    logic [31:0] record_frame;
    logic record_frame_end;
    logic boundary_valid;
    logic boundary_ready = 1;
    logic [31:0] boundary_frame;

    logic [127:0] captured [0:2];
    integer captured_count = 0;
    integer failures = 0;

    nds_h3d_frame_record_cdc #(
        .ASYNC_LGDEPTH(2),
        .SPARSE_HBLANK(1'b1),
        .SCANLINE_TAGS(1'b1)
    ) dut (.*);

    always @(posedge ddr_clk) begin
        if (record_valid && record_ready) begin
            captured[captured_count] <= record;
            captured_count <= captured_count + 1;
        end
    end

    function automatic [8:0] record_line(input logic [127:0] value);
        record_line = value[28:20];
    endfunction

    task automatic wait_capture(input integer count);
        integer guard;
        begin
            guard = 0;
            while (captured_count < count) begin
                @(posedge ddr_clk);
                guard = guard + 1;
                if (guard > 200) $fatal(1, "timed out waiting for record");
            end
            @(negedge ddr_clk);
        end
    endtask

    task automatic send_gpu_after_delay(
        input logic [8:0] posting_line,
        input logic [8:0] drain_line,
        input logic [63:0] posting_timestamp
    );
        begin
            // The product event gate captured this payload/timestamp while the
            // LCD was on posting_line.  Its queue drains only at drain_line.
            hblank_line = posting_line;
            repeat (2) @(posedge source_clk);
            @(negedge source_clk);
            hblank_line = drain_line;
            gpu_timestamp = posting_timestamp;
            gpu_scanline = posting_line;
            gpu_valid = 1;
            do @(posedge source_clk); while (!gpu_ready);
            @(negedge source_clk);
            gpu_valid = 0;
        end
    endtask

    task automatic send_arm9_after_delay(
        input logic [8:0] posting_line,
        input logic [8:0] drain_line,
        input logic [63:0] posting_timestamp
    );
        begin
            hblank_line = posting_line;
            repeat (2) @(posedge source_clk);
            @(negedge source_clk);
            hblank_line = drain_line;
            arm9_vram_timestamp = posting_timestamp;
            arm9_vram_scanline = posting_line;
            arm9_vram_valid = 1;
            do @(posedge source_clk); while (!arm9_vram_ready);
            @(negedge source_clk);
            arm9_vram_valid = 0;
        end
    endtask

    task automatic send_arm7_after_delay(
        input logic [8:0] posting_line,
        input logic [8:0] drain_line,
        input logic [63:0] posting_timestamp
    );
        begin
            hblank_line = posting_line;
            repeat (2) @(posedge source_clk);
            @(negedge source_clk);
            hblank_line = drain_line;
            arm7_vram_timestamp = posting_timestamp;
            arm7_vram_scanline = posting_line;
            arm7_vram_valid = 1;
            do @(posedge source_clk); while (!arm7_vram_ready);
            @(negedge source_clk);
            arm7_vram_valid = 0;
        end
    endtask

    task automatic check_line(
        input integer index,
        input logic [8:0] posting_line,
        input logic [8:0] drain_line,
        input string source_name
    );
        logic [8:0] actual;
        begin
            actual = record_line(captured[index]);
            $display("%s posted_line=%0d drained_line=%0d record_tag=%0d",
                source_name, posting_line, drain_line, actual);
            if (actual != posting_line) failures = failures + 1;
        end
    endtask

    initial begin
        repeat (4) @(posedge source_clk);
        reset = 0;
        wait (source_active && ddr_active);

        send_gpu_after_delay(9'd5, 9'd120, 64'd100);
        wait_capture(1);
        check_line(0, 9'd5, 9'd120, "GPU/PAL/OAM/register");

        send_arm9_after_delay(9'd6, 9'd121, 64'd101);
        wait_capture(2);
        check_line(1, 9'd6, 9'd121, "ARM9 VRAM");

        send_arm7_after_delay(9'd7, 9'd122, 64'd102);
        wait_capture(3);
        check_line(2, 9'd7, 9'd122, "ARM7 VRAM");

        if (source_fault || ddr_fault)
            $fatal(1, "transport faulted instead of preserving ordering");
        if (failures)
            $fatal(1,
                "delayed product sources acquired the live drain-time scanline");
        $display("PASS: delayed sources retained their posting scanline");
        $finish;
    end
endmodule
