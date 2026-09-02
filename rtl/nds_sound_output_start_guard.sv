// Prevents a supported mixer configuration from claiming audio ownership
// before Robert's engine has consumed time and produced a stable output.
//
// A known all-zero sample is valid silence; amplitude changes are not used as
// a readiness test.  Instead, one accepted cycle beat must be observed and a
// later clock must see both engine outputs known.  The known-value predicate
// is primarily a four-state simulation guard; synthesized hardware has only
// binary values.
`timescale 1ns/1ps
`default_nettype none

module nds_sound_output_start_guard (
    input  logic               clk,
    input  logic               reset,
    input  logic               engine_cycles_valid,
    input  logic signed [15:0] raw_audio_left,
    input  logic signed [15:0] raw_audio_right,
    output logic               output_started,
    output logic               output_known
);
    logic cycle_seen;

    always_comb begin
        output_known = 1'b0;
        if ((^raw_audio_left !== 1'bx) &&
            (^raw_audio_right !== 1'bx))
            output_known = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            cycle_seen <= 1'b0;
            output_started <= 1'b0;
        end else begin
            if (engine_cycles_valid === 1'b1)
                cycle_seen <= 1'b1;
            if (cycle_seen === 1'b1 &&
                output_known === 1'b1)
                output_started <= 1'b1;
        end
    end
endmodule

`default_nettype wire
