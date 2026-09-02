module tb_nds_h3d_event_ring;
    localparam logic [28:0] BASE = 29'h00360000;
    localparam integer ENTRY_COUNT = 4;
    localparam integer HEADER_WORDS64 = 16;
    localparam integer PRODUCER_WORD_OFFSET = 2;
    localparam integer CONSUMER_WORD_OFFSET = 3;
    localparam integer EVENT_COUNT = 12;
    localparam integer MEMORY_WORDS = 64;

    logic clk = 0;
    logic reset = 1;

    logic event_valid = 0;
    logic event_ready;
    logic [31:0] event_address = 0;
    logic [31:0] event_data = 0;
    logic [31:0] event_frame = 0;
    logic [7:0] event_type = 0;
    logic event_cpu = 0;
    logic [1:0] event_width = 0;
    logic [3:0] event_byte_enable = 0;
    logic [16:0] event_flags = 0;
    logic [63:0] event_timestamp = 0;
    logic [31:0] event_sequence = 0;

    logic active;
    logic ddram_active;
    logic full;
    logic event_done;
    logic [31:0] producer_sequence;
    logic [31:0] consumer_sequence;
    logic fault;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy = 0;
    logic ddram_accept_enable = 0;
    wire ddram_command_accepted =
        (ddram_read || ddram_write) &&
        !ddram_busy && ddram_accept_enable;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;

    logic [63:0] memory [0:MEMORY_WORDS-1];
    logic read_pending = 0;
    logic [63:0] pending_read_data = 0;
    integer read_delay = 0;
    logic random_stalls = 0;

    integer input_handshakes = 0;
    integer completed_events = 0;
    integer accepted_writes = 0;
    integer accepted_reads = 0;
    integer stalled_request_cycles = 0;
    integer busy_cycles = 0;
    integer expected_beat = 0;
    logic [63:0] expected_sequence = 0;
    logic [31:0] observed_producer_sequence = 0;
    logic producer_header_accepted_on_edge = 0;

    always #5 clk = ~clk;

    nds_h3d_event_ring #(
        .BASE_WORD(BASE),
        .ENTRY_COUNT(ENTRY_COUNT),
        .HEADER_WORDS64(HEADER_WORDS64),
        .CONSUMER_WORD_OFFSET(CONSUMER_WORD_OFFSET),
        .PRODUCER_WORD_OFFSET(PRODUCER_WORD_OFFSET)
    ) dut (
        .*
    );

    function automatic logic [31:0] address_for(
        input logic [63:0] seq
    );
        address_for = 32'h04000320 + seq[9:0] * 4;
    endfunction

    function automatic logic [31:0] data_for(
        input logic [63:0] seq
    );
        data_for = 32'ha5000000 ^ seq[31:0] * 32'h01020305;
    endfunction

    function automatic logic [31:0] frame_for(
        input logic [63:0] seq
    );
        frame_for = 32'h10000000 + seq[31:0] / 3;
    endfunction

    function automatic logic [7:0] type_for(
        input logic [63:0] seq
    );
        type_for = 8'(1 + ((seq - 1) % 5));
    endfunction

    function automatic logic cpu_for(
        input logic [63:0] seq
    );
        cpu_for = seq[0];
    endfunction

    function automatic logic [1:0] width_for(
        input logic [63:0] seq
    );
        width_for = seq[1:0];
    endfunction

    function automatic logic [3:0] byte_enable_for(
        input logic [63:0] seq
    );
        byte_enable_for = 4'b0001 << seq[1:0];
    endfunction

    function automatic logic [16:0] flags_for(
        input logic [63:0] seq
    );
        flags_for = 17'h10000 ^ seq[16:0];
    endfunction

    function automatic logic [63:0] timestamp_for(
        input logic [63:0] seq
    );
        timestamp_for =
            64'h2000000000000000 + seq * 64'h0000000100010001;
    endfunction

    function automatic logic [63:0] beat1_for(
        input logic [63:0] seq
    );
        beat1_for = {
            flags_for(seq),
            byte_enable_for(seq),
            width_for(seq),
            cpu_for(seq),
            type_for(seq),
            frame_for(seq)
        };
    endfunction

    task automatic drive_event(input logic [63:0] seq);
        integer target_handshakes;
        integer target_completions;
        begin
            expected_sequence = seq;
            expected_beat = 0;
            target_handshakes = input_handshakes + 1;
            target_completions = completed_events + 1;
            @(negedge clk);
            event_address = address_for(seq);
            event_data = data_for(seq);
            event_frame = frame_for(seq);
            event_type = type_for(seq);
            event_cpu = cpu_for(seq);
            event_width = width_for(seq);
            event_byte_enable = byte_enable_for(seq);
            event_flags = flags_for(seq);
            event_timestamp = timestamp_for(seq);
            event_sequence = seq[31:0];
            event_valid = 1;

            while (input_handshakes < target_handshakes) begin
                @(posedge clk);
                #1;
            end
            @(negedge clk);
            event_valid = 0;

            while (completed_events < target_completions) begin
                @(posedge clk);
                #1;
            end
            if (expected_beat != 5)
                $fatal(1,
                    "event %0d completed with only %0d accepted writes",
                    seq, expected_beat);
        end
    endtask

    task automatic publish_consumer(input logic [63:0] seq);
        begin
            @(negedge clk);
            memory[CONSUMER_WORD_OFFSET] = seq;
        end
    endtask

    always @(negedge clk) begin
        if (random_stalls) begin
            ddram_busy <= ($urandom_range(0, 3) == 0);
            ddram_accept_enable <= ($urandom_range(0, 2) != 0);
        end
    end

    always @(posedge clk) begin
        integer word_index;
        integer expected_slot;
        integer expected_word_index;
        logic [63:0] expected_word;

        ddram_read_data_ready <= 0;

        if (ddram_busy)
            busy_cycles <= busy_cycles + 1;
        if ((ddram_read || ddram_write) && !ddram_busy &&
            !ddram_command_accepted)
            stalled_request_cycles <= stalled_request_cycles + 1;

        if (ddram_busy && (ddram_read || ddram_write))
            $fatal(1, "DDR request asserted while busy is high");
        if (ddram_burst_count != 1 || ddram_byte_enable != 8'hff)
            $fatal(1, "H3D event ring used a burst or partial byte enable");
        if (ddram_command_accepted && !ddram_active)
            $fatal(1, "physical command accepted while DDR client inactive");

        if (event_valid && event_ready)
            input_handshakes <= input_handshakes + 1;
        if (event_done)
            completed_events <= completed_events + 1;

        producer_header_accepted_on_edge <=
            ddram_command_accepted && ddram_write &&
            expected_beat == 4;

        if (ddram_command_accepted && ddram_write) begin
            expected_slot = (expected_sequence - 1) &
                (ENTRY_COUNT - 1);
            if (expected_beat < 4) begin
                expected_word_index =
                    HEADER_WORDS64 + expected_slot * 4 + expected_beat;
            end else if (expected_beat == 4) begin
                expected_word_index = PRODUCER_WORD_OFFSET;
            end else begin
                $fatal(1, "event produced more than five DDR writes");
            end

            if (ddram_address !== BASE + expected_word_index)
                $fatal(1,
                    "event %0d beat %0d address mismatch got=%h expected=%h",
                    expected_sequence, expected_beat, ddram_address,
                    BASE + expected_word_index);

            case (expected_beat)
                0: expected_word = {
                    data_for(expected_sequence),
                    address_for(expected_sequence)
                };
                1: expected_word = beat1_for(expected_sequence);
                2: expected_word = timestamp_for(expected_sequence);
                3: expected_word = expected_sequence;
                4: expected_word = expected_sequence;
                default: expected_word = 64'hx;
            endcase
            if (ddram_write_data !== expected_word)
                $fatal(1,
                    "event %0d beat %0d data mismatch got=%h expected=%h",
                    expected_sequence, expected_beat, ddram_write_data,
                    expected_word);

            word_index = ddram_address - BASE;
            if (word_index < 0 || word_index >= MEMORY_WORDS)
                $fatal(1, "event write outside modeled DDR memory");
            memory[word_index] <= ddram_write_data;
            accepted_writes <= accepted_writes + 1;
            expected_beat = expected_beat + 1;
        end

        if (ddram_command_accepted && ddram_read) begin
            if (ddram_address != BASE + CONSUMER_WORD_OFFSET)
                $fatal(1, "consumer progress read used wrong address");
            if (read_pending)
                $fatal(1, "overlapping consumer progress reads");
            pending_read_data <= memory[CONSUMER_WORD_OFFSET];
            read_delay <= $urandom_range(1, 5);
            read_pending <= 1;
            accepted_reads <= accepted_reads + 1;
        end

        if (read_pending) begin
            if (read_delay == 0) begin
                ddram_read_data <= pending_read_data;
                ddram_read_data_ready <= 1;
                read_pending <= 0;
            end else begin
                read_delay <= read_delay - 1;
            end
        end
    end

    // Producer progress and done may change only after physical acceptance of
    // the producer header write, which itself follows the slot commit.
    always @(negedge clk) begin
        if (reset) begin
            observed_producer_sequence = producer_sequence;
        end else begin
            if (producer_sequence != observed_producer_sequence) begin
                if (!producer_header_accepted_on_edge || !event_done)
                    $fatal(1,
                        "producer sequence retired before header acceptance");
            end else if (event_done) begin
                $fatal(1,
                    "event_done asserted without producer header retirement");
            end
            observed_producer_sequence = producer_sequence;
        end
    end

    initial begin : timeout_guard
        repeat (16000) @(posedge clk);
        $fatal(1,
            "H3D event ring timeout producer=%0d consumer=%0d state=%0d handshakes=%0d completed=%0d",
            producer_sequence, consumer_sequence, dut.state,
            input_handshakes, completed_events);
    end

    initial begin
        integer index;
        integer reads_before_full;
        integer writes_before_full;
        integer handshakes_before_full;
        integer writes_before_fault;
        integer seq;
        integer slot;

        for (index = 0; index < MEMORY_WORDS; index = index + 1)
            memory[index] = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // A visible but physically unaccepted payload request cannot advance
        // the event, slot commit, producer header, or completion pulse.
        ddram_busy = 0;
        ddram_accept_enable = 0;
        fork
            drive_event(64'd1);
            begin
                wait (ddram_write);
                repeat (5) begin
                    @(posedge clk);
                    #1;
                    if (producer_sequence != 0 || event_done ||
                        expected_beat != 0)
                        $fatal(1,
                            "unaccepted DDR request retired event data");
                end
                @(negedge clk);
                ddram_accept_enable = 1;
            end
        join

        random_stalls = 1;
        drive_event(64'd2);
        drive_event(64'd3);
        drive_event(64'd4);
        #1;
        if (!full || producer_sequence != 4 ||
            consumer_sequence != 0)
            $fatal(1, "four events did not fill the depth-four ring");
        if (memory[PRODUCER_WORD_OFFSET] != 4)
            $fatal(1, "producer header does not contain sequence four");

        // A held fifth event causes only consumer polling.  It cannot
        // overwrite slot zero until HPS releases capacity.
        reads_before_full = accepted_reads;
        writes_before_full = accepted_writes;
        handshakes_before_full = input_handshakes;
        fork
            drive_event(64'd5);
            begin
                repeat (60) begin
                    @(posedge clk);
                    #1;
                    if (input_handshakes != handshakes_before_full ||
                        accepted_writes != writes_before_full ||
                        producer_sequence != 4)
                        $fatal(1,
                            "full H3D ring accepted or overwrote an event");
                end
                if (accepted_reads <= reads_before_full)
                    $fatal(1,
                        "full H3D ring did not poll consumer progress");
                publish_consumer(64'd2);
            end
        join
        if (producer_sequence != 5 || consumer_sequence != 2)
            $fatal(1, "consumer progress did not release event five");

        drive_event(64'd6);

        // Cross repeated physical slot wrap.  HPS remains two events behind.
        for (seq = 7; seq <= EVENT_COUNT;
             seq = seq + 1) begin
            fork
                drive_event(seq);
                begin
                    repeat (8) @(posedge clk);
                    publish_consumer(seq - 2);
                end
            join
        end

        if (producer_sequence != EVENT_COUNT ||
            completed_events != EVENT_COUNT ||
            input_handshakes != EVENT_COUNT ||
            accepted_writes != EVENT_COUNT * 5)
            $fatal(1,
                "event accounting mismatch producer=%0d completed=%0d handshakes=%0d writes=%0d",
                producer_sequence, completed_events, input_handshakes,
                accepted_writes);
        if (fault)
            $fatal(1, "valid contiguous traffic raised a fault");
        if (stalled_request_cycles < 20 || busy_cycles < 20)
            $fatal(1,
                "random DDR model did not exercise enough stalls (%0d/%0d)",
                stalled_request_cycles, busy_cycles);
        if (memory[PRODUCER_WORD_OFFSET] != EVENT_COUNT)
            $fatal(1, "final producer header is stale");

        // Each slot must contain its most recent complete event.  The commit
        // sequence must agree with the producer header upper bound.
        for (seq = EVENT_COUNT - ENTRY_COUNT + 1;
             seq <= EVENT_COUNT; seq = seq + 1) begin
            slot = (seq - 1) & (ENTRY_COUNT - 1);
            index = HEADER_WORDS64 + slot * 4;
            if (memory[index] !==
                    {data_for(seq), address_for(seq)} ||
                memory[index + 1] !== beat1_for(seq) ||
                memory[index + 2] !== timestamp_for(seq) ||
                memory[index + 3] !== seq)
                $fatal(1,
                    "wrapped slot %0d does not contain event %0d",
                    slot, seq);
        end

        // A non-contiguous first sequence fails closed before any write.  The
        // sticky fault also blocks a later corrected event until reset.
        writes_before_fault = accepted_writes;
        random_stalls = 0;
        @(negedge clk);
        reset = 1;
        event_valid = 0;
        ddram_busy = 0;
        ddram_accept_enable = 1;
        read_pending = 0;
        memory[CONSUMER_WORD_OFFSET] = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        event_sequence = 2;
        event_valid = 1;
        repeat (3) @(posedge clk);
        #1;
        if (!fault || event_ready || producer_sequence != 0 ||
            accepted_writes != writes_before_fault)
            $fatal(1,
                "non-contiguous sequence did not fail closed");
        @(negedge clk);
        event_sequence = 1;
        repeat (3) @(posedge clk);
        #1;
        if (event_ready || accepted_writes != writes_before_fault)
            $fatal(1, "sticky sequence fault accepted a corrected event");
        @(negedge clk);
        event_valid = 0;

        // A consumer value beyond the committed producer sequence cannot
        // release capacity.  It sets the same sticky fail-closed fault.
        @(negedge clk);
        reset = 1;
        expected_beat = 0;
        memory[CONSUMER_WORD_OFFSET] = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        drive_event(64'd1);
        drive_event(64'd2);
        drive_event(64'd3);
        drive_event(64'd4);
        writes_before_fault = accepted_writes;
        @(negedge clk);
        expected_sequence = 5;
        expected_beat = 0;
        event_address = address_for(5);
        event_data = data_for(5);
        event_frame = frame_for(5);
        event_type = type_for(5);
        event_cpu = cpu_for(5);
        event_width = width_for(5);
        event_byte_enable = byte_enable_for(5);
        event_flags = flags_for(5);
        event_timestamp = timestamp_for(5);
        event_sequence = 5;
        event_valid = 1;
        memory[CONSUMER_WORD_OFFSET] = 5;
        wait (fault);
        repeat (3) @(posedge clk);
        #1;
        if (producer_sequence != 4 || consumer_sequence != 0 ||
            event_ready || accepted_writes != writes_before_fault)
            $fatal(1,
                "future consumer sequence released or overwrote a slot");
        @(negedge clk);
        event_valid = 0;

        // ARMv7-safe fences use only the low 32 bits. A nonzero reserved high
        // word is malformed and must not release a full slot.
        @(negedge clk);
        reset = 1;
        expected_beat = 0;
        memory[CONSUMER_WORD_OFFSET] = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        drive_event(64'd1);
        drive_event(64'd2);
        drive_event(64'd3);
        drive_event(64'd4);
        writes_before_fault = accepted_writes;
        @(negedge clk);
        expected_sequence = 5;
        expected_beat = 0;
        event_address = address_for(5);
        event_data = data_for(5);
        event_frame = frame_for(5);
        event_type = type_for(5);
        event_cpu = cpu_for(5);
        event_width = width_for(5);
        event_byte_enable = byte_enable_for(5);
        event_flags = flags_for(5);
        event_timestamp = timestamp_for(5);
        event_sequence = 5;
        event_valid = 1;
        memory[CONSUMER_WORD_OFFSET] = 64'h0000000100000001;
        wait (fault);
        repeat (3) @(posedge clk);
        #1;
        if (producer_sequence != 4 || consumer_sequence != 0 ||
            event_ready || accepted_writes != writes_before_fault)
            $fatal(1,
                "nonzero consumer reserved word released a slot");
        @(negedge clk);
        event_valid = 0;

        $display(
            "PASS: H3D1 event ring preserves 3 payload beats, slot commit, and producer header publication under stalls, full backpressure, wrap, and faults");
        $display(
            "INFO: valid_events=%0d valid_writes=%0d consumer_reads=%0d request_stalls=%0d busy_cycles=%0d",
            EVENT_COUNT, EVENT_COUNT * 5, accepted_reads,
            stalled_request_cycles, busy_cycles);
        $finish;
    end
endmodule
