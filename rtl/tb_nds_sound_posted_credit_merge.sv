module tb_nds_sound_posted_credit_merge;
    localparam integer DEPTH = 8;

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

    integer emitted = 0;

    always #5 clk = ~clk;

    nds_sound_posted_credit_merge #(
        .LEDGER_DEPTH(DEPTH)
    ) dut (.*);

    task automatic start_epoch(
        input logic [31:0] epoch,
        input logic [31:0] base_sequence
    );
        begin
            @(negedge clk);
            shadow_feature_enable = 1;
            transport_quiescent = 0;
            epoch_contract_active = 0;
            epoch_contract_fresh = 0;
            epoch_contract = epoch;
            epoch_base_posted_sequence = base_sequence;
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
                shadow_active_epoch != epoch ||
                last_completed_fence_sequence != base_sequence ||
                protocol_error)
                $fatal(1, "valid epoch did not start");
        end
    endtask

    task automatic post_record(
        input logic [31:0] posted_sequence,
        input logic cpu_arm9,
        input logic [31:0] cycles
    );
        begin
            @(negedge clk);
            posted_accept_epoch = shadow_active_epoch;
            posted_accept_cpu_arm9 = cpu_arm9;
            posted_accept_cycles = cycles;
            posted_accept_producer_sequence = posted_sequence;
            posted_accept_valid = 1;
            @(posedge clk);
            @(negedge clk);
            posted_accept_valid = 0;
            posted_accept_epoch = 0;
            posted_accept_cpu_arm9 = 0;
            posted_accept_cycles = 0;
            posted_accept_producer_sequence = 0;
            #1;
            if (protocol_error)
                $fatal(1, "legal posted record %0d failed",
                    posted_sequence);
        end
    endtask

    task automatic send_direct(
        input logic [31:0] source_generation,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [1:0] kind,
        input logic [31:0] fence
    );
        begin
            @(negedge clk);
            direct_credit_epoch = shadow_active_epoch;
            direct_credit_source_generation = source_generation;
            direct_credit_cpu_arm9 = cpu_arm9;
            direct_credit_cycles = cycles;
            direct_credit_kind = kind;
            direct_credit_completed_fence_sequence = fence;
            direct_credit_valid = 1;
            do @(posedge clk); while (!direct_credit_ready);
            @(negedge clk);
            direct_credit_valid = 0;
            direct_credit_epoch = 0;
            direct_credit_source_generation = 0;
            direct_credit_cpu_arm9 = 0;
            direct_credit_cycles = 0;
            direct_credit_kind = 0;
            direct_credit_completed_fence_sequence = 0;
            #1;
            if (protocol_error)
                $fatal(1, "legal mailbox record %0d failed",
                    source_generation);
        end
    endtask

    task automatic consume_expected(
        input logic [31:0] ack,
        input logic [1:0] kind,
        input logic [31:0] source_id,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [31:0] fence,
        input integer stall_cycles
    );
        integer i;
        logic [162:0] held_payload;
        begin
            merged_credit_ready = 0;
            while (!merged_credit_valid) @(posedge clk);
            #1;
            if (merged_credit_epoch != shadow_active_epoch ||
                merged_credit_ack_sequence != ack ||
                merged_credit_kind != kind ||
                merged_credit_source_id != source_id ||
                merged_credit_cpu_arm9 != cpu_arm9 ||
                merged_credit_cycles != cycles ||
                merged_credit_completed_fence_sequence != fence)
                $fatal(1,
                    "merged payload mismatch ack=%h kind=%h source=%h cpu=%b cycles=%h fence=%h",
                    merged_credit_ack_sequence, merged_credit_kind,
                    merged_credit_source_id, merged_credit_cpu_arm9,
                    merged_credit_cycles,
                    merged_credit_completed_fence_sequence);
            held_payload = {
                merged_credit_epoch,
                merged_credit_ack_sequence,
                merged_credit_kind,
                merged_credit_source_id,
                merged_credit_cpu_arm9,
                merged_credit_cycles,
                merged_credit_completed_fence_sequence
            };
            for (i = 0; i < stall_cycles; i = i + 1) begin
                @(posedge clk);
                #1;
                if (!merged_credit_valid ||
                    {
                        merged_credit_epoch,
                        merged_credit_ack_sequence,
                        merged_credit_kind,
                        merged_credit_source_id,
                        merged_credit_cpu_arm9,
                        merged_credit_cycles,
                        merged_credit_completed_fence_sequence
                    } != held_payload)
                    $fatal(1, "merged payload mutated while stalled");
            end
            @(negedge clk);
            merged_credit_ready = 1;
            @(posedge clk);
            emitted = emitted + 1;
            @(negedge clk);
            merged_credit_ready = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        start_epoch(32'h55000001, 0);

        // Retain a delayed three-entry posted batch.  CPU identity and cycle
        // credit are the exact ring-latched values, not the later live bus.
        post_record(1, 1, 11);
        post_record(2, 0, 22);
        post_record(3, 1, 33);
        if (ledger_level != 3 || last_completed_fence_sequence != 0)
            $fatal(1, "delayed posted batch was not retained");

        // Fence two releases exactly posted 1, posted 2, then this mailbox.
        send_direct(32'h100, 0, 44, 2'b01, 2);

        // Later posted accepts may arrive while the current mailbox batch is
        // blocked.  They must not enter ahead of its direct completion.
        post_record(4, 0, 55);
        post_record(5, 1, 66);
        if (ledger_level != 5)
            $fatal(1, "concurrent later posted entries were not retained");

        consume_expected(1, 0, 1, 1, 11, 2, 7);
        consume_expected(2, 0, 2, 0, 22, 2, 1);
        consume_expected(3, 1, 32'h100, 0, 44, 2, 9);
        if (ledger_level != 3 ||
            last_completed_fence_sequence != 2 || mailbox_pending)
            $fatal(1, "first fenced batch did not retire exactly");

        // A distinct mailbox transaction may repeat the same completed fence.
        // It emits only itself; posted 1/2 must never be duplicated.
        send_direct(32'h101, 1, 0, 2'b10, 2);
        consume_expected(4, 2, 32'h101, 1, 0, 2, 3);
        if (ledger_level != 3 ||
            last_completed_fence_sequence != 2)
            $fatal(1, "duplicate fence duplicated a posted credit");

        // The next fence jump releases the remaining interleaved-CPU batch
        // before the ordinary mailbox transaction.
        send_direct(32'h102, 1, 77, 2'b01, 5);
        consume_expected(5, 0, 3, 1, 33, 5, 2);
        consume_expected(6, 0, 4, 0, 55, 5, 4);
        consume_expected(7, 0, 5, 1, 66, 5, 0);
        consume_expected(8, 1, 32'h102, 1, 77, 5, 11);

        @(posedge clk);
        #1;
        if (emitted != 8 || ledger_level != 0 || mailbox_pending ||
            last_completed_fence_sequence != 5 ||
            capture_overflow || posted_sequence_exhausted ||
            ack_sequence_exhausted || protocol_error ||
            !shadow_session_active)
            $fatal(1, "final ordered-merge state mismatch");

        $display(
            "PASS: delayed/batched/duplicate fences emit every interleaved-CPU posted credit exactly once before its direct mailbox credit");
        $finish;
    end
endmodule
