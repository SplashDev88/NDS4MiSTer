module tb_nds_sound_write_order_queue_runtime_seed_faults;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 1;
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
    logic epoch_runtime_contract_active = 0;

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
    logic [2:0] queue_level;
    logic pending_sound_ack;
    logic capture_overflow;
    logic sequence_exhausted;
    logic protocol_error;

    integer epoch_number = 0;
    integer fault_cases = 0;

    always #5 clk = ~clk;

    nds_sound_write_order_queue #(
        .QUEUE_DEPTH(4),
        .RUNTIME_EPOCH_SEEDS(1'b1)
    ) dut (.*);

    task automatic clear_inputs;
        begin
            transport_quiescent = 1;
            epoch_begin_valid = 0;
            epoch_begin = 0;
            epoch_begin_fresh = 0;
            epoch_seed_valid = 0;
            epoch_seed_mailbox_source_id = 0;
            epoch_seed_posted_base_sequence = 0;
            epoch_seed_global_sequence = 0;
            epoch_runtime_contract_active = 0;
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
        end
    endtask

    task automatic hard_reset;
        begin
            @(negedge clk);
            clear_inputs();
            reset = 1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    task automatic attempt_epoch(
        input logic seed_valid,
        input logic [31:0] mailbox_seed,
        input logic [31:0] posted_base,
        input logic [31:0] global_seed,
        input logic contract_active
    );
        begin
            epoch_number = epoch_number + 1;
            @(negedge clk);
            transport_quiescent = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_begin = 32'h7c000000 + epoch_number;
            epoch_begin_fresh = 1;
            epoch_seed_valid = seed_valid;
            epoch_seed_mailbox_source_id = mailbox_seed;
            epoch_seed_posted_base_sequence = posted_base;
            epoch_seed_global_sequence = global_seed;
            epoch_runtime_contract_active = contract_active;
            epoch_begin_valid = 1;
            #1;
            if (!epoch_begin_ready)
                $fatal(1, "runtime seed fault was incorrectly backpressured");
            @(posedge clk);
            @(negedge clk);
            epoch_begin_valid = 0;
            epoch_begin_fresh = 0;
        end
    endtask

    task automatic require_fault(input [8*64-1:0] label);
        begin
            #1;
            if (!protocol_error || epoch_active || write_valid ||
                pending_sound_ack || queue_level != 0 ||
                ack_ready || drain_ready)
                $fatal(1,
                    "%0s did not fail closed active=%b level=%0d",
                    label, epoch_active, queue_level);
            repeat (3) begin
                @(posedge clk);
                #1;
                if (!protocol_error || epoch_active || write_valid ||
                    pending_sound_ack || queue_level != 0)
                    $fatal(1, "%0s fault was not sticky", label);
            end
            fault_cases = fault_cases + 1;
            clear_inputs();
        end
    endtask

    task automatic start_valid_epoch;
        begin
            attempt_epoch(1, 32'd101, 32'd37, 32'd1, 1);
            #1;
            if (!epoch_active || active_epoch == 0 ||
                protocol_error || sequence_exhausted)
                $fatal(1, "valid runtime seeds did not activate");
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);

        hard_reset();
        attempt_epoch(0, 101, 37, 1, 1);
        require_fault("missing runtime seed-valid proof");

        hard_reset();
        attempt_epoch(1, 0, 37, 1, 1);
        require_fault("zero mailbox source seed");

        hard_reset();
        attempt_epoch(1, 101, 32'hffffffff, 1, 1);
        require_fault("terminal posted base seed");

        hard_reset();
        attempt_epoch(1, 101, 37, 0, 1);
        require_fault("zero global ACK/drain seed");

        hard_reset();
        attempt_epoch(1, 101, 37, 1, 0);
        require_fault("inactive runtime epoch contract");

        hard_reset();
        start_valid_epoch();
        @(negedge clk);
        completion_valid = 1;
        completion_epoch = active_epoch;
        completion_source_id = 100;
        completion_cpu_arm9 = 0;
        completion_address = 32'h04000400;
        completion_access = 2'b10;
        @(posedge clk);
        @(negedge clk);
        completion_valid = 0;
        require_fault("completion before seeded mailbox source");

        hard_reset();
        start_valid_epoch();
        @(negedge clk);
        ack_valid = 1;
        ack_epoch = active_epoch;
        ack_sequence = 1;
        ack_kind = 0;
        ack_source_id = 39;
        @(posedge clk);
        @(negedge clk);
        ack_valid = 0;
        require_fault("posted source not base plus one");

        hard_reset();
        start_valid_epoch();
        @(negedge clk);
        ack_valid = 1;
        ack_epoch = active_epoch;
        ack_sequence = 2;
        ack_kind = 0;
        ack_source_id = 38;
        @(posedge clk);
        @(negedge clk);
        ack_valid = 0;
        require_fault("global ACK did not start at runtime seed");

        hard_reset();
        start_valid_epoch();
        @(negedge clk);
        epoch_runtime_contract_active = 0;
        @(posedge clk);
        @(negedge clk);
        require_fault("runtime epoch contract loss");

        if (fault_cases != 9)
            $fatal(1, "runtime seed fault count %0d", fault_cases);
        $display(
            "PASS: nine runtime epoch seed/source/global/contract failures close the write queue without output");
        $finish;
    end
endmodule
