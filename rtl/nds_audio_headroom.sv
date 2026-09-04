// SPDX-License-Identifier: GPL-3.0-or-later
//
// Output-only headroom for the MiSTer audio boundary.  The Nintendo DS mixer
// remains bit-for-bit unchanged; this constant arithmetic shift happens after
// its architectural bias and signed clamp.  A constant shift synthesizes as
// wiring, so the experiment adds no multiplier, adder, state, or latency.
module nds_audio_headroom #(
    parameter integer SHIFT = 1
) (
    input  logic signed [15:0] input_left,
    input  logic signed [15:0] input_right,
    output logic signed [15:0] output_left,
    output logic signed [15:0] output_right
);

assign output_left = input_left >>> SHIFT;
assign output_right = input_right >>> SHIFT;

`ifndef SYNTHESIS
initial begin
    if (SHIFT < 0 || SHIFT > 15)
        $fatal(1, "NDS audio headroom shift must be in the range 0..15");
end
`endif

endmodule
