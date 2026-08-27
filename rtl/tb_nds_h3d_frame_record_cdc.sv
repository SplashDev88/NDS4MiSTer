`timescale 1ns/1ps

module tb_nds_h3d_frame_record_cdc;
    localparam integer MAX_EXPECTED = 256;

    logic source_clk = 0;
    logic ddr_clk = 0;
    logic source_clock_enable = 1;
    logic ddr_clock_enable = 0;
    logic reset = 0;
    logic session_flush = 0;

    logic gpu_valid = 0;
    logic gpu_ready;
    logic [27:0] gpu_address = 0;
    logic [1:0] gpu_access = 2'b10;
    logic [3:0] gpu_byte_enable = 4'hf;
    logic [31:0] gpu_data = 0;
    logic [63:0] gpu_timestamp = 0;

    logic arm9_vram_valid = 0;
    logic arm9_vram_ready;
    logic [27:0] arm9_vram_address = 0;
    logic [1:0] arm9_vram_access = 2'b10;
    logic [3:0] arm9_vram_byte_enable = 4'hf;
    logic [31:0] arm9_vram_data = 0;
    logic [63:0] arm9_vram_timestamp = 0;

    logic arm7_vram_valid = 0;
    logic arm7_vram_ready;
    logic [27:0] arm7_vram_address = 0;
    logic [1:0] arm7_vram_access = 2'b10;
    logic [3:0] arm7_vram_byte_enable = 4'hf;
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

    logic [127:0] expected_record [0:MAX_EXPECTED-1];
    logic [31:0] expected_frame [0:MAX_EXPECTED-1];
    logic expected_end [0:MAX_EXPECTED-1];
    logic expected_boundary [0:MAX_EXPECTED-1];
    integer expected_write = 0;
    integer expected_read = 0;

    logic output_held = 0;
    logic [127:0] held_record;
    logic [31:0] held_frame;
    logic held_end;
    logic held_boundary;

    always #5 begin
        if (source_clock_enable)
            source_clk = ~source_clk;
        else
            source_clk = 0;
    end
    always #7 begin
        if (ddr_clock_enable)
            ddr_clk = ~ddr_clk;
        else
            ddr_clk = 0;
    end

    nds_h3d_frame_record_cdc #(
        .ASYNC_LGDEPTH(2)
    ) dut (.*);

    function automatic logic [127:0] direct_record(
        input logic [7:0] kind,
        input logic [7:0] tag,
        input logic [3:0] byte_enable,
        input logic [31:0] address,
        input logic [31:0] data
    );
        direct_record = {
            32'd0, data, address, 12'd0, byte_enable, tag, kind
        };
    endfunction

    function automatic logic [127:0] gx_record_value(
        input logic [7:0] command,
        input logic [31:0] param_value
    );
        gx_record_value = {
            32'd0, param_value, 32'd0, 12'd0, 4'd0, command, 8'd1
        };
    endfunction

    function automatic logic [127:0] gx_packed_three(
        input logic [7:0] command0,
        input logic [31:0] data0,
        input logic [7:0] command1,
        input logic [31:0] data1,
        input logic [7:0] command2,
        input logic [31:0] data2
    );
        gx_packed_three = {
            data2, data1, data0,
            command2, command1, command0, 8'd9
        };
    endfunction

    task automatic expect_output(
        input logic [127:0] value,
        input logic [31:0] logical_frame_value,
        input logic frame_end_value
    );
        begin
            if (expected_write >= MAX_EXPECTED)
                $fatal(1, "expected queue overflow");
            expected_record[expected_write] = value;
            expected_frame[expected_write] = logical_frame_value;
            expected_end[expected_write] = frame_end_value;
            expected_boundary[expected_write] = 0;
            expected_write = expected_write + 1;
        end
    endtask

    task automatic expect_boundary(input logic [31:0] frame_value);
        begin
            if (expected_write >= MAX_EXPECTED)
                $fatal(1, "expected queue overflow");
            expected_record[expected_write] = 0;
            expected_frame[expected_write] = frame_value;
            expected_end[expected_write] = 0;
            expected_boundary[expected_write] = 1;
            expected_write = expected_write + 1;
        end
    endtask

    task automatic wait_active;
        integer cycles;
        begin
            cycles = 0;
            while (!source_active || !ddr_active) begin
                @(posedge source_clk);
                cycles = cycles + 1;
                if (cycles > 100)
                    $fatal(1, "two-domain release handshake timeout");
            end
        end
    endtask

    task automatic wait_drain;
        integer cycles;
        begin
            cycles = 0;
            while (expected_read != expected_write || record_valid ||
                   boundary_valid ||
                   !fifo_empty) begin
                @(posedge ddr_clk);
                cycles = cycles + 1;
                if (cycles > 2000)
                    $fatal(1,
                        "drain timeout read=%0d write=%0d gx_level=%0d valid=%b",
                        expected_read, expected_write, fifo_level,
                        record_valid);
            end
        end
    endtask

    task automatic send_gpu(
        input logic [27:0] address,
        input logic [1:0] access,
        input logic [3:0] byte_enable,
        input logic [31:0] data,
        input logic [63:0] timestamp
    );
        integer cycles;
        begin
            @(negedge source_clk);
            gpu_address = address;
            gpu_access = access;
            gpu_byte_enable = byte_enable;
            gpu_data = data;
            gpu_timestamp = timestamp;
            gpu_valid = 1;
            cycles = 0;
            do begin
                @(posedge source_clk);
                cycles = cycles + 1;
                if (cycles > 1000)
                    $fatal(1, "GPU input acceptance timeout");
            end while (!gpu_ready);
            @(negedge source_clk);
            gpu_valid = 0;
        end
    endtask

    task automatic send_arm9(
        input logic [27:0] address,
        input logic [31:0] data,
        input logic [63:0] timestamp
    );
        integer cycles;
        begin
            @(negedge source_clk);
            arm9_vram_address = address;
            arm9_vram_access = 2'b10;
            arm9_vram_byte_enable = 4'hf;
            arm9_vram_data = data;
            arm9_vram_timestamp = timestamp;
            arm9_vram_valid = 1;
            cycles = 0;
            do begin
                @(posedge source_clk);
                cycles = cycles + 1;
                if (cycles > 1000)
                    $fatal(1, "ARM9 input acceptance timeout");
            end while (!arm9_vram_ready);
            @(negedge source_clk);
            arm9_vram_valid = 0;
        end
    endtask

    task automatic send_hblank(
        input logic [8:0] line,
        input logic [63:0] timestamp
    );
        integer cycles;
        begin
            @(negedge source_clk);
            hblank_line = line;
            hblank_frame = 32'd8;
            hblank_timestamp = timestamp;
            hblank_valid = 1;
            cycles = 0;
            do begin
                @(posedge source_clk);
                cycles = cycles + 1;
                if (cycles > 1000)
                    $fatal(1, "HBlank input acceptance timeout");
            end while (!hblank_ready);
            @(negedge source_clk);
            hblank_valid = 0;
        end
    endtask

    task automatic wait_for_fault;
        integer cycles;
        begin
            cycles = 0;
            while (!source_fault || !ddr_fault) begin
                @(posedge ddr_clk);
                cycles = cycles + 1;
                if (cycles > 100)
                    $fatal(1, "protocol fault did not cross to DDR");
            end
        end
    endtask

    always @(posedge ddr_clk) begin
        if (reset || session_flush || !ddr_active) begin
            output_held = 0;
        end else begin
            if (output_held &&
                ((record_valid || boundary_valid) !== 1'b1 ||
                 record !== held_record ||
                 (record_valid ? record_frame : boundary_frame) !==
                    held_frame ||
                 record_frame_end !== held_end ||
                 boundary_valid !== held_boundary))
                $fatal(1, "DDR output changed while backpressured");

            if (record_valid && boundary_valid)
                $fatal(1, "record and boundary were valid together");

            if (record_valid && record_ready) begin
                if (expected_read >= expected_write)
                    $fatal(1, "unexpected DDR record");
                if (expected_boundary[expected_read] ||
                    record !== expected_record[expected_read] ||
                    record_frame !== expected_frame[expected_read] ||
                    record_frame_end !== expected_end[expected_read])
                    $fatal(1,
                        "DDR record mismatch index=%0d frame=%0d end=%b",
                        expected_read, record_frame, record_frame_end);
                expected_read = expected_read + 1;
            end

            if (boundary_valid && boundary_ready) begin
                if (expected_read >= expected_write ||
                    !expected_boundary[expected_read] ||
                    boundary_frame !== expected_frame[expected_read])
                    $fatal(1,
                        "DDR boundary mismatch index=%0d frame=%0d",
                        expected_read, boundary_frame);
                expected_read = expected_read + 1;
            end

            output_held = (record_valid && !record_ready) ||
                (boundary_valid && !boundary_ready);
            if (output_held) begin
                held_record = record;
                held_frame = record_valid ? record_frame : boundary_frame;
                held_end = record_frame_end;
                held_boundary = boundary_valid;
            end
        end
    end

    integer cycles;
    integer i;
    logic gpu_fired;
    logic arm9_fired;
    logic arm7_fired;

    initial begin : timeout_guard
        #500000;
        $fatal(1, "frame record CDC test timeout");
    end

    initial begin
        // Source clocks may release first, but neither side advertises active
        // and no producer is accepted until the stopped DDR clock joins.
        #1 reset = 1;
        repeat (4) @(posedge source_clk);
        @(negedge source_clk);
        reset = 0;
        repeat (8) begin
            @(posedge source_clk);
            if (source_active || gpu_ready || arm9_vram_ready ||
                arm7_vram_ready || frame_ready)
                $fatal(1, "source escaped while DDR release was absent");
        end
        ddr_clock_enable = 1;
        wait_active();
        $display("stage reset release");

        // ARM video requires the complete mapped ARM9 VRAM stream. A BG write
        // must therefore emerge as the exact ordered record rather than being
        // consumed by the former 3D-only aperture filter.
        @(negedge ddr_clk);
        record_ready = 1;
        expect_output(direct_record(
            8'd3, 8'h02, 4'hf, 32'h06001000, 32'h2d000001), 1, 0);
        @(negedge source_clk);
        arm9_vram_address = 28'h6001000;
        arm9_vram_data = 32'h2d000001;
        arm9_vram_timestamp = 64'd1;
        arm9_vram_valid = 1;
        wait (arm9_vram_ready);
        @(negedge source_clk);
        arm9_vram_valid = 0;
        wait_drain();

        // Simultaneous held sources are globally timestamp ordered. Ties use
        // GPU, ARM9, then ARM7 priority.
        expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                    32'h06801000, 32'ha9000010), 1, 0);
        expect_output(direct_record(8'd3, 8'h06, 4'hf,
                                    32'h00002000, 32'ha7000020), 1, 0);
        expect_output(direct_record(8'd2, 8'h02, 4'hf,
                                    32'h04000320, 32'h90000030), 1, 0);
        @(negedge source_clk);
        gpu_address = 28'h320;
        gpu_access = 2'b10;
        gpu_byte_enable = 4'hf;
        gpu_data = 32'h90000030;
        gpu_timestamp = 64'd30;
        gpu_valid = 1;
        arm9_vram_address = 28'h6801000;
        arm9_vram_data = 32'ha9000010;
        arm9_vram_timestamp = 64'd10;
        arm9_vram_valid = 1;
        arm7_vram_address = 28'h2000;
        arm7_vram_data = 32'ha7000020;
        arm7_vram_timestamp = 64'd20;
        arm7_vram_valid = 1;
        cycles = 0;
        while (gpu_valid || arm9_vram_valid || arm7_vram_valid) begin
            @(posedge source_clk);
            gpu_fired = gpu_valid && gpu_ready;
            arm9_fired = arm9_vram_valid && arm9_vram_ready;
            arm7_fired = arm7_vram_valid && arm7_vram_ready;
            @(negedge source_clk);
            if (gpu_fired) gpu_valid = 0;
            if (arm9_fired) arm9_vram_valid = 0;
            if (arm7_fired) arm7_vram_valid = 0;
            cycles = cycles + 1;
            if (cycles > 100)
                $fatal(1,
                    "first arbitration stuck valids=%b%b%b ready=%b%b%b active=%b fault=%b",
                    gpu_valid, arm9_vram_valid, arm7_vram_valid,
                    gpu_ready, arm9_vram_ready, arm7_vram_ready,
                    source_active, source_fault);
        end

        expect_output(direct_record(8'd2, 8'h02, 4'hf,
                                    32'h04000320, 32'h90000040), 1, 0);
        expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                    32'h06801004, 32'ha9000040), 1, 0);
        expect_output(direct_record(8'd3, 8'h06, 4'hf,
                                    32'h00002004, 32'ha7000040), 1, 0);
        @(negedge source_clk);
        gpu_address = 28'h320;
        gpu_data = 32'h90000040;
        gpu_timestamp = 64'd40;
        gpu_valid = 1;
        arm9_vram_address = 28'h6801004;
        arm9_vram_data = 32'ha9000040;
        arm9_vram_timestamp = 64'd40;
        arm9_vram_valid = 1;
        arm7_vram_address = 28'h2004;
        arm7_vram_data = 32'ha7000040;
        arm7_vram_timestamp = 64'd40;
        arm7_vram_valid = 1;
        cycles = 0;
        while (gpu_valid || arm9_vram_valid || arm7_vram_valid) begin
            @(posedge source_clk);
            gpu_fired = gpu_valid && gpu_ready;
            arm9_fired = arm9_vram_valid && arm9_vram_ready;
            arm7_fired = arm7_vram_valid && arm7_vram_ready;
            @(negedge source_clk);
            if (gpu_fired) gpu_valid = 0;
            if (arm9_fired) arm9_vram_valid = 0;
            if (arm7_fired) arm7_vram_valid = 0;
            cycles = cycles + 1;
            if (cycles > 100)
                $fatal(1,
                    "tie arbitration stuck valids=%b%b%b ready=%b%b%b active=%b fault=%b",
                    gpu_valid, arm9_vram_valid, arm7_vram_valid,
                    gpu_ready, arm9_vram_ready, arm7_vram_ready,
                    source_active, source_fault);
        end
        wait_drain();
        $display("stage source ordering");

        // Packed normalization retains the parameter word's metadata. A
        // later-presented but older direct source wins over the GX FIFO head.
        send_gpu(28'h400, 2'b10, 4'hf, 32'h00000020, 64'd100);
        send_gpu(28'h400, 2'b10, 4'hf, 32'h20202020, 64'd110);
        expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                    32'h06803000, 32'ha9000105), 1, 0);
        expect_output(gx_record_value(8'h20, 32'h20202020), 1, 0);
        arm9_vram_address = 28'h6803000;
        arm9_vram_data = 32'ha9000105;
        arm9_vram_timestamp = 64'd105;
        arm9_vram_valid = 1;
        cycles = 0;
        while (arm9_vram_valid) begin
            @(posedge source_clk);
            arm9_fired = arm9_vram_valid && arm9_vram_ready;
            @(negedge source_clk);
            if (arm9_fired) arm9_vram_valid = 0;
            cycles = cycles + 1;
            if (cycles > 100)
                $fatal(1, "held ARM9/GX timestamp merge timeout");
        end
        // A later ordering fence drains the single normalized command. Idle
        // time alone deliberately no longer expands a short GX run.
        expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                    32'h06803004, 32'ha9000115), 1, 0);
        send_arm9(28'h6803004, 32'ha9000115, 64'd115);
        wait_drain();
        $display("stage packed ordering");

        // DDR-idle gaps are not architectural ordering fences. Three CPU GX
        // writes separated by much more than the former seven-cycle timeout
        // must still cross as one dense record in their original order.
        expect_output(gx_packed_three(
            8'h20, 32'he0000000,
            8'h20, 32'he0000001,
            8'h20, 32'he0000002), 1, 0);
        send_gpu(28'h480, 2'b10, 4'hf, 32'he0000000, 64'd120);
        repeat (20) @(posedge ddr_clk);
        if (record_valid || dut.gx_pack_count != 1)
            $fatal(1, "one-command idle gap flushed the GX tail");
        send_gpu(28'h480, 2'b10, 4'hf, 32'he0000001, 64'd130);
        repeat (20) @(posedge ddr_clk);
        if (record_valid || dut.gx_pack_count != 2)
            $fatal(1, "two-command idle gap flushed the GX tail");
        send_gpu(28'h480, 2'b10, 4'hf, 32'he0000002, 64'd140);
        wait_drain();
        $display("stage gap-independent GX packing");

        // A packed SWAP header is not yet a normalized record. VBlank may
        // therefore catch up while its parameter is absent. The later SWAP
        // parameter is tagged with frame 5 and increments the next frame to 6.
        send_gpu(28'h400, 2'b10, 4'hf, 32'h00000050, 64'd200);
        @(negedge source_clk);
        boundary_ready = 0;
        frame_number = 32'd4;
        frame_timestamp = 64'd205;
        frame_valid = 1;
        expect_boundary(32'd4);
        cycles = 0;
        while (frame_valid) begin
            @(posedge source_clk);
            arm9_fired = frame_valid && frame_ready;
            @(negedge source_clk);
            if (arm9_fired) frame_valid = 0;
            cycles = cycles + 1;
            if (cycles > 10)
                $fatal(1, "frame was withheld by a header-only SWAP");
        end
        cycles = 0;
        while (!boundary_valid) begin
            @(posedge ddr_clk);
            cycles = cycles + 1;
            if (cycles > 20)
                $fatal(1, "accepted boundary did not reach DDR");
        end
        repeat (3) @(posedge ddr_clk);
        @(negedge ddr_clk);
        boundary_ready = 1;
        expect_output(gx_record_value(8'h50, 32'h00000003), 5, 1);
        send_gpu(28'h400, 2'b10, 4'hf, 32'h00000003, 64'd210);
        // The SWAP already advanced past frame 5, so its later boundary is
        // consumed locally and cannot close or delay frame-6 traffic.
        @(negedge source_clk);
        frame_number = 32'd5;
        frame_timestamp = 64'd215;
        frame_valid = 1;
        cycles = 0;
        while (frame_valid) begin
            @(posedge source_clk);
            arm9_fired = frame_valid && frame_ready;
            @(negedge source_clk);
            if (arm9_fired) frame_valid = 0;
            cycles = cycles + 1;
            if (cycles > 10)
                $fatal(1, "stale post-SWAP boundary was not suppressed");
        end
        wait_drain();

        // A stale boundary is already redundant and must not wait behind a
        // real older record when the async FIFO is full.  Otherwise the
        // console's one-entry boundary holder can survive until the next
        // VBlank and report a false source overrun.  Fill the crossing, hold a
        // fifth older record, and require the stale token to retire locally on
        // its first source edge without emitting anything or accepting the
        // real record out of order.
        @(negedge ddr_clk);
        record_ready = 0;
        boundary_ready = 0;
        for (i = 0; i < 4; i = i + 1) begin
            expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                        32'h06805200 + i * 4,
                                        32'ha9000520 + i), 6, 0);
            send_arm9(28'h6805200 + i * 4,
                      32'ha9000520 + i, 64'd230 + i);
        end
        expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                    32'h06805210, 32'ha9000524), 6, 0);
        @(negedge source_clk);
        arm9_vram_address = 28'h6805210;
        arm9_vram_data = 32'ha9000524;
        arm9_vram_timestamp = 64'd234;
        arm9_vram_valid = 1;
        frame_number = 32'd5;
        frame_timestamp = 64'd235;
        frame_valid = 1;
        @(posedge source_clk);
        if (!frame_ready)
            $fatal(1, "stale boundary waited behind a full ordered stream");
        if (arm9_vram_ready)
            $fatal(1, "real record was accepted beside stale-boundary bypass");
        @(negedge source_clk);
        frame_valid = 0;
        if (source_fault)
            $fatal(1, "stale-boundary bypass raised source fault");
        @(negedge ddr_clk);
        record_ready = 1;
        boundary_ready = 1;
        cycles = 0;
        while (arm9_vram_valid) begin
            @(posedge source_clk);
            arm9_fired = arm9_vram_valid && arm9_vram_ready;
            @(negedge source_clk);
            if (arm9_fired) arm9_vram_valid = 0;
            cycles = cycles + 1;
            if (cycles > 100)
                $fatal(1, "real record did not drain after stale bypass");
        end
        wait_drain();
        $display("stage stale boundary bypass");

        // A globally selected SWAP is an ordered promise to close its current
        // frame.  Its equal VBlank is redundant even if the full async FIFO
        // prevents that SWAP from crossing yet.  Retire the boundary locally,
        // then prove the held SWAP advances the frame exactly once.
        @(negedge ddr_clk);
        record_ready = 0;
        boundary_ready = 0;
        for (i = 0; i < 4; i = i + 1) begin
            expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                        32'h06805300 + i * 4,
                                        32'ha9000530 + i), 6, 0);
            send_arm9(28'h6805300 + i * 4,
                      32'ha9000530 + i, 64'd240 + i);
        end
        send_gpu(28'h400, 2'b10, 4'hf, 32'h00000050, 64'd250);
        send_gpu(28'h400, 2'b10, 4'hf, 32'h00000003, 64'd251);
        expect_output(gx_record_value(8'h50, 32'h00000003), 6, 1);
        @(negedge source_clk);
        frame_number = 32'd6;
        frame_timestamp = 64'd252;
        frame_valid = 1;
        @(posedge source_clk);
        if (!frame_ready)
            $fatal(1, "equal boundary waited behind promised SWAP");
        @(negedge source_clk);
        frame_valid = 0;
        if (source_fault)
            $fatal(1, "promised-SWAP bypass raised source fault");
        @(negedge ddr_clk);
        record_ready = 1;
        boundary_ready = 1;
        wait_drain();
        expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                    32'h06805320, 32'ha9000532), 7, 0);
        send_arm9(28'h6805320, 32'ha9000532, 64'd253);
        wait_drain();

        // Equality alone is not redundant.  An equal boundary behind a
        // non-SWAP GX head remains ordered and must cross after that record.
        @(negedge ddr_clk);
        record_ready = 0;
        boundary_ready = 0;
        for (i = 0; i < 4; i = i + 1) begin
            expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                        32'h06805400 + i * 4,
                                        32'ha9000540 + i), 7, 0);
            send_arm9(28'h6805400 + i * 4,
                      32'ha9000540 + i, 64'd260 + i);
        end
        send_gpu(28'h480, 2'b10, 4'hf, 32'h20202020, 64'd270);
        expect_output(gx_record_value(8'h20, 32'h20202020), 7, 0);
        expect_boundary(32'd7);
        @(negedge source_clk);
        frame_number = 32'd7;
        frame_timestamp = 64'd271;
        frame_valid = 1;
        @(posedge source_clk);
        if (frame_ready)
            $fatal(1, "equal boundary bypassed a non-SWAP GX head");
        @(negedge ddr_clk);
        record_ready = 1;
        boundary_ready = 1;
        cycles = 0;
        while (frame_valid) begin
            @(posedge source_clk);
            arm9_fired = frame_valid && frame_ready;
            @(negedge source_clk);
            if (arm9_fired) frame_valid = 0;
            cycles = cycles + 1;
            if (cycles > 100)
                $fatal(1, "equal boundary did not drain after non-SWAP");
        end
        wait_drain();
        $display("stage promised SWAP boundary bypass");

        expect_output(direct_record(8'd4, 8'h02, 4'hf,
                                    32'h04000240, 32'h00000081), 8, 0);
        send_gpu(28'h240, 2'b10, 4'hf, 32'h00000081, 64'd220);
        wait_drain();
        $display("stage swap frame");

        // Both GPU2D register windows retain byte lanes and join the same
        // timestamp-ordered stream without entering GX normalization.
        expect_output(direct_record(8'd5, 8'h01, 4'h3,
                                    32'h04000018, 32'h00000123), 8, 0);
        send_gpu(28'h018, 2'b01, 4'h3, 32'h00000123, 64'd221);
        expect_output(direct_record(8'd5, 8'h01, 4'hc,
                                    32'h0400101a, 32'habcd0000), 8, 0);
        send_gpu(28'h1018, 2'b01, 4'hc, 32'habcd0000, 64'd222);
        expect_output(direct_record(8'd6, 8'h01, 4'h3,
                                    32'h05000024, 32'h00007c1f), 8, 0);
        send_gpu(28'h1000024, 2'b01, 4'h3, 32'h00007c1f, 64'd223);
        expect_output(direct_record(8'd7, 8'h02, 4'hf,
                                    32'h07000410, 32'h89abcdef), 8, 0);
        send_gpu(28'h3000410, 2'b10, 4'hf, 32'h89abcdef, 64'd224);
        wait_drain();
        $display("stage compact ARM video writes");

        // HBlank is the pre-HDMA line snapshot. On an equal timestamp it
        // must cross before the register update. Line 262 proves the complete
        // LCD lifecycle marker is retained rather than truncated to visible.
        expect_output(direct_record(8'd8, 8'h00, 4'h0,
                                    32'd262, 32'd123), 8, 0);
        expect_output(direct_record(8'd5, 8'h01, 4'h3,
                                    32'h04000018, 32'h00000456), 8, 0);
        @(negedge source_clk);
        hblank_line = 9'd262;
        hblank_frame = 32'd123;
        hblank_timestamp = 64'd225;
        hblank_valid = 1;
        gpu_address = 28'h018;
        gpu_access = 2'b01;
        gpu_byte_enable = 4'h3;
        gpu_data = 32'h00000456;
        gpu_timestamp = 64'd225;
        gpu_valid = 1;
        @(posedge source_clk);
        if (!hblank_ready || gpu_ready)
            $fatal(1, "equal-timestamp HBlank did not precede GPU2D write");
        @(negedge source_clk);
        hblank_valid = 0;
        @(posedge source_clk);
        if (!gpu_ready)
            $fatal(1, "GPU2D write did not follow equal HBlank");
        @(negedge source_clk);
        gpu_valid = 0;
        wait_drain();
        $display("stage HBlank pre-HDMA ordering");

        // Backpressure holds the DDR output exactly. The independent GX FIFO
        // continues accepting normalized commands after the CDC FIFO fills.
        @(negedge ddr_clk);
        record_ready = 0;
        for (i = 0; i < 12; i = i + 3)
            expect_output(gx_packed_three(
                8'h20, 32'hb0000000 + i,
                8'h20, 32'hb0000001 + i,
                8'h20, 32'hb0000002 + i), 8, 0);
        for (i = 0; i < 12; i = i + 1) begin
            send_gpu(28'h480, 2'b10, 4'hf,
                     32'hb0000000 + i, 64'd300 + i);
        end
        repeat (12) @(posedge source_clk);
        if (fifo_level == 0)
            $fatal(1, "GX FIFO serialized behind the blocked CDC FIFO");
        repeat (5) @(posedge ddr_clk);
        @(negedge ddr_clk);
        record_ready = 1;
        wait_drain();
        $display("stage backpressure");

        // A later-timestamp SWAP may already be buffered while a
        // VBlank is waiting behind a full CDC FIFO. Once space returns, the
        // timestamp arbiter emits the older boundary first. The buffered GX
        // record must be tagged with the new ordered-stream frame rather than
        // the stale frame captured when it entered the normalization FIFO.
        // Its pending-SWAP promise is timestamp-qualified and therefore cannot
        // suppress this older boundary.
        @(negedge ddr_clk);
        record_ready = 0;
        boundary_ready = 0;
        for (i = 0; i < 4; i = i + 1) begin
            expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                        32'h06805000 + i * 4,
                                        32'ha9000700 + i), 8, 0);
            send_arm9(28'h6805000 + i * 4,
                      32'ha9000700 + i, 64'd700 + i);
        end
        expect_boundary(32'd8);
        expect_output(gx_record_value(8'h50, 32'h00000003), 9, 1);
        send_gpu(28'h540, 2'b10, 4'hf, 32'h00000003, 64'd750);
        @(negedge source_clk);
        frame_number = 32'd8;
        frame_timestamp = 64'd740;
        frame_valid = 1;
        repeat (4) @(posedge source_clk);
        if (frame_ready)
            $fatal(1, "boundary escaped a full CDC FIFO");
        @(negedge ddr_clk);
        record_ready = 1;
        boundary_ready = 1;
        cycles = 0;
        while (frame_valid) begin
            @(posedge source_clk);
            arm9_fired = frame_valid && frame_ready;
            @(negedge source_clk);
            if (arm9_fired) frame_valid = 0;
            cycles = cycles + 1;
            if (cycles > 100)
                $fatal(1, "ordered boundary retag timeout");
        end
        wait_drain();
        $display("stage ordered boundary retag");

        // The oldest fully normalized SWAP is an ordered frame-close promise
        // even when several non-SWAP GX records hide it from the FIFO head and
        // a later SWAP for the next frame is also pending. Fill the crossing,
        // queue non-SWAPs, SWAP A at t=781, more non-SWAPs, and SWAP B at
        // t=810. Boundary t=790 is redundant because of A; it must not wait on
        // B. Both real SWAP records still drain in order and each advances the
        // output-time logical frame exactly once.
        @(negedge ddr_clk);
        record_ready = 0;
        boundary_ready = 0;
        for (i = 0; i < 4; i = i + 1) begin
            expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                        32'h06805500 + i * 4,
                                        32'ha9000550 + i), 10, 0);
            send_arm9(28'h6805500 + i * 4,
                      32'ha9000550 + i, 64'd760 + i);
        end
        expect_output(gx_packed_three(
            8'h20, 32'hc0000000,
            8'h20, 32'hc0000001,
            8'h20, 32'hc0000002), 10, 0);
        for (i = 0; i < 3; i = i + 1) begin
            send_gpu(28'h480, 2'b10, 4'hf,
                     32'hc0000000 + i, 64'd770 + i);
        end
        expect_output(gx_record_value(8'h50, 32'h00000003), 10, 1);
        send_gpu(28'h400, 2'b10, 4'hf, 32'h00000050, 64'd780);
        send_gpu(28'h400, 2'b10, 4'hf, 32'h00000003, 64'd781);
        expect_output(gx_packed_three(
            8'h21, 32'hd0000000,
            8'h21, 32'hd0000001,
            8'h50, 32'h00000005), 11, 1);
        for (i = 0; i < 2; i = i + 1) begin
            send_gpu(28'h484, 2'b10, 4'hf,
                     32'hd0000000 + i, 64'd800 + i);
        end
        send_gpu(28'h540, 2'b10, 4'hf, 32'h00000005, 64'd810);
        if (fifo_level < 4 || dut.gx_record[15:8] == 8'h50 ||
            !dut.gx_swap_pending || dut.gx_oldest_swap_timestamp != 64'd781)
            $fatal(1, "hidden-SWAP fixture did not retain non-SWAP heads");

        @(negedge source_clk);
        frame_number = 32'd10;
        frame_timestamp = 64'd790;
        frame_valid = 1;
        #1;
        if (!frame_ready)
            $fatal(1, "equal boundary waited for a hidden pending SWAP");
        @(posedge source_clk);
        @(negedge source_clk);
        frame_valid = 0;
        if (source_fault)
            $fatal(1, "hidden-SWAP promise raised source fault");

        @(negedge ddr_clk);
        record_ready = 1;
        boundary_ready = 1;
        wait_drain();
        if (dut.gx_swap_pending)
            $fatal(1, "accepted hidden SWAPs did not retire their promises");
        expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                    32'h06805520, 32'ha9000558), 12, 0);
        send_arm9(28'h6805520, 32'ha9000558, 64'd820);
        wait_drain();
        $display("stage hidden SWAP boundary bypass");

        // A malformed geometry access is accepted once, raises the sticky
        // source protocol fault, crosses to DDR, and is recoverable only by a
        // common session flush. BE=0010 restores the misaligned 0x401 address.
        send_gpu(28'h400, 2'b10, 4'b0010,
                 32'hbad00401, 64'd830);
        wait_for_fault();
        if (source_fault_reason != 4'd1 || ddr_fault_reason != 4'd1)
            $fatal(1, "malformed GX access reported wrong fault reason");
        $display("stage protocol fault");
        if (record_valid || gpu_ready || arm9_vram_ready ||
            arm7_vram_ready || frame_ready)
            $fatal(1, "traffic escaped after sticky protocol fault");

        @(negedge source_clk);
        session_flush = 1;
        repeat (4) @(posedge source_clk);
        @(negedge source_clk);
        session_flush = 0;
        wait_active();
        if (source_fault || ddr_fault ||
            source_fault_reason != 0 || ddr_fault_reason != 0)
            $fatal(1, "session flush did not clear both fault domains");
        expect_output(direct_record(8'd3, 8'h02, 4'hf,
                                    32'h06804000, 32'ha9000600), 1, 0);
        send_arm9(28'h6804000, 32'ha9000600, 64'd600);
        wait_drain();

        if (expected_read != expected_write)
            $fatal(1, "not all expected records drained");
        $display("PASS: frame record CDC timestamp merge, GX normalization/buffering, SWAP/VBlank frames, skewed reset, held backpressure, and protocol-fault recovery");
        $finish;
    end
endmodule
