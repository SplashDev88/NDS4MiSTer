// Passive, no-backpressure completion observer for the simulator-only sound
// shadow.
//
// The HPS mailbox owns transaction completion.  Request metadata is captured
// exactly once when the mailbox leaves IDLE (or from an explicitly supplied
// launch pulse), then released only when mailbox_done reports the matching
// response+IRQ completion.  Live request inputs are never consulted again.
//
// Every qualified mailbox completion has two simultaneous effects:
//   * a one-cycle, non-backpressured completion pulse suitable for
//     nds_sound_write_order_queue; and
//   * a retained ready/valid credit record for a later global ACK sequencer.
//
// The source generation counter mirrors nds_hps_oracle_mailbox from the same
// reset and observes launches even while the sound shadow is disabled.  This
// is required because the sound epoch may begin after ordinary mailbox
// traffic has already occurred.
//
// `epoch_contract_active/epoch_contract` are the exact active outputs of a
// validated sound epoch coordinator.  `epoch_contract_fresh` must assert on
// the first active cycle; it is the caller's proof that the epoch was never
// reused across FPGA resets.  A low/high transport quarantine must have been
// observed before activation.  Mailbox activity before this contract becomes
// active is fatal only when shadow_feature_enable is asserted.
//
// This block intentionally assigns no global ACK sequence.  In particular,
// completed_fence_sequence names the posted-write frontier drained by HPS but
// does not enumerate those posted credits.  A separate bounded posted-credit
// ledger and global merge are required before direct mailbox completion can
// replace the reverse consumed-credit ring.
//
// This module is intentionally absent from the production MiSTer top and QSF.
module nds_sound_mailbox_completion_tap #(
    parameter integer CREDIT_DEPTH = 8,
    parameter logic [31:0] FIRST_SOURCE_GENERATION = 32'd1,
    parameter bit USE_EXPLICIT_LAUNCH = 1'b0,
    parameter logic [3:0] MAILBOX_IDLE_STATE = 4'd0
) (
    input  logic        clk,
    input  logic        reset,

    // Feature/epoch contract.  A disabled observer is passive and cannot
    // poison the production path.
    input  logic        shadow_feature_enable,
    input  logic        transport_quiescent,
    input  logic        epoch_contract_active,
    input  logic        epoch_contract_fresh,
    input  logic [31:0] epoch_contract,
    output logic        shadow_session_active,
    output logic [31:0] shadow_active_epoch,
    // Exact first mailbox/completion source ID for a late-starting consumer.
    // Valid only at an idle, empty, low-to-high-quiesced epoch boundary.
    output logic        epoch_seed_valid,
    output logic [31:0] epoch_next_source_generation,

    // Mailbox launch observation.  Select either an exact external launch
    // pulse or the real mailbox's IDLE+request edge at elaboration time.
    input  logic        mailbox_explicit_launch,
    input  logic        mailbox_request,
    input  logic [3:0]  mailbox_debug_state,
    input  logic        mailbox_cpu_arm9,
    input  logic [31:0] mailbox_elapsed_cycles,
    input  logic [31:0] mailbox_fence_sequence,
    input  logic [31:0] mailbox_address,
    input  logic        mailbox_read_not_write,
    input  logic [1:0]  mailbox_access,
    input  logic [31:0] mailbox_write_data,

    // Authoritative response+IRQ completion from nds_hps_oracle_mailbox.
    input  logic        mailbox_done,
    input  logic [31:0] mailbox_completed_fence_sequence,

    // Non-backpressured pulse.  Field names intentionally match the write
    // ordering queue's completion input seam.
    output logic        completion_valid,
    output logic [31:0] completion_epoch,
    output logic [31:0] completion_source_id,
    output logic        completion_cpu_arm9,
    output logic [31:0] completion_elapsed_cycles,
    output logic [31:0] completion_completed_fence_sequence,
    output logic        completion_read_not_write,
    output logic [1:0]  completion_access,
    output logic [31:0] completion_address,
    output logic [31:0] completion_write_data,

    // Retained mailbox-credit event for a future posted/mailbox global merge.
    output logic        credit_valid,
    input  logic        credit_ready,
    output logic [31:0] credit_epoch,
    output logic [31:0] credit_source_generation,
    output logic        credit_cpu_arm9,
    output logic [31:0] credit_elapsed_cycles,
    output logic [31:0] credit_completed_fence_sequence,
    output logic        credit_read_not_write,
    output logic [1:0]  credit_access,
    output logic [31:0] credit_address,
    output logic [31:0] credit_write_data,
    output logic [$clog2(CREDIT_DEPTH + 1)-1:0] credit_level,

    output logic        owner_active,
    output logic        capture_overflow,
    output logic        sequence_exhausted,
    output logic        generation_desynchronized,
    output logic        protocol_error,
    output logic [7:0]  fault_code
);
    localparam integer POINTER_WIDTH =
        CREDIT_DEPTH <= 1 ? 1 : $clog2(CREDIT_DEPTH);
    localparam integer LEVEL_WIDTH = $clog2(CREDIT_DEPTH + 1);
    localparam logic [POINTER_WIDTH-1:0] LAST_POINTER =
        POINTER_WIDTH'(CREDIT_DEPTH - 1);
    localparam logic [LEVEL_WIDTH-1:0] FULL_LEVEL =
        LEVEL_WIDTH'(CREDIT_DEPTH);

    localparam logic [7:0] FAULT_NONE              = 8'h00;
    localparam logic [7:0] FAULT_EPOCH_CONTRACT    = 8'h01;
    localparam logic [7:0] FAULT_PREMATURE_ACTIVITY= 8'h02;
    localparam logic [7:0] FAULT_EPOCH_ACTIVE_LOSS = 8'h03;
    localparam logic [7:0] FAULT_MULTIPLE_LAUNCH   = 8'h10;
    localparam logic [7:0] FAULT_OWNERLESS_DONE    = 8'h11;
    localparam logic [7:0] FAULT_FENCE_MISMATCH    = 8'h12;
    localparam logic [7:0] FAULT_CREDIT_OVERFLOW   = 8'h13;
    localparam logic [7:0] FAULT_GENERATION        = 8'h14;

    logic quarantine_low_seen;
    logic [31:0] last_active_epoch;
    logic [31:0] next_source_generation;

    logic owner_shadow_qualified;
    logic owner_terminal_generation;
    logic [31:0] owner_epoch;
    logic [31:0] owner_source_generation;
    logic owner_cpu_arm9;
    logic [31:0] owner_elapsed_cycles;
    logic [31:0] owner_fence_sequence;
    logic [31:0] owner_address;
    logic owner_read_not_write;
    logic [1:0] owner_access;
    logic [31:0] owner_write_data;

    logic [31:0] fifo_epoch [0:CREDIT_DEPTH-1];
    logic [31:0] fifo_source [0:CREDIT_DEPTH-1];
    logic fifo_cpu [0:CREDIT_DEPTH-1];
    logic [31:0] fifo_cycles [0:CREDIT_DEPTH-1];
    logic [31:0] fifo_fence [0:CREDIT_DEPTH-1];
    logic fifo_rnw [0:CREDIT_DEPTH-1];
    logic [1:0] fifo_access [0:CREDIT_DEPTH-1];
    logic [31:0] fifo_address [0:CREDIT_DEPTH-1];
    logic [31:0] fifo_data [0:CREDIT_DEPTH-1];
    logic [POINTER_WIDTH-1:0] read_pointer;
    logic [POINTER_WIDTH-1:0] write_pointer;
    logic [LEVEL_WIDTH-1:0] level;
    logic [7:0] fatal_fault_code;

    wire launch_event = USE_EXPLICIT_LAUNCH
        ? mailbox_explicit_launch
        : (mailbox_request && mailbox_debug_state == MAILBOX_IDLE_STATE);
    wire observed_mailbox_activity = launch_event || mailbox_done;

    wire epoch_start_attempt =
        shadow_feature_enable && !shadow_session_active &&
        epoch_contract_active;
    assign epoch_seed_valid =
        !protocol_error && !shadow_session_active &&
        quarantine_low_seen && transport_quiescent &&
        !owner_active && !mailbox_done &&
        level == 0 && !completion_valid &&
        !generation_desynchronized && !sequence_exhausted &&
        next_source_generation != 32'd0;
    assign epoch_next_source_generation =
        epoch_seed_valid ? next_source_generation : 32'd0;
    wire epoch_source_unusable =
        epoch_start_attempt &&
        (generation_desynchronized || sequence_exhausted ||
         next_source_generation == 32'd0);
    wire epoch_start_valid =
        epoch_start_attempt &&
        epoch_contract_fresh &&
        epoch_contract != 32'd0 &&
        epoch_contract != last_active_epoch &&
        quarantine_low_seen && transport_quiescent &&
        !owner_active && !mailbox_done &&
        level == 0 && !completion_valid &&
        !epoch_source_unusable;
    wire effective_session_active =
        shadow_session_active || epoch_start_valid;
    wire [31:0] effective_epoch =
        shadow_session_active ? shadow_active_epoch : epoch_contract;

    wire epoch_contract_error =
        epoch_start_attempt && !epoch_start_valid;
    wire premature_activity =
        shadow_feature_enable && !shadow_session_active &&
        !epoch_start_valid && observed_mailbox_activity;
    wire epoch_active_loss =
        shadow_session_active &&
        (!shadow_feature_enable || !epoch_contract_active ||
         epoch_contract == 32'd0 ||
         epoch_contract != shadow_active_epoch);

    wire qualified_launch =
        launch_event && effective_session_active;
    wire multiple_launch =
        qualified_launch && owner_active;
    wire launch_generation_error =
        qualified_launch &&
        (generation_desynchronized || sequence_exhausted ||
         next_source_generation == 32'd0);

    wire qualified_done =
        mailbox_done && owner_active && owner_shadow_qualified;
    wire ownerless_done =
        mailbox_done && effective_session_active && !owner_active;
    wire unqualified_done =
        mailbox_done && effective_session_active && owner_active &&
        !owner_shadow_qualified;
    wire completed_owner_invalid =
        qualified_done &&
        (owner_epoch == 32'd0 ||
         owner_source_generation == 32'd0 ||
         owner_epoch != effective_epoch);
    wire fence_mismatch =
        qualified_done &&
        mailbox_completed_fence_sequence != owner_fence_sequence;

    assign credit_valid = level != 0 && !protocol_error;
    wire credit_pop = credit_valid && credit_ready;
    wire credit_push =
        qualified_done && !completed_owner_invalid && !fence_mismatch;
    wire credit_overflow =
        credit_push && level == FULL_LEVEL && !credit_pop;

    wire fatal_event =
        epoch_contract_error || epoch_source_unusable ||
        premature_activity || epoch_active_loss ||
        multiple_launch || launch_generation_error ||
        ownerless_done || unqualified_done ||
        completed_owner_invalid || fence_mismatch || credit_overflow;

    always_comb begin
        if (epoch_source_unusable)
            fatal_fault_code = FAULT_GENERATION;
        else if (epoch_contract_error)
            fatal_fault_code = FAULT_EPOCH_CONTRACT;
        else if (premature_activity)
            fatal_fault_code = FAULT_PREMATURE_ACTIVITY;
        else if (epoch_active_loss)
            fatal_fault_code = FAULT_EPOCH_ACTIVE_LOSS;
        else if (multiple_launch)
            fatal_fault_code = FAULT_MULTIPLE_LAUNCH;
        else if (ownerless_done || unqualified_done)
            fatal_fault_code = FAULT_OWNERLESS_DONE;
        else if (fence_mismatch)
            fatal_fault_code = FAULT_FENCE_MISMATCH;
        else if (credit_overflow)
            fatal_fault_code = FAULT_CREDIT_OVERFLOW;
        else if (launch_generation_error || completed_owner_invalid)
            fatal_fault_code = FAULT_GENERATION;
        else
            fatal_fault_code = FAULT_NONE;
    end

    assign credit_level = level;
    assign credit_epoch =
        credit_valid ? fifo_epoch[read_pointer] : 32'd0;
    assign credit_source_generation =
        credit_valid ? fifo_source[read_pointer] : 32'd0;
    assign credit_cpu_arm9 =
        credit_valid ? fifo_cpu[read_pointer] : 1'b0;
    assign credit_elapsed_cycles =
        credit_valid ? fifo_cycles[read_pointer] : 32'd0;
    assign credit_completed_fence_sequence =
        credit_valid ? fifo_fence[read_pointer] : 32'd0;
    assign credit_read_not_write =
        credit_valid ? fifo_rnw[read_pointer] : 1'b0;
    assign credit_access =
        credit_valid ? fifo_access[read_pointer] : 2'd0;
    assign credit_address =
        credit_valid ? fifo_address[read_pointer] : 32'd0;
    assign credit_write_data =
        credit_valid ? fifo_data[read_pointer] : 32'd0;

    function automatic logic [POINTER_WIDTH-1:0] increment_pointer(
        input logic [POINTER_WIDTH-1:0] pointer
    );
        if (pointer == LAST_POINTER)
            increment_pointer = '0;
        else
            increment_pointer = pointer + 1'b1;
    endfunction

    task automatic fail_closed;
        begin
            shadow_session_active <= 1'b0;
            shadow_active_epoch <= 32'd0;
            owner_active <= 1'b0;
            owner_shadow_qualified <= 1'b0;
            level <= '0;
            read_pointer <= '0;
            write_pointer <= '0;
            completion_valid <= 1'b0;
            protocol_error <= 1'b1;
            fault_code <= fatal_fault_code;
            if (credit_overflow)
                capture_overflow <= 1'b1;
        end
    endtask

    always_ff @(posedge clk) begin
        if (reset) begin
            quarantine_low_seen <= 1'b0;
            last_active_epoch <= 32'd0;
            shadow_session_active <= 1'b0;
            shadow_active_epoch <= 32'd0;

            next_source_generation <= FIRST_SOURCE_GENERATION;
            owner_active <= 1'b0;
            owner_shadow_qualified <= 1'b0;
            owner_terminal_generation <= 1'b0;
            owner_epoch <= 32'd0;
            owner_source_generation <= 32'd0;
            owner_cpu_arm9 <= 1'b0;
            owner_elapsed_cycles <= 32'd0;
            owner_fence_sequence <= 32'd0;
            owner_address <= 32'd0;
            owner_read_not_write <= 1'b0;
            owner_access <= 2'd0;
            owner_write_data <= 32'd0;

            read_pointer <= '0;
            write_pointer <= '0;
            level <= '0;

            completion_valid <= 1'b0;
            completion_epoch <= 32'd0;
            completion_source_id <= 32'd0;
            completion_cpu_arm9 <= 1'b0;
            completion_elapsed_cycles <= 32'd0;
            completion_completed_fence_sequence <= 32'd0;
            completion_read_not_write <= 1'b0;
            completion_access <= 2'd0;
            completion_address <= 32'd0;
            completion_write_data <= 32'd0;

            capture_overflow <= 1'b0;
            sequence_exhausted <= 1'b0;
            generation_desynchronized <= 1'b0;
            protocol_error <= 1'b0;
            fault_code <= FAULT_NONE;
        end else begin
            completion_valid <= 1'b0;
            if (!protocol_error) begin
                if (!transport_quiescent)
                    quarantine_low_seen <= 1'b1;

                if (fatal_event) begin
                    fail_closed();
                end else begin
                if (epoch_start_valid) begin
                    shadow_session_active <= 1'b1;
                    shadow_active_epoch <= epoch_contract;
                    last_active_epoch <= epoch_contract;
                    quarantine_low_seen <= 1'b0;
                end

                // Continue mirroring the mailbox generation while disabled.
                // Any impossible handshake makes the mirror unknowable, but
                // it poisons the design only when the shadow is enabled.
                if (launch_event) begin
                    if (owner_active || sequence_exhausted ||
                        next_source_generation == 32'd0) begin
                        if (!effective_session_active)
                            generation_desynchronized <= 1'b1;
                    end else begin
                        owner_active <= 1'b1;
                        owner_shadow_qualified <=
                            effective_session_active;
                        owner_terminal_generation <=
                            next_source_generation == 32'hffffffff;
                        owner_epoch <= effective_session_active
                            ? effective_epoch : 32'd0;
                        owner_source_generation <=
                            next_source_generation;
                        owner_cpu_arm9 <= mailbox_cpu_arm9;
                        owner_elapsed_cycles <= mailbox_elapsed_cycles;
                        owner_fence_sequence <= mailbox_fence_sequence;
                        owner_address <= mailbox_address;
                        owner_read_not_write <=
                            mailbox_read_not_write;
                        owner_access <= mailbox_access;
                        owner_write_data <= mailbox_write_data;
                        if (next_source_generation != 32'hffffffff)
                            next_source_generation <=
                                next_source_generation + 1'b1;
                    end
                end

                if (mailbox_done) begin
                    if (!owner_active) begin
                        if (!effective_session_active)
                            generation_desynchronized <= 1'b1;
                    end else begin
                        owner_active <= 1'b0;
                        owner_shadow_qualified <= 1'b0;
                        if (owner_terminal_generation)
                            sequence_exhausted <= 1'b1;

                        if (mailbox_completed_fence_sequence !=
                            owner_fence_sequence) begin
                            if (!effective_session_active)
                                generation_desynchronized <= 1'b1;
                        end else if (owner_shadow_qualified) begin
                            completion_valid <= 1'b1;
                            completion_epoch <= owner_epoch;
                            completion_source_id <=
                                owner_source_generation;
                            completion_cpu_arm9 <= owner_cpu_arm9;
                            completion_elapsed_cycles <=
                                owner_elapsed_cycles;
                            completion_completed_fence_sequence <=
                                mailbox_completed_fence_sequence;
                            completion_read_not_write <=
                                owner_read_not_write;
                            completion_access <= owner_access;
                            completion_address <= owner_address;
                            completion_write_data <= owner_write_data;

                            fifo_epoch[write_pointer] <= owner_epoch;
                            fifo_source[write_pointer] <=
                                owner_source_generation;
                            fifo_cpu[write_pointer] <= owner_cpu_arm9;
                            fifo_cycles[write_pointer] <=
                                owner_elapsed_cycles;
                            fifo_fence[write_pointer] <=
                                mailbox_completed_fence_sequence;
                            fifo_rnw[write_pointer] <=
                                owner_read_not_write;
                            fifo_access[write_pointer] <= owner_access;
                            fifo_address[write_pointer] <= owner_address;
                            fifo_data[write_pointer] <= owner_write_data;
                            write_pointer <=
                                increment_pointer(write_pointer);

                        end
                    end
                end

                if (credit_pop)
                    read_pointer <= increment_pointer(read_pointer);

                    case ({credit_push, credit_pop})
                        2'b10: level <= level + 1'b1;
                        2'b01: level <= level - 1'b1;
                        default: begin end
                    endcase
                end
            end
        end
    end
endmodule
