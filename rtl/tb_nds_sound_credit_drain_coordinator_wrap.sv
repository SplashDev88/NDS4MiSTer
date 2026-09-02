module tb_nds_sound_credit_drain_coordinator_wrap;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 0;
    logic epoch_begin_valid = 0;
    logic epoch_begin_ready;
    logic [31:0] epoch_begin = 0;
    logic epoch_begin_fresh = 1;
    logic epoch_started;
    logic epoch_active;
    logic [31:0] active_epoch;
    logic credit_valid = 0;
    logic credit_ready;
    logic [31:0] credit_epoch = 0;
    logic [31:0] credit_ack_sequence = 0;
    logic credit_cpu_arm9 = 0;
    logic [31:0] credit_cycles = 0;
    logic [1:0] credit_kind = 0;
    logic [7:0] sound_cycles;
    logic sound_cycles_valid;
    logic sound_cycles_ready = 1;
    logic drain_token_valid;
    logic drain_token_ready = 0;
    logic [31:0] drain_token_epoch;
    logic [31:0] drain_token_ack_sequence;
    logic [63:0] arm9_timestamp;
    logic [63:0] arm7_timestamp;
    logic [63:0] shared_timestamp;
    logic [63:0] remaining_delta_cycles;
    logic busy;
    logic sequence_exhausted;
    logic protocol_error;
    logic overflow;

    always #5 clk = ~clk;

    nds_sound_credit_drain_coordinator #(
        .FIRST_ACK_SEQUENCE(32'hffffffff)
    ) dut (.*);

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_begin_valid = 1;
        epoch_begin = 32'h10203040;
        do @(posedge clk); while (!epoch_begin_ready);
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin = 0;
        while (epoch_started) @(posedge clk);

        @(negedge clk);
        credit_valid = 1;
        credit_epoch = active_epoch;
        credit_ack_sequence = 32'hffffffff;
        credit_cpu_arm9 = 1;
        credit_cycles = 0;
        credit_kind = 1;
        do @(posedge clk); while (!credit_ready);
        @(negedge clk);
        credit_valid = 0;

        while (!drain_token_valid) @(posedge clk);
        #1;
        if (!sequence_exhausted ||
            drain_token_epoch != 32'h10203040 ||
            drain_token_ack_sequence != 32'hffffffff ||
            sound_cycles_valid || protocol_error || overflow)
            $fatal(1, "final ACK sequence token/exhaustion mismatch");
        repeat (4) begin
            @(posedge clk);
            #1;
            if (!drain_token_valid || credit_ready)
                $fatal(1, "terminal token was not retained");
        end
        @(negedge clk);
        drain_token_ready = 1;
        @(posedge clk);
        @(negedge clk);
        drain_token_ready = 0;

        // Exhaustion forbids both another ACK and a new epoch until reset.
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_begin_valid = 1;
        epoch_begin = 32'h50607080;
        credit_valid = 1;
        credit_epoch = 32'h10203040;
        credit_ack_sequence = 0;
        repeat (4) begin
            @(posedge clk);
            #1;
            if (epoch_begin_ready || credit_ready ||
                protocol_error || overflow)
                $fatal(1, "terminal sequence resumed or wrapped");
        end

        $display(
            "PASS: final nonzero ACK emits one drain token and never wraps through reserved zero");
        $finish;
    end
endmodule
