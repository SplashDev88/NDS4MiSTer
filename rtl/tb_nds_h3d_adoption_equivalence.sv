`timescale 1ns/1ps
module tb_nds_h3d_adoption_equivalence;
    logic clk=0, reset=0, lcd_phase=0, merge_start=0, merge_end=0;
    logic [8:0] lcd_line=0;
    logic [7:0] merge_y=0;
    wire reduced_allowed, reference_allowed;
    nds_h3d_adoption_window dut (.clk, .reset, .lcd_phase, .lcd_line,
        .merge_start, .merge_end, .merge_y, .switch_allowed(reduced_allowed));
    nds_h3d_adoption_window_reference reference (.clk, .reset, .lcd_phase, .lcd_line,
        .merge_start, .merge_end, .merge_y, .switch_allowed(reference_allowed));
    integer cases=0;
    initial begin
        // Inductive equivalence: enumerate all states satisfying the invariant
        // tail_complete -> !merge_active, and every input equivalence class.
        for(integer s=0;s<8;s=s+1) begin
            if (!(s[1] && s[0])) begin
                for(integer line_value=0;line_value<512;line_value=line_value+1) begin
                    for(integer inputs=0;inputs<32;inputs=inputs+1) begin
                        clk=0;
                        reference.blank_range=s[2];
                        reference.visible_tail_complete=s[1];
                        reference.merge_active=s[0];
                        dut.blank_range=s[2];
                        dut.visible_tail_complete=s[1];
                        lcd_line=line_value;
                        {reset,lcd_phase,merge_start,merge_end}=inputs[4:1];
                        merge_y=inputs[0] ? 191 : 0;
                        #1;
                        if(reduced_allowed !== reference_allowed)
                            $fatal(1,"before edge mismatch state=%0d line=%0d inputs=%0d",s,line_value,inputs);
                        clk=1; #1;
                        if(reduced_allowed !== reference_allowed ||
                            dut.blank_range !== reference.blank_range ||
                            dut.visible_tail_complete !== reference.visible_tail_complete ||
                            (reference.visible_tail_complete && reference.merge_active))
                            $fatal(1,"inductive transition mismatch state=%0d line=%0d inputs=%0d",s,line_value,inputs);
                        cases=cases+1;
                    end
                end
            end
        end
        $display("PASS: reduced adoption controller is cycle-equivalent across %0d exhaustive invariant-preserving state/input cases",cases);
        $finish;
    end
endmodule

`timescale 1ps/1ps

// A raw clk1x LCD phase, not a queued transport event, bounds this window.
// Require the last visible merge to finish before opening. Close at line 240,
// leaving at least 23 physical lines before line 0 can draw: ce never advances
// nds_gpu_timing by more than one of its 2130 cycles per clk1x. This margin
// covers window CDC/commit confirmation and reseeding the first two rows.
// A stalled DDR activation must wait for a later window in the reader.
module nds_h3d_adoption_window_reference (
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
    logic merge_active;

    always_ff @(posedge clk) begin
        if (reset) begin
            blank_range <= 1'b0;
            visible_tail_complete <= 1'b0;
            merge_active <= 1'b0;
        end else begin
            if (lcd_phase) begin
                blank_range <= lcd_line >= 9'd192 && lcd_line < 9'd240;
            end
            if (merge_end) begin
                merge_active <= 1'b0;
                if (merge_y == 8'd191)
                    visible_tail_complete <= 1'b1;
            end
            if (lcd_phase && lcd_line < 9'd192)
                visible_tail_complete <= 1'b0;
            if (merge_start) begin
                merge_active <= 1'b1;
                visible_tail_complete <= 1'b0;
            end
        end
    end

    // The event-cycle terms close immediately, before the state registers
    // update. A simultaneous first visible merge always wins over an old end.
    assign switch_allowed = !reset && blank_range &&
        visible_tail_complete && !merge_active && !merge_start &&
        !(lcd_phase && (lcd_line < 9'd192 || lcd_line >= 9'd240));
endmodule
