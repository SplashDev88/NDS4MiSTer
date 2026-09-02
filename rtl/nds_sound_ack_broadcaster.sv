// Retained two-consumer fork for one transport-validated reverse
// HPS-consumed acknowledgement.
//
// The upstream source uses a deliberately delayed ready handshake: it must
// hold valid and every payload bit stable while this block independently
// presents the retained record to the write-order queue and shared-time drain
// coordinator.  Upstream ready is asserted only in a registered retirement
// state reached after both consumers have accepted the record.  Therefore
// neither downstream ready participates combinationally in upstream ready.
//
// Each consumer sees valid until its own handshake, independently of the
// other consumer.  A consumer that accepts first cannot see the record again.
// Payload mutation or valid withdrawal before upstream retirement is an
// epoch-fatal protocol error.
//
// This is a simulator-first integration seam.  It is intentionally absent
// from the production MiSTer top and QSF.
module nds_sound_ack_broadcaster #(
    parameter logic [31:0] FIRST_ACK_SEQUENCE = 32'd1
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        transport_quiescent,
    input  logic        epoch_begin_valid,
    output logic        epoch_begin_ready,
    input  logic [31:0] epoch_begin,
    input  logic        epoch_begin_fresh,
    output logic        epoch_started,
    output logic        epoch_active,
    output logic [31:0] active_epoch,

    // The source must retain this record until ack_ready is sampled high.
    input  logic        ack_valid,
    output logic        ack_ready,
    input  logic [31:0] ack_epoch,
    input  logic [31:0] ack_sequence,
    input  logic        ack_cpu_arm9,
    input  logic [31:0] ack_cycles,
    input  logic [1:0]  ack_kind,
    input  logic [31:0] ack_source_id,

    // Consumer A: nds_sound_write_order_queue.ack_*.
    output logic        queue_ack_valid,
    input  logic        queue_ack_ready,
    output logic [31:0] queue_ack_epoch,
    output logic [31:0] queue_ack_sequence,
    output logic        queue_ack_cpu_arm9,
    output logic [1:0]  queue_ack_kind,
    output logic [31:0] queue_ack_source_id,

    // Consumer B: nds_sound_credit_drain_coordinator.credit_*.
    output logic        credit_valid,
    input  logic        credit_ready,
    output logic [31:0] credit_epoch,
    output logic [31:0] credit_ack_sequence,
    output logic        credit_cpu_arm9,
    output logic [31:0] credit_cycles,
    output logic [1:0]  credit_kind,

    output logic        busy,
    output logic        sequence_exhausted,
    output logic        protocol_error
);
    typedef enum logic [1:0] {
        STATE_EMPTY,
        STATE_DISTRIBUTE,
        STATE_RETIRE
    } state_t;

    state_t state;
    logic quarantine_low_seen;
    logic [31:0] last_epoch;
    logic [31:0] expected_ack_sequence;

    logic retained_queue_pending;
    logic retained_credit_pending;
    logic [31:0] retained_epoch;
    logic [31:0] retained_ack_sequence;
    logic retained_cpu_arm9;
    logic [31:0] retained_cycles;
    logic [1:0] retained_kind;
    logic [31:0] retained_source_id;

    wire retained_matches_source =
        ack_valid &&
        ack_epoch == retained_epoch &&
        ack_sequence == retained_ack_sequence &&
        ack_cpu_arm9 == retained_cpu_arm9 &&
        ack_cycles == retained_cycles &&
        ack_kind == retained_kind &&
        ack_source_id == retained_source_id;

    wire incoming_record_error =
        ack_valid &&
        (!epoch_active ||
         ack_epoch == 0 ||
         ack_epoch != active_epoch ||
         ack_sequence == 0 ||
         ack_sequence != expected_ack_sequence ||
         ack_kind == 2'b11 ||
         ack_source_id == 0);

    // This ready has no combinational path from either downstream ready.
    assign ack_ready =
        state == STATE_RETIRE && !protocol_error;
    wire ack_fire = ack_valid && ack_ready;

    assign queue_ack_valid =
        state == STATE_DISTRIBUTE &&
        retained_queue_pending && !protocol_error;
    assign credit_valid =
        state == STATE_DISTRIBUTE &&
        retained_credit_pending && !protocol_error;
    wire queue_ack_fire = queue_ack_valid && queue_ack_ready;
    wire credit_fire = credit_valid && credit_ready;

    assign queue_ack_epoch = retained_epoch;
    assign queue_ack_sequence = retained_ack_sequence;
    assign queue_ack_cpu_arm9 = retained_cpu_arm9;
    assign queue_ack_kind = retained_kind;
    assign queue_ack_source_id = retained_source_id;

    assign credit_epoch = retained_epoch;
    assign credit_ack_sequence = retained_ack_sequence;
    assign credit_cpu_arm9 = retained_cpu_arm9;
    assign credit_cycles = retained_cycles;
    assign credit_kind = retained_kind;

    assign busy = state != STATE_EMPTY;

    assign epoch_begin_ready =
        state == STATE_EMPTY &&
        quarantine_low_seen && transport_quiescent &&
        !ack_valid && !protocol_error && !sequence_exhausted;

    wire both_consumers_done =
        (!retained_queue_pending || queue_ack_fire) &&
        (!retained_credit_pending || credit_fire);

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= STATE_EMPTY;
            quarantine_low_seen <= 1'b0;
            last_epoch <= 32'd0;
            expected_ack_sequence <= FIRST_ACK_SEQUENCE;
            retained_queue_pending <= 1'b0;
            retained_credit_pending <= 1'b0;
            retained_epoch <= 32'd0;
            retained_ack_sequence <= 32'd0;
            retained_cpu_arm9 <= 1'b0;
            retained_cycles <= 32'd0;
            retained_kind <= 2'd0;
            retained_source_id <= 32'd0;
            epoch_started <= 1'b0;
            epoch_active <= 1'b0;
            active_epoch <= 32'd0;
            sequence_exhausted <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            epoch_started <= 1'b0;

            if (!transport_quiescent)
                quarantine_low_seen <= 1'b1;

            if (protocol_error) begin
                state <= STATE_EMPTY;
                retained_queue_pending <= 1'b0;
                retained_credit_pending <= 1'b0;
                epoch_active <= 1'b0;
                active_epoch <= 32'd0;
            end else if (state != STATE_EMPTY &&
                         !retained_matches_source) begin
                // The source withdrew or changed an unretired record.
                state <= STATE_EMPTY;
                retained_queue_pending <= 1'b0;
                retained_credit_pending <= 1'b0;
                epoch_active <= 1'b0;
                active_epoch <= 32'd0;
                protocol_error <= 1'b1;
            end else if (state == STATE_EMPTY &&
                         ack_valid && !sequence_exhausted &&
                         incoming_record_error) begin
                // Invalid records never reach either consumer.
                epoch_active <= 1'b0;
                active_epoch <= 32'd0;
                protocol_error <= 1'b1;
            end else if (epoch_begin_valid && epoch_begin_ready) begin
                quarantine_low_seen <= 1'b0;
                expected_ack_sequence <= FIRST_ACK_SEQUENCE;
                retained_queue_pending <= 1'b0;
                retained_credit_pending <= 1'b0;
                sequence_exhausted <= 1'b0;

                if (epoch_begin == 0 || !epoch_begin_fresh ||
                    epoch_begin == last_epoch) begin
                    epoch_active <= 1'b0;
                    active_epoch <= 32'd0;
                    protocol_error <= 1'b1;
                end else begin
                    epoch_active <= 1'b1;
                    active_epoch <= epoch_begin;
                    last_epoch <= epoch_begin;
                    epoch_started <= 1'b1;
                end
            end else begin
                case (state)
                    STATE_EMPTY: begin
                        if (ack_valid && !epoch_begin_valid &&
                            !sequence_exhausted) begin
                            retained_epoch <= ack_epoch;
                            retained_ack_sequence <= ack_sequence;
                            retained_cpu_arm9 <= ack_cpu_arm9;
                            retained_cycles <= ack_cycles;
                            retained_kind <= ack_kind;
                            retained_source_id <= ack_source_id;
                            retained_queue_pending <= 1'b1;
                            retained_credit_pending <= 1'b1;
                            state <= STATE_DISTRIBUTE;
                        end
                    end

                    STATE_DISTRIBUTE: begin
                        if (queue_ack_fire)
                            retained_queue_pending <= 1'b0;
                        if (credit_fire)
                            retained_credit_pending <= 1'b0;
                        if (both_consumers_done)
                            state <= STATE_RETIRE;
                    end

                    STATE_RETIRE: begin
                        if (ack_fire) begin
                            retained_queue_pending <= 1'b0;
                            retained_credit_pending <= 1'b0;
                            if (retained_ack_sequence == 32'hffffffff)
                                sequence_exhausted <= 1'b1;
                            else
                                expected_ack_sequence <=
                                    expected_ack_sequence + 1'b1;
                            state <= STATE_EMPTY;
                        end
                    end

                    default: begin
                        state <= STATE_EMPTY;
                        retained_queue_pending <= 1'b0;
                        retained_credit_pending <= 1'b0;
                        epoch_active <= 1'b0;
                        active_epoch <= 32'd0;
                        protocol_error <= 1'b1;
                    end
                endcase
            end
        end
    end
endmodule
