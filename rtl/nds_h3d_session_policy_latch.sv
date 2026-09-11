// SPDX-License-Identifier: GPL-3.0-or-later
// OSD selection is pending until Reset or a completed cartridge load. The
// shell's hps_io and this latch share ddr_clk; this is not an asynchronous bus.
// HPS-only session restarts do not enter this boundary or sample the menu.
module nds_h3d_session_policy_latch (
    input  logic        clk,
    input  logic        reset,
    input  logic        cart_ready,
    input  logic        engine_b_select,
    output logic [31:0] session_trigger,
    output logic        engine_b_applied,
    output logic        cart_ready_rise
);
    logic cart_ready_d;
    assign cart_ready_rise = cart_ready && !cart_ready_d;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            session_trigger <= 32'd0;
            engine_b_applied <= 1'b0;
            cart_ready_d <= 1'b0;
        end else begin
            cart_ready_d <= cart_ready;
            if (cart_ready_rise) begin
                session_trigger <= session_trigger == 32'hffffffff ?
                    32'd1 : session_trigger + 1'b1;
                engine_b_applied <= engine_b_select;
            end
        end
    end
endmodule
