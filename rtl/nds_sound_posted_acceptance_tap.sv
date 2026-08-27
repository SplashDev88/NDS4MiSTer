// Passive metadata tap for nds_hps_posted_write_ring's acceptance edge.
//
// The real ring asserts `accepted` in CHECK_SPACE, before its public
// producer_sequence advances at the later commit beat.  CPU identity and
// elapsed cycles are also latched by the ring when it first observes the held
// request.  Sampling public producer_sequence or live request inputs directly
// on `accepted` is therefore wrong.
//
// This observer mirrors that behavior without changing or backpressuring the
// production ring: it captures request metadata only on the ring's IDLE
// launch edge, retains the launch-time producer frontier, and on `accepted`
// emits exactly `{frontier+1, captured CPU, captured cycles}`.  The output is
// a one-cycle pulse because nds_sound_posted_credit_merge is itself a
// no-backpressure bounded observer.
//
// This module is intentionally absent from the production MiSTer top and QSF.
module nds_sound_posted_acceptance_tap (
    input  logic        clk,
    input  logic        reset,

    input  logic        shadow_feature_enable,
    input  logic        shadow_session_active,
    input  logic [31:0] shadow_active_epoch,

    input  logic        posted_request,
    input  logic        posted_active,
    input  logic        posted_accepted,
    input  logic        posted_sequence_exhausted,
    input  logic [31:0] posted_producer_sequence,

    // Live ring request inputs.  They are sampled only on the launch edge.
    input  logic        posted_cpu_arm9,
    input  logic [31:0] posted_elapsed_cycles,

    output logic        acceptance_valid,
    output logic [31:0] acceptance_epoch,
    output logic        acceptance_cpu_arm9,
    output logic [31:0] acceptance_cycles,
    output logic [31:0] acceptance_producer_sequence,

    output logic        owner_active,
    output logic        protocol_error,
    output logic [7:0]  fault_code
);
    localparam logic [7:0] FAULT_NONE             = 8'h00;
    localparam logic [7:0] FAULT_SESSION          = 8'h01;
    localparam logic [7:0] FAULT_MULTIPLE_LAUNCH  = 8'h02;
    localparam logic [7:0] FAULT_OWNERLESS_ACCEPT = 8'h03;
    localparam logic [7:0] FAULT_FRONTIER_CHANGED = 8'h04;
    localparam logic [7:0] FAULT_SEQUENCE_END     = 8'h05;

    logic [31:0] owner_epoch;
    logic owner_cpu_arm9;
    logic [31:0] owner_cycles;
    logic [31:0] owner_frontier;
    logic [7:0] fatal_fault_code;

    wire launch_event =
        shadow_feature_enable && shadow_session_active &&
        posted_request && !posted_active;
    wire session_error =
        shadow_feature_enable &&
        ((posted_request || posted_accepted) &&
         (!shadow_session_active || shadow_active_epoch == 32'd0));
    wire owner_session_loss =
        owner_active &&
        (!shadow_feature_enable || !shadow_session_active ||
         shadow_active_epoch == 32'd0 ||
         shadow_active_epoch != owner_epoch);
    wire multiple_launch = launch_event && owner_active;
    wire ownerless_accept =
        posted_accepted && shadow_feature_enable &&
        shadow_session_active && !owner_active;
    wire frontier_changed =
        posted_accepted && owner_active &&
        (owner_epoch != shadow_active_epoch ||
         posted_producer_sequence != owner_frontier);
    wire sequence_end =
        (launch_event && posted_producer_sequence == 32'hffffffff) ||
        (posted_sequence_exhausted && owner_active);
    wire fatal_event =
        !protocol_error &&
        (session_error || owner_session_loss ||
         multiple_launch || ownerless_accept ||
         frontier_changed || sequence_end);

    always_comb begin
        if (session_error || owner_session_loss)
            fatal_fault_code = FAULT_SESSION;
        else if (multiple_launch)
            fatal_fault_code = FAULT_MULTIPLE_LAUNCH;
        else if (ownerless_accept)
            fatal_fault_code = FAULT_OWNERLESS_ACCEPT;
        else if (frontier_changed)
            fatal_fault_code = FAULT_FRONTIER_CHANGED;
        else if (sequence_end)
            fatal_fault_code = FAULT_SEQUENCE_END;
        else
            fatal_fault_code = FAULT_NONE;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            acceptance_valid <= 1'b0;
            acceptance_epoch <= 32'd0;
            acceptance_cpu_arm9 <= 1'b0;
            acceptance_cycles <= 32'd0;
            acceptance_producer_sequence <= 32'd0;
            owner_active <= 1'b0;
            owner_epoch <= 32'd0;
            owner_cpu_arm9 <= 1'b0;
            owner_cycles <= 32'd0;
            owner_frontier <= 32'd0;
            protocol_error <= 1'b0;
            fault_code <= FAULT_NONE;
        end else begin
            acceptance_valid <= 1'b0;
            if (fatal_event) begin
                owner_active <= 1'b0;
                protocol_error <= 1'b1;
                fault_code <= fatal_fault_code;
            end else if (!protocol_error) begin
                if (launch_event) begin
                    owner_active <= 1'b1;
                    owner_epoch <= shadow_active_epoch;
                    owner_cpu_arm9 <= posted_cpu_arm9;
                    owner_cycles <= posted_elapsed_cycles;
                    owner_frontier <= posted_producer_sequence;
                end
                // Acceptance while the shadow is disabled has no retained
                // owner and is intentionally invisible.  With the feature
                // active, ownerless acceptance is caught above and poisons
                // the epoch instead of fabricating zero/stale metadata.
                if (posted_accepted && owner_active) begin
                    owner_active <= 1'b0;
                    acceptance_valid <= 1'b1;
                    acceptance_epoch <= owner_epoch;
                    acceptance_cpu_arm9 <= owner_cpu_arm9;
                    acceptance_cycles <= owner_cycles;
                    acceptance_producer_sequence <=
                        owner_frontier + 1'b1;
                end
            end
        end
    end
endmodule
