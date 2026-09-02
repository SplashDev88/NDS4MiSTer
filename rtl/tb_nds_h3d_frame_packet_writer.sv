module tb_nds_h3d_frame_packet_writer;
    localparam logic [28:0] CONTROL_BASE = 29'd0;
    localparam logic [28:0] SLOT_BASE = 29'd64;
    localparam integer SLOT_STRIDE_WORDS = 8192;
    localparam integer MAX_RECORDS = 3;
    localparam integer MEMORY_WORDS = 32768;
    localparam integer MAX_WRITES = 1024;

    logic clk = 0;
    logic reset = 1;
    logic session_flush = 0;
    logic [31:0] session = 7;

    logic record_valid = 0;
    logic record_ready;
    logic [127:0] record = 0;
    logic [31:0] record_frame = 0;
    logic record_frame_end = 0;
    logic boundary_valid = 0;
    logic boundary_ready;
    logic [31:0] boundary_frame = 0;

    logic active;
    logic full;
    logic packet_done;
    logic [31:0] producer_sequence;
    logic [31:0] acknowledged_sequence;
    logic fault;
    logic [4:0] fault_reason;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy = 0;
    logic ddram_accept_enable = 1;
    wire ddram_command_accepted =
        (ddram_read || ddram_write) &&
        !ddram_busy && ddram_accept_enable;
    logic [63:0] ddram_read_data;
    logic ddram_read_data_ready;

    logic [63:0] memory [0:MEMORY_WORDS-1];
    logic [28:0] write_log_address [0:MAX_WRITES-1];
    logic [63:0] write_log_data [0:MAX_WRITES-1];
    integer write_log_count = 0;
    integer accepted_reads = 0;
    integer input_handshakes = 0;
    integer boundary_handshakes = 0;
    integer completed_packets = 0;
    integer held_input_cycles = 0;
    integer unaccepted_request_cycles = 0;

    logic next_read_same_edge = 1;
    logic read_pending = 0;
    logic [63:0] pending_read_data = 0;
    integer pending_read_delay = 0;
    logic delayed_read_ready = 0;
    logic [63:0] delayed_read_data = 0;
    logic random_stalls = 0;
    logic [31:0] stall_lfsr = 32'h79a4c31d;

    logic input_held = 0;
    logic [127:0] held_record;
    logic [31:0] held_frame;
    logic held_frame_end;
    logic boundary_input_held = 0;
    logic [31:0] held_boundary_frame;

    logic [127:0] expected_records [0:MAX_RECORDS-1];
    integer expected_record_count = 0;

    always #5 clk = ~clk;

    nds_h3d_frame_packet_writer #(
        .CONTROL_BASE_WORD(CONTROL_BASE),
        .SLOT_BASE_WORD(SLOT_BASE),
        .SLOT_COUNT(4),
        .SLOT_STRIDE_WORDS(SLOT_STRIDE_WORDS),
        .MAX_RECORDS(MAX_RECORDS)
    ) dut (.*);

    wire same_edge_read_ready =
        ddram_command_accepted && ddram_read && next_read_same_edge;
    always_comb begin
        ddram_read_data_ready = same_edge_read_ready || delayed_read_ready;
        if (delayed_read_ready)
            ddram_read_data = delayed_read_data;
        else if (ddram_address < MEMORY_WORDS)
            ddram_read_data = memory[ddram_address];
        else
            ddram_read_data = 64'hxxxxxxxxxxxxxxxx;
    end

    function automatic logic [127:0] record_for(
        input logic [31:0] ordinal
    );
        record_for = {
            32'hd0000000 | ordinal,
            32'hc0000000 | ordinal,
            32'hb0000000 | ordinal,
            12'd0, 4'd0, ordinal[7:0], 8'd1
        };
    endfunction

    function automatic logic [127:0] record_for_fields(
        input logic [31:0] ordinal,
        input logic [7:0] kind,
        input logic [7:0] tag,
        input logic [31:0] address
    );
        record_for_fields = {
            32'hd0000000 | ordinal,
            32'hc0000000 | ordinal,
            address,
            12'd0, 4'hf, tag, kind
        };
    endfunction

    task automatic wait_initialized;
        integer cycles;
        begin
            cycles = 0;
            while (!record_ready && !fault) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
                if (cycles > 500)
                    $fatal(1, "writer initialization timeout state=%0d",
                           dut.state);
            end
            if (fault)
                $fatal(1,
                    "writer faulted during valid initialization state=%0d producer=%h ack=%h read_data=%h ready=%b pending=%b",
                    dut.state, producer_sequence, acknowledged_sequence,
                    ddram_read_data, ddram_read_data_ready, read_pending);
        end
    endtask

    task automatic send_record(
        input logic [127:0] value,
        input logic [31:0] frame,
        input logic frame_end
    );
        integer target;
        begin
            target = input_handshakes + 1;
            @(negedge clk);
            record = value;
            record_frame = frame;
            record_frame_end = frame_end;
            record_valid = 1;
            while (input_handshakes < target) begin
                @(posedge clk);
                #1;
                if (fault)
                    $fatal(1, "writer fault while input record was held");
            end
            @(negedge clk);
            record_valid = 0;
        end
    endtask

    task automatic send_boundary(input logic [31:0] frame);
        integer target;
        begin
            target = boundary_handshakes + 1;
            @(negedge clk);
            boundary_frame = frame;
            boundary_valid = 1;
            while (boundary_handshakes < target) begin
                @(posedge clk);
                #1;
                if (fault)
                    $fatal(1, "writer fault while boundary was held");
            end
            @(negedge clk);
            boundary_valid = 0;
        end
    endtask

    task automatic wait_packet(input integer target);
        integer cycles;
        begin
            cycles = 0;
            while (completed_packets < target) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
                if (fault)
                    $fatal(1, "writer fault while publishing packet");
                if (cycles > 2000)
                    $fatal(1, "packet publication timeout state=%0d",
                           dut.state);
            end
        end
    endtask

    task automatic verify_write(
        input integer index,
        input logic [28:0] address,
        input logic [63:0] data
    );
        begin
            if (index >= write_log_count ||
                write_log_address[index] !== address ||
                write_log_data[index] !== data)
                $fatal(1,
                    "write[%0d] mismatch got=%h/%h expected=%h/%h",
                    index, write_log_address[index], write_log_data[index],
                    address, data);
        end
    endtask

    task automatic verify_packet(
        input integer log_start,
        input logic [31:0] packet_session,
        input logic [31:0] packet_seq,
        input logic [31:0] frame,
        input logic [31:0] flags
    );
        integer index;
        integer cursor;
        logic [1:0] slot;
        logic [28:0] base;
        begin
            slot = (packet_seq - 1) & 2'b11;
            base = SLOT_BASE + 29'(slot) * 29'(SLOT_STRIDE_WORDS);
            cursor = log_start;
            for (index = 0; index < expected_record_count;
                 index = index + 1) begin
                verify_write(cursor, base + 8 + index * 2,
                             expected_records[index][63:0]);
                cursor = cursor + 1;
                verify_write(cursor, base + 9 + index * 2,
                             expected_records[index][127:64]);
                cursor = cursor + 1;
            end
            verify_write(cursor, base + 0,
                         {32'h00400001, 32'h31423348});
            cursor = cursor + 1;
            verify_write(cursor, base + 1, {32'd0, packet_session});
            cursor = cursor + 1;
            verify_write(cursor, base + 2, {32'd0, packet_seq});
            cursor = cursor + 1;
            verify_write(cursor, base + 3, {flags, frame});
            cursor = cursor + 1;
            verify_write(cursor, base + 4,
                         {32'(expected_record_count),
                          32'(expected_record_count * 16)});
            cursor = cursor + 1;
            verify_write(cursor, base + 5, {32'd0, 30'd0, slot});
            cursor = cursor + 1;
            verify_write(cursor, base + 6, 64'd0);
            cursor = cursor + 1;
            // Slot commit must be the last slot write.
            verify_write(cursor, base + 7, {32'd0, packet_seq});
            cursor = cursor + 1;
            // Global producer publication must follow physical slot commit.
            verify_write(cursor, CONTROL_BASE + 2, {32'd0, packet_seq});
            cursor = cursor + 1;
            if (write_log_count != cursor)
                $fatal(1,
                    "packet sequence %0d had extra/missing writes %0d/%0d",
                    packet_seq, write_log_count - log_start,
                    cursor - log_start);
            if (memory[base + 7] !== {32'd0, packet_seq} ||
                memory[CONTROL_BASE + 2] !== {32'd0, packet_seq})
                $fatal(1, "commit/producer memory publication mismatch");
        end
    endtask

    task automatic pulse_flush(
        input logic [31:0] new_session,
        input logic [31:0] producer,
        input logic [63:0] ack
    );
        begin
            @(negedge clk);
            // session_flush resets the writer-side transaction owner. Quiesce
            // the test DDR responder on the same boundary so an old delayed
            // acknowledgement cannot masquerade as the new session read.
            random_stalls = 0;
            ddram_busy = 0;
            ddram_accept_enable = 0;
            read_pending = 0;
            delayed_read_ready = 0;
            session = new_session;
            memory[CONTROL_BASE + 1] = {32'd0, new_session};
            memory[CONTROL_BASE + 2] = {32'd0, producer};
            memory[CONTROL_BASE + 3] = ack;
            session_flush = 1;
            @(posedge clk);
            @(negedge clk);
            session_flush = 0;
            next_read_same_edge = 1;
            ddram_accept_enable = 1;
            random_stalls = 1;
        end
    endtask

    // Random waitrequest and independent physical acceptance stalls. A DDR
    // command is never retired merely because it was presented.
    always @(negedge clk) begin
        delayed_read_ready = 0;
        if (read_pending) begin
            if (pending_read_delay == 0) begin
                delayed_read_data = pending_read_data;
                delayed_read_ready = 1;
                read_pending = 0;
            end else begin
                pending_read_delay = pending_read_delay - 1;
            end
        end
        if (random_stalls) begin
            stall_lfsr = {
                stall_lfsr[30:0],
                stall_lfsr[31] ^ stall_lfsr[21] ^
                stall_lfsr[1] ^ stall_lfsr[0]
            };
            ddram_busy = stall_lfsr[2:0] == 3'b000;
            ddram_accept_enable = stall_lfsr[5:3] != 3'b000;
        end
    end

    always @(posedge clk) begin
        if (ddram_burst_count !== 8'd1 ||
            ddram_byte_enable !== 8'hff)
            $fatal(1, "writer used burst or partial DDR byte enable");
        if (ddram_busy && (ddram_read || ddram_write))
            $fatal(1, "writer requested DDR while busy was asserted");
        if ((ddram_read || ddram_write) && !ddram_busy &&
            !ddram_command_accepted)
            unaccepted_request_cycles = unaccepted_request_cycles + 1;

        if (!reset && !session_flush && record_valid && record_ready)
            input_handshakes = input_handshakes + 1;
        if (!reset && !session_flush && boundary_valid && boundary_ready)
            boundary_handshakes = boundary_handshakes + 1;
        if (packet_done)
            completed_packets = completed_packets + 1;

        if (input_held &&
            (!record_valid || record !== held_record ||
             record_frame !== held_frame ||
             record_frame_end !== held_frame_end))
            $fatal(1, "record source changed payload while backpressured");
        input_held = record_valid && !record_ready;
        if (record_valid && !record_ready) begin
            held_record = record;
            held_frame = record_frame;
            held_frame_end = record_frame_end;
            held_input_cycles = held_input_cycles + 1;
        end
        if (boundary_input_held &&
            (!boundary_valid || boundary_frame !== held_boundary_frame))
            $fatal(1, "boundary source changed while backpressured");
        boundary_input_held = boundary_valid && !boundary_ready;
        if (boundary_valid && !boundary_ready) begin
            held_boundary_frame = boundary_frame;
            held_input_cycles = held_input_cycles + 1;
        end

        if (ddram_command_accepted && ddram_write) begin
            if (ddram_address >= MEMORY_WORDS)
                $fatal(1, "DDR write outside test memory: %h",
                       ddram_address);
            if (write_log_count >= MAX_WRITES)
                $fatal(1, "write log overflow");
            write_log_address[write_log_count] = ddram_address;
            write_log_data[write_log_count] = ddram_write_data;
            write_log_count = write_log_count + 1;
            memory[ddram_address] = ddram_write_data;
        end

        if (ddram_command_accepted && ddram_read) begin
            if (ddram_address >= MEMORY_WORDS)
                $fatal(1, "DDR read outside test memory: %h",
                       ddram_address);
            accepted_reads = accepted_reads + 1;
            if (!next_read_same_edge) begin
                if (read_pending)
                    $fatal(1, "overlapping delayed DDR reads");
                pending_read_data <= memory[ddram_address];
                pending_read_delay <= 1 + (accepted_reads % 3);
                read_pending <= 1;
            end
            next_read_same_edge <= !next_read_same_edge;
        end
    end

    integer index;
    integer log_start;
    integer packet_target;
    integer reads_before_full;
    integer writes_before_full;
    integer handshakes_before_full;

    initial begin : timeout_guard
        repeat (30000) @(posedge clk);
        $fatal(1,
            "frame-packet writer timeout state=%0d producer=%0d ack=%0d",
            dut.state, producer_sequence, acknowledged_sequence);
    end

    initial begin
        for (index = 0; index < MEMORY_WORDS; index = index + 1)
            memory[index] = 0;
        memory[CONTROL_BASE + 1] = {32'd0, session};
        memory[CONTROL_BASE + 2] = 0;
        memory[CONTROL_BASE + 3] = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;
        random_stalls = 1;
        wait_initialized();

        // Three records without FRAME_END auto-close a continuation packet.
        log_start = write_log_count;
        expected_record_count = 3;
        expected_records[0] = record_for_fields(
            1, 8'd3, 8'd1, 32'h06000000);
        expected_records[1] = record_for_fields(
            2, 8'd4, 8'd0, 32'h04000240);
        expected_records[2] = record_for_fields(
            3, 8'd1, 8'h2a, 32'd0);
        packet_target = completed_packets + 1;
        send_record(expected_records[0], 32'd40, 0);
        send_record(expected_records[1], 32'd40, 0);
        send_record(expected_records[2], 32'd40, 0);
        wait_packet(packet_target);
        verify_packet(log_start, 7, 1, 40, 32'h00000001);

        // The terminal bit on the record that reaches MAX_RECORDS takes
        // precedence over automatic continuation.
        log_start = write_log_count;
        expected_records[0] = record_for_fields(
            4, 8'd1, 8'h2b, 32'd0);
        expected_records[1] = record_for_fields(
            5, 8'd2, 8'd1, 32'h04000060);
        expected_records[2] = record_for_fields(
            6, 8'd1, 8'h50, 32'd0);
        packet_target = completed_packets + 1;
        send_record(expected_records[0], 32'd40, 0);
        send_record(expected_records[1], 32'd40, 0);
        send_record(expected_records[2], 32'd40, 1);
        wait_packet(packet_target);
        verify_packet(log_start, 7, 2, 40, 32'h00000002);
        // Publish two more terminal packets to fill all four unacknowledged
        // slots. The fifth record must remain held and cause no overwrite.
        for (index = 3; index <= 4; index = index + 1) begin
            log_start = write_log_count;
            expected_record_count = 1;
            expected_records[0] = record_for(10 + index);
            packet_target = completed_packets + 1;
            send_record(expected_records[0], 40 + index, 1);
            wait_packet(packet_target);
            verify_packet(log_start, 7, 32'(index),
                          32'(40 + index), 32'h00000002);
        end
        if (!full || producer_sequence != 4 ||
            acknowledged_sequence != 0)
            $fatal(1, "four packets did not fill all slots");

        expected_record_count = 1;
        expected_records[0] = record_for(20);
        log_start = write_log_count;
        packet_target = completed_packets + 1;
        reads_before_full = accepted_reads;
        writes_before_full = write_log_count;
        handshakes_before_full = input_handshakes;
        fork
            send_record(expected_records[0], 32'd45, 1);
            begin
                repeat (40) begin
                    @(posedge clk);
                    #1;
                    if (write_log_count != writes_before_full ||
                        input_handshakes != handshakes_before_full ||
                        producer_sequence != 4)
                        $fatal(1, "full writer accepted or overwrote slot");
                end
                if (accepted_reads <= reads_before_full)
                    $fatal(1, "full writer did not poll acknowledgement");
                @(negedge clk);
                memory[CONTROL_BASE + 3] = {32'd0, 32'd1};
            end
        join
        wait_packet(packet_target);
        verify_packet(log_start, 7, 5, 45, 32'h00000002);
        if (acknowledged_sequence != 1)
            $fatal(1, "acknowledged slot was not reused");

        // A live session input change is fail-closed. session_flush clears
        // the sticky fault and then revalidates the new control session.
        @(negedge clk);
        memory[CONTROL_BASE + 3] = {32'd0, 32'd5};
        while (!record_ready && !fault) begin
            @(posedge clk);
            #1;
        end
        if (fault)
            $fatal(1, "writer faulted while releasing full-ring credit");
        send_record(
            record_for_fields(21, 8'd3, 8'd1, 32'h06800000),
            32'd46, 0);
        while (!record_ready && !fault) begin
            @(posedge clk);
            #1;
        end
        @(negedge clk);
        session = 8;
        repeat (2) @(posedge clk);
        #1;
        if (!fault || record_ready)
            $fatal(1, "unflushed session change did not fault/stop");
        pulse_flush(8, 0, 64'd0);
        wait_initialized();
        if (fault || producer_sequence != 0 ||
            acknowledged_sequence != 0)
            $fatal(1, "session flush did not recover cleanly");

        log_start = write_log_count;
        expected_record_count = 1;
        expected_records[0] = record_for(30);
        packet_target = completed_packets + 1;
        send_record(expected_records[0], 32'd80, 0);
        send_boundary(32'd80);
        wait_packet(packet_target);
        verify_packet(log_start, 8, 1, 80, 32'h00000002);

        // A frame with no records still emits one zero-payload terminal
        // packet, preserving VBlank/render ownership without a fake command.
        log_start = write_log_count;
        expected_record_count = 0;
        packet_target = completed_packets + 1;
        send_boundary(32'd81);
        wait_packet(packet_target);
        verify_packet(log_start, 8, 2, 81, 32'h00000002);

        // Corrupt HPS acknowledgement (reserved high word nonzero) must fault
        // during initialization and can never release a slot.
        pulse_flush(9, 2, {32'h00000001, 32'd1});
        repeat (100) begin
            @(posedge clk);
            #1;
            if (fault) break;
        end
        if (!fault || record_ready || producer_sequence != 2 ||
            fault_reason != 5'd6)
            $fatal(1, "corrupt acknowledgement was accepted");

        if (held_input_cycles == 0 || unaccepted_request_cycles == 0 ||
            accepted_reads == 0)
            $fatal(1, "directed stalls did not exercise backpressure");
        $display(
            "PASS: H3B1 writer commit ordering, CONT/FRAME_END, random stalls, four-slot ack reuse, session flush, and corrupt-ack fault");
        $display(
            "packets=%0d writes=%0d reads=%0d held_input_cycles=%0d unaccepted_ddr_cycles=%0d",
            completed_packets, write_log_count, accepted_reads,
            held_input_cycles, unaccepted_request_cycles);
        $finish;
    end
endmodule
