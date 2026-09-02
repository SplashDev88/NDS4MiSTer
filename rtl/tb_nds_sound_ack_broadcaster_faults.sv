module tb_nds_sound_ack_broadcaster_faults;
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

    logic ack_valid = 0;
    logic ack_ready;
    logic [31:0] ack_epoch = 0;
    logic [31:0] ack_sequence = 0;
    logic ack_cpu_arm9 = 0;
    logic [31:0] ack_cycles = 0;
    logic [1:0] ack_kind = 0;
    logic [31:0] ack_source_id = 0;

    logic queue_ack_valid;
    logic queue_ack_ready = 1;
    logic [31:0] queue_ack_epoch;
    logic [31:0] queue_ack_sequence;
    logic queue_ack_cpu_arm9;
    logic [1:0] queue_ack_kind;
    logic [31:0] queue_ack_source_id;
    logic credit_valid;
    logic credit_ready = 1;
    logic [31:0] credit_epoch;
    logic [31:0] credit_ack_sequence;
    logic credit_cpu_arm9;
    logic [31:0] credit_cycles;
    logic [1:0] credit_kind;
    logic busy;
    logic sequence_exhausted;
    logic protocol_error;

    integer epoch_counter = 1;
    integer fault_cases = 0;
    integer queue_fires = 0;
    integer credit_fires = 0;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (!reset && queue_ack_valid && queue_ack_ready)
            queue_fires <= queue_fires + 1;
        if (!reset && credit_valid && credit_ready)
            credit_fires <= credit_fires + 1;
    end

    nds_sound_ack_broadcaster dut (.*);

    task automatic clear_inputs;
        begin
            epoch_begin_valid = 0;
            epoch_begin = 0;
            epoch_begin_fresh = 1;
            ack_valid = 0;
            ack_epoch = 0;
            ack_sequence = 0;
            ack_cpu_arm9 = 0;
            ack_cycles = 0;
            ack_kind = 0;
            ack_source_id = 0;
            queue_ack_ready = 1;
            credit_ready = 1;
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
            wanted = 32'h72000000 + epoch_counter;
            epoch_counter = epoch_counter + 1;
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
            if (!epoch_active || protocol_error || sequence_exhausted)
                $fatal(1, "fault-test valid epoch failed");
        end
    endtask

    task automatic drive_raw(
        input logic [31:0] epoch,
        input logic [31:0] seq,
        input logic [1:0] kind,
        input logic [31:0] source_id
    );
        begin
            @(negedge clk);
            ack_valid = 1;
            ack_epoch = epoch;
            ack_sequence = seq;
            ack_cpu_arm9 = 0;
            ack_cycles = 32'h11223344;
            ack_kind = kind;
            ack_source_id = source_id;
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic require_fault(input [8*80-1:0] label);
        begin
            #1;
            if (!protocol_error || epoch_active || ack_ready ||
                queue_ack_valid || credit_valid || busy)
                $fatal(1,
                    "%0s did not fail closed error=%b active=%b busy=%b",
                    label, protocol_error, epoch_active, busy);
            fault_cases = fault_cases + 1;
            clear_inputs();
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);

        hard_reset();
        start_epoch(0);
        require_fault("non-fresh epoch");

        hard_reset();
        drive_raw(32'h12345678, 1, 1, 1);
        require_fault("ACK before epoch");

        restart_valid_epoch();
        drive_raw(active_epoch ^ 32'h1, 1, 1, 1);
        require_fault("stale ACK epoch");

        restart_valid_epoch();
        drive_raw(active_epoch, 0, 1, 1);
        require_fault("zero ACK sequence");

        restart_valid_epoch();
        drive_raw(active_epoch, 2, 1, 1);
        require_fault("ACK sequence gap");

        restart_valid_epoch();
        drive_raw(active_epoch, 1, 3, 1);
        require_fault("reserved ACK kind");

        restart_valid_epoch();
        drive_raw(active_epoch, 1, 1, 0);
        require_fault("zero ACK source");

        // Let queue accept first, then mutate a retained payload while credit
        // is stalled.  The already-accepted queue copy cannot be repeated and
        // the entire epoch is poisoned before credit sees the mutation.
        restart_valid_epoch();
        queue_ack_ready = 1;
        credit_ready = 0;
        @(negedge clk);
        ack_valid = 1;
        ack_epoch = active_epoch;
        ack_sequence = 1;
        ack_cpu_arm9 = 0;
        ack_cycles = 7;
        ack_kind = 1;
        ack_source_id = 1;
        wait (queue_fires == 1);
        repeat (5) @(posedge clk);
        @(negedge clk);
        ack_cycles = 8;
        @(posedge clk);
        @(negedge clk);
        require_fault("payload mutation while retained");
        if (queue_fires != 1 || credit_fires != 0)
            $fatal(1, "mutated record duplicated or reached second consumer");

        // Valid withdrawal is the other forbidden ready/valid source change.
        restart_valid_epoch();
        queue_ack_ready = 0;
        credit_ready = 0;
        @(negedge clk);
        ack_valid = 1;
        ack_epoch = active_epoch;
        ack_sequence = 1;
        ack_cycles = 9;
        ack_kind = 1;
        ack_source_id = 1;
        @(posedge clk);
        @(negedge clk);
        ack_valid = 0;
        @(posedge clk);
        @(negedge clk);
        require_fault("valid withdrawal before retirement");

        // A persistent epoch value cannot be reused after a fresh quiescent
        // low/high boundary.
        restart_valid_epoch();
        @(negedge clk);
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
        require_fault("epoch reuse");

        $display(
            "PASS: %0d broadcaster epoch/sequence/kind/source/source-stability faults fail closed",
            fault_cases);
        $finish;
    end
endmodule
