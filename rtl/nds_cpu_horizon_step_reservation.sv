// Stateless per-CPU instruction-start reservation against an HPS-certified
// inclusive run horizon.
//
// The safe-through horizon gate is the sole owner of absolute T9/T7.  This
// block forms each live completion candidate from that authoritative time and
// reserves the largest representable next instruction before allowing another
// start.  Keeping this block stateless is important: barrier rebases, epoch
// resets, and simultaneous CPU reports cannot diverge from a duplicate clock.
//
// The exact gba_cpu seam is nine bits.  With the reused wait table and the
// largest Underclock setting, a legal region-C/D LDM including PC can report
// 338 raw cycles. ARM9 normalization therefore reserves ceil(338/2) = 169;
// ARM7 reserves all 338. DMA is tied off and is outside this primitive.
//
// ENABLED defaults to zero. Merely instantiating the block therefore leaves
// both legacy do_step paths open and cannot change the working production core.

`timescale 1ns/1ps
`default_nettype none

module nds_cpu_horizon_step_reservation #(
    parameter bit          ENABLED = 1'b0,
    parameter logic [8:0] ARM9_MAX_NORMALIZED_CYCLES = 9'd169,
    parameter logic [8:0] ARM7_MAX_NORMALIZED_CYCLES = 9'd338
) (
    input  logic        reset,
    input  logic        enable,
    input  logic        session_active,
    input  logic        horizon_valid,
    input  logic        horizon_events_consumed,
    // stop_request is combinationally earlier than barrier admission. It
    // closes normal and IRQ starts while already-launched work drains.
    input  logic        barrier_stop_request,
    input  logic        barrier_active,
    input  logic [63:0] run_safe_through,

    input  logic [63:0] authoritative_arm9_timestamp,
    input  logic [63:0] authoritative_arm7_timestamp,
    input  logic        arm9_cycles_valid,
    input  logic [8:0]  arm9_normalized_cycles,
    input  logic        arm7_cycles_valid,
    input  logic [8:0]  arm7_normalized_cycles,

    output logic        arm9_advance_valid,
    output logic [63:0] arm9_advance_timestamp,
    output logic        arm7_advance_valid,
    output logic [63:0] arm7_advance_timestamp,
    output logic        arm9_step_permit,
    output logic        arm7_step_permit,
    output logic        stalled_arm9_on_horizon,
    output logic        stalled_arm7_on_horizon,
    output logic        report_error
);
    logic effective_enable;
    logic [64:0] arm9_candidate_ext;
    logic [64:0] arm7_candidate_ext;
    logic [64:0] arm9_reservation_end_ext;
    logic [64:0] arm7_reservation_end_ext;
    logic arm9_report_in_range;
    logic arm7_report_in_range;
    logic arm9_candidate_data_legal;
    logic arm7_candidate_data_legal;
    logic arm9_reservation_data_fits;
    logic arm7_reservation_data_fits;
    logic completion_present;
    logic completion_authorized;
    logic start_authorized;

    assign effective_enable = ENABLED && enable;

    assign arm9_candidate_ext = {1'b0, authoritative_arm9_timestamp} +
        (arm9_cycles_valid ? {56'd0, arm9_normalized_cycles} : 65'd0);
    assign arm7_candidate_ext = {1'b0, authoritative_arm7_timestamp} +
        (arm7_cycles_valid ? {56'd0, arm7_normalized_cycles} : 65'd0);
    assign arm9_advance_timestamp = arm9_candidate_ext[63:0];
    assign arm7_advance_timestamp = arm7_candidate_ext[63:0];
    assign arm9_report_in_range = !arm9_cycles_valid ||
        (arm9_normalized_cycles <= ARM9_MAX_NORMALIZED_CYCLES);
    assign arm7_report_in_range = !arm7_cycles_valid ||
        (arm7_normalized_cycles <= ARM7_MAX_NORMALIZED_CYCLES);
    // The candidate and maximum-next-step comparisons are a registered data
    // plane.  In production run_safe_through is the horizon gate's raw
    // registered reservation view.  Live reset/fault/session authorization
    // is applied only after this 64-bit cone, so those controls cannot become
    // selectors inside either adder/comparator.
    assign arm9_candidate_data_legal = arm9_report_in_range &&
        !arm9_candidate_ext[64] &&
        arm9_candidate_ext[63:0] <= run_safe_through;
    assign arm7_candidate_data_legal = arm7_report_in_range &&
        !arm7_candidate_ext[64] &&
        arm7_candidate_ext[63:0] <= run_safe_through;
    // A completion and a new instruction start are mutually exclusive.  The
    // enclosing path also closes both CPUs on the raw report edge, but make
    // that contract explicit here so live new_cycles_exact data cannot feed
    // the same-cycle do_step cone.  Completion candidates still retain the
    // exact reported cycles above; the next cycle's reservation starts from
    // the authoritative timestamp after that candidate is retired.
    assign arm9_reservation_end_ext =
        {1'b0, authoritative_arm9_timestamp} +
        {{56{1'b0}}, ARM9_MAX_NORMALIZED_CYCLES};
    assign arm7_reservation_end_ext =
        {1'b0, authoritative_arm7_timestamp} +
        {{56{1'b0}}, ARM7_MAX_NORMALIZED_CYCLES};
    assign arm9_reservation_data_fits = !arm9_reservation_end_ext[64] &&
        arm9_reservation_end_ext[63:0] <= run_safe_through;
    assign arm7_reservation_data_fits = !arm7_reservation_end_ext[64] &&
        arm7_reservation_end_ext[63:0] <= run_safe_through;

    // Live authorization is a shallow Boolean plane after the arithmetic.
    // barrier_stop_request includes same-edge raw CPU completions in the
    // enclosing path, so neither a stop nor a completion gains an extra
    // cycle of CPU-start exposure.
    assign completion_authorized = !reset && session_active &&
        horizon_valid;
    assign completion_present = arm9_cycles_valid || arm7_cycles_valid;
    assign start_authorized = completion_authorized &&
        horizon_events_consumed && !barrier_stop_request &&
        !barrier_active && !completion_present;

    // A malformed or out-of-horizon completion is evidence for the sticky
    // epoch fault in the enclosing path, never a timestamp update.  Keeping
    // advance-valid low on that edge prevents the horizon from momentarily
    // accepting a report that is rejected by report_error.
    assign arm9_advance_valid = effective_enable &&
        completion_authorized && arm9_cycles_valid &&
        arm9_candidate_data_legal;
    assign arm7_advance_valid = effective_enable &&
        completion_authorized && arm7_cycles_valid &&
        arm7_candidate_data_legal;

    // report_error can only arise from a presented completion.  Starts are
    // already closed whenever either completion lane is present, so feeding
    // report_error back into these permits is logically redundant and would
    // rebuild the measured completion-to-CPU critical path.
    assign arm9_step_permit = !effective_enable ||
        (start_authorized && arm9_reservation_data_fits);
    assign arm7_step_permit = !effective_enable ||
        (start_authorized && arm7_reservation_data_fits);

    assign stalled_arm9_on_horizon = effective_enable &&
        start_authorized && !arm9_reservation_data_fits;
    assign stalled_arm7_on_horizon = effective_enable &&
        start_authorized && !arm7_reservation_data_fits;

    // A stop request may legitimately race an already-launched completion.
    // An admitted barrier may not: quiescence is a prerequisite to admission.
    assign report_error = effective_enable && !reset && (
        ((arm9_cycles_valid || arm7_cycles_valid) &&
         (!session_active || !horizon_valid || !horizon_events_consumed ||
          barrier_active)) ||
        (arm9_cycles_valid && !arm9_candidate_data_legal) ||
        (arm7_cycles_valid && !arm7_candidate_data_legal));
endmodule

`default_nettype wire
