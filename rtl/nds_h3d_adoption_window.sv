`timescale 1ps/1ps

// A raw clk1x LCD phase, not a queued transport event, bounds this window.
// Require the last visible merge to finish before opening. Close at line 240,
// leaving at least 23 physical lines before line 0 can draw: ce never advances
// nds_gpu_timing by more than one of its 2130 cycles per clk1x. This margin
// covers window CDC/commit confirmation and reseeding the first two rows.
// A stalled DDR activation must wait for a later window in the reader.
module nds_h3d_adoption_window (
    input logic clk,
    input logic reset,
    input logic lcd_phase,
    input logic [8:0] lcd_line,
    input logic merge_start,
    input logic merge_end,
    input logic [7:0] merge_y,
    output logic switch_allowed
);
    logic blank_range;
    logic visible_tail_complete;
    // These bit tests are the exact unsigned ranges for all 512 line values.
    wire phase_in_window = lcd_line[8:6] == 3'b011 &&
        lcd_line[5:4] != 2'b11;
    wire phase_visible = !lcd_line[8] && lcd_line[7:6] != 2'b11;

    always_ff @(posedge clk) begin
        if (reset) begin
            blank_range <= 1'b0;
            visible_tail_complete <= 1'b0;
        end else begin
            if (lcd_phase) begin
                blank_range <= phase_in_window;
            end
            if (merge_end && merge_y == 8'd191)
                visible_tail_complete <= 1'b1;
            if (lcd_phase && phase_visible)
                visible_tail_complete <= 1'b0;
            if (merge_start) begin
                visible_tail_complete <= 1'b0;
            end
        end
    end

    // Tail completion implies no active merge: every start clears it, and
    // only the end of line 191 sets it. No separate active-merge bit is needed.
    // The event-cycle terms close immediately, before the state registers
    // update. A simultaneous first visible merge always wins over an old end.
    assign switch_allowed = !reset && blank_range &&
        visible_tail_complete && !merge_start &&
        !(lcd_phase && !phase_in_window);
endmodule
