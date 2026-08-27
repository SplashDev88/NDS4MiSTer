module tb_nds_sound_posted_credit_merge_faults;
    localparam integer DEPTH = 2;

    logic clk = 0;
    logic reset = 1;
    logic shadow_feature_enable = 0;
    logic transport_quiescent = 1;
    logic epoch_contract_active = 0;
    logic epoch_contract_fresh = 0;
    logic [31:0] epoch_contract = 0;
    logic [31:0] epoch_base_posted_sequence = 0;
    logic shadow_session_active;
    logic [31:0] shadow_active_epoch;
    logic posted_accept_valid = 0;
    logic [31:0] posted_accept_epoch = 0;
    logic posted_accept_cpu_arm9 = 0;
    logic [31:0] posted_accept_cycles = 0;
    logic [31:0] posted_accept_producer_sequence = 0;
    logic direct_credit_valid = 0;
    logic direct_credit_ready;
    logic [31:0] direct_credit_epoch = 0;
    logic [31:0] direct_credit_source_generation = 0;
    logic direct_credit_cpu_arm9 = 0;
    logic [31:0] direct_credit_cycles = 0;
    logic [1:0] direct_credit_kind = 0;
    logic [31:0] direct_credit_completed_fence_sequence = 0;
    logic simulation_inject_missing_posted = 0;
    logic merged_credit_valid;
    logic merged_credit_ready = 0;
    logic [31:0] merged_credit_epoch;
    logic [31:0] merged_credit_ack_sequence;
    logic merged_credit_cpu_arm9;
    logic [31:0] merged_credit_cycles;
    logic [1:0] merged_credit_kind;
    logic [31:0] merged_credit_source_id;
    logic [31:0] merged_credit_completed_fence_sequence;
    logic [$clog2(DEPTH + 1)-1:0] ledger_level;
    logic mailbox_pending;
    logic [31:0] last_completed_fence_sequence;
    logic capture_overflow;
    logic posted_sequence_exhausted;
    logic ack_sequence_exhausted;
    logic protocol_error;
    logic [7:0] fault_code;

    integer epoch_counter = 0;
    integer fault_cases = 0;

    always #5 clk = ~clk;

    nds_sound_posted_credit_merge #(
        .LEDGER_DEPTH(DEPTH)
    ) dut (.*);

    task automatic clear_inputs;
        begin
            shadow_feature_enable = 0;
            transport_quiescent = 1;
            epoch_contract_active = 0;
            epoch_contract_fresh = 0;
            epoch_contract = 0;
            epoch_base_posted_sequence = 0;
            posted_accept_valid = 0;
            posted_accept_epoch = 0;
            posted_accept_cpu_arm9 = 0;
            posted_accept_cycles = 0;
            posted_accept_producer_sequence = 0;
            direct_credit_valid = 0;
            direct_credit_epoch = 0;
            direct_credit_source_generation = 0;
            direct_credit_cpu_arm9 = 0;
            direct_credit_cycles = 0;
            direct_credit_kind = 0;
            direct_credit_completed_fence_sequence = 0;
            simulation_inject_missing_posted = 0;
            merged_credit_ready = 0;
        end
    endtask

    task automatic hard_reset;
        begin
            @(negedge clk);
            clear_inputs();
            reset = 1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    task automatic start_epoch(input logic [31:0] base_sequence);
        begin
            epoch_counter = epoch_counter + 1;
            @(negedge clk);
            shadow_feature_enable = 1;
            transport_quiescent = 0;
            epoch_contract = 32'h66000000 + epoch_counter;
            epoch_contract_active = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_contract_active = 1;
            epoch_contract_fresh = 1;
            epoch_base_posted_sequence = base_sequence;
            @(posedge clk);
            @(negedge clk);
            epoch_contract_fresh = 0;
            #1;
            if (!shadow_session_active || protocol_error)
                $fatal(1, "fault-test epoch failed to start");
        end
    endtask

    task automatic post_raw(
        input logic [31:0] epoch,
        input logic [31:0] posted_sequence
    );
        begin
            @(negedge clk);
            posted_accept_epoch = epoch;
            posted_accept_cpu_arm9 = posted_sequence[0];
            posted_accept_cycles = posted_sequence + 32'h100;
            posted_accept_producer_sequence = posted_sequence;
            posted_accept_valid = 1;
            @(posedge clk);
            @(negedge clk);
            posted_accept_valid = 0;
        end
    endtask

    task automatic direct_raw(
        input logic [31:0] epoch,
        input logic [31:0] source_generation,
        input logic [1:0] kind,
        input logic [31:0] fence
    );
        begin
            @(negedge clk);
            direct_credit_epoch = epoch;
            direct_credit_source_generation = source_generation;
            direct_credit_cpu_arm9 = source_generation[0];
            direct_credit_cycles = source_generation + 32'h200;
            direct_credit_kind = kind;
            direct_credit_completed_fence_sequence = fence;
            direct_credit_valid = 1;
            do @(posedge clk); while (!direct_credit_ready);
            @(negedge clk);
            direct_credit_valid = 0;
        end
    endtask

    task automatic drain_all;
        begin
            @(negedge clk);
            merged_credit_ready = 1;
            while (mailbox_pending || merged_credit_valid) @(posedge clk);
            @(negedge clk);
            merged_credit_ready = 0;
        end
    endtask

    task automatic require_fault(
        input logic [7:0] expected_code,
        input logic expected_overflow,
        input [8*72-1:0] label
    );
        begin
            #1;
            if (!protocol_error || shadow_session_active ||
                direct_credit_ready || merged_credit_valid ||
                mailbox_pending || ledger_level != 0 ||
                fault_code != expected_code ||
                capture_overflow != expected_overflow)
                $fatal(1,
                    "%0s did not fail closed code=%h overflow=%b active=%b level=%0d",
                    label, fault_code, capture_overflow,
                    shadow_session_active, ledger_level);
            repeat (3) begin
                @(posedge clk);
                #1;
                if (!protocol_error || fault_code != expected_code ||
                    capture_overflow != expected_overflow ||
                    shadow_session_active || merged_credit_valid ||
                    mailbox_pending || ledger_level != 0)
                    $fatal(1,
                        "%0s first fault was not sticky code=%h",
                        label, fault_code);
            end
            fault_cases = fault_cases + 1;
            clear_inputs();
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);

        // High quiescent alone is not a valid fresh-session boundary.
        hard_reset();
        @(negedge clk);
        shadow_feature_enable = 1;
        transport_quiescent = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        epoch_contract = 32'h66000001;
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h01, 0, "epoch without low/high quarantine");

        // Activity while an enabled observer lacks an epoch is fatal.
        hard_reset();
        @(negedge clk);
        shadow_feature_enable = 1;
        posted_accept_valid = 1;
        posted_accept_epoch = 32'h1;
        posted_accept_producer_sequence = 1;
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h02, 0, "posted activity before epoch");

        hard_reset();
        start_epoch(0);
        post_raw(shadow_active_epoch ^ 1, 1);
        require_fault(8'h10, 0, "stale posted epoch");

        hard_reset();
        start_epoch(0);
        post_raw(shadow_active_epoch, 2);
        require_fault(8'h10, 0, "posted sequence gap");

        // No ready exists on the passive posted observer: overflow is sticky
        // and closes the shadow without touching the producer.
        hard_reset();
        start_epoch(0);
        post_raw(shadow_active_epoch, 1);
        post_raw(shadow_active_epoch, 2);
        post_raw(shadow_active_epoch, 3);
        require_fault(8'h11, 1, "bounded posted ledger overflow");

        hard_reset();
        start_epoch(0);
        direct_raw(shadow_active_epoch ^ 1, 1, 1, 0);
        require_fault(8'h12, 0, "stale direct epoch");

        hard_reset();
        start_epoch(0);
        direct_raw(shadow_active_epoch, 1, 0, 0);
        require_fault(8'h12, 0, "posted kind on direct input");

        hard_reset();
        start_epoch(0);
        direct_raw(shadow_active_epoch, 1, 1, 1);
        require_fault(8'h13, 0, "future completed fence");

        // Repeating the same fence is legal only as a new mailbox source.
        // Reusing a source generation would duplicate the direct record.
        hard_reset();
        start_epoch(0);
        direct_raw(shadow_active_epoch, 16, 1, 0);
        drain_all();
        direct_raw(shadow_active_epoch, 16, 1, 0);
        require_fault(8'h12, 0, "duplicate direct source generation");

        // A completed fence may not move backward.
        hard_reset();
        start_epoch(0);
        post_raw(shadow_active_epoch, 1);
        direct_raw(shadow_active_epoch, 16, 1, 1);
        drain_all();
        direct_raw(shadow_active_epoch, 17, 1, 0);
        require_fault(8'h13, 0, "backward completed fence");

        // Contract loss invalidates a retained batch immediately.
        hard_reset();
        start_epoch(0);
        post_raw(shadow_active_epoch, 1);
        direct_raw(shadow_active_epoch, 16, 1, 1);
        @(negedge clk);
        epoch_contract_active = 0;
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h03, 0, "epoch contract loss");

        // Corrupting the otherwise contiguous retained head demonstrates the
        // independent fail-closed missing-record check.
        hard_reset();
        start_epoch(0);
        post_raw(shadow_active_epoch, 1);
        direct_raw(shadow_active_epoch, 16, 1, 1);
        simulation_inject_missing_posted = 1;
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h14, 0, "missing covered posted sequence");

        // The nonwrapping ABI permits the terminal value exactly once but
        // rejects sequence-zero aliasing afterward.
        hard_reset();
        start_epoch(32'hfffffffe);
        post_raw(shadow_active_epoch, 32'hffffffff);
        #1;
        if (!posted_sequence_exhausted || protocol_error)
            $fatal(1, "terminal posted sequence was not accepted once");
        post_raw(shadow_active_epoch, 0);
        require_fault(8'h10, 0, "posted sequence wrap to reserved zero");

        if (fault_cases != 13)
            $fatal(1, "fault coverage count %0d", fault_cases);
        $display(
            "PASS: 13 posted-credit merge epoch/order/overflow/duplicate/wrap failures close the shadow without producer backpressure");
        $finish;
    end
endmodule
