module tb_nds_hps_consumed_credit_ddr_ring_arbiter;
    localparam logic [28:0] BASE_WORD = 29'd16;
    localparam integer ENTRY_COUNT = 2;
    localparam integer HEADER_WORDS64 = 4;
    localparam logic [31:0] EPOCH = 32'h76543210;
    localparam logic [31:0] MAGIC = 32'h4341434b;

    logic clk = 0;
    logic reset = 1;
    logic session_begin_valid = 0;
    logic session_begin_ready;
    logic session_started;
    logic session_active;
    logic [31:0] active_epoch;
    logic [31:0] consumer_sequence;
    logic ack_valid;
    logic ack_ready = 1;
    logic [31:0] ack_epoch;
    logic [31:0] ack_sequence;
    logic ack_cpu_arm9;
    logic [31:0] ack_cycles;
    logic [1:0] ack_kind;
    logic [31:0] ack_source_id;
    logic consumer_active;
    logic consumer_ddram_active;
    logic sequence_exhausted;
    logic protocol_error;
    logic consumer_rd;
    logic consumer_we;
    logic [7:0] consumer_burst;
    logic [28:0] consumer_addr;
    logic [63:0] consumer_din;
    logic [7:0] consumer_be;
    logic consumer_busy;
    logic [63:0] consumer_dout;
    logic consumer_dout_ready;
    logic consumer_command_accepted;

    logic a_rd = 0;
    logic a_we = 0;
    logic [28:0] a_addr = 0;
    logic a_busy;
    logic [63:0] a_dout;
    logic a_dout_ready;
    logic a_command_accepted;
    logic [17:0] debug_state;
    logic physical_rd;
    logic physical_we;
    logic [7:0] physical_burst;
    logic [28:0] physical_addr;
    logic [63:0] physical_din;
    logic [7:0] physical_be;
    logic physical_busy = 1;
    logic [63:0] physical_dout = 0;
    logic physical_dout_ready = 0;
    logic [63:0] memory [0:63];
    logic response_pending = 0;
    logic [28:0] response_address = 0;
    integer held_physical_cycles = 0;
    integer consumer_accepts = 0;
    integer same_edge_responses = 0;

    always #5 clk = ~clk;

    nds_hps_consumed_credit_ddr_ring #(
        .ENABLED(1'b1),
        .BASE_WORD(BASE_WORD),
        .ENTRY_COUNT(ENTRY_COUNT),
        .HEADER_WORDS64(HEADER_WORDS64),
        .POLL_BACKOFF_CYCLES(2)
    ) consumer (
        .clk,
        .reset,
        .session_begin_valid,
        .session_begin_ready,
        .session_begin_epoch(EPOCH),
        .session_epoch_fresh(1'b1),
        .transport_quiescent(1'b1),
        .session_started,
        .session_active,
        .active_epoch,
        .consumer_sequence,
        .ack_valid,
        .ack_ready,
        .ack_epoch,
        .ack_sequence,
        .ack_cpu_arm9,
        .ack_cycles,
        .ack_kind,
        .ack_source_id,
        .active(consumer_active),
        .ddram_active(consumer_ddram_active),
        .sequence_exhausted,
        .protocol_error,
        .ddram_read(consumer_rd),
        .ddram_write(consumer_we),
        .ddram_burst_count(consumer_burst),
        .ddram_address(consumer_addr),
        .ddram_write_data(consumer_din),
        .ddram_byte_enable(consumer_be),
        .ddram_busy(consumer_busy),
        .ddram_command_accepted(consumer_command_accepted),
        .ddram_read_data(consumer_dout),
        .ddram_read_data_ready(consumer_dout_ready)
    );

    nds_ddram_arbiter arbiter (
        .clk,
        .reset,
        .a_rd,
        .a_we,
        .a_burstcnt(8'd1),
        .a_addr,
        .a_din(64'd0),
        .a_be(8'hff),
        .a_busy,
        .a_dout,
        .a_dout_ready,
        .a_command_accepted,
        .b_rd(consumer_rd),
        .b_we(consumer_we),
        .b_burstcnt(consumer_burst),
        .b_addr(consumer_addr),
        .b_din(consumer_din),
        .b_be(consumer_be),
        .b_busy(consumer_busy),
        .b_dout(consumer_dout),
        .b_dout_ready(consumer_dout_ready),
        .b_command_accepted(consumer_command_accepted),
        .debug_state,
        .ddram_rd(physical_rd),
        .ddram_we(physical_we),
        .ddram_burstcnt(physical_burst),
        .ddram_addr(physical_addr),
        .ddram_din(physical_din),
        .ddram_be(physical_be),
        .ddram_busy(physical_busy),
        .ddram_dout(physical_dout),
        .ddram_dout_ready(physical_dout_ready)
    );

    always @(posedge clk) begin
        integer byte_index;
        physical_dout_ready <= 1'b0;
        if (reset) begin
            response_pending <= 1'b0;
        end else begin
            if (physical_rd && physical_busy)
                held_physical_cycles <= held_physical_cycles + 1;
            if (consumer_command_accepted)
                consumer_accepts <= consumer_accepts + 1;
            if (consumer_command_accepted &&
                consumer_dout_ready)
                same_edge_responses <=
                    same_edge_responses + 1;

            if (response_pending) begin
                physical_dout <= memory[response_address];
                physical_dout_ready <= 1'b1;
                response_pending <= 1'b0;
            end
            if (physical_rd && !physical_busy &&
                !physical_dout_ready) begin
                if (response_pending)
                    $fatal(1, "real arbiter accepted overlapping read");
                response_address <= physical_addr;
                response_pending <= 1'b1;
            end
            if (physical_we && !physical_busy) begin
                for (byte_index = 0; byte_index < 8;
                     byte_index = byte_index + 1) begin
                    if (physical_be[byte_index])
                        memory[physical_addr][byte_index * 8 +: 8] <=
                            physical_din[byte_index * 8 +: 8];
                end
            end
        end
    end

    initial begin
        integer index;
        integer base;
        for (index = 0; index < 64; index = index + 1)
            memory[index] = 64'd0;
        memory[BASE_WORD + 1] = {MAGIC, EPOCH};

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        session_begin_valid = 1;
        do @(posedge clk); while (!session_begin_ready);
        @(negedge clk);
        session_begin_valid = 0;

        // The real arbiter queues the request but its physical port remains
        // waitrequested.  The consumer must wait for b_command_accepted, not
        // client busy or the initial queue-admission edge.
        wait (physical_rd);
        repeat (6) begin
            @(negedge clk);
            if (!physical_rd || physical_we ||
                physical_addr != BASE_WORD + 1 ||
                consumer_command_accepted ||
                !consumer_rd)
                $fatal(1,
                    "consumer/real arbiter did not retain denied descriptor read");
        end
        // Return the descriptor on the same edge that accepts the held
        // physical read, matching the arbiter's acceptance-edge route.
        physical_dout = memory[BASE_WORD + 1];
        physical_dout_ready = 1;
        physical_busy = 0;
        wait (consumer_command_accepted);
        @(posedge clk);
        @(negedge clk);
        physical_dout_ready = 0;
        physical_busy = 0;
        wait (session_started);
        wait (memory[BASE_WORD] === {EPOCH, 32'd0});

        // Add a competing A request as the first ACK is committed.  Fair
        // arbitration may choose either first; both must complete and the
        // credit must remain ordered.
        base = BASE_WORD + HEADER_WORDS64;
        @(negedge clk);
        memory[base] = {32'd19, 32'd1};
        memory[base + 1] =
            {EPOCH, 29'd0, 2'd0, 1'b1};
        memory[base + 2][31:0] = 1;
        a_addr = 29'd3;
        a_rd = 1;
        wait (a_command_accepted);
        @(negedge clk);
        a_rd = 0;
        wait (ack_valid);
        #1;
        if (ack_epoch != EPOCH || ack_sequence != 1 ||
            !ack_cpu_arm9 || ack_cycles != 19 ||
            ack_kind != 0 || ack_source_id != 1)
            $fatal(1, "real-arbiter ACK decode mismatch");
        wait (memory[BASE_WORD] === {EPOCH, 32'd1});

        if (protocol_error || sequence_exhausted ||
            held_physical_cycles < 5 || consumer_accepts < 10 ||
            same_edge_responses != 1 ||
            memory[base + 2] != 0)
            $fatal(1,
                "real-arbiter transport mismatch held=%0d accepts=%0d debug=%h",
                held_physical_cycles, consumer_accepts, debug_state);
        $display(
            "PASS: consumed-credit reverse ring interoperates with real queued DDR arbiter");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "real-arbiter consumed-credit test timeout");
    end
endmodule
