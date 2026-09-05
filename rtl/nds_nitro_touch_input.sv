// SPDX-License-Identifier: GPL-3.0-or-later
// Lightweight MiSTer right-stick/mouse arbiter for the DS touchscreen.
//
// hps_io publishes mouse packets as a held 25-bit level: bit 24 toggles for
// every packet, bits 15:8/23:16 are signed X/Y deltas, and bit 0 is the left
// button. PS/2 positive Y is upward, so it is subtracted from the DS Y axis.
module nds_nitro_touch_input (
    input  logic        clk,
    input  logic        reset,
    input  logic        controller_pressed,
    input  logic [15:0] controller_analog,
    input  logic [24:0] ps2_mouse,
    output logic        touch_pressed,
    output logic [15:0] touch_analog
);
    logic mouse_toggle_d;
    logic controller_pressed_d;
    logic [15:0] controller_analog_d;
    logic use_mouse;
    // These are the unsigned values consumed by the console island before
    // its native 0..255 X and 0..191 Y conversion.
    logic [7:0] mouse_x_unsigned;
    logic [7:0] mouse_y_unsigned;

    wire mouse_event = ps2_mouse[24] != mouse_toggle_d;
    wire controller_event = controller_analog != controller_analog_d ||
                            (controller_pressed && !controller_pressed_d);
    wire signed [9:0] mouse_dx =
        $signed({{2{ps2_mouse[15]}},ps2_mouse[15:8]});
    wire signed [9:0] mouse_dy =
        $signed({{2{ps2_mouse[23]}},ps2_mouse[23:16]});
    wire signed [9:0] mouse_x_sum =
        $signed({2'b00,mouse_x_unsigned}) + mouse_dx;
    wire signed [9:0] mouse_y_sum =
        $signed({2'b00,mouse_y_unsigned}) - mouse_dy;

    function automatic logic [7:0] clamp_unsigned_byte(
        input logic signed [9:0] value
    );
        if (value < 0)
            clamp_unsigned_byte = 8'd0;
        else if (value > 10'sd255)
            clamp_unsigned_byte = 8'hff;
        else
            clamp_unsigned_byte = value[7:0];
    endfunction

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            mouse_toggle_d <= 1'b0;
            controller_pressed_d <= 1'b0;
            controller_analog_d <= 16'd0;
            use_mouse <= 1'b0;
            mouse_x_unsigned <= 8'd128;
            mouse_y_unsigned <= 8'd128;
        end else begin
            mouse_toggle_d <= ps2_mouse[24];
            controller_pressed_d <= controller_pressed;
            controller_analog_d <= controller_analog;

            // The most recently active device owns position and press state.
            if (controller_event)
                use_mouse <= 1'b0;
            if (mouse_event) begin
                mouse_x_unsigned <= clamp_unsigned_byte(mouse_x_sum);
                mouse_y_unsigned <= clamp_unsigned_byte(mouse_y_sum);
                use_mouse <= 1'b1;
            end
        end
    end

    // Flip the unsigned sign bits back to MiSTer's signed absolute-axis
    // representation. The console island performs the shared native DS
    // coordinate conversion for both mouse and right stick.
    wire [15:0] mouse_analog = {
        ~mouse_y_unsigned[7],mouse_y_unsigned[6:0],
        ~mouse_x_unsigned[7],mouse_x_unsigned[6:0]
    };
    assign touch_analog = use_mouse ? mouse_analog : controller_analog;
    assign touch_pressed = use_mouse ? ps2_mouse[0] : controller_pressed;
endmodule
