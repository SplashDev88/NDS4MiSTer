module tb_nds_sound_mailbox_posted_credit_merge;
    localparam integer TAP_DEPTH = 4;
    localparam integer LEDGER_DEPTH = 4;

    logic clk = 0;
    logic reset = 1;
    logic shadow_feature_enable = 0;
    logic transport_quiescent = 1;
    logic epoch_contract_active = 0;
    logic epoch_contract_fresh = 0;
    logic [31:0] epoch_contract = 0;
    logic [31:0] epoch_base_posted_sequence = 0;

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

    logic tap_credit_valid;
    logic tap_credit_ready;
    logic [31:0] tap_credit_epoch;
    logic [31:0] tap_credit_source_generation;
    logic tap_credit_cpu_arm9;
    logic [31:0] tap_credit_elapsed_cycles;
    logic [31:0] tap_credit_completed_fence_sequence;
    logic tap_credit_read_not_write;
    logic [1:0] tap_credit_access;
    logic [31:0] tap_credit_address;
    logic [31:0] tap_credit_write_data;
    logic [$clog2(TAP_DEPTH + 1)-1:0] tap_credit_level;
    logic tap_owner_active;
    logic tap_capture_overflow;
    logic tap_sequence_exhausted;
    logic tap_generation_desynchronized;
    logic tap_protocol_error;
    logic [7:0] tap_fault_code;
    logic tap_shadow_session_active;
    logic [31:0] tap_shadow_active_epoch;
    logic tap_epoch_seed_valid;
    logic [31:0] tap_epoch_next_source_generation;

    logic posted_accept_valid = 0;
    logic [31:0] posted_accept_epoch = 0;
    logic posted_accept_cpu_arm9 = 0;
    logic [31:0] posted_accept_cycles = 0;
    logic [31:0] posted_accept_producer_sequence = 0;
    logic simulation_inject_missing_posted = 0;

    logic merge_shadow_session_active;
    logic [31:0] merge_shadow_active_epoch;
    logic merged_credit_valid;
    logic merged_credit_ready = 0;
    logic [31:0] merged_credit_epoch;
    logic [31:0] merged_credit_ack_sequence;
    logic merged_credit_cpu_arm9;
    logic [31:0] merged_credit_cycles;
    logic [1:0] merged_credit_kind;
    logic [31:0] merged_credit_source_id;
    logic [31:0] merged_credit_completed_fence_sequence;
    logic [$clog2(LEDGER_DEPTH + 1)-1:0] ledger_level;
    logic mailbox_pending;
    logic [31:0] last_completed_fence_sequence;
    logic merge_capture_overflow;
    logic posted_sequence_exhausted;
    logic ack_sequence_exhausted;
    logic merge_protocol_error;
    logic [7:0] merge_fault_code;

    integer completion_pulses = 0;

    always #5 clk = ~clk;
    always @(posedge clk)
        if (!reset && completion_valid)
            completion_pulses <= completion_pulses + 1;

    nds_sound_mailbox_completion_tap #(
        .CREDIT_DEPTH(TAP_DEPTH),
        .USE_EXPLICIT_LAUNCH(1'b1)
    ) tap (
        .clk,
        .reset,
        .shadow_feature_enable,
        .transport_quiescent,
        .epoch_contract_active,
        .epoch_contract_fresh,
        .epoch_contract,
        .shadow_session_active(tap_shadow_session_active),
        .shadow_active_epoch(tap_shadow_active_epoch),
        .epoch_seed_valid(tap_epoch_seed_valid),
        .epoch_next_source_generation(
            tap_epoch_next_source_generation),
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
        .completion_valid,
        .completion_epoch,
        .completion_source_id,
        .completion_cpu_arm9,
        .completion_elapsed_cycles,
        .completion_completed_fence_sequence,
        .completion_read_not_write,
        .completion_access,
        .completion_address,
        .completion_write_data,
        .credit_valid(tap_credit_valid),
        .credit_ready(tap_credit_ready),
        .credit_epoch(tap_credit_epoch),
        .credit_source_generation(tap_credit_source_generation),
        .credit_cpu_arm9(tap_credit_cpu_arm9),
        .credit_elapsed_cycles(tap_credit_elapsed_cycles),
        .credit_completed_fence_sequence(
            tap_credit_completed_fence_sequence),
        .credit_read_not_write(tap_credit_read_not_write),
        .credit_access(tap_credit_access),
        .credit_address(tap_credit_address),
        .credit_write_data(tap_credit_write_data),
        .credit_level(tap_credit_level),
        .owner_active(tap_owner_active),
        .capture_overflow(tap_capture_overflow),
        .sequence_exhausted(tap_sequence_exhausted),
        .generation_desynchronized(tap_generation_desynchronized),
        .protocol_error(tap_protocol_error),
        .fault_code(tap_fault_code)
    );

    nds_sound_posted_credit_merge #(
        .LEDGER_DEPTH(LEDGER_DEPTH)
    ) merge (
        .clk,
        .reset,
        .shadow_feature_enable,
        .transport_quiescent,
        .epoch_contract_active,
        .epoch_contract_fresh,
        .epoch_contract,
        .epoch_base_posted_sequence,
        .shadow_session_active(merge_shadow_session_active),
        .shadow_active_epoch(merge_shadow_active_epoch),
        .posted_accept_valid,
        .posted_accept_epoch,
        .posted_accept_cpu_arm9,
        .posted_accept_cycles,
        .posted_accept_producer_sequence,
        .direct_credit_valid(tap_credit_valid),
        .direct_credit_ready(tap_credit_ready),
        .direct_credit_epoch(tap_credit_epoch),
        .direct_credit_source_generation(
            tap_credit_source_generation),
        .direct_credit_cpu_arm9(tap_credit_cpu_arm9),
        .direct_credit_cycles(tap_credit_elapsed_cycles),
        .direct_credit_kind(2'b01),
        .direct_credit_completed_fence_sequence(
            tap_credit_completed_fence_sequence),
        .simulation_inject_missing_posted,
        .merged_credit_valid,
        .merged_credit_ready,
        .merged_credit_epoch,
        .merged_credit_ack_sequence,
        .merged_credit_cpu_arm9,
        .merged_credit_cycles,
        .merged_credit_kind,
        .merged_credit_source_id,
        .merged_credit_completed_fence_sequence,
        .ledger_level,
        .mailbox_pending,
        .last_completed_fence_sequence,
        .capture_overflow(merge_capture_overflow),
        .posted_sequence_exhausted,
        .ack_sequence_exhausted,
        .protocol_error(merge_protocol_error),
        .fault_code(merge_fault_code)
    );

    task automatic post_record(
        input logic [31:0] posted_sequence,
        input logic cpu_arm9,
        input logic [31:0] cycles
    );
        begin
            @(negedge clk);
            posted_accept_valid = 1;
            posted_accept_epoch = epoch_contract;
            posted_accept_cpu_arm9 = cpu_arm9;
            posted_accept_cycles = cycles;
            posted_accept_producer_sequence = posted_sequence;
            @(posedge clk);
            @(negedge clk);
            posted_accept_valid = 0;
        end
    endtask

    task automatic complete_mailbox(
        input logic [31:0] fence,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [31:0] address
    );
        begin
            @(negedge clk);
            mailbox_cpu_arm9 = cpu_arm9;
            mailbox_elapsed_cycles = cycles;
            mailbox_fence_sequence = fence;
            mailbox_address = address;
            mailbox_read_not_write = 1;
            mailbox_access = 2'b10;
            mailbox_write_data = 0;
            mailbox_explicit_launch = 1;
            @(posedge clk);
            @(negedge clk);
            mailbox_explicit_launch = 0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            mailbox_completed_fence_sequence = fence;
            mailbox_done = 1;
            @(posedge clk);
            @(negedge clk);
            mailbox_done = 0;
        end
    endtask

    task automatic consume(
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
            if (merged_credit_ack_sequence != ack ||
                merged_credit_kind != kind ||
                merged_credit_source_id != source ||
                merged_credit_cpu_arm9 != cpu_arm9 ||
                merged_credit_cycles != cycles ||
                merged_credit_completed_fence_sequence != fence)
                $fatal(1,
                    "tap/merge payload mismatch ack=%h kind=%h source=%h",
                    merged_credit_ack_sequence,
                    merged_credit_kind,
                    merged_credit_source_id);
            @(negedge clk);
            merged_credit_ready = 1;
            @(posedge clk);
            @(negedge clk);
            merged_credit_ready = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        shadow_feature_enable = 1;
        transport_quiescent = 0;
        epoch_contract = 32'h79000001;
        epoch_base_posted_sequence = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        @(posedge clk);
        @(negedge clk);
        epoch_contract_fresh = 0;
        if (!tap_shadow_session_active ||
            !merge_shadow_session_active ||
            tap_shadow_active_epoch != epoch_contract ||
            merge_shadow_active_epoch != epoch_contract)
            $fatal(1, "tap/merge epoch did not start together");

        post_record(1, 1, 11);
        post_record(2, 0, 22);
        complete_mailbox(2, 1, 33, 32'h04000130);

        // The first merge batch remains blocked, yet a second real mailbox
        // completion is still captured in the tap's no-backpressure FIFO.
        post_record(3, 1, 44);
        complete_mailbox(3, 0, 55, 32'hffffffff);
        repeat (2) @(posedge clk);
        #1;
        if (completion_pulses != 2 || tap_credit_level == 0 ||
            !mailbox_pending || tap_protocol_error ||
            merge_protocol_error)
            $fatal(1,
                "tap failed to buffer a later completion behind merge");

        consume(1, 0, 1, 1, 11, 2);
        consume(2, 0, 2, 0, 22, 2);
        consume(3, 1, 1, 1, 33, 2);
        consume(4, 0, 3, 1, 44, 3);
        consume(5, 1, 2, 0, 55, 3);

        repeat (2) @(posedge clk);
        #1;
        if (tap_credit_level != 0 || ledger_level != 0 ||
            mailbox_pending || tap_owner_active ||
            tap_capture_overflow || merge_capture_overflow ||
            tap_sequence_exhausted || posted_sequence_exhausted ||
            ack_sequence_exhausted ||
            tap_generation_desynchronized ||
            tap_protocol_error || merge_protocol_error ||
            last_completed_fence_sequence != 3)
            $fatal(1, "tap/merge final state mismatch");

        $display(
            "PASS: real mailbox tap buffers direct completions while posted ledger emits each covered credit before its mailbox credit");
        $finish;
    end
endmodule
