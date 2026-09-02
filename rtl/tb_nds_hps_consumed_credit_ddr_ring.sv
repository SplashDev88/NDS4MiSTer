module tb_nds_hps_consumed_credit_ddr_ring;
    localparam logic [28:0] BASE_WORD = 29'd32;
    localparam integer ENTRY_COUNT = 4;
    localparam integer HEADER_WORDS64 = 4;
    localparam logic [31:0] MAGIC = 32'h4341434b;

    logic clk = 0;
    logic reset = 1;
    logic session_begin_valid = 0;
    logic session_begin_ready;
    logic [31:0] session_begin_epoch = 0;
    logic session_epoch_fresh = 0;
    logic transport_quiescent = 0;
    logic session_started;
    logic session_active;
    logic [31:0] active_epoch;
    logic [31:0] consumer_sequence;

    logic ring_ack_valid;
    logic ring_ack_ready;
    logic [31:0] ring_ack_epoch;
    logic [31:0] ring_ack_sequence;
    logic ring_ack_cpu_arm9;
    logic [31:0] ring_ack_cycles;
    logic [1:0] ring_ack_kind;
    logic [31:0] ring_ack_source_id;
    logic active;
    logic ddram_active;
    logic sequence_exhausted;
    logic protocol_error;
    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy = 0;
    logic ddram_command_accepted;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;
    logic arbiter_grant = 0;

    logic receiver_epoch_valid = 0;
    logic receiver_epoch_ready;
    logic [31:0] receiver_epoch = 0;
    logic receiver_quiescent = 0;
    logic receiver_credit_valid;
    logic receiver_credit_ready = 1;
    logic receiver_credit_arm9;
    logic [31:0] receiver_credit_cycles;
    logic [1:0] receiver_credit_kind;
    logic [31:0] receiver_credit_source;
    logic tracker_epoch_reset;
    logic receiver_epoch_active;
    logic [31:0] receiver_active_epoch;
    logic receiver_sequence_exhausted;
    logic receiver_protocol_error;
    logic [63:0] arm9_timestamp;
    logic [63:0] arm7_timestamp;
    logic [63:0] shared_timestamp;
    logic shared_timestamp_changed;
    logic tracker_overflow;

    logic [63:0] memory [0:127];
    logic read_pending = 0;
    logic [28:0] pending_read_address = 0;
    integer read_delay = 0;
    integer accepted_reads = 0;
    integer accepted_writes = 0;
    integer delivered = 0;
    integer cycle_count = 0;
    logic zero_poll_response = 0;
    logic [28:0] last_response_address = 0;

    // Default-off proof instance.  Its DDR and ACK ports must remain passive
    // even while the enabled instance is active.
    logic off_session_begin_ready;
    logic off_session_started;
    logic off_session_active;
    logic [31:0] off_active_epoch;
    logic [31:0] off_consumer_sequence;
    logic off_ack_valid;
    logic [31:0] off_ack_epoch;
    logic [31:0] off_ack_sequence;
    logic off_ack_cpu_arm9;
    logic [31:0] off_ack_cycles;
    logic [1:0] off_ack_kind;
    logic [31:0] off_ack_source_id;
    logic off_active;
    logic off_ddram_active;
    logic off_sequence_exhausted;
    logic off_protocol_error;
    logic off_ddram_read;
    logic off_ddram_write;
    logic [7:0] off_ddram_burst_count;
    logic [28:0] off_ddram_address;
    logic [63:0] off_ddram_write_data;
    logic [7:0] off_ddram_byte_enable;

    always #5 clk = ~clk;

    assign ddram_command_accepted =
        arbiter_grant && (ddram_read || ddram_write);

    nds_hps_consumed_credit_ddr_ring #(
        .ENABLED(1'b1),
        .BASE_WORD(BASE_WORD),
        .ENTRY_COUNT(ENTRY_COUNT),
        .HEADER_WORDS64(HEADER_WORDS64),
        .POLL_BACKOFF_CYCLES(3)
    ) dut (
        .clk,
        .reset,
        .session_begin_valid,
        .session_begin_ready,
        .session_begin_epoch,
        .session_epoch_fresh,
        .transport_quiescent,
        .session_started,
        .session_active,
        .active_epoch,
        .consumer_sequence,
        .ack_valid(ring_ack_valid),
        .ack_ready(ring_ack_ready),
        .ack_epoch(ring_ack_epoch),
        .ack_sequence(ring_ack_sequence),
        .ack_cpu_arm9(ring_ack_cpu_arm9),
        .ack_cycles(ring_ack_cycles),
        .ack_kind(ring_ack_kind),
        .ack_source_id(ring_ack_source_id),
        .active,
        .ddram_active,
        .sequence_exhausted,
        .protocol_error,
        .ddram_read,
        .ddram_write,
        .ddram_burst_count,
        .ddram_address,
        .ddram_write_data,
        .ddram_byte_enable,
        .ddram_busy,
        .ddram_command_accepted,
        .ddram_read_data,
        .ddram_read_data_ready
    );

    nds_hps_consumed_credit_ddr_ring off_dut (
        .clk,
        .reset,
        .session_begin_valid(1'b1),
        .session_begin_ready(off_session_begin_ready),
        .session_begin_epoch(32'hfeed1234),
        .session_epoch_fresh(1'b1),
        .transport_quiescent(1'b1),
        .session_started(off_session_started),
        .session_active(off_session_active),
        .active_epoch(off_active_epoch),
        .consumer_sequence(off_consumer_sequence),
        .ack_valid(off_ack_valid),
        .ack_ready(1'b1),
        .ack_epoch(off_ack_epoch),
        .ack_sequence(off_ack_sequence),
        .ack_cpu_arm9(off_ack_cpu_arm9),
        .ack_cycles(off_ack_cycles),
        .ack_kind(off_ack_kind),
        .ack_source_id(off_ack_source_id),
        .active(off_active),
        .ddram_active(off_ddram_active),
        .sequence_exhausted(off_sequence_exhausted),
        .protocol_error(off_protocol_error),
        .ddram_read(off_ddram_read),
        .ddram_write(off_ddram_write),
        .ddram_burst_count(off_ddram_burst_count),
        .ddram_address(off_ddram_address),
        .ddram_write_data(off_ddram_write_data),
        .ddram_byte_enable(off_ddram_byte_enable),
        .ddram_busy(1'b0),
        .ddram_command_accepted(1'b0),
        .ddram_read_data(64'd0),
        .ddram_read_data_ready(1'b0)
    );

    nds_hps_consumed_credit_ack receiver (
        .clk,
        .reset,
        .epoch_begin_valid(receiver_epoch_valid),
        .epoch_begin_ready(receiver_epoch_ready),
        .epoch_begin(receiver_epoch),
        .transport_quiescent(receiver_quiescent),
        .ack_valid(ring_ack_valid),
        .ack_ready(ring_ack_ready),
        .ack_epoch(ring_ack_epoch),
        .ack_sequence(ring_ack_sequence),
        .ack_cpu_arm9(ring_ack_cpu_arm9),
        .ack_cycles(ring_ack_cycles),
        .ack_kind(ring_ack_kind),
        .ack_source_id(ring_ack_source_id),
        .credit_valid(receiver_credit_valid),
        .credit_ready(receiver_credit_ready),
        .credit_arm9(receiver_credit_arm9),
        .credit_cycles(receiver_credit_cycles),
        .credit_kind(receiver_credit_kind),
        .credit_source_id(receiver_credit_source),
        .tracker_epoch_reset,
        .epoch_active(receiver_epoch_active),
        .active_epoch(receiver_active_epoch),
        .sequence_exhausted(receiver_sequence_exhausted),
        .protocol_error(receiver_protocol_error)
    );

    nds_shared_time_credit_tracker tracker (
        .clk,
        .reset(reset || tracker_epoch_reset),
        .credit_valid(receiver_credit_valid &&
                      receiver_credit_ready),
        .credit_arm9(receiver_credit_arm9),
        .credit_cycles(receiver_credit_cycles),
        .arm9_timestamp,
        .arm7_timestamp,
        .shared_timestamp,
        .shared_timestamp_changed,
        .overflow(tracker_overflow)
    );

    // DDR model: physical busy deliberately remains low.  arbiter_grant is
    // independent and is the only source of command acceptance.
    always @(posedge clk) begin
        integer byte_index;
        cycle_count <= cycle_count + 1;
        ddram_read_data_ready <= 1'b0;
        zero_poll_response <= 1'b0;

        if (reset) begin
            read_pending <= 1'b0;
            read_delay <= 0;
        end else if (read_pending) begin
            if (read_delay == 0) begin
                ddram_read_data <= memory[pending_read_address];
                ddram_read_data_ready <= 1'b1;
                last_response_address <= pending_read_address;
                if (memory[pending_read_address] == 0 &&
                    pending_read_address >=
                        BASE_WORD + HEADER_WORDS64 + 2)
                    zero_poll_response <= 1'b1;
                read_pending <= 1'b0;
            end else begin
                read_delay <= read_delay - 1;
            end
        end

        if (!reset && ddram_command_accepted && ddram_read) begin
            if (read_pending)
                $fatal(1, "consumer issued overlapping DDR reads");
            pending_read_address <= ddram_address;
            read_delay <= 1;
            read_pending <= 1'b1;
            accepted_reads <= accepted_reads + 1;
        end
        if (!reset && ddram_command_accepted && ddram_write) begin
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1) begin
                if (ddram_byte_enable[byte_index])
                    memory[ddram_address][byte_index * 8 +: 8] <=
                        ddram_write_data[byte_index * 8 +: 8];
            end
            accepted_writes <= accepted_writes + 1;
        end

        if (!reset && receiver_credit_valid &&
            receiver_credit_ready)
            delivered <= delivered + 1;

        if (!reset && (
            off_session_begin_ready || off_session_started ||
            off_session_active || off_ack_valid || off_active ||
            off_ddram_active || off_sequence_exhausted ||
            off_protocol_error || off_ddram_read || off_ddram_write))
            $fatal(1, "default-off consumed-credit ring became active");
    end

    function automatic integer entry_base(
        input logic [31:0] seq);
        entry_base = BASE_WORD + HEADER_WORDS64 +
            (((seq - 1) & (ENTRY_COUNT - 1)) * 3);
    endfunction

    task automatic clear_transport;
        integer index;
        begin
            @(negedge clk);
            for (index = BASE_WORD;
                 index < BASE_WORD + HEADER_WORDS64 +
                     ENTRY_COUNT * 3;
                 index = index + 1)
                memory[index] = 64'd0;
        end
    endtask

    task automatic publish_descriptor_magic_only;
        begin
            @(negedge clk);
            memory[BASE_WORD + 1] = {MAGIC, 32'd0};
        end
    endtask

    task automatic publish_descriptor_epoch(
        input logic [31:0] epoch);
        begin
            @(negedge clk);
            memory[BASE_WORD + 1][31:0] = epoch;
        end
    endtask

    task automatic begin_receiver(input logic [31:0] epoch);
        begin
            @(negedge clk);
            receiver_quiescent = 1;
            receiver_epoch = epoch;
            receiver_epoch_valid = 1;
            do @(posedge clk); while (!receiver_epoch_ready);
            @(negedge clk);
            receiver_epoch_valid = 0;
            receiver_epoch = 0;
            @(posedge clk);
        end
    endtask

    task automatic request_session(input logic [31:0] epoch);
        begin
            @(negedge clk);
            transport_quiescent = 1;
            session_epoch_fresh = 1;
            session_begin_epoch = epoch;
            session_begin_valid = 1;
            do @(posedge clk); while (!session_begin_ready);
            @(negedge clk);
            session_begin_valid = 0;
            session_begin_epoch = 0;
            transport_quiescent = 0;
            session_epoch_fresh = 0;
        end
    endtask

    task automatic publish_payload(
        input logic [31:0] epoch,
        input logic [31:0] seq,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [1:0] kind,
        input logic [31:0] source_id
    );
        integer base;
        begin
            base = entry_base(seq);
            @(negedge clk);
            memory[base] = {cycles, source_id};
            memory[base + 1] =
                {epoch, 29'd0, kind, cpu_arm9};
        end
    endtask

    task automatic publish_commit(
        input logic [31:0] seq);
        integer base;
        begin
            base = entry_base(seq);
            @(negedge clk);
            // One atomic HPS 32-bit store; the upper half remains reserved.
            memory[base + 2][31:0] = seq;
        end
    endtask

    task automatic wait_control(
        input logic [31:0] epoch,
        input logic [31:0] seq);
        integer timeout;
        begin
            timeout = 0;
            while (memory[BASE_WORD] !== {epoch, seq}) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 300)
                    $fatal(1, "consumer control timeout");
            end
        end
    endtask

    task automatic wait_tracker(
        input logic [63:0] expected9,
        input logic [63:0] expected7,
        input logic [63:0] expected_shared);
        integer timeout;
        begin
            timeout = 0;
            while (arm9_timestamp !== expected9 ||
                   arm7_timestamp !== expected7 ||
                   shared_timestamp !== expected_shared) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100)
                    $fatal(1,
                        "tracker timeout got=%0d/%0d/%0d",
                        arm9_timestamp, arm7_timestamp,
                        shared_timestamp);
            end
        end
    endtask

    initial begin
        integer base2;
        integer held_address;
        integer reads_before_backoff;

        clear_transport();
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // The receiver is activated first; no physical record exists yet.
        begin_receiver(32'h11112222);
        publish_descriptor_magic_only();
        request_session(32'h11112222);

        // Busy is low but the arbiter declines this client.  Request/address
        // must remain asserted and stable until the accepted pulse.
        wait (ddram_read);
        held_address = ddram_address;
        repeat (5) begin
            @(posedge clk);
            #1;
            if (!ddram_read || ddram_address != held_address ||
                session_started)
                $fatal(1,
                    "read request did not wait for actual arbiter grant");
        end

        // A torn descriptor with magic but zero epoch is not a session.
        arbiter_grant = 1;
        repeat (6) @(posedge clk);
        if (session_started || protocol_error)
            $fatal(1, "uncommitted descriptor started/faulted session");
        publish_descriptor_epoch(32'h11112222);
        wait (session_started);
        wait_control(32'h11112222, 0);
        if (!session_active || active_epoch != 32'h11112222)
            $fatal(1, "session did not activate");

        // An empty ring is polled once, then yields deterministic idle cycles.
        wait (zero_poll_response);
        reads_before_backoff = accepted_reads;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (ddram_read ||
                accepted_reads != reads_before_backoff)
                $fatal(1, "empty ring ignored poll backoff");
        end

        // Payload alone is not visible without the 32-bit sequence commit.
        receiver_credit_ready = 0;
        publish_payload(
            32'h11112222, 1, 1, 37, 0, 100);
        repeat (12) @(posedge clk);
        if (ring_ack_valid || delivered != 0 ||
            arm9_timestamp != 0)
            $fatal(1, "uncommitted payload was consumed");
        publish_commit(1);
        wait_control(32'h11112222, 1);
        if (!receiver_credit_valid ||
            receiver_credit_cycles != 37 ||
            !receiver_credit_arm9 ||
            receiver_credit_kind != 0 ||
            receiver_credit_source != 100 ||
            delivered != 0)
            $fatal(1, "first ACK was not retained downstream");

        // The next globally sequenced ACK cannot overtake that retained beat.
        publish_payload(
            32'h11112222, 2, 0, 11, 1, 7);
        publish_commit(2);
        wait (ring_ack_valid);
        #1;
        if (ring_ack_sequence != 2 ||
            ring_ack_epoch != 32'h11112222 ||
            ring_ack_cycles != 11 ||
            ring_ack_cpu_arm9 ||
            ring_ack_kind != 1 ||
            ring_ack_source_id != 7 ||
            memory[entry_base(2) + 2][31:0] != 2 ||
            memory[BASE_WORD][31:0] != 1)
            $fatal(1, "stalled physical ACK/order mismatch");

        // Downstream accepts sequence two, but the DDR arbiter declines the
        // clear.  Commit and consumer watermark remain unchanged while the
        // write request/address/lanes are held.
        @(negedge clk);
        arbiter_grant = 0;
        receiver_credit_ready = 1;
        @(posedge clk);
        wait (ddram_write);
        held_address = ddram_address;
        repeat (4) begin
            @(posedge clk);
            #1;
            if (!ddram_write || ddram_address != held_address ||
                ddram_byte_enable != 8'h0f ||
                memory[entry_base(2) + 2][31:0] != 2 ||
                memory[BASE_WORD][31:0] != 1)
                $fatal(1,
                    "commit clear retired without arbiter acceptance");
        end
        arbiter_grant = 1;
        wait_control(32'h11112222, 2);
        if (memory[entry_base(2) + 2] != 0)
            $fatal(1, "commit was not cleared before consumer watermark");
        wait_tracker(37, 11, 11);
        if (delivered != 2)
            $fatal(1, "ready/valid turnover lost a credit");

        // Synthetic halt ticks share the same global order and shared-min
        // tracker.  One CPU alone does not advance the shared timestamp.
        publish_payload(
            32'h11112222, 3, 1, 32768, 2, 10);
        publish_commit(3);
        wait_control(32'h11112222, 3);
        wait_tracker(32805, 11, 11);
        publish_payload(
            32'h11112222, 4, 0, 32768, 2, 11);
        publish_commit(4);
        wait_control(32'h11112222, 4);
        wait_tracker(32805, 32779, 32779);

        if (tracker_overflow || protocol_error ||
            receiver_protocol_error || sequence_exhausted)
            $fatal(1, "clean transport run latched an error");

        // Reset mid-session cannot silently resume: the persistent coordinator
        // must first supply a fresh epoch, and the old descriptor then fails
        // that new-epoch check.
        @(negedge clk);
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        session_begin_epoch = 32'h11112222;
        session_begin_valid = 1;
        transport_quiescent = 1;
        session_epoch_fresh = 0;
        repeat (4) begin
            @(posedge clk);
            #1;
            if (session_begin_ready || active)
                $fatal(1,
                    "post-reset old epoch resumed without freshness proof");
        end
        @(negedge clk);
        session_begin_valid = 0;
        session_begin_epoch = 0;
        session_epoch_fresh = 1;
        request_session(32'h22223333);
        arbiter_grant = 1;
        wait (protocol_error);
        if (session_active)
            $fatal(1, "stale descriptor did not fail closed");

        // A new clean epoch starts, but a future/gapped commit at the expected
        // slot fails before payload delivery.
        @(negedge clk);
        reset = 1;
        @(posedge clk);
        clear_transport();
        @(negedge clk);
        reset = 0;
        memory[BASE_WORD + 1] =
            {MAGIC, 32'h33334444};
        request_session(32'h33334444);
        wait (session_started);
        base2 = entry_base(1);
        @(negedge clk);
        memory[base2] = {32'd1, 32'd1};
        memory[base2 + 1] =
            {32'h33334444, 29'd0, 2'd1, 1'b1};
        memory[base2 + 2] = 64'd2;
        wait (protocol_error);
        if (ring_ack_valid)
            $fatal(1, "gapped sequence reached downstream");

        // Because consumed commits are cleared before the watermark advances,
        // a lower nonzero value in the next slot is an actual duplicate, not
        // normal ring reuse.
        @(negedge clk);
        reset = 1;
        @(posedge clk);
        clear_transport();
        @(negedge clk);
        reset = 0;
        begin_receiver(32'h44445555);
        memory[BASE_WORD + 1] =
            {MAGIC, 32'h44445555};
        request_session(32'h44445555);
        wait (session_started);
        publish_payload(
            32'h44445555, 1, 1, 1, 1, 1);
        publish_commit(1);
        wait_control(32'h44445555, 1);
        base2 = entry_base(2);
        @(negedge clk);
        memory[base2] = {32'd1, 32'd2};
        memory[base2 + 1] =
            {32'h44445555, 29'd0, 2'd1, 1'b1};
        memory[base2 + 2] = 64'd1;
        wait (protocol_error);
        if (ring_ack_valid)
            $fatal(1, "duplicate sequence reached downstream");

        // Commit zero is the only empty marker.  A torn/nonzero upper half
        // with zero low sequence is not empty and fails closed.
        @(negedge clk);
        reset = 1;
        @(posedge clk);
        clear_transport();
        @(negedge clk);
        reset = 0;
        memory[BASE_WORD + 1] =
            {MAGIC, 32'h55556666};
        request_session(32'h55556666);
        wait (session_started);
        base2 = entry_base(1);
        @(negedge clk);
        memory[base2 + 2] =
            {32'hdeadbeef, 32'd0};
        wait (protocol_error);
        if (ring_ack_valid)
            $fatal(1, "zero/torn sequence reached downstream");

        // Epoch zero is never a valid physical session identifier.
        @(negedge clk);
        reset = 1;
        @(posedge clk);
        clear_transport();
        @(negedge clk);
        reset = 0;
        request_session(32'd0);
        @(posedge clk);
        #1;
        if (!protocol_error || session_active)
            $fatal(1, "zero session epoch did not fail closed");

        $display(
            "PASS: reverse DDR consumed-credit transport, ordering, stalls, reset, and backoff");
        $finish;
    end
endmodule
