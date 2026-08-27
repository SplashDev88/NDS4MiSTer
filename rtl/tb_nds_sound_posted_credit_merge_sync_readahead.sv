module tb_nds_sound_posted_credit_merge_sync_readahead;
    // Depth three deliberately makes rptr+3 wrap onto the FULL write pointer.
    // Sustained pop/capture therefore exercises the synchronous-read
    // write-forward collision on every retirement.
    localparam integer DEPTH = 3;

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

    integer expected_ack;
    logic [32:0] protected_payload;

    always #5 clk = ~clk;

    nds_sound_posted_credit_merge #(
        .LEDGER_DEPTH(DEPTH)
    ) dut (.*);

    function automatic logic [31:0] cycles_for_post(
        input logic [31:0] sequence_value
    );
        cycles_for_post = 32'h01000000 + sequence_value * 17;
    endfunction

    function automatic logic [31:0] cycles_for_direct(
        input logic [31:0] source_value
    );
        cycles_for_direct = 32'h02000000 + source_value;
    endfunction

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

    task automatic reset_dut;
        begin
            @(negedge clk);
            clear_inputs();
            reset = 1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    task automatic start_epoch(input logic [31:0] epoch_value);
        begin
            shadow_feature_enable = 1;
            transport_quiescent = 0;
            epoch_contract = epoch_value;
            epoch_base_posted_sequence = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_contract_active = 1;
            epoch_contract_fresh = 1;
            @(posedge clk);
            @(negedge clk);
            epoch_contract_fresh = 0;
            #1;
            if (!shadow_session_active ||
                shadow_active_epoch != epoch_value ||
                protocol_error)
                $fatal(1, "synchronous-read-ahead epoch did not start");
            expected_ack = 1;
        end
    endtask

    task automatic post_one(input logic [31:0] sequence_value);
        begin
            @(negedge clk);
            posted_accept_valid = 1;
            posted_accept_epoch = shadow_active_epoch;
            posted_accept_cpu_arm9 = sequence_value[0];
            posted_accept_cycles = cycles_for_post(sequence_value);
            posted_accept_producer_sequence = sequence_value;
            @(posedge clk);
            @(negedge clk);
            posted_accept_valid = 0;
            #1;
            if (protocol_error)
                $fatal(1, "legal post %0d failed", sequence_value);
        end
    endtask

    task automatic fill_three(input logic [31:0] first_sequence);
        integer offset;
        begin
            for (offset = 0; offset < DEPTH; offset = offset + 1)
                post_one(first_sequence + offset);
            if (ledger_level != DEPTH)
                $fatal(1, "ledger did not reach FULL");
        end
    endtask

    task automatic send_direct(
        input logic [31:0] source_value,
        input logic [31:0] fence_value
    );
        begin
            @(negedge clk);
            direct_credit_valid = 1;
            direct_credit_epoch = shadow_active_epoch;
            direct_credit_source_generation = source_value;
            direct_credit_cpu_arm9 = source_value[0];
            direct_credit_cycles = cycles_for_direct(source_value);
            direct_credit_kind = 2'b01;
            direct_credit_completed_fence_sequence = fence_value;
            #1;
            if (!direct_credit_ready)
                $fatal(1, "legal direct record was not ready");
            @(posedge clk);
            @(negedge clk);
            direct_credit_valid = 0;
            #1;
            if (!mailbox_pending || protocol_error)
                $fatal(1, "legal direct record was not retained");
        end
    endtask

    task automatic check_output(
        input logic [31:0] ack_value,
        input logic [1:0] kind_value,
        input logic [31:0] source_value,
        input logic cpu_value,
        input logic [31:0] cycles_value,
        input logic [31:0] fence_value
    );
        begin
            if (!merged_credit_valid ||
                merged_credit_epoch != shadow_active_epoch ||
                merged_credit_ack_sequence != ack_value ||
                merged_credit_kind != kind_value ||
                merged_credit_source_id != source_value ||
                merged_credit_cpu_arm9 != cpu_value ||
                merged_credit_cycles != cycles_value ||
                merged_credit_completed_fence_sequence != fence_value)
                $fatal(1,
                    "output mismatch valid=%0d ack=%0d/%0d kind=%0d/%0d source=%0d/%0d cpu=%0d/%0d cycles=%h/%h fence=%0d/%0d",
                    merged_credit_valid,
                    merged_credit_ack_sequence, ack_value,
                    merged_credit_kind, kind_value,
                    merged_credit_source_id, source_value,
                    merged_credit_cpu_arm9, cpu_value,
                    merged_credit_cycles, cycles_value,
                    merged_credit_completed_fence_sequence, fence_value);
        end
    endtask

    task automatic drain_full_with_replacement(
        input logic [31:0] first_source_post,
        input logic [31:0] first_replacement_post,
        input logic [31:0] direct_source,
        input logic [31:0] fence_value
    );
        integer offset;
        logic [31:0] source_post;
        logic [31:0] replacement_post;
        begin
            for (offset = 0; offset < DEPTH; offset = offset + 1) begin
                source_post = first_source_post + offset;
                replacement_post = first_replacement_post + offset;
                @(negedge clk);
                posted_accept_valid = 1;
                posted_accept_epoch = shadow_active_epoch;
                posted_accept_cpu_arm9 = replacement_post[0];
                posted_accept_cycles = cycles_for_post(replacement_post);
                posted_accept_producer_sequence = replacement_post;
                merged_credit_ready = 1;
                #1;
                check_output(
                    expected_ack, 2'b00, source_post,
                    source_post[0], cycles_for_post(source_post),
                    fence_value);
                @(posedge clk);
                #1;
                expected_ack = expected_ack + 1;
                if (ledger_level != DEPTH || protocol_error)
                    $fatal(1,
                        "FULL pop/capture failed level=%0d fault=%h",
                        ledger_level, fault_code);
                if (!merged_credit_valid)
                    $fatal(1,
                        "bubble after sustained FULL posted retirement");
            end

            @(negedge clk);
            posted_accept_valid = 0;
            #1;
            check_output(
                expected_ack, 2'b01, direct_source,
                direct_source[0], cycles_for_direct(direct_source),
                fence_value);
            @(posedge clk);
            #1;
            expected_ack = expected_ack + 1;
            if (merged_credit_valid || mailbox_pending ||
                ledger_level != DEPTH || protocol_error)
                $fatal(1,
                    "direct tail did not retire after no-bubble replacement");
            @(negedge clk);
            merged_credit_ready = 0;
        end
    endtask

    task automatic drain_full_without_replacement(
        input logic [31:0] first_source_post,
        input logic [31:0] direct_source,
        input logic [31:0] fence_value
    );
        integer offset;
        logic [31:0] source_post;
        begin
            for (offset = 0; offset < DEPTH; offset = offset + 1) begin
                source_post = first_source_post + offset;
                @(negedge clk);
                posted_accept_valid = 0;
                merged_credit_ready = 1;
                #1;
                check_output(
                    expected_ack, 2'b00, source_post,
                    source_post[0], cycles_for_post(source_post),
                    fence_value);
                @(posedge clk);
                #1;
                expected_ack = expected_ack + 1;
                if (protocol_error)
                    $fatal(1, "ordinary no-bubble drain faulted");
                if (!merged_credit_valid)
                    $fatal(1, "bubble during synchronous-RAM drain");
            end

            @(negedge clk);
            #1;
            check_output(
                expected_ack, 2'b01, direct_source,
                direct_source[0], cycles_for_direct(direct_source),
                fence_value);
            @(posedge clk);
            #1;
            expected_ack = expected_ack + 1;
            if (merged_credit_valid || mailbox_pending ||
                ledger_level != 0 || protocol_error)
                $fatal(1, "final direct/ledger state mismatch");
            @(negedge clk);
            merged_credit_ready = 0;
        end
    endtask

    initial begin
        // Two complete cycles exercise fill, synchronous third-entry forwarding,
        // FULL write/read collision on every pop, pointer wrap, and contiguous
        // posted-then-direct output with ready held high.
        reset_dut();
        start_epoch(32'h5b000001);

        fill_three(1);
        send_direct(32'h100, 3);
        drain_full_with_replacement(1, 4, 32'h100, 3);
        send_direct(32'h101, 6);
        drain_full_without_replacement(4, 32'h101, 6);

        fill_three(7);
        send_direct(32'h102, 9);
        drain_full_with_replacement(7, 10, 32'h102, 9);
        send_direct(32'h103, 12);
        drain_full_without_replacement(10, 32'h103, 12);

        if (last_completed_fence_sequence != 12 ||
            capture_overflow || posted_sequence_exhausted ||
            ack_sequence_exhausted || protocol_error)
            $fatal(1, "final synchronous-read-ahead state mismatch");

        // The final replacement batch left sequence ten in physical slot zero.
        // A malformed sequence targets that same next-write slot after reset
        // but must not assert the M10K write enable.
        protected_payload = dut.posted_payload_fifo[0];
        if (protected_payload !== {1'b0, cycles_for_post(10)})
            $fatal(1, "known protected RAM payload was not sequence ten");
        reset_dut();
        start_epoch(32'h5b000002);
        @(negedge clk);
        posted_accept_valid = 1;
        posted_accept_epoch = shadow_active_epoch;
        posted_accept_cpu_arm9 = 1;
        posted_accept_cycles = 32'hdeadc0de;
        posted_accept_producer_sequence = 2;
        @(posedge clk);
        #1;
        if (!protocol_error || fault_code != 8'h10 ||
            dut.posted_payload_fifo[0] !== protected_payload)
            $fatal(1,
                "sequence-invalid capture modified RAM or wrong fault=%h",
                fault_code);

        // FULL without a simultaneous pop is rejected and leaves the wrapped
        // write slot untouched.
        reset_dut();
        start_epoch(32'h5b000003);
        fill_three(1);
        protected_payload = dut.posted_payload_fifo[0];
        if (protected_payload !== {1'b1, cycles_for_post(1)})
            $fatal(1, "known FULL protected RAM payload was not sequence one");
        @(negedge clk);
        posted_accept_valid = 1;
        posted_accept_epoch = shadow_active_epoch;
        posted_accept_cpu_arm9 = 0;
        posted_accept_cycles = 32'hbad0f10f;
        posted_accept_producer_sequence = 4;
        merged_credit_ready = 0;
        @(posedge clk);
        #1;
        if (!protocol_error || fault_code != 8'h11 ||
            !capture_overflow ||
            dut.posted_payload_fifo[0] !== protected_payload)
            $fatal(1,
                "FULL overflow modified RAM or wrong fault=%h",
                fault_code);

        // An invalid direct record is accepted exactly once on its detecting
        // edge so it cannot deadlock as an ordinary stall.  The sticky poison
        // prevents any later fire or fault-code overwrite.
        reset_dut();
        start_epoch(32'h5b000004);
        @(negedge clk);
        direct_credit_valid = 1;
        direct_credit_epoch = shadow_active_epoch;
        direct_credit_source_generation = 32'h100;
        direct_credit_cpu_arm9 = 0;
        direct_credit_cycles = 32'h4444;
        direct_credit_kind = 2'b11;
        // Also violates fence order.  DIRECT_RECORD has defined priority
        // when multiple faults first arrive together, and must remain sticky.
        direct_credit_completed_fence_sequence = 1;
        #1;
        if (!direct_credit_ready)
            $fatal(1, "invalid direct was not accepted for fail-closed");
        @(posedge clk);
        #1;
        if (!protocol_error || fault_code != 8'h12 ||
            direct_credit_ready || mailbox_pending ||
            !dut.mailbox_pending_state ||
            dut.last_direct_source_generation != 32'h100)
            $fatal(1,
                "invalid direct detecting edge was not isolated code=%h",
                fault_code);
        direct_credit_source_generation = 32'h101;
        epoch_contract = 32'hffffffff;
        @(posedge clk);
        #1;
        if (fault_code != 8'h12 || direct_credit_ready ||
            dut.mailbox_pending_state ||
            dut.last_direct_source_generation != 32'h100)
            $fatal(1,
                "invalid direct fired twice or first fault was overwritten");

        // A live nonempty ledger and retained mailbox are immediately hidden on
        // the detecting fault edge, while the bulk state is intentionally
        // cleared one edge later from the registered poison.
        reset_dut();
        start_epoch(32'h5b000005);
        fill_three(1);
        send_direct(32'h100, 3);
        if (!merged_credit_valid || merged_credit_ready)
            $fatal(1,
                "fault-mask test did not begin with a stalled valid credit");
        @(negedge clk);
        shadow_feature_enable = 0;
        @(posedge clk);
        #1;
        if (!protocol_error || fault_code != 8'h03 ||
            shadow_session_active || shadow_active_epoch != 0 ||
            mailbox_pending || ledger_level != 0 ||
            merged_credit_valid || direct_credit_ready)
            $fatal(1,
                "fault edge was not immediately masked code=%h", fault_code);
        if (!dut.shadow_session_active_state ||
            !dut.mailbox_pending_state ||
            dut.posted_level != DEPTH)
            $fatal(1,
                "raw fault drove bulk state instead of sticky boundary");
        @(posedge clk);
        #1;
        if (dut.shadow_session_active_state ||
            dut.mailbox_pending_state || dut.posted_level != 0)
            $fatal(1,
                "registered poison did not clear bulk state one edge later");
        repeat (2) @(posedge clk);
        #1;
        if (!protocol_error || fault_code != 8'h03)
            $fatal(1, "first fault was not sticky");

        // Activity on the epoch-start edge is explicitly rejected.  The
        // composition's epoch_request_ready contract guarantees this does not
        // occur in the functional integration.
        reset_dut();
        shadow_feature_enable = 1;
        transport_quiescent = 0;
        epoch_contract = 32'h5b000006;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        posted_accept_valid = 1;
        posted_accept_epoch = epoch_contract;
        posted_accept_cpu_arm9 = 1;
        posted_accept_cycles = 32'h1234;
        posted_accept_producer_sequence = 1;
        @(posedge clk);
        #1;
        if (!protocol_error || fault_code != 8'h02 ||
            shadow_session_active || ledger_level != 0 ||
            merged_credit_valid || direct_credit_ready)
            $fatal(1,
                "same-edge epoch activity was not rejected code=%h",
                fault_code);
        if (!dut.shadow_session_active_state ||
            dut.last_accepted_posted_sequence != 0)
            $fatal(1,
                "epoch-edge record was silently admitted or start state missing");
        @(posedge clk);
        #1;
        if (dut.shadow_session_active_state ||
            dut.posted_level != 0 || fault_code != 8'h02)
            $fatal(1,
                "epoch-edge fault cleanup/first-fault retention failed");

        $display(
            "PASS: packed synchronous read-ahead survives FULL collisions, wrap, sustained no-bubble pop/capture, and registered fail-closed isolation");
        $finish;
    end
endmodule
