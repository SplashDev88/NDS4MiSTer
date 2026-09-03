`timescale 1ns/1ps

module tb_nds_h3d_sparse_phase_cdc;
    logic source_clk = 0;
    logic ddr_clk = 0;
    logic reset = 1;
    logic session_flush = 0;

    logic gpu_valid = 0;
    logic gpu_ready;
    logic [27:0] gpu_address = 0;
    logic [1:0] gpu_access = 2'b01;
    logic [3:0] gpu_byte_enable = 4'h3;
    logic [31:0] gpu_data = 0;
    logic [63:0] gpu_timestamp = 0;
    logic arm9_vram_valid = 0;
    logic arm9_vram_ready;
    logic [27:0] arm9_vram_address = 0;
    logic [1:0] arm9_vram_access = 0;
    logic [3:0] arm9_vram_byte_enable = 0;
    logic [31:0] arm9_vram_data = 0;
    logic [63:0] arm9_vram_timestamp = 0;
    logic arm7_vram_valid = 0;
    logic arm7_vram_ready;
    logic [27:0] arm7_vram_address = 0;
    logic [1:0] arm7_vram_access = 0;
    logic [3:0] arm7_vram_byte_enable = 0;
    logic [31:0] arm7_vram_data = 0;
    logic [63:0] arm7_vram_timestamp = 0;
    logic hblank_valid = 0;
    logic hblank_ready;
    logic [8:0] hblank_line = 0;
    logic [31:0] hblank_frame = 0;
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

    logic [127:0] captured [0:7];
    integer captured_count = 0;

    always #5 source_clk = ~source_clk;
    always #7 ddr_clk = ~ddr_clk;

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

    task automatic pulse_hblank(
        input logic [8:0] line,
        input logic [31:0] frame,
        input logic [63:0] timestamp
    );
        begin
            @(negedge source_clk);
            hblank_line = line;
            hblank_frame = frame;
            hblank_timestamp = timestamp;
            hblank_valid = 1;
            @(posedge source_clk);
            if (!hblank_ready)
                $fatal(1, "sparse HBlank backpressured its source");
            @(negedge source_clk);
            hblank_valid = 0;
        end
    endtask

    task automatic send_gpu2d(
        input logic [31:0] data,
        input logic [63:0] timestamp
    );
        integer cycles;
        begin
            @(negedge source_clk);
            gpu_address = 28'h018;
            gpu_data = data;
            gpu_timestamp = timestamp;
            gpu_valid = 1;
            cycles = 0;
            do begin
                @(posedge source_clk);
                cycles = cycles + 1;
                if (cycles > 100)
                    $fatal(1, "GPU2D write was not accepted");
            end while (!gpu_ready);
            @(negedge source_clk);
            gpu_valid = 0;
        end
    endtask

    task automatic wait_captured(input integer count);
        integer cycles;
        begin
            cycles = 0;
            while (captured_count < count) begin
                @(posedge ddr_clk);
                cycles = cycles + 1;
                if (cycles > 200)
                    $fatal(1, "timed out waiting for sparse record");
            end
            @(negedge ddr_clk);
        end
    endtask

    function automatic [8:0] record_line(input logic [127:0] value);
        record_line = value[28:20];
    endfunction

    initial begin
        repeat (4) @(posedge source_clk);
        reset = 0;
        wait (source_active && ddr_active);

        // Ordinary lines are consumed immediately and create no transport
        // record. Their current value still tags an ordered state write.
        pulse_hblank(9'd5, 32'd10, 64'd10);
        repeat (8) @(posedge ddr_clk);
        if (captured_count != 0)
            $fatal(1, "non-boundary HBlank entered sparse stream");
        send_gpu2d(32'h00000123, 64'd11);
        wait_captured(1);
        if (captured[0][7:0] != 8'd5 || !captured[0][29] ||
            record_line(captured[0]) != 9'd5)
            $fatal(1, "GPU2D record lost its scanline tag");

        // Line zero enters the existing async transport while DDR output is
        // stalled; the LCD source remains acknowledged and cannot grow the
        // retired 512-entry backlog.
        record_ready = 0;
        pulse_hblank(9'd0, 32'd11, 64'd20);
        repeat (4) @(posedge source_clk);
        if (!hblank_ready || source_fault)
            $fatal(1, "sparse phase path faulted under backpressure");
        record_ready = 1;
        wait_captured(2);
        if (captured[1][7:0] != 8'd8 ||
            captured[1][63:32] != 32'd0 ||
            captured[1][95:64] != 32'd11)
            $fatal(1, "line-zero sparse marker was corrupted");

        // Under load the LCD pulse remains nonblocking, but its exact boundary
        // is retained and ordered before the same-edge state write. Losing
        // every busy line-0 marker left the live Engine-B renderer permanently
        // inactive even though scanline-tagged writes continued to arrive.
        @(negedge source_clk);
        hblank_line = 9'd192;
        hblank_frame = 32'd11;
        hblank_timestamp = 64'd30;
        hblank_valid = 1;
        gpu_address = 28'h018;
        gpu_data = 32'h00000456;
        gpu_timestamp = 64'd30;
        gpu_valid = 1;
        @(posedge source_clk);
        if (!hblank_ready || gpu_ready)
            $fatal(1, "sparse phase did not precede same-edge state");
        @(negedge source_clk);
        hblank_valid = 0;
        @(posedge source_clk);
        if (!gpu_ready)
            $fatal(1, "tagged state write did not follow sparse phase");
        @(negedge source_clk);
        gpu_valid = 0;
        wait_captured(4);
        if (captured[2][7:0] != 8'd8 ||
            captured[2][63:32] != 32'd192 ||
            captured[2][95:64] != 32'd11)
            $fatal(1, "retained line-192 sparse marker mismatch");
        if (captured[3][7:0] != 8'd5 || !captured[3][29] ||
            record_line(captured[3]) != 9'd192)
            $fatal(1, "sparse tagged-write fallback mismatch");
        if (source_fault || ddr_fault)
            $fatal(1, "sparse transport raised a protocol fault");

        $display("PASS: sparse Engine-B phases never backpressure LCD, cannot starve under state traffic, and tag intervening writes");
        $finish;
    end
endmodule
