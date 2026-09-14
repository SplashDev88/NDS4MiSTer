// SPDX-License-Identifier: GPL-3.0-or-later
// Inverse display transform in the existing normalized 8-bit touch space.
// Native DS clamping/calibration and the scanout cursor remain unchanged.
module nds_tate_input (
    input wire [1:0] rotation,
    input wire [15:0] analog_in,
    input wire [31:0] buttons_in,
    output reg [15:0] analog_out,
    output reg [31:0] buttons_out
);
    always @* begin
        analog_out = analog_in;
        buttons_out = buttons_in;
        case (rotation)
            1: begin
                analog_out = {~analog_in[7:0],analog_in[15:8]};
                buttons_out[3:0] = {buttons_in[0],buttons_in[1],buttons_in[3],buttons_in[2]};
            end
            2: begin
                analog_out = {analog_in[7:0],~analog_in[15:8]};
                buttons_out[3:0] = {buttons_in[1],buttons_in[0],buttons_in[2],buttons_in[3]};
            end
            default: begin end
        endcase
    end
endmodule

// Repeated addition computes the largest integer scale that fits both HDMI
// dimensions. No divider, multiplier or parallel bank of scale comparators.
// The HDMI mode is unchanged. Nonstandard/small modes retain a correct ratio.
module nds_tate_scale (
    input wire clk, reset,
    input wire [11:0] hdmi_width, hdmi_height,
    input wire [9:0] source_width, source_height,
    output reg [12:0] arx, ary
);
    reg [11:0] width_q=0, height_q=0;
    reg [9:0] source_w_q=0, source_h_q=0;
    reg [12:0] sum_x=0, sum_y=0;
    reg calculating=0;
    wire changed = width_q != hdmi_width || height_q != hdmi_height ||
        source_w_q != source_width || source_h_q != source_height;
    wire [12:0] next_x = sum_x + {3'd0,source_h_q};
    wire [12:0] next_y = sum_y + {3'd0,source_w_q};
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            width_q<=0; height_q<=0; source_w_q<=0; source_h_q<=0;
            sum_x<=0; sum_y<=0; calculating<=0; arx<=0; ary<=0;
        end else if (changed) begin
            width_q<=hdmi_width; height_q<=hdmi_height;
            source_w_q<=source_width; source_h_q<=source_height;
            sum_x<=0; sum_y<=0;
            calculating<=source_width != 0 && source_height != 0;
        end else if (calculating) begin
            if (next_x <= {1'b0,width_q} && next_y <= {1'b0,height_q}) begin
                sum_x<=next_x; sum_y<=next_y;
            end else begin
                calculating<=0;
                arx<=sum_x == 0 ? {3'd0,source_h_q} : 13'h1000 | sum_x;
                ary<=sum_y == 0 ? {3'd0,source_w_q} : 13'h1000 | sum_y;
            end
        end
    end
endmodule
