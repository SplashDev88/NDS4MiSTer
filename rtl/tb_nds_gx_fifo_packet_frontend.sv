module tb_nds_gx_fifo_packet_frontend;
    localparam integer FIFO_DEPTH = 256;
    localparam integer MAX_EXPECTED = 2048;

    logic clk = 0;
    logic reset = 1;
    logic write_valid = 0;
    logic write_ready;
    logic write_is_dma = 0;
    logic [31:0] write_address = 0;
    logic [1:0] write_access = 2'b10;
    logic [31:0] write_data = 0;
    logic [31:0] write_frame = 1;
    logic [63:0] write_timestamp = 1;
    logic record_valid;
    logic record_ready = 1;
    logic [127:0] record;
    logic [31:0] record_frame;
    logic [63:0] record_timestamp;
    logic record_frame_end;
    logic swap_enqueued;
    logic swap_pending;
    logic [63:0] oldest_swap_timestamp;
    logic [8:0] fifo_level;
    logic fifo_empty;
    logic fifo_below_half;
    logic fifo_full;
    logic packed_active;
    logic protocol_error;

    logic [7:0] expected_command [0:MAX_EXPECTED-1];
    logic [31:0] expected_parameter [0:MAX_EXPECTED-1];
    logic [31:0] expected_frame [0:MAX_EXPECTED-1];
    logic [63:0] expected_timestamp [0:MAX_EXPECTED-1];
    integer expected_write = 0;
    integer expected_read = 0;
    integer accepted_writes = 0;
    integer accepted_dma_writes = 0;
    integer accepted_records = 0;
    integer accepted_swaps = 0;
    integer enqueued_swaps = 0;

    logic output_held = 0;
    logic [127:0] held_record;
    logic [31:0] held_record_frame;
    logic [63:0] held_record_timestamp;

    always #5 clk = ~clk;

    nds_gx_fifo_packet_frontend dut (.*);

    task automatic expect_record(
        input logic [7:0] command,
        input logic [31:0] param
    );
        begin
            if (expected_write >= MAX_EXPECTED)
                $fatal(1, "expected record queue overflow");
            expected_command[expected_write] = command;
            expected_parameter[expected_write] = param;
            expected_frame[expected_write] = write_frame;
            expected_timestamp[expected_write] = write_timestamp;
            expected_write = expected_write + 1;
        end
    endtask

    task automatic send_write(
        input logic source_dma,
        input logic [31:0] address,
        input logic [31:0] data
    );
        integer wait_cycles;
        logic [31:0] held_frame;
        logic [63:0] held_timestamp;
        begin
            held_frame = write_frame;
            held_timestamp = write_timestamp;
            @(negedge clk);
            write_is_dma = source_dma;
            write_address = address;
            write_access = 2'b10;
            write_data = data;
            write_valid = 1;
            wait_cycles = 0;
            while (!write_ready) begin
                @(posedge clk);
                if (write_address !== address || write_data !== data ||
                    write_is_dma !== source_dma ||
                    write_frame !== held_frame ||
                    write_timestamp !== held_timestamp || !write_valid)
                    $fatal(1, "input payload changed while stalled");
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 2000)
                    $fatal(1, "input acceptance timeout");
                @(negedge clk);
            end
            @(posedge clk);
            accepted_writes = accepted_writes + 1;
            if (source_dma)
                accepted_dma_writes = accepted_dma_writes + 1;
            @(negedge clk);
            write_valid = 0;
        end
    endtask

    task automatic send_direct(
        input logic source_dma,
        input logic [7:0] command,
        input logic [31:0] param
    );
        begin
            expect_record(command, param);
            send_write(source_dma,
                       32'h04000400 + (32'(command) << 2),
                       param);
        end
    endtask

    task automatic wait_for_packed_idle;
        integer cycles;
        begin
            cycles = 0;
            while (packed_active) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > 2000)
                    $fatal(1, "packed decoder did not become idle");
            end
        end
    endtask

    task automatic wait_for_drain;
        integer cycles;
        begin
            cycles = 0;
            while (expected_read != expected_write || !fifo_empty ||
                   record_valid || packed_active) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > 10000)
                    $fatal(1,
                        "record FIFO did not drain read=%0d write=%0d level=%0d valid=%b packed=%b",
                        expected_read, expected_write, fifo_level,
                        record_valid, packed_active);
            end
        end
    endtask

    task automatic reset_state;
        begin
            @(negedge clk);
            reset = 1;
            write_valid = 0;
            record_ready = 1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 0;
            expected_write = 0;
            expected_read = 0;
            output_held = 0;
        end
    endtask

    always @(posedge clk) begin
        if (!reset) begin
            if (fifo_empty !== (fifo_level == 0) ||
                fifo_full !== (fifo_level == 9'd256) ||
                fifo_below_half !== (fifo_level <= 9'd127))
                $fatal(1,
                    "FIFO status mismatch level=%0d empty=%b below=%b full=%b",
                    fifo_level, fifo_empty, fifo_below_half, fifo_full);

            if (output_held &&
                (!record_valid || record !== held_record ||
                 record_frame !== held_record_frame ||
                 record_timestamp !== held_record_timestamp))
                $fatal(1, "record payload changed under backpressure");

            if (record_valid) begin
                if (record[7:0] !== 8'd1 || record[19:16] !== 4'd0 ||
                    record[31:20] !== 12'd0 ||
                    record[63:32] !== 32'd0 ||
                    record[127:96] !== 32'd0)
                    $fatal(1, "record ABI reserved fields were not exact");
                if (record_frame_end !==
                    (record_ready && record[15:8] == 8'h50))
                    $fatal(1, "frame_end did not pulse only on accepted SWAP");
            end else if (record !== 128'd0 || record_frame !== 32'd0 ||
                         record_timestamp !== 64'd0 || record_frame_end)
                $fatal(1, "invalid record output was not zero");

            if (record_valid && record_ready) begin
                if (expected_read >= expected_write)
                    $fatal(1, "unexpected output record");
                if (record[15:8] !== expected_command[expected_read] ||
                    record[95:64] !== expected_parameter[expected_read] ||
                    record_frame !== expected_frame[expected_read] ||
                    record_timestamp !== expected_timestamp[expected_read])
                    $fatal(1,
                        "record mismatch index=%0d got=%02x/%08x frame=%0d time=%0d expected=%02x/%08x frame=%0d time=%0d",
                        expected_read, record[15:8], record[95:64],
                        record_frame, record_timestamp,
                        expected_command[expected_read],
                        expected_parameter[expected_read],
                        expected_frame[expected_read],
                        expected_timestamp[expected_read]);
                if (record_frame_end &&
                    record[15:8] !== expected_command[expected_read])
                    $fatal(1, "frame_end separated from accepted SWAP record");
                accepted_records = accepted_records + 1;
                if (record_frame_end)
                    accepted_swaps = accepted_swaps + 1;
                expected_read = expected_read + 1;
            end

            output_held = record_valid && !record_ready;
            if (record_valid && !record_ready) begin
                held_record = record;
                held_record_frame = record_frame;
                held_record_timestamp = record_timestamp;
            end

            if (!swap_pending && oldest_swap_timestamp != 0)
                $fatal(1, "empty SWAP timestamp queue exposed stale data");

            if (swap_enqueued)
                enqueued_swaps = enqueued_swaps + 1;
        end
    end

    integer i;
    integer before_read;
    integer dma_write_base;
    logic [31:0] held_input_data;
    logic [31:0] dma_word;

    initial begin : timeout_guard
        repeat (50000) @(posedge clk);
        $fatal(1, "GX FIFO packet frontend test timeout");
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Each normalized entry retains metadata from the raw word that
        // creates it: direct/parameter entries use that accepted word, while
        // internally emitted zero-parameter commands use the packed header.
        write_frame = 32'd7;
        write_timestamp = 64'd70;
        send_direct(0, 8'h20, 32'h70000020);
        write_frame = 32'd8;
        write_timestamp = 64'd80;
        send_write(0, 32'h04000400, 32'h00000020);
        write_frame = 32'd9;
        write_timestamp = 64'd90;
        expect_record(8'h20, 32'h90000020);
        send_write(0, 32'h04000400, 32'h90000020);
        write_frame = 32'd10;
        write_timestamp = 64'd100;
        expect_record(8'h11, 32'h00000011);
        send_write(0, 32'h04000400, 32'h00000011);
        wait_for_packed_idle();
        wait_for_drain();
        write_frame = 32'd1;
        write_timestamp = 64'd1;

        // Direct CPU and DMA command writes share one ordered normalized FIFO.
        send_direct(0, 8'h20, 32'h20000001);
        send_direct(1, 8'h21, 32'h21000002);

        // Packed 10/12/23 consumes 1/1/2 parameters; zero padding is skipped.
        expect_record(8'h10, 32'h10101010);
        expect_record(8'h12, 32'h12121212);
        expect_record(8'h23, 32'h23232301);
        expect_record(8'h23, 32'h23232302);
        send_write(0, 32'h04000400, 32'h00231210);
        send_write(0, 32'h04000400, 32'h10101010);
        send_write(0, 32'h04000404, 32'h12121212);
        send_write(0, 32'h04000408, 32'h23232301);
        send_write(0, 32'h0400040c, 32'h23232302);

        // Preserve the existing zero-parameter rules: nonzero commands use
        // the triggering packed word as their dummy parameter, trailing zero
        // padding is skipped, and an all-zero word emits exactly one NOP.
        expect_record(8'h11, 32'h00411511);
        expect_record(8'h15, 32'h00411511);
        expect_record(8'h41, 32'h00411511);
        send_write(0, 32'h04000400, 32'h00411511);
        expect_record(8'h00, 32'h00000000);
        send_write(0, 32'h04000400, 32'h00000000);
        wait_for_packed_idle();
        wait_for_drain();

        // SWAP is not a standalone marker: its accepted command record itself
        // carries frame_end, and the following record cannot overtake it.
        record_ready = 0;
        expect_record(8'h50, 32'h00000003);
        send_write(1, 32'h04000400, 32'h00000050);
        send_write(1, 32'h04000400, 32'h00000003);
        wait_for_packed_idle();
        send_direct(0, 8'h21, 32'h21000004);
        repeat (3) begin
            @(posedge clk);
            if (!record_valid || record[15:8] !== 8'h50 ||
                record_frame_end)
                $fatal(1, "stalled SWAP did not remain an unaccepted head record");
        end
        @(negedge clk);
        record_ready = 1;
        wait_for_drain();

        // Exact 118-raw-word NSMB-sized GXFIFO DMA batch. Each pair is one
        // packed command word followed by its parameter. Packed zero padding
        // and deterministic sink stalls force held-valid source cycles while
        // preserving all 59 normalized records in order.
        reset_state();
        dma_write_base = accepted_dma_writes;
        for (i = 0; i < 59; i = i + 1) begin
            dma_word = 32'ha5a50000 ^ (32'h02000000 + 32'(i * 8));
            expect_record(8'h20, dma_word);
            send_write(1, 32'h04000400, 32'h00000020);
            send_write(1, 32'h04000400, dma_word);
            if ((i % 7) == 3) begin
                @(negedge clk);
                record_ready = 0;
                repeat ((i % 4) + 1) @(posedge clk);
                @(negedge clk);
                record_ready = 1;
            end
        end
        wait_for_drain();
        if (accepted_dma_writes - dma_write_base != 118)
            $fatal(1,
                "DMA batch accepted %0d raw words instead of 118",
                accepted_dma_writes - dma_write_base);

        // Fill the real FIFO and verify exact architectural thresholds.
        reset_state();
        record_ready = 0;
        for (i = 0; i < 127; i = i + 1)
            send_direct(i[0], 8'h20 + (i % 16), 32'hc0000000 + i);
        if (fifo_level !== 9'd127 || !fifo_below_half || fifo_full)
            $fatal(1, "below-half boundary at 127 was incorrect");
        send_direct(0, 8'h20, 32'hc000007f);
        if (fifo_level !== 9'd128 || fifo_below_half || fifo_full)
            $fatal(1, "below-half deassertion at 128 was incorrect");
        for (i = 128; i < 256; i = i + 1)
            send_direct(i[0], 8'h20 + (i % 16), 32'hc0000000 + i);
        if (fifo_level !== 9'd256 || !fifo_full || fifo_empty ||
            fifo_below_half)
            $fatal(1, "full FIFO status was incorrect");

        // A direct write must remain valid and stable while full. Releasing
        // one record permits same-edge pop/push without an occupancy bubble.
        held_input_data = 32'hdeadbeef;
        expect_record(8'h40, held_input_data);
        @(negedge clk);
        write_is_dma = 1;
        write_address = 32'h04000500;
        write_access = 2'b10;
        write_data = held_input_data;
        write_valid = 1;
        repeat (7) begin
            @(posedge clk);
            if (write_ready || write_data !== held_input_data ||
                write_address !== 32'h04000500 || !write_valid)
                $fatal(1, "full-FIFO input hold contract failed");
        end
        before_read = expected_read;
        @(negedge clk);
        record_ready = 1;
        @(posedge clk);
        if (!write_ready || fifo_level !== 9'd256)
            $fatal(1, "simultaneous full-FIFO pop/push was not lossless");
        accepted_writes = accepted_writes + 1;
        accepted_dma_writes = accepted_dma_writes + 1;
        @(negedge clk);
        write_valid = 0;
        if (expected_read != before_read + 1)
            $fatal(1, "full-FIFO release did not consume exactly one record");
        wait_for_drain();

        if (expected_read != expected_write)
            $fatal(1, "not all ordered records were accepted");
        if (accepted_swaps != 1)
            $fatal(1, "SWAP closure count mismatch %0d", accepted_swaps);
        if (enqueued_swaps != accepted_swaps)
            $fatal(1, "SWAP enqueue pulse count mismatch %0d/%0d",
                   enqueued_swaps, accepted_swaps);
        if (protocol_error)
            $fatal(1, "valid directed traffic raised protocol_error");

        $display(
            "PASS: GX FIFO packet frontend 118-word DMA order/stalls, packed/direct normalization, 256-entry thresholds, SWAP closure, and held backpressure");
        $display(
            "accepted_writes=%0d accepted_dma_writes=%0d accepted_records=%0d swaps=%0d",
            accepted_writes, accepted_dma_writes,
            accepted_records, accepted_swaps);
        $finish;
    end
endmodule
