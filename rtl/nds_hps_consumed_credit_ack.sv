// Receives credits only after the on-MiSTer HPS model has consumed them.
//
// This is a simulator-first protocol seam. It is deliberately disconnected
// from the production top and Quartus project. A future transport must publish
// one record after HpsOracleResponder has applied advance_external_cycles(),
// with one global sequence shared by posted writes, ordinary mailboxes, timing
// flushes, and synthetic halt ticks.
//
// Epoch and sequence zero are reserved. A reset does not make stale transport
// data safe: integration must first prove the old HPS/DDR epoch quiescent, then
// begin a fresh nonzero epoch before any acknowledgement is accepted.
module nds_hps_consumed_credit_ack (
    input  logic        clk,
    input  logic        reset,

    input  logic        epoch_begin_valid,
    output logic        epoch_begin_ready,
    input  logic [31:0] epoch_begin,
    input  logic        transport_quiescent,

    input  logic        ack_valid,
    output logic        ack_ready,
    input  logic [31:0] ack_epoch,
    input  logic [31:0] ack_sequence,
    input  logic        ack_cpu_arm9,
    input  logic [31:0] ack_cycles,
    // 0=posted write, 1=ordinary/timing mailbox, 2=synthetic halt tick.
    input  logic [1:0]  ack_kind,
    // Posted producer sequence or mailbox generation. Diagnostic only.
    input  logic [31:0] ack_source_id,

    output logic        credit_valid,
    input  logic        credit_ready,
    output logic        credit_arm9,
    output logic [31:0] credit_cycles,
    output logic [1:0]  credit_kind,
    output logic [31:0] credit_source_id,
    output logic        tracker_epoch_reset,
    output logic        epoch_active,
    output logic [31:0] active_epoch,
    output logic        sequence_exhausted,
    output logic        protocol_error
);
    logic [31:0] expected_sequence;

    // A new epoch is an explicit low-level reset handshake, not an in-band
    // record. Never race it with an acknowledgement or a retained output beat.
    assign epoch_begin_ready =
        transport_quiescent && !ack_valid && !credit_valid &&
        !protocol_error && !sequence_exhausted;

    // One retained output register supplies normal ready/valid backpressure.
    // Invalid records are accepted once and make the epoch fail closed.
    assign ack_ready =
        !protocol_error && !sequence_exhausted &&
        (!credit_valid || credit_ready);

    always_ff @(posedge clk) begin
        if (reset) begin
            credit_valid <= 1'b0;
            credit_arm9 <= 1'b0;
            credit_cycles <= 32'd0;
            credit_kind <= 2'd0;
            credit_source_id <= 32'd0;
            tracker_epoch_reset <= 1'b0;
            epoch_active <= 1'b0;
            active_epoch <= 32'd0;
            expected_sequence <= 32'd1;
            sequence_exhausted <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            tracker_epoch_reset <= 1'b0;
            if (credit_valid && credit_ready)
                credit_valid <= 1'b0;

            if (epoch_begin_valid && epoch_begin_ready) begin
                if (epoch_begin == 0 ||
                    (epoch_active && epoch_begin == active_epoch)) begin
                    protocol_error <= 1'b1;
                    epoch_active <= 1'b0;
                end else begin
                    active_epoch <= epoch_begin;
                    expected_sequence <= 32'd1;
                    epoch_active <= 1'b1;
                    tracker_epoch_reset <= 1'b1;
                end
            end

            if (ack_valid && ack_ready) begin
                if (!epoch_active || ack_epoch == 0 ||
                    ack_epoch != active_epoch ||
                    ack_sequence == 0 ||
                    ack_sequence != expected_sequence ||
                    ack_kind == 2'd3) begin
                    // A gap, duplicate, stale epoch, or reserved record would
                    // make local shared time unknowable. Stop until reset.
                    protocol_error <= 1'b1;
                    epoch_active <= 1'b0;
                    credit_valid <= 1'b0;
                end else begin
                    credit_valid <= 1'b1;
                    credit_arm9 <= ack_cpu_arm9;
                    credit_cycles <= ack_cycles;
                    credit_kind <= ack_kind;
                    credit_source_id <= ack_source_id;
                    expected_sequence <= expected_sequence + 1'b1;
                    if (ack_sequence == 32'hffffffff)
                        sequence_exhausted <= 1'b1;
                end
            end
        end
    end
endmodule
