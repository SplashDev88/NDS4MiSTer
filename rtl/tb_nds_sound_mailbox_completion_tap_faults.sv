module tb_nds_sound_mailbox_completion_tap_faults;
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
    logic [1:0] mailbox_access = 2'b10;
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

    always #5 clk = ~clk;

    nds_sound_mailbox_completion_tap #(
        .CREDIT_DEPTH(2),
        .USE_EXPLICIT_LAUNCH(1'b1)
    ) dut (.*);

    task automatic clear_inputs;
        begin
            shadow_feature_enable = 0;
            transport_quiescent = 1;
            epoch_contract_active = 0;
            epoch_contract_fresh = 0;
            epoch_contract = 0;
            mailbox_explicit_launch = 0;
            mailbox_request = 0;
            mailbox_debug_state = 0;
            mailbox_cpu_arm9 = 0;
            mailbox_elapsed_cycles = 0;
            mailbox_fence_sequence = 0;
            mailbox_address = 0;
            mailbox_read_not_write = 0;
            mailbox_access = 2'b10;
            mailbox_write_data = 0;
            mailbox_done = 0;
            mailbox_completed_fence_sequence = 0;
            credit_ready = 0;
        end
    endtask

    task automatic hard_reset;
        begin
            @(negedge clk);
            reset = 1;
            clear_inputs();
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

    task automatic activate(input logic [31:0] epoch);
        begin
            quarantine();
            shadow_feature_enable = 1;
            epoch_contract_active = 1;
            epoch_contract_fresh = 1;
            epoch_contract = epoch;
            @(posedge clk);
            @(negedge clk);
            epoch_contract_fresh = 0;
            #1;
            if (!shadow_session_active || protocol_error)
                $fatal(1, "valid epoch activation failed");
        end
    endtask

    task automatic pulse_launch(input logic [31:0] fence);
        begin
            @(negedge clk);
            mailbox_fence_sequence = fence;
            mailbox_elapsed_cycles = fence + 1;
            mailbox_address = 32'h04000400 + fence;
            mailbox_write_data = 32'h80000000 | fence;
            mailbox_explicit_launch = 1;
            @(posedge clk);
            @(negedge clk);
            mailbox_explicit_launch = 0;
        end
    endtask

    task automatic pulse_done(input logic [31:0] fence);
        begin
            @(negedge clk);
            mailbox_completed_fence_sequence = fence;
            mailbox_done = 1;
            @(posedge clk);
            @(negedge clk);
            mailbox_done = 0;
            mailbox_completed_fence_sequence = 0;
        end
    endtask

    task automatic expect_fault(input logic [7:0] expected);
        begin
            #1;
            if (!protocol_error || fault_code != expected ||
                completion_valid || credit_valid || credit_level != 0 ||
                owner_active || shadow_session_active)
                $fatal(1,
                    "fault mismatch got error=%b code=%h expected=%h",
                    protocol_error, fault_code, expected);
            repeat (3) @(posedge clk);
            #1;
            if (!protocol_error || fault_code != expected ||
                completion_valid || credit_valid || credit_level != 0 ||
                owner_active || shadow_session_active)
                $fatal(1, "fail-closed state was not sticky");
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // Disabled observer: even ownerless activity cannot fault production.
        @(negedge clk);
        mailbox_done = 1;
        @(posedge clk);
        @(negedge clk);
        mailbox_done = 0;
        #1;
        if (protocol_error)
            $fatal(1, "disabled activity caused a fault");
        if (!generation_desynchronized)
            $fatal(1, "disabled ownerless activity did not mark desync");

        // The same pre-ready activity is terminal once the feature is armed.
        hard_reset();
        shadow_feature_enable = 1;
        pulse_launch(1);
        expect_fault(8'h02);

        // No epoch is accepted without the required low/high quarantine.
        hard_reset();
        shadow_feature_enable = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        epoch_contract = 32'h101;
        @(posedge clk);
        @(negedge clk);
        expect_fault(8'h01);

        // A zero or externally nonfresh epoch is rejected after quarantine.
        hard_reset();
        quarantine();
        shadow_feature_enable = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 0;
        epoch_contract = 32'h102;
        @(posedge clk);
        @(negedge clk);
        expect_fault(8'h01);

        hard_reset();
        quarantine();
        shadow_feature_enable = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        epoch_contract = 0;
        @(posedge clk);
        @(negedge clk);
        expect_fault(8'h01);

        // Completion without a captured owner cannot invent a credit.
        hard_reset();
        activate(32'h201);
        pulse_done(0);
        expect_fault(8'h11);

        // A second launch cannot overwrite retained ownership.
        hard_reset();
        activate(32'h202);
        pulse_launch(3);
        pulse_launch(4);
        expect_fault(8'h10);

        // HPS must complete exactly the posted frontier captured at launch.
        hard_reset();
        activate(32'h203);
        pulse_launch(5);
        pulse_done(6);
        expect_fault(8'h12);

        // Loss or mutation of the exact active epoch closes the gate and
        // discards all retained events.
        hard_reset();
        activate(32'h204);
        pulse_launch(7);
        pulse_done(7);
        if (!credit_valid)
            $fatal(1, "setup credit missing");
        @(negedge clk);
        epoch_contract = 32'h205;
        @(posedge clk);
        @(negedge clk);
        expect_fault(8'h03);

        // The FIFO is bounded.  A third completion without a simultaneous
        // pop poisons the epoch and suppresses every partial record.
        hard_reset();
        activate(32'h206);
        pulse_launch(8);
        pulse_done(8);
        pulse_launch(9);
        pulse_done(9);
        if (credit_level != 2)
            $fatal(1, "overflow setup did not fill FIFO");
        pulse_launch(10);
        pulse_done(10);
        expect_fault(8'h13);
        if (!capture_overflow)
            $fatal(1, "overflow flag was not sticky");

        $display("PASS: mailbox completion tap fails closed on epoch, owner, fence, and FIFO faults");
        $finish;
    end
endmodule
