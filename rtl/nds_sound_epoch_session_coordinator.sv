// Simulator-first fail-closed session coordinator for the private sound
// shadow.
//
// The default reverse-ring startup is deliberately serialized:
//   1. observe transport_quiescent low and then high;
//   2. accept one externally proven, fresh, nonzero epoch;
//   3. retain a start request to nds_hps_consumed_credit_ddr_ring;
//   4. wait for that ring to validate DDR state and report started+active;
//   5. independently retain/fan out the same epoch to the ACK broadcaster,
//      write-order queue, and credit-drain coordinator;
//   6. release the sound shadow only after all four consumers are active on
//      the exact retained epoch.
//
// DIRECT_COMPLETION_MODE is a compile-time alternative for an integration
// whose mailbox_done pulse is already the authoritative completion/credit
// event.  It keeps the same low/high quarantine and external epoch proof but
// skips the unused reverse-ring session and starts the three consumers
// directly.  The mode is intentionally static: changing credit authority
// inside a live epoch would make causality unknowable.
//
// This block does not claim persistent freshness.  last_accepted_epoch only
// catches reuse during the current FPGA reset lifetime.  The external/HPS
// owner must prove epoch_fresh after every reset and must never reuse an epoch
// across resets.
//
// sound_data_activity is an integration assertion input: it must cover every
// sound data-plane valid/request (but not the DDR reads/writes used by the
// ring itself to validate and start a session).  Any activity before the
// release gate is terminal.  Integrators must also AND source valids/enables
// with sound_data_enable; observation alone cannot retract an already-issued
// request.
//
// This module is intentionally absent from the production MiSTer top and QSF.
module nds_sound_epoch_session_coordinator #(
    parameter bit DIRECT_COMPLETION_MODE = 1'b0
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        transport_quiescent,

    // One retained ready/valid request from a persistent external/HPS epoch
    // owner.  Once valid is raised before acceptance, valid and payload must
    // remain stable until the handshake.
    input  logic        epoch_request_valid,
    output logic        epoch_request_ready,
    input  logic [31:0] epoch_request,
    input  logic        epoch_request_fresh,

    // nds_hps_consumed_credit_ddr_ring session interface/status.
    output logic        ring_session_begin_valid,
    input  logic        ring_session_begin_ready,
    output logic [31:0] ring_session_begin_epoch,
    output logic        ring_session_epoch_fresh,
    input  logic        ring_session_started,
    input  logic        ring_session_active,
    input  logic [31:0] ring_active_epoch,
    input  logic        ring_sequence_exhausted,
    input  logic        ring_protocol_error,

    // nds_sound_ack_broadcaster epoch interface/status.
    output logic        broadcaster_epoch_begin_valid,
    input  logic        broadcaster_epoch_begin_ready,
    output logic [31:0] broadcaster_epoch_begin,
    output logic        broadcaster_epoch_begin_fresh,
    input  logic        broadcaster_epoch_started,
    input  logic        broadcaster_epoch_active,
    input  logic [31:0] broadcaster_active_epoch,
    input  logic        broadcaster_sequence_exhausted,
    input  logic        broadcaster_protocol_error,

    // nds_sound_write_order_queue epoch interface/status.
    output logic        queue_epoch_begin_valid,
    input  logic        queue_epoch_begin_ready,
    output logic [31:0] queue_epoch_begin,
    output logic        queue_epoch_begin_fresh,
    input  logic        queue_epoch_started,
    input  logic        queue_epoch_active,
    input  logic [31:0] queue_active_epoch,
    input  logic        queue_capture_overflow,
    input  logic        queue_sequence_exhausted,
    input  logic        queue_protocol_error,

    // nds_sound_credit_drain_coordinator epoch interface/status.
    output logic        drain_epoch_begin_valid,
    input  logic        drain_epoch_begin_ready,
    output logic [31:0] drain_epoch_begin,
    output logic        drain_epoch_begin_fresh,
    input  logic        drain_epoch_started,
    input  logic        drain_epoch_active,
    input  logic [31:0] drain_active_epoch,
    input  logic        drain_sequence_exhausted,
    input  logic        drain_protocol_error,
    input  logic        drain_overflow,

    // Aggregate observation of the gated sound data plane.
    input  logic        sound_data_activity,

    output logic        sound_epoch_ready,
    output logic [31:0] active_epoch,
    output logic        sound_data_enable,
    output logic        sound_shadow_enable,
    output logic        sound_shadow_reset,
    output logic        protocol_error,
    output logic        terminal_fault,
    output logic        premature_activity,
    output logic [7:0]  fault_code
);
    typedef enum logic [3:0] {
        STATE_WAIT_QUIESCENT_LOW,
        STATE_WAIT_QUIESCENT_HIGH,
        STATE_WAIT_EXTERNAL_EPOCH,
        STATE_START_RING,
        STATE_WAIT_RING,
        STATE_START_CONSUMERS,
        STATE_WAIT_CONSUMERS,
        STATE_READY,
        STATE_FAILED
    } state_t;

    localparam logic [7:0] FAULT_NONE             = 8'h00;
    localparam logic [7:0] FAULT_EXTERNAL_FORMAT  = 8'h01;
    localparam logic [7:0] FAULT_EXTERNAL_HOLD    = 8'h02;
    localparam logic [7:0] FAULT_PREMATURE_DATA   = 8'h03;
    localparam logic [7:0] FAULT_QUIESCENCE_LOST  = 8'h04;
    localparam logic [7:0] FAULT_EXTERNAL_RESTART = 8'h05;
    localparam logic [7:0] FAULT_RING_STATUS      = 8'h10;
    localparam logic [7:0] FAULT_RING_PROTOCOL    = 8'h11;
    localparam logic [7:0] FAULT_BCAST_STATUS     = 8'h20;
    localparam logic [7:0] FAULT_BCAST_PROTOCOL   = 8'h21;
    localparam logic [7:0] FAULT_QUEUE_STATUS     = 8'h30;
    localparam logic [7:0] FAULT_QUEUE_PROTOCOL   = 8'h31;
    localparam logic [7:0] FAULT_DRAIN_STATUS     = 8'h40;
    localparam logic [7:0] FAULT_DRAIN_PROTOCOL   = 8'h41;
    localparam logic [7:0] FAULT_INTERNAL         = 8'h7f;

    state_t state;

    logic [31:0] retained_epoch;
    logic [31:0] last_accepted_epoch;
    logic        retained_fresh;

    // Monitor a request that was asserted before ready.  This makes payload
    // mutation/withdrawal a visible protocol failure rather than silently
    // selecting a different epoch when quiescence eventually arrives.
    logic        observed_unaccepted_request;
    logic [31:0] observed_request_epoch;
    logic        observed_request_fresh;
    logic        request_accepted;
    logic        accepted_source_released;

    logic ring_request_sent;
    logic ring_started_seen;

    logic broadcaster_pending;
    logic queue_pending;
    logic drain_pending;
    logic broadcaster_request_sent;
    logic queue_request_sent;
    logic drain_request_sent;
    logic broadcaster_started_seen;
    logic queue_started_seen;
    logic drain_started_seen;

    wire epoch_request_fire =
        epoch_request_valid && epoch_request_ready;
    wire ring_request_fire =
        ring_session_begin_valid && ring_session_begin_ready;
    wire broadcaster_request_fire =
        broadcaster_epoch_begin_valid &&
        broadcaster_epoch_begin_ready;
    wire queue_request_fire =
        queue_epoch_begin_valid && queue_epoch_begin_ready;
    wire drain_request_fire =
        drain_epoch_begin_valid && drain_epoch_begin_ready;

    wire ring_epoch_exact =
        ring_session_active && ring_active_epoch == retained_epoch;
    wire broadcaster_epoch_exact =
        broadcaster_epoch_active &&
        broadcaster_active_epoch == retained_epoch;
    wire queue_epoch_exact =
        queue_epoch_active && queue_active_epoch == retained_epoch;
    wire drain_epoch_exact =
        drain_epoch_active && drain_active_epoch == retained_epoch;

    wire all_started_seen =
        (DIRECT_COMPLETION_MODE || ring_started_seen) &&
        broadcaster_started_seen && queue_started_seen &&
        drain_started_seen;
    wire all_epochs_exact =
        (DIRECT_COMPLETION_MODE || ring_epoch_exact) &&
        broadcaster_epoch_exact && queue_epoch_exact &&
        drain_epoch_exact;

    wire external_hold_error =
        !request_accepted && observed_unaccepted_request &&
        (!epoch_request_valid ||
         epoch_request != observed_request_epoch ||
         epoch_request_fresh != observed_request_fresh);
    wire external_restart_error =
        request_accepted &&
        ((!accepted_source_released && epoch_request_valid &&
          (epoch_request != retained_epoch ||
           !epoch_request_fresh)) ||
         (accepted_source_released && epoch_request_valid));

    assign epoch_request_ready =
        state == STATE_WAIT_EXTERNAL_EPOCH &&
        transport_quiescent && !protocol_error;

    assign ring_session_begin_valid =
        !DIRECT_COMPLETION_MODE &&
        state == STATE_START_RING && !protocol_error;
    assign ring_session_begin_epoch = retained_epoch;
    assign ring_session_epoch_fresh =
        ring_session_begin_valid && retained_fresh;

    assign broadcaster_epoch_begin_valid =
        (state == STATE_START_CONSUMERS ||
         state == STATE_WAIT_CONSUMERS) &&
        broadcaster_pending && !protocol_error;
    assign queue_epoch_begin_valid =
        (state == STATE_START_CONSUMERS ||
         state == STATE_WAIT_CONSUMERS) &&
        queue_pending && !protocol_error;
    assign drain_epoch_begin_valid =
        (state == STATE_START_CONSUMERS ||
         state == STATE_WAIT_CONSUMERS) &&
        drain_pending && !protocol_error;

    assign broadcaster_epoch_begin = retained_epoch;
    assign queue_epoch_begin = retained_epoch;
    assign drain_epoch_begin = retained_epoch;
    assign broadcaster_epoch_begin_fresh =
        broadcaster_epoch_begin_valid && retained_fresh;
    assign queue_epoch_begin_fresh =
        queue_epoch_begin_valid && retained_fresh;
    assign drain_epoch_begin_fresh =
        drain_epoch_begin_valid && retained_fresh;

    // The exact active status is included combinationally so a status drop
    // closes the gate immediately, before the sticky fault is recorded.
    assign sound_epoch_ready =
        state == STATE_READY && all_started_seen &&
        all_epochs_exact && !protocol_error;
    assign active_epoch =
        sound_epoch_ready ? retained_epoch : 32'd0;
    assign sound_data_enable = sound_epoch_ready;
    assign sound_shadow_enable = sound_epoch_ready;
    assign sound_shadow_reset = reset || !sound_epoch_ready;

    task automatic fail_closed(input logic [7:0] code);
        begin
            state <= STATE_FAILED;
            protocol_error <= 1'b1;
            terminal_fault <= 1'b1;
            fault_code <= code;
            broadcaster_pending <= 1'b0;
            queue_pending <= 1'b0;
            drain_pending <= 1'b0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= STATE_WAIT_QUIESCENT_LOW;
            retained_epoch <= 32'd0;
            last_accepted_epoch <= 32'd0;
            retained_fresh <= 1'b0;

            observed_unaccepted_request <= 1'b0;
            observed_request_epoch <= 32'd0;
            observed_request_fresh <= 1'b0;
            request_accepted <= 1'b0;
            accepted_source_released <= 1'b0;

            ring_request_sent <= 1'b0;
            ring_started_seen <= 1'b0;

            broadcaster_pending <= 1'b0;
            queue_pending <= 1'b0;
            drain_pending <= 1'b0;
            broadcaster_request_sent <= 1'b0;
            queue_request_sent <= 1'b0;
            drain_request_sent <= 1'b0;
            broadcaster_started_seen <= 1'b0;
            queue_started_seen <= 1'b0;
            drain_started_seen <= 1'b0;

            protocol_error <= 1'b0;
            terminal_fault <= 1'b0;
            premature_activity <= 1'b0;
            fault_code <= FAULT_NONE;
        end else if (!protocol_error) begin
            // Capture and enforce an early request until it is accepted.
            if (!request_accepted) begin
                if (epoch_request_valid) begin
                    if (!observed_unaccepted_request) begin
                        observed_unaccepted_request <= 1'b1;
                        observed_request_epoch <= epoch_request;
                        observed_request_fresh <= epoch_request_fresh;
                    end
                end
            end else if (!accepted_source_released) begin
                // The accepted item may remain asserted with the same payload
                // until the source observes ready.  A new payload without a
                // valid-low separator is an unexpected second request.
                if (!epoch_request_valid)
                    accepted_source_released <= 1'b1;
            end

            if (external_hold_error) begin
                fail_closed(FAULT_EXTERNAL_HOLD);
            end else if (external_restart_error) begin
                // Exactly one epoch is admitted per reset.
                fail_closed(FAULT_EXTERNAL_RESTART);
            end else if (sound_data_activity && !sound_epoch_ready) begin
                premature_activity <= 1'b1;
                fail_closed(FAULT_PREMATURE_DATA);
            end else if (!DIRECT_COMPLETION_MODE &&
                         (ring_protocol_error ||
                          ring_sequence_exhausted)) begin
                fail_closed(FAULT_RING_PROTOCOL);
            end else if (broadcaster_protocol_error ||
                         broadcaster_sequence_exhausted) begin
                fail_closed(FAULT_BCAST_PROTOCOL);
            end else if (queue_protocol_error ||
                         queue_capture_overflow ||
                         queue_sequence_exhausted) begin
                fail_closed(FAULT_QUEUE_PROTOCOL);
            end else if (drain_protocol_error ||
                         drain_overflow ||
                         drain_sequence_exhausted) begin
                fail_closed(FAULT_DRAIN_PROTOCOL);
            end else if (
                !DIRECT_COMPLETION_MODE && ring_session_started &&
                !(ring_request_sent || ring_request_fire)) begin
                fail_closed(FAULT_RING_STATUS);
            end else if (
                !DIRECT_COMPLETION_MODE && ring_session_started &&
                (ring_started_seen || !ring_session_active ||
                 ring_active_epoch != retained_epoch)) begin
                fail_closed(FAULT_RING_STATUS);
            end else if (
                !DIRECT_COMPLETION_MODE && ring_session_active &&
                !(ring_request_sent || ring_request_fire)) begin
                fail_closed(FAULT_RING_STATUS);
            end else if (
                !DIRECT_COMPLETION_MODE && ring_session_active &&
                ring_active_epoch != retained_epoch) begin
                fail_closed(FAULT_RING_STATUS);
            end else if (
                !DIRECT_COMPLETION_MODE &&
                ring_started_seen && !ring_epoch_exact) begin
                fail_closed(FAULT_RING_STATUS);
            end else if (
                broadcaster_epoch_started &&
                !(broadcaster_request_sent ||
                  broadcaster_request_fire)) begin
                fail_closed(FAULT_BCAST_STATUS);
            end else if (
                broadcaster_epoch_started &&
                (broadcaster_started_seen ||
                 !broadcaster_epoch_active ||
                 broadcaster_active_epoch != retained_epoch)) begin
                fail_closed(FAULT_BCAST_STATUS);
            end else if (
                broadcaster_epoch_active &&
                !(broadcaster_request_sent ||
                  broadcaster_request_fire)) begin
                fail_closed(FAULT_BCAST_STATUS);
            end else if (
                broadcaster_epoch_active &&
                broadcaster_active_epoch != retained_epoch) begin
                fail_closed(FAULT_BCAST_STATUS);
            end else if (
                broadcaster_started_seen &&
                !broadcaster_epoch_exact) begin
                fail_closed(FAULT_BCAST_STATUS);
            end else if (
                queue_epoch_started &&
                !(queue_request_sent || queue_request_fire)) begin
                fail_closed(FAULT_QUEUE_STATUS);
            end else if (
                queue_epoch_started &&
                (queue_started_seen || !queue_epoch_active ||
                 queue_active_epoch != retained_epoch)) begin
                fail_closed(FAULT_QUEUE_STATUS);
            end else if (
                queue_epoch_active &&
                !(queue_request_sent || queue_request_fire)) begin
                fail_closed(FAULT_QUEUE_STATUS);
            end else if (
                queue_epoch_active &&
                queue_active_epoch != retained_epoch) begin
                fail_closed(FAULT_QUEUE_STATUS);
            end else if (
                queue_started_seen && !queue_epoch_exact) begin
                fail_closed(FAULT_QUEUE_STATUS);
            end else if (
                drain_epoch_started &&
                !(drain_request_sent || drain_request_fire)) begin
                fail_closed(FAULT_DRAIN_STATUS);
            end else if (
                drain_epoch_started &&
                (drain_started_seen || !drain_epoch_active ||
                 drain_active_epoch != retained_epoch)) begin
                fail_closed(FAULT_DRAIN_STATUS);
            end else if (
                drain_epoch_active &&
                !(drain_request_sent || drain_request_fire)) begin
                fail_closed(FAULT_DRAIN_STATUS);
            end else if (
                drain_epoch_active &&
                drain_active_epoch != retained_epoch) begin
                fail_closed(FAULT_DRAIN_STATUS);
            end else if (
                drain_started_seen && !drain_epoch_exact) begin
                fail_closed(FAULT_DRAIN_STATUS);
            end else begin
                if (!DIRECT_COMPLETION_MODE &&
                    ring_session_started)
                    ring_started_seen <= 1'b1;
                if (broadcaster_epoch_started)
                    broadcaster_started_seen <= 1'b1;
                if (queue_epoch_started)
                    queue_started_seen <= 1'b1;
                if (drain_epoch_started)
                    drain_started_seen <= 1'b1;

                if (broadcaster_request_fire) begin
                    broadcaster_pending <= 1'b0;
                    broadcaster_request_sent <= 1'b1;
                end
                if (queue_request_fire) begin
                    queue_pending <= 1'b0;
                    queue_request_sent <= 1'b1;
                end
                if (drain_request_fire) begin
                    drain_pending <= 1'b0;
                    drain_request_sent <= 1'b1;
                end

                case (state)
                    STATE_WAIT_QUIESCENT_LOW: begin
                        if (!transport_quiescent)
                            state <= STATE_WAIT_QUIESCENT_HIGH;
                    end

                    STATE_WAIT_QUIESCENT_HIGH: begin
                        if (transport_quiescent)
                            state <= STATE_WAIT_EXTERNAL_EPOCH;
                    end

                    STATE_WAIT_EXTERNAL_EPOCH: begin
                        if (!transport_quiescent) begin
                            state <= STATE_WAIT_QUIESCENT_HIGH;
                        end else if (epoch_request_fire) begin
                            observed_unaccepted_request <= 1'b0;
                            request_accepted <= 1'b1;
                            accepted_source_released <= 1'b0;
                            if (epoch_request == 0 ||
                                !epoch_request_fresh ||
                                epoch_request ==
                                    last_accepted_epoch) begin
                                fail_closed(
                                    FAULT_EXTERNAL_FORMAT);
                            end else begin
                                retained_epoch <= epoch_request;
                                last_accepted_epoch <=
                                    epoch_request;
                                retained_fresh <= 1'b1;
                                if (DIRECT_COMPLETION_MODE) begin
                                    broadcaster_pending <= 1'b1;
                                    queue_pending <= 1'b1;
                                    drain_pending <= 1'b1;
                                    state <=
                                        STATE_START_CONSUMERS;
                                end else begin
                                    state <= STATE_START_RING;
                                end
                            end
                        end
                    end

                    STATE_START_RING: begin
                        if (!transport_quiescent) begin
                            fail_closed(
                                FAULT_QUIESCENCE_LOST);
                        end else if (ring_request_fire) begin
                            ring_request_sent <= 1'b1;
                            state <= STATE_WAIT_RING;
                        end
                    end

                    STATE_WAIT_RING: begin
                        if (!transport_quiescent) begin
                            fail_closed(
                                FAULT_QUIESCENCE_LOST);
                        end else if (ring_session_started &&
                                     ring_session_active &&
                                     ring_active_epoch ==
                                        retained_epoch) begin
                            broadcaster_pending <= 1'b1;
                            queue_pending <= 1'b1;
                            drain_pending <= 1'b1;
                            state <= STATE_START_CONSUMERS;
                        end
                    end

                    STATE_START_CONSUMERS,
                    STATE_WAIT_CONSUMERS: begin
                        if (!transport_quiescent) begin
                            fail_closed(
                                FAULT_QUIESCENCE_LOST);
                        end else begin
                            state <= STATE_WAIT_CONSUMERS;
                            if (!broadcaster_pending &&
                                !queue_pending &&
                                !drain_pending &&
                                all_started_seen &&
                                all_epochs_exact)
                                state <= STATE_READY;
                        end
                    end

                    STATE_READY: begin
                        // Exact active status and all downstream faults are
                        // monitored above on every cycle.
                    end

                    STATE_FAILED: begin
                        state <= STATE_FAILED;
                    end

                    default: begin
                        fail_closed(FAULT_INTERNAL);
                    end
                endcase
            end
        end
    end
endmodule
