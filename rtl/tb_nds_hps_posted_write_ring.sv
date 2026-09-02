module tb_nds_hps_posted_write_ring;
    localparam logic [28:0] BASE = 29'h00310000;
    localparam integer ENTRY_COUNT = 4;
    localparam integer HEADER_WORDS64 = 8;

    logic clk = 0;
    logic reset = 1;
    logic request = 0;
    logic cpu_is_arm9 = 1;
    logic [31:0] elapsed_cycles = 0;
    logic [31:0] address = 0;
    logic [1:0] access = 2'b01;
    logic [31:0] write_data = 0;
    logic [31:0] session_epoch = 32'h11223344;
    logic [31:0] session_capabilities = 32'h0000000d;
    logic consumer_ack = 0;
    logic [31:0] consumer_ack_epoch = 32'h11223344;
    logic [31:0] consumer_ack_sequence = 0;
    logic accepted;
    logic active;
    logic ddram_active;
    logic done;
    logic [31:0] producer_sequence;
    logic sequence_exhausted;
    logic consumer_protocol_error;
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

    logic [63:0] memory [0:31];
    integer write_accepts = 0;
    integer read_accepts = 0;
    integer busy_cycles = 0;
    integer read_delay = 0;

    always #5 clk = ~clk;
    assign ddram_command_accepted = ddram_write && !ddram_busy;

    nds_hps_posted_write_ring #(
        .BASE_WORD(BASE),
        .ENTRY_COUNT(ENTRY_COUNT),
        .HEADER_WORDS64(HEADER_WORDS64),
        .REQUIRE_EPOCH_SESSION(1)
    ) dut (
        .*
    );

    always_ff @(posedge clk) begin
        ddram_read_data_ready <= 0;
        if (busy_cycles > 0) begin
            ddram_busy <= 1;
            busy_cycles <= busy_cycles - 1;
        end else begin
            ddram_busy <= 0;
        end

        if (ddram_write) begin
            if (ddram_busy)
                $fatal(1, "write asserted while DDR busy");
            if (ddram_burst_count != 1 || ddram_byte_enable != 8'hff)
                $fatal(1, "bad posted-write transfer shape");
            if (ddram_address < BASE ||
                ddram_address >= BASE + HEADER_WORDS64 +
                    ENTRY_COUNT * 3)
                $fatal(1, "posted write outside ring");
            memory[ddram_address - BASE] <= ddram_write_data;
            write_accepts <= write_accepts + 1;
            // Exercise waitrequest retention between every accepted word.
            busy_cycles <= 1;
        end

        if (ddram_read) begin
            if (ddram_busy)
                $fatal(1, "read asserted while DDR busy");
            if (ddram_address != BASE + 1)
                $fatal(1, "consumer read used wrong header word");
            read_accepts <= read_accepts + 1;
            read_delay <= 2;
        end else if (read_delay > 0) begin
            read_delay <= read_delay - 1;
            if (read_delay == 1) begin
                ddram_read_data <= memory[1];
                ddram_read_data_ready <= 1;
            end
        end
    end

    task automatic issue_write(
        input logic selected_cpu,
        input logic [31:0] cycles,
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] bus_data
    );
        integer accepted_pulses;
        integer done_pulses;
        begin
            accepted_pulses = 0;
            done_pulses = 0;
            @(negedge clk);
            cpu_is_arm9 = selected_cpu;
            elapsed_cycles = cycles;
            address = bus_address;
            access = bus_access;
            write_data = bus_data;
            request = 1;
            while (done_pulses == 0) begin
                @(posedge clk);
                #1;
                if (accepted)
                    accepted_pulses = accepted_pulses + 1;
                if (done)
                    done_pulses = done_pulses + 1;
            end
            repeat (2) begin
                @(posedge clk);
                #1;
                if (accepted)
                    accepted_pulses = accepted_pulses + 1;
                if (done)
                    done_pulses = done_pulses + 1;
            end
            if (accepted_pulses != 1 || done_pulses != 1)
                $fatal(1, "held request generated duplicate pulses");
            @(negedge clk);
            request = 0;
            wait (!active);
        end
    endtask

    task automatic verify_entry(
        input integer slot,
        input logic [31:0] expected_sequence,
        input logic expected_cpu,
        input logic [31:0] expected_cycles,
        input logic [31:0] expected_address,
        input logic [1:0] expected_access,
        input logic [31:0] expected_data
    );
        integer word_index;
        logic [3:0] expected_control;
        begin
            word_index = HEADER_WORDS64 + slot * 3;
            expected_control = {expected_cpu, expected_access, 1'b0};
            if (memory[word_index] !== {expected_data, expected_address})
                $fatal(1, "entry %0d address/data mismatch: %h",
                       slot, memory[word_index]);
            if (memory[word_index + 1] !==
                {28'h0, expected_control, expected_cycles})
                $fatal(1, "entry %0d cycles/control mismatch: %h",
                       slot, memory[word_index + 1]);
            if (memory[word_index + 2] !==
                {session_epoch, expected_sequence})
                $fatal(1, "entry %0d commit mismatch: %h",
                       slot, memory[word_index + 2]);
        end
    endtask

    initial begin
        integer index;
        integer writes_before_full;
        integer reads_before_ack;
        integer accepted_while_blocked;
        integer done_while_blocked;
        logic [63:0] blocked_word0;
        logic [63:0] blocked_word1;
        logic [63:0] blocked_word2;
        for (index = 0; index < 32; index = index + 1)
            memory[index] = 0;
        memory[1] = 0;

        repeat (3) @(posedge clk);
        reset = 0;

        issue_write(1, 32'h00000101, 32'h0600c000, 2'b01,
                    32'h00001111);
        issue_write(0, 32'h00000202, 32'h0600c002, 2'b00,
                    32'h00000022);
        issue_write(1, 32'h00000303, 32'h0600c004, 2'b10,
                    32'h33334444);
        if (producer_sequence != 3 || write_accepts != 9)
            $fatal(1, "first three entries were not committed once");
        verify_entry(0, 1, 1, 32'h00000101, 32'h0600c000, 2'b01,
                     32'h00001111);
        verify_entry(1, 2, 0, 32'h00000202, 32'h0600c002, 2'b00,
                     32'h00000022);
        verify_entry(2, 3, 1, 32'h00000303, 32'h0600c004, 2'b10,
                     32'h33334444);

        // Force the ring to issue its physical fallback read, then return a
        // stale header on the exact edge a newer validated LW ACK arrives.
        // The ACK must win and the fourth entry must not deadlock or reuse an
        // unconsumed slot.
        reads_before_ack = read_accepts;
        @(negedge clk);
        cpu_is_arm9 = 1;
        elapsed_cycles = 32'h00000404;
        address = 32'h0600c006;
        access = 2'b01;
        write_data = 32'h00005555;
        request = 1;
        wait (dut.state == 4'd3); // READ_CONSUMER_WAIT
        @(negedge clk);
        consumer_ack_sequence = 32'd2;
        consumer_ack = 1;
        ddram_read_data = 64'h0; // stale physical header
        ddram_read_data_ready = 1;
        @(posedge clk); #1;
        if (dut.consumer_sequence != 2 || consumer_protocol_error)
            $fatal(1, "validated ACK lost to simultaneous stale header");
        @(negedge clk);
        consumer_ack = 0;
        ddram_read_data_ready = 0;
        wait (done);
        @(negedge clk);
        request = 0;
        wait (!active);
        issue_write(0, 32'h00000505, 32'h0600c008, 2'b01,
                    32'h00006666);
        if (producer_sequence != 5 || read_accepts != reads_before_ack + 1)
            $fatal(1, "ACK/header collision did not preserve ring progress");
        verify_entry(3, 4, 1, 32'h00000404, 32'h0600c006, 2'b01,
                     32'h00005555);
        verify_entry(0, 5, 0, 32'h00000505, 32'h0600c008, 2'b01,
                     32'h00006666);

        // Capacity is ENTRY_COUNT-1. A sixth request must not overwrite slot
        // one until the physical fallback observes further HPS progress.
        writes_before_full = write_accepts;
        @(negedge clk);
        cpu_is_arm9 = 1;
        elapsed_cycles = 32'h00000606;
        address = 32'h0600c00a;
        access = 2'b01;
        write_data = 32'h00007777;
        request = 1;
        repeat (12) @(posedge clk);
        if (done || accepted || write_accepts != writes_before_full ||
            read_accepts == 0)
            $fatal(1, "full ring failed to apply backpressure");

        // HPS has now consumed through sequence five. The delayed header
        // refresh must admit exactly one new entry in wrapped slot one.
        memory[1][31:0] = 32'd5;
        wait (done);
        #1;
        if (producer_sequence != 6 || write_accepts != writes_before_full + 3)
            $fatal(1, "consumer refresh did not release one entry");
        verify_entry(1, 6, 1, 32'h00000606, 32'h0600c00a, 2'b01,
                     32'h00007777);
        @(negedge clk);
        request = 0;
        wait (!active);

        // The current ABI reserves sequence zero as "not committed." Seed the
        // deterministic near-wrap state: 0xffffffff is the last publishable
        // entry and the following request must stop before any side effect.
        @(negedge clk);
        dut.producer_sequence = 32'hfffffffe;
        dut.consumer_sequence = 32'hfffffffe;
        issue_write(1, 32'hffff0101, 32'h04000400, 2'b10,
                    32'h89abcdef);
        if (producer_sequence != 32'hffffffff ||
            !sequence_exhausted)
            $fatal(1, "last nonzero sequence did not commit/exhaust");
        verify_entry(2, 32'hffffffff, 1, 32'hffff0101,
                     32'h04000400, 2'b10, 32'h89abcdef);

        writes_before_full = write_accepts;
        blocked_word0 = memory[HEADER_WORDS64 + 3 * 3];
        blocked_word1 = memory[HEADER_WORDS64 + 3 * 3 + 1];
        blocked_word2 = memory[HEADER_WORDS64 + 3 * 3 + 2];
        accepted_while_blocked = 0;
        done_while_blocked = 0;
        @(negedge clk);
        elapsed_cycles = 32'h0000beef;
        address = 32'h04000404;
        access = 2'b10;
        write_data = 32'h01234567;
        request = 1;
        repeat (16) begin
            @(posedge clk);
            #1;
            if (accepted)
                accepted_while_blocked = accepted_while_blocked + 1;
            if (done)
                done_while_blocked = done_while_blocked + 1;
            if (ddram_read || ddram_write || active)
                $fatal(1, "exhausted ring issued DDR or became active");
        end
        if (accepted_while_blocked != 0 || done_while_blocked != 0 ||
            write_accepts != writes_before_full ||
            producer_sequence != 32'hffffffff ||
            memory[HEADER_WORDS64 + 3 * 3] !== blocked_word0 ||
            memory[HEADER_WORDS64 + 3 * 3 + 1] !== blocked_word1 ||
            memory[HEADER_WORDS64 + 3 * 3 + 2] !== blocked_word2)
            $fatal(1,
                "sequence wrap was not side-effect-free accepted=%0d done=%0d writes=%0d/%0d",
                accepted_while_blocked, done_while_blocked,
                write_accepts, writes_before_full);
        @(negedge clk);
        request = 0;
        repeat (2) @(posedge clk);
        if (!sequence_exhausted)
            $fatal(1, "sequence exhaustion diagnostic was not sticky");

        // Start a clean session and inject credit from a stale epoch. Sequence
        // alone is no longer sufficient under NDS2: it must be ignored,
        // reported, and fail closed before later work can touch DDR.
        @(negedge clk); reset = 1;
        repeat (2) @(posedge clk);
        @(negedge clk); reset = 0;
        dut.producer_sequence = 32'd6;
        dut.consumer_sequence = 32'd5;
        @(negedge clk);
        consumer_ack_epoch = 32'h55667788;
        consumer_ack_sequence = 32'd6;
        consumer_ack = 1;
        @(negedge clk);
        consumer_ack = 0;
        if (!consumer_protocol_error || dut.consumer_sequence != 5)
            $fatal(1, "stale-epoch ACK advanced credit or was not reported");
        writes_before_full = write_accepts;
        request = 1;
        repeat (8) begin
            @(posedge clk); #1;
            if (active || accepted || done || ddram_read || ddram_write)
                $fatal(1, "consumer-credit fault did not stop admission");
        end
        request = 0;
        if (write_accepts != writes_before_full)
            $fatal(1, "consumer-credit fault changed DDR");

        // A separate clean epoch retains the legacy future-sequence guard.
        @(negedge clk); reset = 1;
        repeat (2) @(posedge clk);
        @(negedge clk); reset = 0;
        consumer_ack_epoch = session_epoch;
        dut.producer_sequence = 32'd6;
        dut.consumer_sequence = 32'd5;
        @(negedge clk);
        consumer_ack_sequence = 32'd7;
        consumer_ack = 1;
        @(negedge clk);
        consumer_ack = 0;
        if (!consumer_protocol_error || dut.consumer_sequence != 5)
            $fatal(1, "future consumer ACK advanced credit or was not reported");

        $display("PASS: epoch-tagged posted ring commits atomically, rejects stale/future credit, retains full-ring fallback, and fails closed before sequence zero");
        $finish;
    end
endmodule
