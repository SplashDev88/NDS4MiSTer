module tb_nds_sound_mailbox_completion_tap_terminal;
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
    logic [31:0] mailbox_elapsed_cycles = 32'h1234;
    logic [31:0] mailbox_fence_sequence = 32'h5678;
    logic [31:0] mailbox_address = 32'h04000400;
    logic mailbox_read_not_write = 0;
    logic [1:0] mailbox_access = 2'b10;
    logic [31:0] mailbox_write_data = 32'h87654321;
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

    logic zero_shadow_enable = 0;
    logic zero_epoch_active = 0;
    logic zero_epoch_fresh = 0;
    logic [31:0] zero_epoch = 0;
    logic zero_protocol_error;
    logic [7:0] zero_fault_code;

    always #5 clk = ~clk;

    nds_sound_mailbox_completion_tap #(
        .CREDIT_DEPTH(2),
        .FIRST_SOURCE_GENERATION(32'hffffffff),
        .USE_EXPLICIT_LAUNCH(1'b1)
    ) terminal_dut (.*);

    nds_sound_mailbox_completion_tap #(
        .CREDIT_DEPTH(2),
        .FIRST_SOURCE_GENERATION(32'd0),
        .USE_EXPLICIT_LAUNCH(1'b1)
    ) zero_dut (
        .clk,
        .reset,
        .shadow_feature_enable(zero_shadow_enable),
        .transport_quiescent,
        .epoch_contract_active(zero_epoch_active),
        .epoch_contract_fresh(zero_epoch_fresh),
        .epoch_contract(zero_epoch),
        .shadow_session_active(),
        .shadow_active_epoch(),
        .epoch_seed_valid(),
        .epoch_next_source_generation(),
        .mailbox_explicit_launch,
        .mailbox_request,
        .mailbox_debug_state,
        .mailbox_cpu_arm9,
        .mailbox_elapsed_cycles,
        .mailbox_fence_sequence,
        .mailbox_address,
        .mailbox_read_not_write,
        .mailbox_access,
        .mailbox_write_data,
        .mailbox_done,
        .mailbox_completed_fence_sequence,
        .completion_valid(),
        .completion_epoch(),
        .completion_source_id(),
        .completion_cpu_arm9(),
        .completion_elapsed_cycles(),
        .completion_completed_fence_sequence(),
        .completion_read_not_write(),
        .completion_access(),
        .completion_address(),
        .completion_write_data(),
        .credit_valid(),
        .credit_ready(1'b0),
        .credit_epoch(),
        .credit_source_generation(),
        .credit_cpu_arm9(),
        .credit_elapsed_cycles(),
        .credit_completed_fence_sequence(),
        .credit_read_not_write(),
        .credit_access(),
        .credit_address(),
        .credit_write_data(),
        .credit_level(),
        .owner_active(),
        .capture_overflow(),
        .sequence_exhausted(),
        .generation_desynchronized(),
        .protocol_error(zero_protocol_error),
        .fault_code(zero_fault_code)
    );

    task automatic reset_all;
        begin
            @(negedge clk);
            reset = 1;
            shadow_feature_enable = 0;
            epoch_contract_active = 0;
            epoch_contract_fresh = 0;
            epoch_contract = 0;
            zero_shadow_enable = 0;
            zero_epoch_active = 0;
            zero_epoch_fresh = 0;
            zero_epoch = 0;
            mailbox_explicit_launch = 0;
            mailbox_done = 0;
            mailbox_completed_fence_sequence = 0;
            credit_ready = 0;
            transport_quiescent = 1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    task automatic quarantine;
        begin
            @(negedge clk);
            transport_quiescent = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // A zero initial mailbox generation can never form a valid session.
        quarantine();
        zero_shadow_enable = 1;
        zero_epoch_active = 1;
        zero_epoch_fresh = 1;
        zero_epoch = 32'h4001;
        @(posedge clk);
        @(negedge clk);
        #1;
        if (!zero_protocol_error || zero_fault_code != 8'h14)
            $fatal(1, "zero generation did not fail closed");

        reset_all();
        quarantine();
        shadow_feature_enable = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        epoch_contract = 32'h5001;
        @(posedge clk);
        @(negedge clk);
        epoch_contract_fresh = 0;
        if (!shadow_session_active || protocol_error)
            $fatal(1, "terminal session failed to activate");

        @(negedge clk);
        mailbox_explicit_launch = 1;
        @(posedge clk);
        @(negedge clk);
        mailbox_explicit_launch = 0;
        mailbox_completed_fence_sequence = 32'h5678;
        mailbox_done = 1;
        @(posedge clk);
        #1;
        if (!completion_valid ||
            completion_source_id != 32'hffffffff ||
            !credit_valid ||
            credit_source_generation != 32'hffffffff ||
            !sequence_exhausted || protocol_error)
            $fatal(1, "terminal generation was not delivered exactly once");
        @(negedge clk);
        mailbox_done = 0;
        mailbox_completed_fence_sequence = 0;
        credit_ready = 1;
        @(posedge clk);
        @(negedge clk);
        credit_ready = 0;
        if (credit_valid)
            $fatal(1, "terminal credit did not retire");

        // The next launch would wrap the mailbox generation to zero and must
        // be rejected before it can acquire ownership.
        @(negedge clk);
        mailbox_explicit_launch = 1;
        @(posedge clk);
        @(negedge clk);
        mailbox_explicit_launch = 0;
        #1;
        if (!protocol_error || fault_code != 8'h14 ||
            owner_active || completion_valid || credit_valid)
            $fatal(1, "post-terminal wrap did not fail closed");

        $display("PASS: mailbox completion tap delivers terminal generation and rejects zero/wrap");
        $finish;
    end
endmodule
