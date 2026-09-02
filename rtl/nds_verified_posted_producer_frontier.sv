// Simulator-only proof seam for a future lightweight-bridge producer register.
//
// The physical posted ring may commit an entry before all of that entry's
// externally visible effects have been verified.  This block therefore
// advertises only the largest contiguous prefix which is safe for HPS to
// consume.  An ordinary physical commit advances the advertised frontier on
// its acceptance edge.  A verification-required commit is retained behind a
// hard barrier and cannot advance the frontier until a later, exactly matching
// verification pulse arrives.
//
// There is intentionally no queue behind the barrier.  Upstream must observe
// physical_commit_ready and stop issuing physical commits while verification
// is pending.  A pulse delivered while not ready is a protocol violation and
// freezes the last safe frontier.  The block is default-off and is not part of
// any Quartus project.

`timescale 1ns/1ps
`default_nettype none

module nds_verified_posted_producer_frontier #(
    parameter bit ENABLED = 1'b0,
    // Nonzero values exist for near-wrap directed simulation.  Production
    // sessions are expected to start from sequence zero.
    parameter logic [31:0] RESET_SEQUENCE = 32'd0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,

    // Pulse only after the ring's sequence commit marker was physically
    // accepted.  Sequences must be contiguous and may never wrap through zero.
    input  logic        physical_commit_valid,
    input  logic [31:0] physical_commit_sequence,
    input  logic        physical_commit_requires_verification,
    output logic        physical_commit_ready,
    output logic        physical_commit_accepted,

    // A verification pulse is legal only after a special physical commit and
    // must name that exact sequence.  Same-edge commit+verify is deliberately
    // rejected: verification cannot precede observation of the commit.
    input  logic        verify_valid,
    input  logic [31:0] verify_sequence,
    output logic        verify_ready,
    output logic        verify_accepted,

    // Future kLwRegProducer must use this safe frontier, never the raw ring
    // producer sequence.  It remains frozen on fault or runtime disable.
    output logic [31:0] advertised_sequence,
    output logic        frontier_advanced,
    output logic [31:0] last_physical_sequence,
    output logic        verification_pending,
    output logic [31:0] pending_sequence,
    output logic        protocol_error
);
    typedef enum logic [1:0] {
        DISARMED,
        READY,
        WAIT_VERIFY,
        FAULT
    } state_t;

    state_t state;
    logic [31:0] advertised_sequence_q;
    logic [31:0] last_physical_sequence_q;
    logic [31:0] pending_sequence_q;
    logic physical_commit_accepted_q;
    logic verify_accepted_q;
    logic frontier_advanced_q;

    logic commit_valid_known;
    logic verify_valid_known;
    logic commit_verification_known;

    assign commit_valid_known =
        physical_commit_valid === 1'b0 ||
        physical_commit_valid === 1'b1;
    assign verify_valid_known =
        verify_valid === 1'b0 || verify_valid === 1'b1;
    assign commit_verification_known =
        physical_commit_requires_verification === 1'b0 ||
        physical_commit_requires_verification === 1'b1;

    assign physical_commit_ready = ENABLED && !reset &&
        enable === 1'b1 && state == READY;
    assign verify_ready = ENABLED && !reset &&
        enable === 1'b1 && state == WAIT_VERIFY;

    assign physical_commit_accepted = ENABLED && !reset &&
        enable === 1'b1 &&
        physical_commit_accepted_q;
    assign verify_accepted = ENABLED && !reset &&
        enable === 1'b1 && verify_accepted_q;
    assign frontier_advanced = ENABLED && !reset &&
        enable === 1'b1 && frontier_advanced_q;

    // Only reset or the compile-time default-off gate may replace the safe
    // prefix.  Runtime disable and protocol faults freeze it monotonically.
    assign advertised_sequence = ENABLED && !reset
        ? advertised_sequence_q : RESET_SEQUENCE;
    assign last_physical_sequence = ENABLED && !reset
        ? last_physical_sequence_q : RESET_SEQUENCE;
    assign verification_pending = ENABLED && !reset &&
        pending_sequence_q != 32'd0;
    assign pending_sequence = ENABLED && !reset
        ? pending_sequence_q : 32'd0;
    assign protocol_error = ENABLED && !reset && state == FAULT;

    always_ff @(posedge clk) begin
        if (reset || !ENABLED) begin
            state <= DISARMED;
            advertised_sequence_q <= RESET_SEQUENCE;
            last_physical_sequence_q <= RESET_SEQUENCE;
            pending_sequence_q <= 32'd0;
            physical_commit_accepted_q <= 1'b0;
            verify_accepted_q <= 1'b0;
            frontier_advanced_q <= 1'b0;
        end else begin
            physical_commit_accepted_q <= 1'b0;
            verify_accepted_q <= 1'b0;
            frontier_advanced_q <= 1'b0;

            case (state)
                DISARMED: begin
                    // Arming consumes a quiet edge.  A commit or verification
                    // delivered before commit_ready/verify_ready is asserted
                    // has unknowable ownership and therefore fails closed.
                    if (enable !== 1'b0 && enable !== 1'b1) begin
                        state <= FAULT;
                    end else if (physical_commit_valid !== 1'b0 ||
                                 verify_valid !== 1'b0) begin
                        state <= FAULT;
                    end else if (enable === 1'b1) begin
                        state <= READY;
                    end
                end

                READY: begin
                    if (enable !== 1'b1 || !commit_valid_known ||
                        !verify_valid_known) begin
                        state <= FAULT;
                    end else if (verify_valid === 1'b1) begin
                        // Includes same-edge commit+verify.  There is no
                        // pending special commit at the start of this edge.
                        state <= FAULT;
                    end else if (physical_commit_valid === 1'b1) begin
                        if (!commit_verification_known ||
                            physical_commit_sequence == 32'd0 ||
                            last_physical_sequence_q == 32'hffffffff ||
                            physical_commit_sequence !==
                                last_physical_sequence_q + 32'd1) begin
                            // Duplicate, gap, zero/wrap, or unknown metadata.
                            state <= FAULT;
                        end else begin
                            last_physical_sequence_q <=
                                physical_commit_sequence;
                            physical_commit_accepted_q <= 1'b1;
                            if (physical_commit_requires_verification ===
                                1'b1) begin
                                pending_sequence_q <=
                                    physical_commit_sequence;
                                state <= WAIT_VERIFY;
                            end else begin
                                advertised_sequence_q <=
                                    physical_commit_sequence;
                                frontier_advanced_q <= 1'b1;
                            end
                        end
                    end
                end

                WAIT_VERIFY: begin
                    if (enable !== 1'b1 || !commit_valid_known ||
                        !verify_valid_known) begin
                        state <= FAULT;
                    end else if (physical_commit_valid === 1'b1) begin
                        // No commit may pass an unverified physical entry,
                        // even if its verification also arrives this edge.
                        state <= FAULT;
                    end else if (verify_valid === 1'b1) begin
                        if (pending_sequence_q == 32'd0 ||
                            verify_sequence !== pending_sequence_q) begin
                            state <= FAULT;
                        end else begin
                            advertised_sequence_q <= pending_sequence_q;
                            pending_sequence_q <= 32'd0;
                            verify_accepted_q <= 1'b1;
                            frontier_advanced_q <= 1'b1;
                            state <= READY;
                        end
                    end
                end

                FAULT: begin
                    // Sticky until reset.  In particular, re-enabling after a
                    // runtime disable cannot resurrect a pending commit.
                    state <= FAULT;
                end

                default: state <= FAULT;
            endcase
        end
    end
endmodule

`default_nettype wire
