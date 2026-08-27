module tb_nds_hps_consumed_credit_ddr_ring_wrap;
    localparam logic [28:0] BASE_WORD = 29'd16;
    localparam integer ENTRY_COUNT = 2;
    localparam integer HEADER_WORDS64 = 4;
    localparam logic [31:0] EPOCH = 32'habcd9876;
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
    logic ack_ready = 0;
    logic [31:0] ack_epoch;
    logic [31:0] ack_sequence;
    logic ack_cpu_arm9;
    logic [31:0] ack_cycles;
    logic [1:0] ack_kind;
    logic [31:0] ack_source_id;
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
    logic ddram_command_accepted;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;
    logic grant = 1;
    logic [63:0] memory [0:63];
    logic read_pending = 0;
    logic [28:0] pending_address = 0;

    always #5 clk = ~clk;
    assign ddram_command_accepted =
        grant && (ddram_read || ddram_write);

    nds_hps_consumed_credit_ddr_ring #(
        .ENABLED(1'b1),
        .BASE_WORD(BASE_WORD),
        .ENTRY_COUNT(ENTRY_COUNT),
        .HEADER_WORDS64(HEADER_WORDS64),
        .POLL_BACKOFF_CYCLES(1),
        .INITIAL_CONSUMER_SEQUENCE(32'hfffffffe)
    ) dut (
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
        .ddram_busy(1'b0),
        .ddram_command_accepted,
        .ddram_read_data,
        .ddram_read_data_ready
    );

    always @(posedge clk) begin
        integer byte_index;
        ddram_read_data_ready <= 1'b0;
        if (reset) begin
            read_pending <= 1'b0;
        end else begin
            if (read_pending) begin
                ddram_read_data <= memory[pending_address];
                ddram_read_data_ready <= 1'b1;
                read_pending <= 1'b0;
            end
            if (ddram_command_accepted && ddram_read) begin
                if (read_pending)
                    $fatal(1, "wrap TB overlapping read");
                pending_address <= ddram_address;
                read_pending <= 1'b1;
            end
            if (ddram_command_accepted && ddram_write) begin
                for (byte_index = 0; byte_index < 8;
                     byte_index = byte_index + 1) begin
                    if (ddram_byte_enable[byte_index])
                        memory[ddram_address][byte_index * 8 +: 8] <=
                            ddram_write_data[byte_index * 8 +: 8];
                end
            end
        end
    end

    initial begin
        integer index;
        integer terminal_base;
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
        wait (session_started);
        if (memory[BASE_WORD] !== {EPOCH, 32'hfffffffe})
            wait (memory[BASE_WORD] ===
                  {EPOCH, 32'hfffffffe});

        terminal_base = BASE_WORD + HEADER_WORDS64 +
            (((32'hffffffff - 1) & (ENTRY_COUNT - 1)) * 3);
        @(negedge clk);
        memory[terminal_base] = {32'd8, 32'd77};
        memory[terminal_base + 1] =
            {EPOCH, 29'd0, 2'd2, 1'b0};
        // Low 32-bit terminal commit; upper half remains zero.
        memory[terminal_base + 2][31:0] = 32'hffffffff;

        wait (ack_valid);
        #1;
        if (ack_epoch != EPOCH ||
            ack_sequence != 32'hffffffff ||
            ack_cpu_arm9 || ack_cycles != 8 ||
            ack_kind != 2 || ack_source_id != 77)
            $fatal(1, "terminal ACK decode mismatch");

        @(negedge clk);
        ack_ready = 1;
        wait (sequence_exhausted);
        if (protocol_error || session_active ||
            consumer_sequence != 32'hffffffff ||
            memory[BASE_WORD] !== {EPOCH, 32'hffffffff} ||
            memory[terminal_base + 2] != 0)
            $fatal(1, "terminal ACK did not retire without wrap");
        repeat (8) begin
            @(posedge clk);
            #1;
            if (ddram_read || ddram_write ||
                session_begin_ready)
                $fatal(1, "terminal sequence wrapped/restarted");
        end

        $display(
            "PASS: reverse DDR consumed-credit terminal sequence fails closed before wrap");
        $finish;
    end
endmodule
