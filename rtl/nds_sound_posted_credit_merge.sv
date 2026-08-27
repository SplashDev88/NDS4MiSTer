// Bounded posted-write credit ledger and deterministic direct-mailbox merge
// for the simulator-only Nintendo DS sound shadow.
//
// `posted_accept_valid` is a passive copy of the exact acceptance pulse from
// nds_hps_posted_write_ring.  It has deliberately no ready signal: this
// observer can never stall or otherwise influence the production posted path.
// Every accepted record is retained until an authoritative HPS mailbox
// completion reports a completed fence that covers it.
//
// `direct_credit_*` is a separate retained ready/valid stream sourced by
// nds_sound_mailbox_completion_tap.  For each accepted mailbox completion this
// block emits, in order:
//   1. every not-yet-emitted posted record through the completed fence; then
//   2. the mailbox record itself.
// A new global, nonzero ACK sequence is assigned to each emitted record.
//
// The current posted-ring ABI reserves sequence zero and intentionally does
// not wrap.  Ordering is ordinary unsigned monotonic ordering within one
// externally proven fresh epoch.  0xffffffff may be accepted and retired once;
// a subsequent posted acceptance (including sequence zero) fails closed.
//
// This module is intentionally absent from the production MiSTer top and QSF.
module nds_sound_posted_credit_merge #(
    parameter integer LEDGER_DEPTH = 16,
    parameter logic [31:0] FIRST_ACK_SEQUENCE = 32'd1
) (
    input  logic        clk,
    input  logic        reset,

    // Validated external session contract.  A low-to-high quiescence phase
    // and a caller-proven fresh, nonzero epoch are mandatory.
    input  logic        shadow_feature_enable,
    input  logic        transport_quiescent,
    input  logic        epoch_contract_active,
    input  logic        epoch_contract_fresh,
    input  logic [31:0] epoch_contract,
    // Producer frontier at the session boundary.  The first observed posted
    // acceptance must be exactly base+1.
    input  logic [31:0] epoch_base_posted_sequence,
    output logic        shadow_session_active,
    output logic [31:0] shadow_active_epoch,

    // Passive, no-backpressure posted-write acceptance observer.
    input  logic        posted_accept_valid,
    input  logic [31:0] posted_accept_epoch,
    input  logic        posted_accept_cpu_arm9,
    input  logic [31:0] posted_accept_cycles,
    input  logic [31:0] posted_accept_producer_sequence,

    // Retained direct mailbox completion stream.  Kind 1 is an ordinary or
    // timing-only mailbox record; kind 2 is a synthetic halt record.  Posted
    // records never enter through this interface.
    input  logic        direct_credit_valid,
    output logic        direct_credit_ready,
    input  logic [31:0] direct_credit_epoch,
    input  logic [31:0] direct_credit_source_generation,
    input  logic        direct_credit_cpu_arm9,
    input  logic [31:0] direct_credit_cycles,
    input  logic [1:0]  direct_credit_kind,
    input  logic [31:0] direct_credit_completed_fence_sequence,

    // Simulator-only invariant injection.  Keep tied low in every functional
    // composition; the fault regression asserts it to model a corrupted or
    // missing retained head without nonportable hierarchical RAM writes.
    input  logic        simulation_inject_missing_posted,

    // Globally ordered credit stream for nds_sound_credit_drain_coordinator.
    output logic        merged_credit_valid,
    input  logic        merged_credit_ready,
    output logic [31:0] merged_credit_epoch,
    output logic [31:0] merged_credit_ack_sequence,
    output logic        merged_credit_cpu_arm9,
    output logic [31:0] merged_credit_cycles,
    output logic [1:0]  merged_credit_kind,
    // Diagnostic identity: posted producer sequence for kind 0, mailbox
    // source generation for kinds 1/2.
    output logic [31:0] merged_credit_source_id,
    output logic [31:0] merged_credit_completed_fence_sequence,

    output logic [$clog2(LEDGER_DEPTH + 1)-1:0] ledger_level,
    output logic        mailbox_pending,
    output logic [31:0] last_completed_fence_sequence,
    output logic        capture_overflow,
    output logic        posted_sequence_exhausted,
    output logic        ack_sequence_exhausted,
    output logic        protocol_error,
    output logic [7:0]  fault_code
);
    localparam integer POINTER_WIDTH =
        LEDGER_DEPTH <= 1 ? 1 : $clog2(LEDGER_DEPTH);
    localparam integer LEVEL_WIDTH = $clog2(LEDGER_DEPTH + 1);
    localparam logic [POINTER_WIDTH-1:0] LAST_POINTER =
        POINTER_WIDTH'(LEDGER_DEPTH - 1);
    localparam logic [LEVEL_WIDTH-1:0] FULL_LEVEL =
        LEVEL_WIDTH'(LEDGER_DEPTH);

    localparam logic [7:0] FAULT_NONE                = 8'h00;
    localparam logic [7:0] FAULT_EPOCH_CONTRACT      = 8'h01;
    localparam logic [7:0] FAULT_PREMATURE_ACTIVITY  = 8'h02;
    localparam logic [7:0] FAULT_EPOCH_ACTIVE_LOSS   = 8'h03;
    localparam logic [7:0] FAULT_POSTED_SEQUENCE     = 8'h10;
    localparam logic [7:0] FAULT_POSTED_OVERFLOW     = 8'h11;
    localparam logic [7:0] FAULT_DIRECT_RECORD       = 8'h12;
    localparam logic [7:0] FAULT_FENCE_ORDER         = 8'h13;
    localparam logic [7:0] FAULT_MISSING_POSTED      = 8'h14;
    localparam logic [7:0] FAULT_ACK_EXHAUSTED       = 8'h15;

    logic quarantine_low_seen;
    logic [31:0] last_active_epoch;

    // Canonical synchronous simple-dual-port inference form.  The two visible
    // cache slots below keep the ready/valid output no-bubble while this packed
    // payload RAM supplies the third logical queue entry one clock ahead.
    (* ramstyle = "M10K" *)
    logic [32:0] posted_payload_fifo [0:LEDGER_DEPTH-1];
    logic [POINTER_WIDTH-1:0] posted_read_pointer;
    logic [POINTER_WIDTH-1:0] posted_write_pointer;
    logic [LEVEL_WIDTH-1:0] posted_level;
    logic posted_head_valid;
    logic posted_head_cpu_arm9;
    logic [31:0] posted_head_cycles;
    logic posted_next_cpu_arm9;
    logic [31:0] posted_next_cycles;
    logic [32:0] posted_prefetch_ram_q;
    logic posted_prefetch_bypass_valid;
    logic [32:0] posted_prefetch_bypass_data;
    logic [31:0] last_accepted_posted_sequence;
    logic [31:0] expected_posted_sequence;

    logic shadow_session_active_state;
    logic [31:0] shadow_active_epoch_state;
    logic mailbox_pending_state;

    logic [31:0] pending_mailbox_epoch;
    logic [31:0] pending_mailbox_source_generation;
    logic pending_mailbox_cpu_arm9;
    logic [31:0] pending_mailbox_cycles;
    logic [1:0] pending_mailbox_kind;
    logic [31:0] pending_mailbox_fence;
    logic direct_source_initialized;
    logic direct_source_exhausted;
    logic [31:0] last_direct_source_generation;

    logic [31:0] next_ack_sequence;
    logic [7:0] fatal_fault_code;

    initial begin
        if (LEDGER_DEPTH < 2)
            $fatal(1, "sound posted-credit LEDGER_DEPTH must be at least 2");
        if (FIRST_ACK_SEQUENCE == 32'd0)
            $fatal(1, "sound posted-credit FIRST_ACK_SEQUENCE cannot be zero");
    end

    function automatic logic [POINTER_WIDTH-1:0] increment_pointer(
        input logic [POINTER_WIDTH-1:0] pointer
    );
        if (pointer == LAST_POINTER)
            increment_pointer = '0;
        else
            increment_pointer = pointer + 1'b1;
    endfunction

    wire epoch_start_attempt =
        shadow_feature_enable && !shadow_session_active &&
        epoch_contract_active;
    wire epoch_start_valid =
        epoch_start_attempt &&
        epoch_contract_fresh &&
        epoch_contract != 32'd0 &&
        epoch_contract != last_active_epoch &&
        quarantine_low_seen && transport_quiescent &&
        posted_level == 0 && !mailbox_pending &&
        !protocol_error;

    // Externally visible ownership is masked on the exact clock that the sticky
    // fault boundary commits.  The wider retained state is quarantined from the
    // registered protocol_error on the following edge.
    assign shadow_session_active =
        shadow_session_active_state && !protocol_error;
    assign shadow_active_epoch =
        shadow_session_active ? shadow_active_epoch_state : 32'd0;
    assign mailbox_pending =
        mailbox_pending_state && !protocol_error;

    wire observed_activity =
        posted_accept_valid || direct_credit_valid;
    wire epoch_contract_error =
        epoch_start_attempt && !epoch_start_valid;
    wire premature_activity =
        shadow_feature_enable && !shadow_session_active &&
        observed_activity;
    wire epoch_active_loss =
        shadow_session_active &&
        (!shadow_feature_enable || !epoch_contract_active ||
         epoch_contract == 32'd0 ||
         epoch_contract != shadow_active_epoch);

    // Epoch admission is deliberately a registered boundary.  The enclosing
    // composition proves posted/direct activity is absent when it raises
    // epoch_request_ready; violating that quiescent contract fails closed above
    // instead of silently dropping or same-edge-admitting a record.
    wire posted_capture =
        posted_accept_valid && shadow_session_active;
    wire posted_record_error =
        posted_capture &&
        (posted_accept_epoch == 32'd0 ||
         posted_accept_epoch != shadow_active_epoch ||
         posted_accept_producer_sequence == 32'd0 ||
         posted_sequence_exhausted ||
         posted_accept_producer_sequence !=
             expected_posted_sequence);

    wire covered_posted_remains =
        mailbox_pending &&
        pending_mailbox_fence > last_completed_fence_sequence;
    // Accepted posted sequences are strictly contiguous within one epoch, so
    // the retained head identity is exactly the completed frontier plus one.
    // Storing the epoch and sequence per entry would duplicate invariants and
    // create a 256:1 asynchronous control mux.  Only the varying CPU/cycle
    // payloads remain in the ledger RAM; a registered show-ahead head keeps
    // their variable-index read out of the downstream acknowledgement cone.
    wire [31:0] posted_head_sequence =
        last_completed_fence_sequence + 1'b1;
    wire posted_head_available =
        posted_head_valid && posted_level != 0;
    wire posted_head_exact =
        posted_head_available &&
        !simulation_inject_missing_posted;
    wire posted_head_covered =
        posted_head_exact &&
        posted_head_sequence <= pending_mailbox_fence;
    wire missing_covered_post =
        covered_posted_remains && !posted_head_covered;

    wire select_posted_credit =
        mailbox_pending && covered_posted_remains &&
        posted_head_covered && !protocol_error;
    wire select_direct_credit =
        mailbox_pending && !covered_posted_remains &&
        !protocol_error;

    assign merged_credit_valid =
        select_posted_credit || select_direct_credit;
    assign merged_credit_epoch = select_posted_credit
        ? shadow_active_epoch
        : select_direct_credit ? pending_mailbox_epoch : 32'd0;
    assign merged_credit_ack_sequence =
        merged_credit_valid ? next_ack_sequence : 32'd0;
    assign merged_credit_cpu_arm9 = select_posted_credit
        ? posted_head_cpu_arm9
        : select_direct_credit ? pending_mailbox_cpu_arm9 : 1'b0;
    assign merged_credit_cycles = select_posted_credit
        ? posted_head_cycles
        : select_direct_credit ? pending_mailbox_cycles : 32'd0;
    assign merged_credit_kind = select_posted_credit
        ? 2'b00
        : select_direct_credit ? pending_mailbox_kind : 2'b00;
    assign merged_credit_source_id = select_posted_credit
        ? posted_head_sequence
        : select_direct_credit
            ? pending_mailbox_source_generation : 32'd0;
    assign merged_credit_completed_fence_sequence =
        merged_credit_valid ? pending_mailbox_fence : 32'd0;

    wire merged_credit_fire =
        merged_credit_valid && merged_credit_ready;
    wire posted_pop =
        merged_credit_fire && select_posted_credit;
    wire direct_pop =
        merged_credit_fire && select_direct_credit;

    wire [POINTER_WIDTH-1:0] posted_pointer_plus_one =
        increment_pointer(posted_read_pointer);
    wire [POINTER_WIDTH-1:0] posted_pointer_plus_two =
        increment_pointer(posted_pointer_plus_one);
    wire [POINTER_WIDTH-1:0] posted_pointer_plus_three =
        increment_pointer(posted_pointer_plus_two);
    // Before a pop, the registered RAM output already owns logical entry two.
    // A pop consumes it into the next cache, so ask the synchronous port for
    // logical entry three; without a pop, keep entry two warm.
    wire [POINTER_WIDTH-1:0] posted_prefetch_read_address =
        posted_pop ? posted_pointer_plus_three : posted_pointer_plus_two;
    wire [32:0] posted_accept_payload = {
        posted_accept_cpu_arm9,
        posted_accept_cycles
    };
    wire [32:0] posted_prefetch_payload =
        posted_prefetch_bypass_valid
            ? posted_prefetch_bypass_data
            : posted_prefetch_ram_q;

    // The direct stream may stall behind one retained mailbox and its covered
    // posted batch.  This only backpressures the observer FIFO; it has no path
    // to the production mailbox request or completion handshake.
    assign direct_credit_ready =
        shadow_session_active && !mailbox_pending &&
        !protocol_error;
    wire direct_credit_fire =
        direct_credit_valid && direct_credit_ready;

    // direct_credit_fire implies !mailbox_pending, while posted_pop implies
    // mailbox_pending.  They cannot coincide, so subtracting posted_pop here
    // was both redundant and a long false-by-construction control cone from
    // the ledger head into every terminal-fault destination.
    wire [LEVEL_WIDTH:0] direct_admission_posted_level =
        {1'b0, posted_level} +
        ((posted_capture && !posted_record_error) ? 1'b1 : 1'b0);
    wire [31:0] accepted_frontier_with_current_post =
        (posted_capture && !posted_record_error)
            ? posted_accept_producer_sequence
            : last_accepted_posted_sequence;
    wire posted_overflow =
        posted_capture && !posted_record_error &&
        posted_level == FULL_LEVEL && !posted_pop;
    wire posted_payload_store =
        posted_capture && !posted_record_error &&
        !posted_overflow && !protocol_error;
    wire posted_prefetch_write_collision =
        posted_payload_store &&
        posted_write_pointer == posted_prefetch_read_address;

    wire direct_source_error =
        direct_credit_fire &&
        (direct_credit_source_generation == 32'd0 ||
         direct_source_exhausted ||
         (direct_source_initialized &&
          direct_credit_source_generation !=
              last_direct_source_generation + 1'b1));
    wire direct_record_error =
        direct_credit_fire &&
        (direct_credit_epoch == 32'd0 ||
         direct_credit_epoch != shadow_active_epoch ||
         (direct_credit_kind != 2'b01 &&
          direct_credit_kind != 2'b10) ||
         direct_source_error);
    wire fence_order_error =
        direct_credit_fire &&
        (direct_credit_completed_fence_sequence <
             last_completed_fence_sequence ||
         direct_credit_completed_fence_sequence >
             accepted_frontier_with_current_post ||
         ({1'b0, direct_credit_completed_fence_sequence} -
          {1'b0, last_completed_fence_sequence}) >
             direct_admission_posted_level);

    // Reserve enough nonzero global ACK identities for every covered posted
    // record plus this mailbox record before accepting the mailbox credit.
    wire [32:0] outputs_needed =
        ({1'b0, direct_credit_completed_fence_sequence} -
         {1'b0, last_completed_fence_sequence}) + 33'd1;
    wire [32:0] ack_identities_remaining =
        33'h1_0000_0000 - {1'b0, next_ack_sequence};
    wire ack_capacity_error =
        direct_credit_fire &&
        (ack_sequence_exhausted ||
         outputs_needed > ack_identities_remaining);

    wire new_fatal_event =
        epoch_contract_error || premature_activity || epoch_active_loss ||
        posted_record_error || posted_overflow ||
        direct_record_error || fence_order_error ||
        missing_covered_post || ack_capacity_error;
    // Preserve the first proof of invalidity.  Once closed, a still-asserted
    // external epoch contract must not overwrite its diagnostic on later
    // clocks.
    wire fault_commit = !protocol_error && new_fatal_event;

    always_comb begin
        if (epoch_contract_error)
            fatal_fault_code = FAULT_EPOCH_CONTRACT;
        else if (premature_activity)
            fatal_fault_code = FAULT_PREMATURE_ACTIVITY;
        else if (epoch_active_loss)
            fatal_fault_code = FAULT_EPOCH_ACTIVE_LOSS;
        else if (posted_record_error)
            fatal_fault_code = FAULT_POSTED_SEQUENCE;
        else if (posted_overflow)
            fatal_fault_code = FAULT_POSTED_OVERFLOW;
        else if (direct_record_error)
            fatal_fault_code = FAULT_DIRECT_RECORD;
        else if (fence_order_error)
            fatal_fault_code = FAULT_FENCE_ORDER;
        else if (missing_covered_post)
            fatal_fault_code = FAULT_MISSING_POSTED;
        else if (ack_capacity_error)
            fatal_fault_code = FAULT_ACK_EXHAUSTED;
        else
            fatal_fault_code = FAULT_NONE;
    end

    assign ledger_level = protocol_error ? '0 : posted_level;

    // The deep validation cone terminates only at this compact sticky boundary.
    // It never drives the enables or data muxes of the retained queue, mailbox,
    // or session state.  All externally actionable outputs are masked by the
    // registered poison immediately after this edge; the wide dead state is
    // cleared one clock later from protocol_error itself.
    always_ff @(posedge clk) begin
        if (reset) begin
            protocol_error <= 1'b0;
            fault_code <= FAULT_NONE;
            capture_overflow <= 1'b0;
        end else if (fault_commit) begin
            protocol_error <= 1'b1;
            fault_code <= fatal_fault_code;
            if (posted_overflow)
                capture_overflow <= 1'b1;
        end
    end

    // The retained payload RAM is dead state whenever this observer fails
    // closed.  Keep its canonical write/read inference process independent of
    // the wide fail-closed state muxes.  Its one write enable accepts only a
    // validated, nonoverflowing posted capture; malformed or unretained tails
    // never modify the M10K.
    always_ff @(posedge clk) begin
        if (posted_payload_store)
            posted_payload_fifo[posted_write_pointer] <=
                posted_accept_payload;
        posted_prefetch_ram_q <=
            posted_payload_fifo[posted_prefetch_read_address];
    end

    // Keep write-during-read forwarding outside the RAM-q assignment so
    // Quartus can infer one synchronous M10K.  This is required when a third
    // entry is accepted into the exact slot being prefetched, including the
    // small-depth/FULL pointer-collision cases.
    always_ff @(posedge clk) begin
        if (reset) begin
            posted_prefetch_bypass_valid <= 1'b0;
            posted_prefetch_bypass_data <= '0;
        end else begin
            posted_prefetch_bypass_valid <=
                posted_prefetch_write_collision;
            if (posted_prefetch_write_collision)
                posted_prefetch_bypass_data <=
                    posted_accept_payload;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            quarantine_low_seen <= 1'b0;
            last_active_epoch <= 32'd0;
            shadow_session_active_state <= 1'b0;
            shadow_active_epoch_state <= 32'd0;

            posted_read_pointer <= '0;
            posted_write_pointer <= '0;
            posted_level <= '0;
            posted_head_valid <= 1'b0;
            posted_head_cpu_arm9 <= 1'b0;
            posted_head_cycles <= 32'd0;
            posted_next_cpu_arm9 <= 1'b0;
            posted_next_cycles <= 32'd0;
            last_accepted_posted_sequence <= 32'd0;
            expected_posted_sequence <= 32'd1;
            last_completed_fence_sequence <= 32'd0;
            posted_sequence_exhausted <= 1'b0;

            mailbox_pending_state <= 1'b0;
            pending_mailbox_epoch <= 32'd0;
            pending_mailbox_source_generation <= 32'd0;
            pending_mailbox_cpu_arm9 <= 1'b0;
            pending_mailbox_cycles <= 32'd0;
            pending_mailbox_kind <= 2'd0;
            pending_mailbox_fence <= 32'd0;
            direct_source_initialized <= 1'b0;
            direct_source_exhausted <= 1'b0;
            last_direct_source_generation <= 32'd0;

            next_ack_sequence <= FIRST_ACK_SEQUENCE;
            ack_sequence_exhausted <= 1'b0;
        end else begin
            if (!transport_quiescent)
                quarantine_low_seen <= 1'b1;

            if (protocol_error) begin
                shadow_session_active_state <= 1'b0;
                shadow_active_epoch_state <= 32'd0;
                posted_level <= '0;
                posted_read_pointer <= '0;
                posted_write_pointer <= '0;
                posted_head_valid <= 1'b0;
                mailbox_pending_state <= 1'b0;
            end else begin
                if (epoch_start_valid) begin
                    shadow_session_active_state <= 1'b1;
                    shadow_active_epoch_state <= epoch_contract;
                    last_active_epoch <= epoch_contract;
                    quarantine_low_seen <= 1'b0;

                    posted_read_pointer <= '0;
                    posted_write_pointer <= '0;
                    posted_level <= '0;
                    posted_head_valid <= 1'b0;
                    last_accepted_posted_sequence <=
                        epoch_base_posted_sequence;
                    expected_posted_sequence <=
                        epoch_base_posted_sequence + 1'b1;
                    last_completed_fence_sequence <=
                        epoch_base_posted_sequence;
                    posted_sequence_exhausted <=
                        epoch_base_posted_sequence == 32'hffffffff;

                    mailbox_pending_state <= 1'b0;
                    direct_source_initialized <= 1'b0;
                    direct_source_exhausted <= 1'b0;
                    last_direct_source_generation <= 32'd0;

                    next_ack_sequence <= FIRST_ACK_SEQUENCE;
                    ack_sequence_exhausted <= 1'b0;
                end

                if (posted_capture) begin
                    posted_write_pointer <=
                        increment_pointer(posted_write_pointer);
                    last_accepted_posted_sequence <=
                        posted_accept_producer_sequence;
                    if (posted_accept_producer_sequence ==
                        32'hffffffff) begin
                        posted_sequence_exhausted <= 1'b1;
                        expected_posted_sequence <= 32'd0;
                    end else begin
                        expected_posted_sequence <=
                            posted_accept_producer_sequence + 1'b1;
                    end
                end

                if (posted_pop) begin
                    posted_read_pointer <=
                        increment_pointer(posted_read_pointer);
                    last_completed_fence_sequence <=
                        posted_head_sequence;
                end

                // Two visible cache slots plus the synchronous third-entry
                // read-ahead preserve one posted retirement per clock.  Empty,
                // depth-one, deeper, and FULL simultaneous pop/capture cases
                // never consume the just-written tail ahead of older entries.
                if (posted_pop) begin
                    if (posted_level > 1) begin
                        posted_head_cpu_arm9 <=
                            posted_next_cpu_arm9;
                        posted_head_cycles <=
                            posted_next_cycles;
                        posted_head_valid <= 1'b1;
                        if (posted_level > 2) begin
                            posted_next_cpu_arm9 <=
                                posted_prefetch_payload[32];
                            posted_next_cycles <=
                                posted_prefetch_payload[31:0];
                        end else if (posted_capture) begin
                            posted_next_cpu_arm9 <=
                                posted_accept_cpu_arm9;
                            posted_next_cycles <=
                                posted_accept_cycles;
                        end
                    end else if (posted_capture) begin
                        posted_head_cpu_arm9 <=
                            posted_accept_cpu_arm9;
                        posted_head_cycles <= posted_accept_cycles;
                        posted_head_valid <= 1'b1;
                    end else begin
                        posted_head_valid <= 1'b0;
                    end
                end else if (posted_capture) begin
                    if (posted_level == 0) begin
                        posted_head_cpu_arm9 <=
                            posted_accept_cpu_arm9;
                        posted_head_cycles <=
                            posted_accept_cycles;
                        posted_head_valid <= 1'b1;
                    end else if (posted_level == 1) begin
                        posted_next_cpu_arm9 <=
                            posted_accept_cpu_arm9;
                        posted_next_cycles <=
                            posted_accept_cycles;
                    end
                end

                case ({posted_capture, posted_pop})
                    2'b10: posted_level <= posted_level + 1'b1;
                    2'b01: posted_level <= posted_level - 1'b1;
                    default: begin end
                endcase

                if (direct_credit_fire) begin
                    mailbox_pending_state <= 1'b1;
                    pending_mailbox_epoch <= direct_credit_epoch;
                    pending_mailbox_source_generation <=
                        direct_credit_source_generation;
                    pending_mailbox_cpu_arm9 <=
                        direct_credit_cpu_arm9;
                    pending_mailbox_cycles <= direct_credit_cycles;
                    pending_mailbox_kind <= direct_credit_kind;
                    pending_mailbox_fence <=
                        direct_credit_completed_fence_sequence;

                    direct_source_initialized <= 1'b1;
                    last_direct_source_generation <=
                        direct_credit_source_generation;
                    if (direct_credit_source_generation ==
                        32'hffffffff)
                        direct_source_exhausted <= 1'b1;
                end

                if (direct_pop) begin
                    mailbox_pending_state <= 1'b0;
                    last_completed_fence_sequence <=
                        pending_mailbox_fence;
                end

                if (merged_credit_fire) begin
                    if (next_ack_sequence == 32'hffffffff) begin
                        ack_sequence_exhausted <= 1'b1;
                    end else begin
                        next_ack_sequence <= next_ack_sequence + 1'b1;
                    end
                end
            end
        end
    end
endmodule
