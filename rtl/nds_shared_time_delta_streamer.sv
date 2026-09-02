// Converts an epoch-qualified absolute Nintendo DS shared timestamp into a
// lossless stream of nonzero, at-most-255-cycle deltas.
//
// The source may jump by any representable 64-bit amount.  Only one absolute
// timestamp is accepted at a time; ready/valid backpressure retains the entire
// un-emitted difference, so no finite catch-up requires a fixed-size delta
// accumulator.  A downstream nds_sound_cycle_scaler can then apply Robert
// Peip's proven factor of two.
//
// This is an isolated integration primitive.  It is intentionally absent from
// the production MiSTer top and QSF.
module nds_shared_time_delta_streamer (
    input  logic        clk,
    input  logic        reset,

    // Starting or replacing an epoch requires an explicit post-reset
    // quiescence transition: transport_quiescent must first be observed low and
    // then high.  epoch_begin_fresh is supplied by the persistent HPS/session
    // coordinator, which alone can prove freshness across an FPGA reset.
    input  logic        transport_quiescent,
    input  logic        epoch_begin_valid,
    output logic        epoch_begin_ready,
    input  logic [31:0] epoch_begin,
    input  logic        epoch_begin_fresh,
    output logic        epoch_started,
    output logic        epoch_active,
    output logic [31:0] active_epoch,

    // Absolute timestamps use an ordinary ready/valid contract.  The producer
    // must hold epoch and timestamp stable until timestamp_ready is asserted.
    input  logic        timestamp_valid,
    output logic        timestamp_ready,
    input  logic [31:0] timestamp_epoch,
    input  logic [63:0] timestamp,
    // Sticky overflow from the absolute timestamp producer.  It is meaningful
    // only in an active epoch and terminates that epoch immediately.
    input  logic        timestamp_overflow,

    output logic        delta_valid,
    input  logic        delta_ready,
    output logic [7:0]  delta_cycles,

    output logic [63:0] accepted_timestamp,
    output logic [63:0] remaining_cycles,
    output logic        protocol_error,
    output logic        overflow
);
    logic [31:0] last_epoch;
    logic quarantine_low_seen;

    function automatic logic [7:0] next_chunk(
        input logic [63:0] remaining
    );
        if (remaining > 64'd255)
            next_chunk = 8'd255;
        else
            next_chunk = remaining[7:0];
    endfunction

    always_comb begin
        // Epoch replacement is legal only at a completely drained boundary.
        // An asserted epoch request has priority over a simultaneous timestamp;
        // the timestamp producer simply retains its valid beat.
        epoch_begin_ready =
            quarantine_low_seen && transport_quiescent &&
            remaining_cycles == 0 && !delta_valid &&
            !protocol_error && !overflow;
        timestamp_ready =
            epoch_active && !epoch_begin_valid &&
            remaining_cycles == 0 && !delta_valid &&
            !protocol_error && !overflow;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            epoch_started <= 1'b0;
            epoch_active <= 1'b0;
            active_epoch <= 32'd0;
            last_epoch <= 32'd0;
            quarantine_low_seen <= 1'b0;
            accepted_timestamp <= 64'd0;
            remaining_cycles <= 64'd0;
            delta_valid <= 1'b0;
            delta_cycles <= 8'd0;
            protocol_error <= 1'b0;
            overflow <= 1'b0;
        end else begin
            epoch_started <= 1'b0;

            if (!transport_quiescent)
                quarantine_low_seen <= 1'b1;

            // A source-side timestamp overflow makes the absolute time
            // unknowable.  Discard every retained output and fail closed until
            // reset rather than emitting a partial interval.
            if (epoch_active && timestamp_overflow) begin
                epoch_active <= 1'b0;
                active_epoch <= 32'd0;
                remaining_cycles <= 64'd0;
                delta_valid <= 1'b0;
                delta_cycles <= 8'd0;
                overflow <= 1'b1;
            end else if (epoch_begin_valid && epoch_begin_ready) begin
                quarantine_low_seen <= 1'b0;
                remaining_cycles <= 64'd0;
                delta_valid <= 1'b0;
                delta_cycles <= 8'd0;
                accepted_timestamp <= 64'd0;

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
            end else if (timestamp_valid && timestamp_ready) begin
                if (timestamp_epoch == 0 ||
                    timestamp_epoch != active_epoch ||
                    timestamp < accepted_timestamp) begin
                    epoch_active <= 1'b0;
                    active_epoch <= 32'd0;
                    remaining_cycles <= 64'd0;
                    delta_valid <= 1'b0;
                    delta_cycles <= 8'd0;
                    protocol_error <= 1'b1;
                end else begin
                    // Equality is a valid no-op and never creates a zero beat.
                    remaining_cycles <= timestamp - accepted_timestamp;
                    accepted_timestamp <= timestamp;
                end
            end else if (delta_valid && delta_ready) begin
                if (remaining_cycles <= {56'd0, delta_cycles}) begin
                    remaining_cycles <= 64'd0;
                    delta_valid <= 1'b0;
                    delta_cycles <= 8'd0;
                end else begin
                    remaining_cycles <=
                        remaining_cycles - {56'd0, delta_cycles};
                    delta_cycles <= next_chunk(
                        remaining_cycles - {56'd0, delta_cycles});
                    delta_valid <= 1'b1;
                end
            end else if (!delta_valid && remaining_cycles != 0) begin
                delta_cycles <= next_chunk(remaining_cycles);
                delta_valid <= 1'b1;
            end
        end
    end
endmodule
