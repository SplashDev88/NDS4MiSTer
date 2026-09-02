module tb_nds_hps_consumed_credit_ack;
    logic clk = 0;
    logic reset = 1;
    logic epoch_begin_valid = 0;
    logic epoch_begin_ready;
    logic [31:0] epoch_begin = 0;
    logic transport_quiescent = 0;
    logic ack_valid = 0;
    logic ack_ready;
    logic [31:0] ack_epoch = 0;
    logic [31:0] ack_sequence = 0;
    logic ack_cpu_arm9 = 0;
    logic [31:0] ack_cycles = 0;
    logic [1:0] ack_kind = 0;
    logic [31:0] ack_source_id = 0;
    logic credit_valid;
    logic credit_ready = 1;
    logic credit_arm9;
    logic [31:0] credit_cycles;
    logic [1:0] credit_kind;
    logic [31:0] credit_source_id;
    logic tracker_epoch_reset;
    logic epoch_active;
    logic [31:0] active_epoch;
    logic sequence_exhausted;
    logic protocol_error;

    logic [63:0] arm9_timestamp;
    logic [63:0] arm7_timestamp;
    logic [63:0] shared_timestamp;
    logic shared_timestamp_changed;
    logic tracker_overflow;
    logic previous_credit_valid = 0;
    logic previous_credit_ready = 0;
    logic previous_credit_arm9 = 0;
    logic [31:0] previous_credit_cycles = 0;
    logic [1:0] previous_credit_kind = 0;
    logic [31:0] previous_credit_source_id = 0;
    integer delivered = 0;

    always #5 clk = ~clk;

    nds_hps_consumed_credit_ack dut (.*);

    nds_shared_time_credit_tracker tracker (
        .clk,
        .reset(reset || tracker_epoch_reset),
        .credit_valid(credit_valid && credit_ready),
        .credit_arm9,
        .credit_cycles,
        .arm9_timestamp,
        .arm7_timestamp,
        .shared_timestamp,
        .shared_timestamp_changed,
        .overflow(tracker_overflow)
    );

    always @(posedge clk) begin
        if (!reset && credit_valid && !credit_ready &&
            previous_credit_valid && !previous_credit_ready) begin
            if (credit_arm9 != previous_credit_arm9 ||
                credit_cycles != previous_credit_cycles ||
                credit_kind != previous_credit_kind ||
                credit_source_id != previous_credit_source_id)
                $fatal(1, "credit payload changed while backpressured");
        end
        if (!reset && credit_valid && credit_ready)
            delivered <= delivered + 1;
        previous_credit_valid <= credit_valid;
        previous_credit_ready <= credit_ready;
        previous_credit_arm9 <= credit_arm9;
        previous_credit_cycles <= credit_cycles;
        previous_credit_kind <= credit_kind;
        previous_credit_source_id <= credit_source_id;
    end

    task automatic begin_epoch(input logic [31:0] epoch);
        begin
            @(negedge clk);
            epoch_begin = epoch;
            epoch_begin_valid = 1;
            do @(posedge clk); while (!epoch_begin_ready);
            @(negedge clk);
            epoch_begin_valid = 0;
            epoch_begin = 0;
            // Allow the tracker to observe its synchronous epoch reset.
            @(posedge clk);
        end
    endtask

    task automatic send_ack(
        input logic [31:0] epoch,
        input logic [31:0] seq,
        input logic arm9,
        input logic [31:0] cycles,
        input logic [1:0] kind,
        input logic [31:0] source_id
    );
        begin
            @(negedge clk);
            ack_epoch = epoch;
            ack_sequence = seq;
            ack_cpu_arm9 = arm9;
            ack_cycles = cycles;
            ack_kind = kind;
            ack_source_id = source_id;
            ack_valid = 1;
            do @(posedge clk); while (!ack_ready);
            @(negedge clk);
            ack_valid = 0;
            ack_epoch = 0;
            ack_sequence = 0;
            ack_cycles = 0;
            ack_kind = 0;
            ack_source_id = 0;
        end
    endtask

    task automatic wait_tracker(
        input logic [63:0] expected9,
        input logic [63:0] expected7,
        input logic [63:0] expected_shared
    );
        begin
            wait (!credit_valid);
            @(posedge clk);
            #1;
            if (arm9_timestamp !== expected9 ||
                arm7_timestamp !== expected7 ||
                shared_timestamp !== expected_shared)
                $fatal(1,
                    "tracker mismatch got=%0d/%0d/%0d expected=%0d/%0d/%0d",
                    arm9_timestamp, arm7_timestamp, shared_timestamp,
                    expected9, expected7, expected_shared);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // A session cannot begin merely because FPGA reset deasserted.
        epoch_begin = 32'h11111111;
        epoch_begin_valid = 1;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (epoch_begin_ready || epoch_active)
                $fatal(1, "epoch began before transport quiescence");
        end
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin = 0;
        transport_quiescent = 1;
        begin_epoch(32'h11111111);
        if (!epoch_active || active_epoch != 32'h11111111)
            $fatal(1, "fresh nonzero epoch was not activated");

        // A posted commit/admission is intentionally absent from this seam.
        // Until HPS sends its consumed acknowledgement, local time cannot move.
        repeat (5) @(posedge clk);
        if (arm9_timestamp != 0 || arm7_timestamp != 0 ||
            shared_timestamp != 0 || delivered != 0)
            $fatal(1, "unacknowledged posted commit advanced local time");

        // Retain the first consumed posted credit through downstream stalls.
        credit_ready = 0;
        send_ack(32'h11111111, 1, 1, 37, 0, 100);
        repeat (6) begin
            @(posedge clk);
            #1;
            if (!credit_valid || credit_cycles != 37 ||
                !credit_arm9 || credit_kind != 0 ||
                credit_source_id != 100 || delivered != 0)
                $fatal(1, "stalled posted acknowledgement was not retained");
        end
        // The following ACK must itself remain backpressured behind that
        // retained output beat; its producer holds the full record stable.
        @(negedge clk);
        ack_epoch = 32'h11111111;
        ack_sequence = 2;
        ack_cpu_arm9 = 1;
        ack_cycles = 14;
        ack_kind = 0;
        ack_source_id = 101;
        ack_valid = 1;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (ack_ready || arm9_timestamp != 0 ||
                arm7_timestamp != 0 || shared_timestamp != 0)
                $fatal(1, "ACK input overtook a stalled consumed credit");
        end
        @(negedge clk);
        credit_ready = 1;
        @(posedge clk);
        #1;
        if (!ack_ready || arm9_timestamp != 37 ||
            !credit_valid || credit_cycles != 14 ||
            !credit_arm9 || credit_source_id != 101)
            $fatal(1, "ready/valid turnover lost ordered posted credit");
        @(negedge clk);
        ack_valid = 0;
        ack_epoch = 0;
        ack_sequence = 0;
        ack_cycles = 0;
        ack_kind = 0;
        ack_source_id = 0;
        wait_tracker(51, 0, 0);

        // These globally sequenced records represent HPS consumption order:
        // the two ARM9 posted writes above, then two ARM7 mailbox operations.
        send_ack(32'h11111111, 3, 0, 11, 1, 7);
        wait_tracker(51, 11, 11);
        send_ack(32'h11111111, 4, 0, 40, 1, 8);
        wait_tracker(51, 51, 51);

        // A zero-cycle fenced mailbox refresh is still ordered and consumes a
        // global ACK sequence, but cannot fabricate elapsed time.
        send_ack(32'h11111111, 5, 1, 0, 1, 9);
        wait_tracker(51, 51, 51);

        // Synthetic halt ticks use the same HPS-consumed stream. Advancing only
        // ARM9 cannot move shared time; ARM7 catch-up advances it exactly once.
        send_ack(32'h11111111, 6, 1, 32768, 2, 10);
        wait_tracker(32819, 51, 51);
        send_ack(32'h11111111, 7, 0, 32768, 2, 11);
        wait_tracker(32819, 32819, 32819);
        if (delivered != 7 || tracker_overflow || sequence_exhausted)
            $fatal(1, "delivered credit count/overflow mismatch");

        // Runtime reset retires the epoch. A stale acknowledgement arriving
        // before a fresh quiescent epoch handshake must fail closed.
        @(negedge clk);
        transport_quiescent = 0;
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        ack_epoch = 32'h11111111;
        ack_sequence = 8;
        ack_cpu_arm9 = 1;
        ack_cycles = 1;
        ack_kind = 1;
        ack_source_id = 12;
        ack_valid = 1;
        @(posedge clk);
        #1;
        if (!protocol_error || epoch_active || credit_valid)
            $fatal(1, "stale pre-epoch acknowledgement did not fail closed");
        @(negedge clk);
        ack_valid = 0;

        // Reset clears the fault, but epoch zero remains forbidden.
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        transport_quiescent = 1;
        epoch_begin = 0;
        epoch_begin_valid = 1;
        @(posedge clk);
        #1;
        if (!protocol_error || epoch_active)
            $fatal(1, "reserved epoch zero did not fail closed");
        @(negedge clk);
        epoch_begin_valid = 0;

        // Recover only through reset plus a different nonzero epoch. Sequence
        // restarts at one; a gap is then epoch-fatal.
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        begin_epoch(32'h22222222);
        send_ack(32'h22222222, 2, 1, 99, 1, 1);
        @(posedge clk);
        #1;
        if (!protocol_error || epoch_active || credit_valid ||
            arm9_timestamp != 0 || arm7_timestamp != 0)
            $fatal(1, "sequence gap did not fail closed without time advance");

        // Sequence zero is also reserved and cannot alias a fresh epoch.
        @(negedge clk);
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        begin_epoch(32'h33333333);
        send_ack(32'h33333333, 0, 1, 99, 1, 1);
        @(posedge clk);
        #1;
        if (!protocol_error || epoch_active || credit_valid ||
            arm9_timestamp != 0 || arm7_timestamp != 0)
            $fatal(1, "reserved sequence zero did not fail closed");

        $display("PASS: consumed-credit ACK stream preserves HPS order, stalls, posted causality, reset epochs, and synthetic halt catch-up");
        $display("INFO: first_epoch_delivered=%0d shared_catchup=%0d",
            delivered, 32819);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "consumed-credit ACK timeout");
    end
endmodule
