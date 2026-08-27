module tb_nds_sound_posted_credit_merge_head_cache;
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

    always #5 clk = ~clk;

    nds_sound_posted_credit_merge #(
        .LEDGER_DEPTH(DEPTH)
    ) dut (.*);

    task automatic start_epoch;
        begin
            @(negedge clk);
            shadow_feature_enable = 1;
            transport_quiescent = 0;
            epoch_contract = 32'h5a000001;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_contract_active = 1;
            epoch_contract_fresh = 1;
            @(posedge clk);
            @(negedge clk);
            epoch_contract_fresh = 0;
            #1;
            if (!shadow_session_active || protocol_error)
                $fatal(1, "head-cache epoch did not start");
        end
    endtask

    task automatic post_record(
        input logic [31:0] sequence_value,
        input logic cpu_arm9,
        input logic [31:0] cycles
    );
        begin
            @(negedge clk);
            posted_accept_epoch = shadow_active_epoch;
            posted_accept_cpu_arm9 = cpu_arm9;
            posted_accept_cycles = cycles;
            posted_accept_producer_sequence = sequence_value;
            posted_accept_valid = 1;
            @(posedge clk);
            @(negedge clk);
            posted_accept_valid = 0;
            if (protocol_error)
                $fatal(1, "legal head-cache post failed");
        end
    endtask

    task automatic send_direct(
        input logic [31:0] source,
        input logic [31:0] cycles,
        input logic [31:0] fence
    );
        begin
            @(negedge clk);
            direct_credit_epoch = shadow_active_epoch;
            direct_credit_source_generation = source;
            direct_credit_cpu_arm9 = source[0];
            direct_credit_cycles = cycles;
            direct_credit_kind = 2'b01;
            direct_credit_completed_fence_sequence = fence;
            direct_credit_valid = 1;
            do @(posedge clk); while (!direct_credit_ready);
            @(negedge clk);
            direct_credit_valid = 0;
        end
    endtask

    task automatic require_payload(
        input logic [31:0] ack,
        input logic [1:0] kind,
        input logic [31:0] source,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [31:0] fence
    );
        begin
            while (!merged_credit_valid) @(posedge clk);
            #1;
            if (merged_credit_epoch != shadow_active_epoch ||
                merged_credit_ack_sequence != ack ||
                merged_credit_kind != kind ||
                merged_credit_source_id != source ||
                merged_credit_cpu_arm9 != cpu_arm9 ||
                merged_credit_cycles != cycles ||
                merged_credit_completed_fence_sequence != fence)
                $fatal(1,
                    "head-cache payload mismatch ack=%0d kind=%0d source=%0d cpu=%0d cycles=%0d fence=%0d",
                    merged_credit_ack_sequence, merged_credit_kind,
                    merged_credit_source_id, merged_credit_cpu_arm9,
                    merged_credit_cycles,
                    merged_credit_completed_fence_sequence);
        end
    endtask

    task automatic consume_expected(
        input logic [31:0] ack,
        input logic [1:0] kind,
        input logic [31:0] source,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [31:0] fence
    );
        begin
            require_payload(ack, kind, source, cpu_arm9, cycles, fence);
            @(negedge clk);
            merged_credit_ready = 1;
            @(posedge clk);
            @(negedge clk);
            merged_credit_ready = 0;
        end
    endtask

    task automatic pop_and_capture(
        input logic [31:0] expected_ack,
        input logic [31:0] expected_source,
        input logic expected_cpu,
        input logic [31:0] expected_cycles,
        input logic [31:0] fence,
        input logic [31:0] captured_sequence,
        input logic captured_cpu,
        input logic [31:0] captured_cycles,
        input integer expected_level
    );
        begin
            require_payload(
                expected_ack, 2'b00, expected_source,
                expected_cpu, expected_cycles, fence);
            @(negedge clk);
            posted_accept_epoch = shadow_active_epoch;
            posted_accept_cpu_arm9 = captured_cpu;
            posted_accept_cycles = captured_cycles;
            posted_accept_producer_sequence = captured_sequence;
            posted_accept_valid = 1;
            merged_credit_ready = 1;
            @(posedge clk);
            #1;
            if (ledger_level != expected_level || protocol_error)
                $fatal(1,
                    "simultaneous head pop/capture level=%0d expected=%0d fault=%h",
                    ledger_level, expected_level, fault_code);
            @(negedge clk);
            posted_accept_valid = 0;
            merged_credit_ready = 0;
        end
    endtask

    task automatic capture_and_direct_same_edge(
        input logic [31:0] sequence_value,
        input logic captured_cpu,
        input logic [31:0] captured_cycles,
        input logic [31:0] direct_source,
        input logic [31:0] direct_cycles
    );
        begin
            @(negedge clk);
            posted_accept_epoch = shadow_active_epoch;
            posted_accept_cpu_arm9 = captured_cpu;
            posted_accept_cycles = captured_cycles;
            posted_accept_producer_sequence = sequence_value;
            posted_accept_valid = 1;
            direct_credit_epoch = shadow_active_epoch;
            direct_credit_source_generation = direct_source;
            direct_credit_cpu_arm9 = direct_source[0];
            direct_credit_cycles = direct_cycles;
            direct_credit_kind = 2'b01;
            direct_credit_completed_fence_sequence = sequence_value;
            direct_credit_valid = 1;
            #1;
            if (!direct_credit_ready)
                $fatal(1,
                    "same-edge posted/direct admission was not ready");
            @(posedge clk);
            #1;
            if (protocol_error || !mailbox_pending ||
                ledger_level != 1)
                $fatal(1,
                    "same-edge posted/direct admission failed level=%0d fault=%h",
                    ledger_level, fault_code);
            @(negedge clk);
            posted_accept_valid = 0;
            direct_credit_valid = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        start_epoch();

        // With two retained records, a simultaneous pop/capture must fetch
        // the older second record, not bypass the newly accepted tail.
        post_record(1, 1, 11);
        post_record(2, 0, 22);
        send_direct(32'h100, 44, 1);
        pop_and_capture(1, 1, 1, 11, 1, 3, 1, 33, 2);
        consume_expected(2, 1, 32'h100, 0, 44, 1);

        send_direct(32'h101, 45, 3);
        consume_expected(3, 0, 2, 0, 22, 3);
        consume_expected(4, 0, 3, 1, 33, 3);
        consume_expected(5, 1, 32'h101, 1, 45, 3);

        // With exactly one retained record, simultaneous pop/capture must
        // bypass the new tail into the registered head without a stale read.
        post_record(4, 0, 44);
        send_direct(32'h102, 46, 4);
        pop_and_capture(6, 4, 0, 44, 4, 5, 1, 55, 1);
        consume_expected(7, 1, 32'h102, 0, 46, 4);

        send_direct(32'h103, 47, 5);
        consume_expected(8, 0, 5, 1, 55, 5);
        consume_expected(9, 1, 32'h103, 1, 47, 5);

        // At FULL, read and write pointers coincide. A simultaneous pop and
        // capture must be legal, fetch the older next record, and write the
        // new tail into the vacated slot without raising overflow.
        post_record(6, 0, 66);
        post_record(7, 1, 77);
        post_record(8, 0, 88);
        post_record(9, 1, 99);
        if (ledger_level != DEPTH)
            $fatal(1, "head-cache ledger did not reach FULL");
        send_direct(32'h104, 48, 6);
        pop_and_capture(10, 6, 0, 66, 6, 10, 0, 110, DEPTH);
        consume_expected(11, 1, 32'h104, 0, 48, 6);

        send_direct(32'h105, 49, 10);
        consume_expected(12, 0, 7, 1, 77, 10);
        consume_expected(13, 0, 8, 0, 88, 10);
        consume_expected(14, 0, 9, 1, 99, 10);
        consume_expected(15, 0, 10, 0, 110, 10);
        consume_expected(16, 1, 32'h105, 1, 49, 10);

        // A mailbox completion may be accepted on the exact edge that its
        // final covered post enters an empty ledger. Fence admission must
        // count that capture and cannot depend on a mutually-exclusive pop.
        capture_and_direct_same_edge(11, 1, 121, 32'h106, 50);
        consume_expected(17, 0, 11, 1, 121, 11);
        consume_expected(18, 1, 32'h106, 0, 50, 11);

        @(posedge clk);
        #1;
        if (ledger_level != 0 || mailbox_pending ||
            last_completed_fence_sequence != 11 ||
            capture_overflow || posted_sequence_exhausted ||
            ack_sequence_exhausted || protocol_error ||
            !shadow_session_active)
            $fatal(1, "head-cache final state mismatch");

        $display(
            "PASS: registered posted head preserves empty/deep/FULL/same-edge ordering across simultaneous pop/capture/direct admission");
        $finish;
    end
endmodule
