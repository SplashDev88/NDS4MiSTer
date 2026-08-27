module tb_nds_sound_mailbox_completion_tap;
    logic clk = 0;
    logic reset = 1;
    logic shadow_feature_enable = 0;
    logic transport_quiescent = 1;
    logic epoch_contract_active = 0;
    logic epoch_contract_fresh = 0;
    logic [31:0] epoch_contract = 0;
    logic shadow_session_active;
    logic [31:0] shadow_active_epoch;
    logic epoch_seed_valid;
    logic [31:0] epoch_next_source_generation;

    logic mailbox_explicit_launch = 0;
    logic mailbox_request = 0;
    logic [3:0] mailbox_debug_state = 0;
    logic mailbox_cpu_arm9 = 0;
    logic [31:0] mailbox_elapsed_cycles = 0;
    logic [31:0] mailbox_fence_sequence = 0;
    logic [31:0] mailbox_address = 0;
    logic mailbox_read_not_write = 0;
    logic [1:0] mailbox_access = 0;
    logic [31:0] mailbox_write_data = 0;
    logic mailbox_done = 0;
    logic [31:0] mailbox_completed_fence_sequence = 0;

    logic completion_valid;
    logic [31:0] completion_epoch;
    logic [31:0] completion_source_id;
    logic completion_cpu_arm9;
    logic [31:0] completion_elapsed_cycles;
    logic [31:0] completion_completed_fence_sequence;
    logic completion_read_not_write;
    logic [1:0] completion_access;
    logic [31:0] completion_address;
    logic [31:0] completion_write_data;

    logic credit_valid;
    logic credit_ready = 0;
    logic [31:0] credit_epoch;
    logic [31:0] credit_source_generation;
    logic credit_cpu_arm9;
    logic [31:0] credit_elapsed_cycles;
    logic [31:0] credit_completed_fence_sequence;
    logic credit_read_not_write;
    logic [1:0] credit_access;
    logic [31:0] credit_address;
    logic [31:0] credit_write_data;
    logic [1:0] credit_level;
    logic owner_active;
    logic capture_overflow;
    logic sequence_exhausted;
    logic generation_desynchronized;
    logic protocol_error;
    logic [7:0] fault_code;

    integer completion_count = 0;

    logic previous_credit_valid = 0;
    logic previous_credit_ready = 0;
    logic [31:0] previous_credit_epoch = 0;
    logic [31:0] previous_credit_source = 0;
    logic previous_credit_cpu = 0;
    logic [31:0] previous_credit_cycles = 0;
    logic [31:0] previous_credit_fence = 0;
    logic previous_credit_rnw = 0;
    logic [1:0] previous_credit_access = 0;
    logic [31:0] previous_credit_address = 0;
    logic [31:0] previous_credit_data = 0;

    always #5 clk = ~clk;

    nds_sound_mailbox_completion_tap #(
        .CREDIT_DEPTH(2),
        .USE_EXPLICIT_LAUNCH(1'b1)
    ) dut (.*);

    always @(posedge clk) begin
        if (!reset && previous_credit_valid && !previous_credit_ready) begin
            if (!credit_valid ||
                credit_epoch != previous_credit_epoch ||
                credit_source_generation != previous_credit_source ||
                credit_cpu_arm9 != previous_credit_cpu ||
                credit_elapsed_cycles != previous_credit_cycles ||
                credit_completed_fence_sequence != previous_credit_fence ||
                credit_read_not_write != previous_credit_rnw ||
                credit_access != previous_credit_access ||
                credit_address != previous_credit_address ||
                credit_write_data != previous_credit_data)
                $fatal(1, "credit metadata changed under backpressure");
        end
        if (!reset && completion_valid)
            completion_count <= completion_count + 1;
        previous_credit_valid <= credit_valid;
        previous_credit_ready <= credit_ready;
        previous_credit_epoch <= credit_epoch;
        previous_credit_source <= credit_source_generation;
        previous_credit_cpu <= credit_cpu_arm9;
        previous_credit_cycles <= credit_elapsed_cycles;
        previous_credit_fence <= credit_completed_fence_sequence;
        previous_credit_rnw <= credit_read_not_write;
        previous_credit_access <= credit_access;
        previous_credit_address <= credit_address;
        previous_credit_data <= credit_write_data;
    end

    task automatic launch(
        input logic cpu,
        input logic [31:0] cycles,
        input logic [31:0] fence,
        input logic [31:0] address,
        input logic rnw,
        input logic [1:0] access,
        input logic [31:0] data
    );
        begin
            @(negedge clk);
            mailbox_cpu_arm9 = cpu;
            mailbox_elapsed_cycles = cycles;
            mailbox_fence_sequence = fence;
            mailbox_address = address;
            mailbox_read_not_write = rnw;
            mailbox_access = access;
            mailbox_write_data = data;
            mailbox_explicit_launch = 1;
            @(posedge clk);
            @(negedge clk);
            mailbox_explicit_launch = 0;
            if (!owner_active)
                $fatal(1, "launch did not establish ownership");
        end
    endtask

    task automatic mutate_live_inputs;
        begin
            mailbox_cpu_arm9 = ~mailbox_cpu_arm9;
            mailbox_elapsed_cycles = 32'hdead0001;
            mailbox_fence_sequence = 32'hdead0002;
            mailbox_address = 32'hdead0003;
            mailbox_read_not_write = ~mailbox_read_not_write;
            mailbox_access = 2'b11;
            mailbox_write_data = 32'hdead0004;
        end
    endtask

    task automatic finish_transaction(input logic [31:0] fence);
        begin
            @(negedge clk);
            mailbox_completed_fence_sequence = fence;
            mailbox_done = 1;
            @(posedge clk);
            #1;
            @(negedge clk);
            mailbox_done = 0;
            mailbox_completed_fence_sequence = 0;
        end
    endtask

    task automatic expect_completion(
        input logic [31:0] source,
        input logic cpu,
        input logic [31:0] cycles,
        input logic [31:0] fence,
        input logic [31:0] address,
        input logic rnw,
        input logic [1:0] access,
        input logic [31:0] data
    );
        begin
            #1;
            if (!completion_valid ||
                completion_epoch != 32'h0000a501 ||
                completion_source_id != source ||
                completion_cpu_arm9 != cpu ||
                completion_elapsed_cycles != cycles ||
                completion_completed_fence_sequence != fence ||
                completion_address != address ||
                completion_read_not_write != rnw ||
                completion_access != access ||
                completion_write_data != data)
                $fatal(1, "completion metadata mismatch source=%h",
                    completion_source_id);
        end
    endtask

    task automatic expect_credit(
        input logic [31:0] source,
        input logic cpu,
        input logic [31:0] cycles,
        input logic [31:0] fence,
        input logic [31:0] address,
        input logic rnw,
        input logic [1:0] access,
        input logic [31:0] data
    );
        begin
            #1;
            if (!credit_valid ||
                credit_epoch != 32'h0000a501 ||
                credit_source_generation != source ||
                credit_cpu_arm9 != cpu ||
                credit_elapsed_cycles != cycles ||
                credit_completed_fence_sequence != fence ||
                credit_address != address ||
                credit_read_not_write != rnw ||
                credit_access != access ||
                credit_write_data != data)
                $fatal(1, "credit metadata mismatch source=%h",
                    credit_source_generation);
        end
    endtask

    task automatic pop_credit;
        begin
            @(negedge clk);
            credit_ready = 1;
            @(posedge clk);
            @(negedge clk);
            credit_ready = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // A complete transaction while disabled is harmless but advances the
        // mirrored mailbox generation from 1 to 2.
        launch(1, 32'h11, 32'h21, 32'h04000208, 0, 2'b01,
            32'h11112222);
        mutate_live_inputs();
        finish_transaction(32'h21);
        #1;
        if (protocol_error || completion_valid || credit_valid ||
            generation_desynchronized)
            $fatal(1, "disabled traffic was not passive");

        // Exact low/high quarantine, then a fresh nonzero active epoch.
        @(negedge clk);
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        shadow_feature_enable = 1;
        epoch_contract = 32'h0000a501;
        epoch_contract_fresh = 1;
        epoch_contract_active = 1;
        @(posedge clk);
        @(negedge clk);
        epoch_contract_fresh = 0;
        #1;
        if (!shadow_session_active ||
            shadow_active_epoch != 32'h0000a501)
            $fatal(1, "fresh epoch contract did not activate");

        // The live input bus is deliberately mutated after launch.  Both
        // completion outputs must retain only the launch metadata.
        launch(0, 32'h101, 32'h201, 32'h04000400, 0, 2'b10,
            32'h01020304);
        mutate_live_inputs();
        finish_transaction(32'h201);
        expect_completion(2, 0, 32'h101, 32'h201, 32'h04000400, 0,
            2'b10, 32'h01020304);
        expect_credit(2, 0, 32'h101, 32'h201, 32'h04000400, 0,
            2'b10, 32'h01020304);
        if (credit_level != 1)
            $fatal(1, "first retained level %0d", credit_level);

        // Fill the bounded FIFO and hold the head stable for several cycles.
        launch(1, 32'h102, 32'h202, 32'h04000130, 1, 2'b00,
            32'h11111111);
        mutate_live_inputs();
        finish_transaction(32'h202);
        expect_completion(3, 1, 32'h102, 32'h202, 32'h04000130, 1,
            2'b00, 32'h11111111);
        expect_credit(2, 0, 32'h101, 32'h201, 32'h04000400, 0,
            2'b10, 32'h01020304);
        if (credit_level != 2)
            $fatal(1, "FIFO did not fill");
        repeat (4) @(posedge clk);
        expect_credit(2, 0, 32'h101, 32'h201, 32'h04000400, 0,
            2'b10, 32'h01020304);

        // A pop and completion push on the same edge are lossless even while
        // full: source 2 retires, source 3 becomes head, source 4 becomes tail.
        launch(0, 32'h103, 32'h203, 32'h04000404, 0, 2'b01,
            32'h22223333);
        mutate_live_inputs();
        @(negedge clk);
        credit_ready = 1;
        mailbox_completed_fence_sequence = 32'h203;
        mailbox_done = 1;
        @(posedge clk);
        #1;
        if (!completion_valid || completion_source_id != 4 ||
            credit_level != 2 || protocol_error)
            $fatal(1, "simultaneous full pop/push failed");
        @(negedge clk);
        credit_ready = 0;
        mailbox_done = 0;
        mailbox_completed_fence_sequence = 0;
        expect_credit(3, 1, 32'h102, 32'h202, 32'h04000130, 1,
            2'b00, 32'h11111111);
        pop_credit();
        expect_credit(4, 0, 32'h103, 32'h203, 32'h04000404, 0,
            2'b01, 32'h22223333);
        pop_credit();
        #1;
        if (credit_valid || credit_level != 0)
            $fatal(1, "FIFO did not drain");

        repeat (2) @(posedge clk);
        if (completion_count != 3)
            $fatal(1, "completion pulse count %0d", completion_count);
        if (protocol_error || capture_overflow || sequence_exhausted)
            $fatal(1, "valid sequence poisoned tap");

        $display("PASS: mailbox completion tap retains exact metadata and losslessly queues credits");
        $finish;
    end
endmodule
