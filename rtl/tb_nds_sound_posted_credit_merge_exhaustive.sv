module tb_nds_sound_posted_credit_merge_exhaustive;
    localparam integer DEPTH = 4;

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
    integer expected_ack;
    integer next_expected_post;
    integer next_direct_source;
    integer ready_phase;
    integer cases_run = 0;
    logic [3:0] active_ready_mask;

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
            merged_credit_ready = 0;
        end
    endtask

    task automatic restart_case(input logic [3:0] ready_mask);
        begin
            @(negedge clk);
            clear_inputs();
            reset = 1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            reset = 0;

            epoch_counter = epoch_counter + 1;
            shadow_feature_enable = 1;
            transport_quiescent = 0;
            epoch_contract = 32'h78000000 + epoch_counter;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_contract_active = 1;
            epoch_contract_fresh = 1;
            @(posedge clk);
            @(negedge clk);
            epoch_contract_fresh = 0;
            if (!shadow_session_active || protocol_error)
                $fatal(1, "exhaustive-case epoch start failed");

            active_ready_mask = ready_mask;
            ready_phase = 0;
            expected_ack = 1;
            next_expected_post = 1;
            next_direct_source = 32'h400;
        end
    endtask

    task automatic post_three;
        integer seq;
        begin
            for (seq = 1; seq <= 3; seq = seq + 1) begin
                @(negedge clk);
                posted_accept_valid = 1;
                posted_accept_epoch = shadow_active_epoch;
                posted_accept_cpu_arm9 = seq[0];
                posted_accept_cycles = seq * 10;
                posted_accept_producer_sequence = seq;
                @(posedge clk);
                @(negedge clk);
                posted_accept_valid = 0;
            end
            if (ledger_level != 3 || protocol_error)
                $fatal(1, "exhaustive posted setup failed");
        end
    endtask

    task automatic send_direct(input integer fence);
        logic [1:0] kind;
        begin
            kind = next_direct_source[0] ? 2'b10 : 2'b01;
            @(negedge clk);
            direct_credit_valid = 1;
            direct_credit_epoch = shadow_active_epoch;
            direct_credit_source_generation = next_direct_source;
            direct_credit_cpu_arm9 = next_direct_source[0];
            direct_credit_cycles = next_direct_source + 32'h1000;
            direct_credit_kind = kind;
            direct_credit_completed_fence_sequence = fence;
            do @(posedge clk); while (!direct_credit_ready);
            @(negedge clk);
            direct_credit_valid = 0;
        end
    endtask

    task automatic consume_one(
        input logic [1:0] expected_kind,
        input integer expected_source,
        input logic expected_cpu,
        input integer expected_cycles,
        input integer expected_fence
    );
        logic choose_ready;
        integer watchdog;
        begin : consume_until_handshake
            watchdog = 0;
            while (1) begin
                @(negedge clk);
                // Sweep every 4-cycle ready mask.  Mask zero still makes
                // deterministic progress on the fifth phase.
                choose_ready =
                    active_ready_mask[ready_phase & 3] ||
                    (ready_phase % 5 == 4);
                ready_phase = ready_phase + 1;
                merged_credit_ready = choose_ready;
                @(posedge clk);
                if (merged_credit_valid) begin
                    if (merged_credit_epoch != shadow_active_epoch ||
                        merged_credit_ack_sequence != expected_ack ||
                        merged_credit_kind != expected_kind ||
                        merged_credit_source_id != expected_source ||
                        merged_credit_cpu_arm9 != expected_cpu ||
                        merged_credit_cycles != expected_cycles ||
                        merged_credit_completed_fence_sequence !=
                            expected_fence)
                        $fatal(1,
                            "exhaustive mismatch ack=%0d/%0d kind=%0d/%0d source=%0d/%0d fence=%0d/%0d",
                            merged_credit_ack_sequence, expected_ack,
                            merged_credit_kind, expected_kind,
                            merged_credit_source_id, expected_source,
                            merged_credit_completed_fence_sequence,
                            expected_fence);
                    if (choose_ready) begin
                        expected_ack = expected_ack + 1;
                        @(negedge clk);
                        merged_credit_ready = 0;
                        disable consume_until_handshake;
                    end
                end
                watchdog = watchdog + 1;
                if (watchdog > 40)
                    $fatal(1, "exhaustive ready pattern made no progress");
            end
        end
    endtask

    task automatic drain_direct(input integer fence);
        integer seq;
        logic [1:0] expected_direct_kind;
        begin
            expected_direct_kind =
                next_direct_source[0] ? 2'b10 : 2'b01;
            send_direct(fence);
            for (seq = next_expected_post; seq <= fence; seq = seq + 1)
                consume_one(0, seq, seq[0], seq * 10, fence);
            next_expected_post = fence + 1;
            consume_one(
                expected_direct_kind,
                next_direct_source,
                next_direct_source[0],
                next_direct_source + 32'h1000,
                fence);
            next_direct_source = next_direct_source + 1;
        end
    endtask

    integer checkpoint_mask;
    integer ready_mask;
    integer fence;
    initial begin
        repeat (2) @(posedge clk);

        // Exhaust all 2^3 checkpoint subsets for fences 0/1/2, every one of
        // the 2^4 output-ready masks, and always finish at fence 3.  Each case
        // then repeats fence 3 with a distinct mailbox source to prove the
        // duplicate frontier cannot duplicate a posted credit.
        for (checkpoint_mask = 0;
             checkpoint_mask < 8;
             checkpoint_mask = checkpoint_mask + 1) begin
            for (ready_mask = 0;
                 ready_mask < 16;
                 ready_mask = ready_mask + 1) begin
                restart_case(ready_mask[3:0]);
                post_three();
                for (fence = 0; fence <= 2; fence = fence + 1)
                    if (checkpoint_mask[fence])
                        drain_direct(fence);
                drain_direct(3);
                drain_direct(3);
                @(posedge clk);
                #1;
                if (ledger_level != 0 || mailbox_pending ||
                    last_completed_fence_sequence != 3 ||
                    capture_overflow || posted_sequence_exhausted ||
                    ack_sequence_exhausted || protocol_error ||
                    next_expected_post != 4)
                    $fatal(1,
                        "exhaustive final state mask=%0d ready=%0d",
                        checkpoint_mask, ready_mask);
                cases_run = cases_run + 1;
            end
        end

        if (cases_run != 128)
            $fatal(1, "exhaustive case count %0d", cases_run);
        $display(
            "PASS: exhaustive 128 checkpoint/ready schedules preserve posted-before-mailbox order and exact-once duplicate-fence behavior");
        $finish;
    end
endmodule
