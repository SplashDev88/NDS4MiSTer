module tb_nds_sound_write_order_queue_faults;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 0;
    logic epoch_begin_valid = 0;
    logic epoch_begin_ready;
    logic [31:0] epoch_begin = 0;
    logic epoch_begin_fresh = 0;
    logic epoch_started;
    logic epoch_active;
    logic [31:0] active_epoch;
    logic epoch_seed_valid = 0;
    logic [31:0] epoch_seed_mailbox_source_id = 0;
    logic [31:0] epoch_seed_posted_base_sequence = 0;
    logic [31:0] epoch_seed_global_sequence = 0;
    logic epoch_runtime_contract_active = 1;
    logic completion_valid = 0;
    logic [31:0] completion_epoch = 0;
    logic [31:0] completion_source_id = 0;
    logic completion_cpu_arm9 = 0;
    logic completion_read_not_write = 0;
    logic [1:0] completion_access = 0;
    logic [31:0] completion_address = 0;
    logic [31:0] completion_write_data = 0;
    logic ack_valid = 0;
    logic ack_ready;
    logic [31:0] ack_epoch = 0;
    logic [31:0] ack_sequence = 0;
    logic ack_cpu_arm9 = 0;
    logic [1:0] ack_kind = 0;
    logic [31:0] ack_source_id = 0;
    logic drain_valid = 0;
    logic drain_ready;
    logic [31:0] drain_epoch = 0;
    logic [31:0] drain_ack_sequence = 0;
    logic write_valid;
    logic write_ready = 1;
    logic [31:0] write_epoch;
    logic [31:0] write_source_id;
    logic [31:0] write_address;
    logic [1:0] write_access;
    logic [31:0] write_data;
    logic [1:0] queue_level;
    logic pending_sound_ack;
    logic capture_overflow;
    logic sequence_exhausted;
    logic protocol_error;

    integer epoch_number = 1;
    integer fault_cases = 0;

    always #5 clk = ~clk;

    nds_sound_write_order_queue #(
        .QUEUE_DEPTH(2)
    ) dut (.*);

    task automatic clear_inputs;
        begin
            epoch_begin_valid = 0;
            epoch_begin = 0;
            epoch_begin_fresh = 0;
            completion_valid = 0;
            completion_epoch = 0;
            completion_source_id = 0;
            completion_cpu_arm9 = 0;
            completion_read_not_write = 0;
            completion_access = 0;
            completion_address = 0;
            completion_write_data = 0;
            ack_valid = 0;
            ack_epoch = 0;
            ack_sequence = 0;
            ack_cpu_arm9 = 0;
            ack_kind = 0;
            ack_source_id = 0;
            drain_valid = 0;
            drain_epoch = 0;
            drain_ack_sequence = 0;
            write_ready = 1;
        end
    endtask

    task automatic restart_epoch;
        logic [31:0] wanted_epoch;
        begin
            clear_inputs();
            @(negedge clk);
            reset = 1;
            transport_quiescent = 0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            reset = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            wanted_epoch = 32'h80000000 + epoch_number;
            epoch_number = epoch_number + 1;
            epoch_begin = wanted_epoch;
            epoch_begin_fresh = 1;
            epoch_begin_valid = 1;
            do @(posedge clk); while (!epoch_begin_ready);
            @(negedge clk);
            epoch_begin_valid = 0;
            epoch_begin_fresh = 0;
            epoch_begin = 0;
            #1;
            if (!epoch_active || active_epoch != wanted_epoch ||
                protocol_error || capture_overflow)
                $fatal(1, "fault-test epoch failed to restart");
        end
    endtask

    task automatic pulse_completion(
        input logic [31:0] epoch,
        input logic [31:0] source,
        input logic cpu_arm9,
        input logic rnw,
        input logic [1:0] access,
        input logic [31:0] address
    );
        begin
            @(negedge clk);
            completion_epoch = epoch;
            completion_source_id = source;
            completion_cpu_arm9 = cpu_arm9;
            completion_read_not_write = rnw;
            completion_access = access;
            completion_address = address;
            completion_write_data = 32'hc0010000 ^ source;
            completion_valid = 1;
            @(posedge clk);
            @(negedge clk);
            completion_valid = 0;
            completion_epoch = 0;
            completion_source_id = 0;
            completion_cpu_arm9 = 0;
            completion_read_not_write = 0;
            completion_access = 0;
            completion_address = 0;
            completion_write_data = 0;
        end
    endtask

    task automatic pulse_ack(
        input logic [31:0] epoch,
        input logic [31:0] seq,
        input logic cpu_arm9,
        input logic [1:0] kind,
        input logic [31:0] source
    );
        begin
            @(negedge clk);
            ack_epoch = epoch;
            ack_sequence = seq;
            ack_cpu_arm9 = cpu_arm9;
            ack_kind = kind;
            ack_source_id = source;
            ack_valid = 1;
            do @(posedge clk); while (!ack_ready);
            @(negedge clk);
            ack_valid = 0;
            ack_epoch = 0;
            ack_sequence = 0;
            ack_cpu_arm9 = 0;
            ack_kind = 0;
            ack_source_id = 0;
        end
    endtask

    task automatic pulse_drain(
        input logic [31:0] epoch,
        input logic [31:0] seq
    );
        begin
            @(negedge clk);
            drain_epoch = epoch;
            drain_ack_sequence = seq;
            drain_valid = 1;
            do @(posedge clk); while (!drain_ready);
            @(negedge clk);
            drain_valid = 0;
            drain_epoch = 0;
            drain_ack_sequence = 0;
        end
    endtask

    task automatic require_fault(
        input logic expect_overflow,
        input [8*80-1:0] label
    );
        begin
            #1;
            if (!protocol_error || epoch_active || write_valid ||
                queue_level != 0 || pending_sound_ack ||
                capture_overflow != expect_overflow)
                $fatal(1, "%0s did not fail closed error=%b overflow=%b",
                    label, protocol_error, capture_overflow);
            fault_cases = fault_cases + 1;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);

        restart_epoch();
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_begin = active_epoch + 1'b1;
        epoch_begin_fresh = 0;
        epoch_begin_valid = 1;
        do @(posedge clk); while (!epoch_begin_ready);
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin = 0;
        require_fault(0, "unproven fresh epoch");

        restart_epoch();
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
        epoch_begin_fresh = 0;
        epoch_begin = 0;
        require_fault(0, "active epoch reuse");

        restart_epoch();
        pulse_completion(active_epoch, 0, 0, 0, 0, 32'h04000400);
        require_fault(0, "zero completion source");

        restart_epoch();
        pulse_completion(active_epoch, 2, 0, 0, 0, 32'h04000400);
        require_fault(0, "completion gap");

        restart_epoch();
        pulse_completion(active_epoch, 1, 1, 1, 2, 32'hffffffff);
        pulse_completion(active_epoch, 1, 1, 1, 2, 32'hffffffff);
        require_fault(0, "duplicate completion");

        restart_epoch();
        pulse_completion(active_epoch ^ 32'h1, 1, 0, 0, 0, 32'h04000400);
        require_fault(0, "stale completion epoch");

        restart_epoch();
        pulse_completion(active_epoch, 1, 0, 0, 3, 32'h04000400);
        require_fault(0, "reserved sound access");

        // No completion backpressure exists: the third retained sound write
        // is sampled and turns finite capture overflow into an epoch-fatal
        // condition instead of being silently dropped.
        restart_epoch();
        pulse_completion(active_epoch, 1, 0, 0, 0, 32'h04000400);
        pulse_completion(active_epoch, 2, 0, 0, 1, 32'h04000401);
        pulse_completion(active_epoch, 3, 0, 0, 2, 32'h04000402);
        require_fault(1, "capture overflow");

        restart_epoch();
        pulse_completion(active_epoch, 1, 1, 1, 2, 32'hffffffff);
        pulse_ack(active_epoch, 2, 1, 1, 1);
        require_fault(0, "global ACK sequence gap");

        restart_epoch();
        pulse_completion(active_epoch, 1, 1, 1, 2, 32'hffffffff);
        pulse_ack(active_epoch, 1, 1, 1, 2);
        require_fault(0, "mailbox source gap");

        restart_epoch();
        pulse_ack(active_epoch, 1, 1, 0, 2);
        require_fault(0, "posted source gap");

        restart_epoch();
        pulse_completion(active_epoch, 1, 1, 1, 2, 32'hffffffff);
        pulse_ack(active_epoch ^ 32'h1, 1, 1, 1, 1);
        require_fault(0, "stale ACK epoch");

        restart_epoch();
        pulse_completion(active_epoch, 1, 1, 1, 2, 32'hffffffff);
        pulse_ack(active_epoch, 1, 1, 1, 0);
        require_fault(0, "zero ACK source");

        restart_epoch();
        pulse_completion(active_epoch, 1, 0, 0, 0, 32'h04000400);
        pulse_ack(active_epoch, 1, 1, 1, 1);
        require_fault(0, "wrong CPU for sound ACK");

        restart_epoch();
        pulse_ack(active_epoch, 1, 1, 0, 1);
        pulse_drain(active_epoch, 2);
        require_fault(0, "drain sequence gap");

        restart_epoch();
        pulse_ack(active_epoch, 1, 1, 0, 1);
        pulse_drain(active_epoch ^ 32'h1, 1);
        require_fault(0, "stale drain epoch");

        // An exact future drain is normal transport skew and waits for ACK
        // acceptance.  It must not be mistaken for a gap.
        restart_epoch();
        @(negedge clk);
        drain_epoch = active_epoch;
        drain_ack_sequence = 1;
        drain_valid = 1;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (drain_ready || protocol_error)
                $fatal(1, "future exact drain did not backpressure cleanly");
        end
        pulse_ack(active_epoch, 1, 1, 0, 1);
        do @(posedge clk); while (!drain_ready);
        @(negedge clk);
        drain_valid = 0;
        drain_epoch = 0;
        drain_ack_sequence = 0;
        #1;
        if (protocol_error || !epoch_active)
            $fatal(1, "future exact drain failed after ACK arrived");

        $display(
            "PASS: %0d zero/gap/stale/order/overflow faults fail closed and future transport skew stalls safely",
            fault_cases);
        $finish;
    end
endmodule
