// SPDX-License-Identifier: GPL-3.0-or-later
// Focused frame-linger, shape, and pressed-color proof for the touch pointer.
`timescale 1ns/1ps

module tb_nds_nitro_touch_pointer;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic reset = 1'b1;
    logic frame_boundary = 1'b0;
    logic touch_pressed = 1'b0;
    logic [7:0] touch_x = 8'd128;
    logic [7:0] touch_y = 8'd96;
    logic pixel_valid = 1'b1;
    logic [7:0] pixel_x = 8'd128;
    logic [7:0] pixel_y = 8'd96;
    wire pointer_visible;
    wire pointer_white_pixel;
    wire pointer_red_pixel;
    wire pointer_outline_pixel;

    nds_nitro_touch_pointer dut (.*);

    task automatic next_frame;
        begin
            @(negedge clk);
            frame_boundary = 1'b1;
            @(negedge clk);
            frame_boundary = 1'b0;
            #1;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 1'b0;
        #1;
        if (pointer_visible)
            $fatal(1, "pointer visible before right-stick movement");

        touch_x = 8'd42;
        touch_y = 8'd77;
        next_frame();
        pixel_x = 8'd42;
        pixel_y = 8'd77;
        #1;
        if (!pointer_visible || !pointer_white_pixel || pointer_red_pixel)
            $fatal(1, "moving pointer is not a white crosshair");

        pixel_x = 8'd43;
        pixel_y = 8'd81;
        #1;
        if (!pointer_outline_pixel || pointer_white_pixel)
            $fatal(1, "crosshair black outline shape mismatch");
        pixel_x = 8'd48;
        pixel_y = 8'd83;
        #1;
        if (pointer_white_pixel || pointer_red_pixel || pointer_outline_pixel)
            $fatal(1, "pointer footprint exceeds 11x11 pixels");

        // The default is exactly 30 display-frame intervals (about 0.5 s).
        pixel_x = 8'd42;
        pixel_y = 8'd77;
        repeat (29) next_frame();
        if (!pointer_visible || !pointer_white_pixel)
            $fatal(1, "pointer disappeared before 30-frame linger elapsed");
        next_frame();
        if (pointer_visible || pointer_white_pixel)
            $fatal(1, "pointer did not disappear after 30 idle frames");

        // Touch forces a continuously visible red crosshair, even after more
        // than the normal linger period, and release hides an idle pointer.
        touch_pressed = 1'b1;
        #1;
        if (!pointer_visible || !pointer_red_pixel || pointer_white_pixel)
            $fatal(1, "held Touch did not force a red pointer");
        repeat (35) begin
            next_frame();
            if (!pointer_visible || !pointer_red_pixel)
                $fatal(1, "red pointer dropped while Touch remained held");
        end
        touch_pressed = 1'b0;
        #1;
        if (pointer_visible || pointer_red_pixel)
            $fatal(1, "idle pointer remained after Touch release");

        pixel_valid = 1'b0;
        touch_pressed = 1'b1;
        #1;
        if (pointer_white_pixel || pointer_red_pixel || pointer_outline_pixel)
            $fatal(1, "pointer escaped the visible Engine-A slot");

        $display("PASS: right-stick pointer coordinates, 30-frame linger, outline, held red, and disappearance");
        $finish;
    end
endmodule
