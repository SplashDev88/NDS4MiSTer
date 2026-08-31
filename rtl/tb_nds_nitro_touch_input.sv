// SPDX-License-Identifier: GPL-3.0-or-later
// Focused source selection, mouse sign, saturation, and button proof.
`timescale 1ns/1ps

module tb_nds_nitro_touch_input;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic reset = 1'b1;
    logic controller_pressed = 1'b0;
    logic [15:0] controller_analog = 16'd0;
    logic [24:0] ps2_mouse = 25'd0;
    wire touch_pressed;
    wire [15:0] touch_analog;

    nds_nitro_touch_input dut (.*);

    task automatic mouse_packet(
        input logic [7:0] buttons,
        input logic signed [7:0] dx,
        input logic signed [7:0] dy
    );
        begin
            @(negedge clk);
            ps2_mouse[23:0] = {dy,dx,buttons};
            ps2_mouse[24] = ~ps2_mouse[24];
            @(negedge clk);
            #1;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 1'b0;
        @(negedge clk);
        #1;
        if (touch_analog !== 16'd0 || touch_pressed)
            $fatal(1, "reset did not select the centered right stick");

        controller_analog = 16'hA355;
        @(negedge clk);
        #1;
        if (touch_analog !== 16'hA355)
            $fatal(1, "right-stick movement did not own touch position");

        // +X moves right; PS/2 +Y is up and therefore lowers native DS Y.
        mouse_packet(8'h00,8'sd10,8'sd5);
        if (touch_analog !== 16'hFB0A || touch_pressed)
            $fatal(1, "mouse sign/coordinate conversion mismatch %h",
                   touch_analog);

        mouse_packet(8'h01,8'sd0,8'sd0);
        if (!touch_pressed || touch_analog !== 16'hFB0A)
            $fatal(1, "left mouse button did not hold touch at mouse position");
        mouse_packet(8'h00,8'sd0,8'sd0);
        if (touch_pressed)
            $fatal(1, "left mouse button release left touch active");

        // A controller Touch press is activity even if the stick coordinate
        // has not changed, so it must switch cleanly back to the right stick.
        controller_pressed = 1'b1;
        @(negedge clk);
        #1;
        if (!touch_pressed || touch_analog !== 16'hA355)
            $fatal(1, "controller Touch did not reclaim the input source");
        controller_pressed = 1'b0;
        @(negedge clk);

        // Repeated large deltas clamp instead of wrapping at screen edges.
        repeat (3) mouse_packet(8'h00,8'sd127,-8'sd128);
        if (touch_analog !== 16'h7F7F)
            $fatal(1, "positive mouse saturation mismatch %h",touch_analog);
        repeat (3) mouse_packet(8'h00,-8'sd128,8'sd127);
        if (touch_analog !== 16'h8080)
            $fatal(1, "negative mouse saturation mismatch %h",touch_analog);

        $display("PASS: right-stick/mouse arbitration, button, sign, and saturation");
        $finish;
    end
endmodule
