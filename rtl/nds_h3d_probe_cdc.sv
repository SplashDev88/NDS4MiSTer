// SPDX-License-Identifier: GPL-3.0-or-later
// Passive bundled-data observer. The source holds data across a toggle and
// until its next snapshot (62.6 ms); only the toggle crosses synchronizers.
module nds_h3d_probe_cdc (
    input logic clk, reset,
    input logic [31:0] source_data,
    input logic source_toggle,
    output logic [31:0] sample_data
);
    (* async_reg = "true" *) logic [2:0] toggle_sync;
    logic seen;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            toggle_sync <= 3'd0;
            seen <= 1'b0;
            sample_data <= 32'd0;
        end else begin
            toggle_sync <= {toggle_sync[1:0], source_toggle};
            if (toggle_sync[2] != seen) begin
                sample_data <= source_data;
                seen <= toggle_sync[2];
            end
        end
    end
endmodule
