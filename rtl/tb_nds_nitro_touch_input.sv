// SPDX-License-Identifier: GPL-3.0-or-later
// Focused source selection, controller range, mouse sign/saturation, and
// button proof.
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
    integer axis_value;
    integer previous_x;
    integer previous_y;
    integer current_x;
    integer current_y;

    nds_nitro_touch_input dut (.*);

    function automatic integer native_x(input logic [7:0] axis);
        native_x = {~axis[7],axis[6:0]};
    endfunction

    function automatic integer native_y(input logic [7:0] axis);
        native_y = (3 * {~axis[7],axis[6:0]}) >> 2;
    endfunction

    task automatic controller_position(
        input logic signed [7:0] x,
        input logic signed [7:0] y
    );
        begin
            @(negedge clk);
            controller_analog = {y,x};
            @(negedge clk);
            #1;
        end
    endtask

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

        // The arbiter preserves the controller's documented -127..+127 byte
        // values. Full-edge normalization happens once, after source
        // arbitration, in the console-island native-coordinate conversion.
        controller_position(-8'sd127,-8'sd127);
        if (touch_analog !== 16'h8181 ||
            native_x(touch_analog[7:0]) != 1 ||
            native_y(touch_analog[15:8]) != 0)
            $fatal(1, "controller raw negative endpoint changed analog=%h x=%0d y=%0d",
                   touch_analog,native_x(touch_analog[7:0]),
                   native_y(touch_analog[15:8]));

        controller_position(8'sd0,8'sd0);
        if (touch_analog !== 16'h0000 ||
            native_x(touch_analog[7:0]) != 128 ||
            native_y(touch_analog[15:8]) != 96)
            $fatal(1, "controller center changed analog=%h x=%0d y=%0d",
                   touch_analog,native_x(touch_analog[7:0]),
                   native_y(touch_analog[15:8]));

        controller_position(8'sd127,8'sd127);
        if (touch_analog !== 16'h7F7F ||
            native_x(touch_analog[7:0]) != 255 ||
            native_y(touch_analog[15:8]) != 191)
            $fatal(1, "positive full deflection missed far edges analog=%h x=%0d y=%0d",
                   touch_analog,native_x(touch_analog[7:0]),
                   native_y(touch_analog[15:8]));

        previous_x = -1;
        previous_y = -1;
        for (axis_value = -127; axis_value <= 127; axis_value = axis_value + 1) begin
            controller_position(axis_value[7:0],axis_value[7:0]);
            if (touch_analog[7:0] !== axis_value[7:0])
                $fatal(1, "controller arbiter changed X raw=%h got=%h",
                       axis_value[7:0],touch_analog[7:0]);
            current_x = native_x(touch_analog[7:0]);
            current_y = native_y(touch_analog[15:8]);
            if (current_x < previous_x || current_y < previous_y)
                $fatal(1, "controller mapping is not monotonic at raw=%0d: (%0d,%0d) after (%0d,%0d)",
                       axis_value,current_x,current_y,previous_x,previous_y);
            previous_x = current_x;
            previous_y = current_y;
        end

        // Values around the existing MiSTer deadzone/center are identity
        // mapped; this range extension must not introduce a new deadzone.
        controller_position(-8'sd1,-8'sd1);
        if (touch_analog !== 16'hFFFF)
            $fatal(1, "negative center neighbor changed %h",touch_analog);
        controller_position(8'sd1,8'sd1);
        if (touch_analog !== 16'h0101)
            $fatal(1, "positive center neighbor changed %h",touch_analog);
        controller_position(8'h55,8'hA3);
        if (touch_analog !== 16'hA355)
            $fatal(1, "controller test position was not restored %h",
                   touch_analog);

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
        mouse_packet(8'h00,8'sd1,-8'sd1);
        if (touch_analog !== 16'h8181)
            $fatal(1, "controller endpoint normalization altered mouse pixels %h",
                   touch_analog);

        $display("PASS: right-stick identity/monotonicity and mouse arbitration/saturation");
        $finish;
    end
endmodule
