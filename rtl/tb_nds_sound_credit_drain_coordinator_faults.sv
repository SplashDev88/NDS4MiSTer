module tb_nds_sound_credit_drain_coordinator_faults;
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
    integer epoch_index = 1;
    integer fault_cases = 0;

    always #5 clk = ~clk;

    nds_sound_credit_drain_coordinator dut (.*);

    task automatic clear_inputs;
        begin
            epoch_begin_valid = 0;
            epoch_begin = 0;
            epoch_begin_fresh = 1;
            credit_valid = 0;
            credit_epoch = 0;
            credit_ack_sequence = 0;
            credit_cpu_arm9 = 0;
            credit_cycles = 0;
            credit_kind = 0;
            sound_cycles_ready = 1;
            drain_token_ready = 0;
        end
    endtask

    task automatic hard_reset;
        begin
            @(negedge clk);
            clear_inputs();
            reset = 1;
            transport_quiescent = 0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    task automatic start_epoch(input logic fresh);
        logic [31:0] wanted;
        begin
            wanted = 32'h70000000 + epoch_index;
            epoch_index = epoch_index + 1;
            @(negedge clk);
            transport_quiescent = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_begin = wanted;
            epoch_begin_fresh = fresh;
            epoch_begin_valid = 1;
            do @(posedge clk); while (!epoch_begin_ready);
            @(negedge clk);
            epoch_begin_valid = 0;
            epoch_begin = 0;
            epoch_begin_fresh = 1;
            while (epoch_started) @(posedge clk);
        end
    endtask

    task automatic restart_valid_epoch;
        begin
            hard_reset();
            start_epoch(1);
            #1;
            if (!epoch_active || protocol_error || overflow)
                $fatal(1, "fault-test valid epoch failed");
        end
    endtask

    task automatic send_raw_credit(
        input logic [31:0] epoch,
        input logic [31:0] seq,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [1:0] kind
    );
        begin
            @(negedge clk);
            credit_epoch = epoch;
            credit_ack_sequence = seq;
            credit_cpu_arm9 = cpu_arm9;
            credit_cycles = cycles;
            credit_kind = kind;
            credit_valid = 1;
            do @(posedge clk); while (!credit_ready);
            @(negedge clk);
            credit_valid = 0;
            credit_epoch = 0;
            credit_ack_sequence = 0;
            credit_cpu_arm9 = 0;
            credit_cycles = 0;
            credit_kind = 0;
        end
    endtask

    task automatic consume_token;
        begin
            while (!drain_token_valid) @(posedge clk);
            @(negedge clk);
            drain_token_ready = 1;
            @(posedge clk);
            @(negedge clk);
            drain_token_ready = 0;
        end
    endtask

    task automatic require_protocol_fault(input [8*80-1:0] label);
        begin
            #1;
            if (!protocol_error || overflow || epoch_active ||
                credit_ready || sound_cycles_valid || drain_token_valid)
                $fatal(1,
                    "%0s did not fail closed protocol=%b overflow=%b active=%b",
                    label, protocol_error, overflow, epoch_active);
            fault_cases = fault_cases + 1;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);

        hard_reset();
        start_epoch(0);
        require_protocol_fault("non-fresh epoch");

        hard_reset();
        // A stale credit before any epoch is accepted once and poisons the
        // seam rather than looking like indefinite ordinary backpressure.
        send_raw_credit(32'h12345678, 1, 0, 0, 1);
        require_protocol_fault("credit before epoch");

        restart_valid_epoch();
        send_raw_credit(active_epoch ^ 32'h1, 1, 0, 0, 1);
        require_protocol_fault("stale credit epoch");

        restart_valid_epoch();
        send_raw_credit(active_epoch, 0, 0, 0, 1);
        require_protocol_fault("zero ACK sequence");

        restart_valid_epoch();
        send_raw_credit(active_epoch, 2, 0, 0, 1);
        require_protocol_fault("ACK sequence gap");

        restart_valid_epoch();
        send_raw_credit(active_epoch, 1, 0, 0, 1);
        consume_token();
        send_raw_credit(active_epoch, 1, 0, 0, 1);
        require_protocol_fault("duplicate ACK sequence");

        restart_valid_epoch();
        send_raw_credit(active_epoch, 1, 0, 0, 3);
        require_protocol_fault("reserved credit kind");

        // Replacing an active epoch with the same persistent ID is stale.
        restart_valid_epoch();
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_begin = active_epoch;
        epoch_begin_fresh = 1;
        epoch_begin_valid = 1;
        do @(posedge clk); while (!epoch_begin_ready);
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin = 0;
        require_protocol_fault("epoch reuse");

        // Exercise the coordinator's fail-closed monitor for the composed
        // scaler.  The real scaler raises this sticky flag only if its
        // ready/valid source contract is violated; forcing the internal fault
        // here tests containment without weakening the production interface.
        restart_valid_epoch();
        force dut.scaler_overflow = 1'b1;
        @(posedge clk);
        #1;
        release dut.scaler_overflow;
        @(posedge clk);
        #1;
        if (!overflow || protocol_error || epoch_active ||
            credit_ready || sound_cycles_valid || drain_token_valid)
            $fatal(1, "scaler overflow was not contained");
        fault_cases = fault_cases + 1;

        $display(
            "PASS: %0d keyed coordinator epoch/sequence/kind faults fail closed",
            fault_cases);
        $finish;
    end
endmodule

/* verilator lint_off DECLFILENAME */
module tb_nds_sound_credit_drain_coordinator_overflow;
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
        .TRACKER_RESET_TIMESTAMP(64'hfffffffffffffff0)
    ) dut (.*);

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_begin = 32'haabbccdd;
        epoch_begin_valid = 1;
        do @(posedge clk); while (!epoch_begin_ready);
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin = 0;
        while (epoch_started) @(posedge clk);

        @(negedge clk);
        credit_valid = 1;
        credit_epoch = active_epoch;
        credit_ack_sequence = 1;
        credit_cpu_arm9 = 1;
        credit_cycles = 32;
        credit_kind = 2;
        do @(posedge clk); while (!credit_ready);
        @(negedge clk);
        credit_valid = 0;
        repeat (3) @(posedge clk);
        #1;
        if (!overflow || protocol_error || epoch_active ||
            sound_cycles_valid || drain_token_valid || credit_ready)
            $fatal(1, "tracker overflow did not suppress partial output/token");

        $display(
            "PASS: canonical timestamp overflow fails coordinator closed without a partial token");
        $finish;
    end
endmodule
/* verilator lint_on DECLFILENAME */
