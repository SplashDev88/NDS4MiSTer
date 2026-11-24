// SPDX-License-Identifier: GPL-3.0-or-later
// LCD Grid 2 approximation for the integer-scaled HDMI picture, before OSD.
// Geometry comes from the scaler's active canvas (already rotated). The mask
// stays display-oriented, as in the saved RetroTINK reference. No frame RAM or
// division. Three small DSP products replace the logic-heavy shift/add trees.
(* altera_attribute="-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module nds_pixel_grid (
    input wire clk, reset, ce,
    input wire enable_async,
    input wire [1:0] strength_async,
    input wire [11:0] source_width, source_height,
    input wire [11:0] image_width, image_height,
    input wire [11:0] raster_width, raster_height,
    input wire [23:0] din,
    input wire hs_in, vs_in, de_in, brd_in,
    output wire [23:0] dout,
    output wire hs_out, vs_out, de_out
);
    (* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] control_meta=0, control_sync=0;
    reg [2:0] control_frame=0;
    wire [71:0] geometry={source_width,source_height,image_width,image_height,raster_width,raster_height};
    reg [71:0] geometry_frame=0;
    reg [2:0] scale=0;
    reg [2:0] xphase=0, yphase=0;
    reg picture_prev=0, vs_prev=0;
    wire picture=de_in && !brd_in;
    wire standard_mode=(raster_width==1280 && raster_height==720) ||
                       (raster_width==1920 && raster_height==1080);

    // Search 2x..5x in four enabled clocks after VS starts, during vertical
    // blanking. Share one adder/comparator per axis instead of evaluating
    // every scale in parallel. The captured geometry is the only input to
    // the search; a mid-frame change still triggers the pixel bypass below.
    // Fifteen bits hold 5*4095 without wrapping malformed geometry.
    reg [14:0] scaled_w=0, scaled_h=0;
    reg [2:0] scale_step=0;

    // Q4 gains. 4x is measured from the saved 1080p Grid 2 reference.
    // 2x/3x/5x area-average the same cell, avoiding a disproportionately dark
    // one-pixel seam at low scales. 1x and noninteger rectangles are bypassed.
    function automatic [4:0] cell_gain(input [2:0] s,x,y);
        begin
            cell_gain=16;
            case({s,y,x})
                {3'd2,3'd0,3'd0}:cell_gain=9;
                {3'd2,3'd1,3'd0}:cell_gain=11;
                {3'd2,3'd1,3'd1}:cell_gain=19;
                {3'd3,3'd0,3'd0}:cell_gain=6;
                {3'd3,3'd1,3'd0}:cell_gain=7;
                {3'd3,3'd1,3'd1}:cell_gain=20;
                {3'd3,3'd1,3'd2}:cell_gain=19;
                {3'd3,3'd2,3'd0}:cell_gain=6;
                {3'd3,3'd2,3'd1}, {3'd3,3'd2,3'd2}:cell_gain=18;
                {3'd4,3'd0,3'd0}:cell_gain=3;
                {3'd4,3'd0,3'd2}:cell_gain=15;
                {3'd4,3'd1,3'd0}:cell_gain=1;
                {3'd4,3'd1,3'd1}, {3'd4,3'd1,3'd2}:cell_gain=17;
                {3'd4,3'd2,3'd0}:cell_gain=4;
                {3'd4,3'd2,3'd1}, {3'd4,3'd2,3'd3}:cell_gain=22;
                {3'd4,3'd2,3'd2}:cell_gain=23;
                {3'd4,3'd3,3'd0}:cell_gain=2;
                {3'd5,3'd0,3'd0}:cell_gain=3;
                {3'd5,3'd0,3'd1}:cell_gain=13;
                {3'd5,3'd0,3'd3}:cell_gain=15;
                {3'd5,3'd1,3'd0}:cell_gain=2;
                {3'd5,3'd1,3'd1}:cell_gain=13;
                {3'd5,3'd1,3'd2}:cell_gain=17;
                {3'd5,3'd2,3'd0}:cell_gain=3;
                {3'd5,3'd2,3'd1}:cell_gain=15;
                {3'd5,3'd2,3'd2}, {3'd5,3'd2,3'd3}:cell_gain=20;
                {3'd5,3'd2,3'd4}:cell_gain=19;
                {3'd5,3'd3,3'd0}:cell_gain=4;
                {3'd5,3'd3,3'd2}, {3'd5,3'd3,3'd3}, {3'd5,3'd3,3'd4}:cell_gain=21;
                {3'd5,3'd4,3'd0}:cell_gain=2;
                {3'd5,3'd4,3'd1}:cell_gain=13;
                default:cell_gain=16;
            endcase
        end
    endfunction

    // Check each geometry field separately before the gain stage. A single
    // 72-bit equality folded into the gain mux made a nine-level path in the
    // first fit. These six registered comparisons preserve immediate bypass
    // for that pixel while giving each stage a short, bounded logic path.
    (* preserve *) reg [5:0] geometry_match_q=0;
    reg [4:0] base_gain=16;
    reg [1:0] strength_q=0;
    reg active_q=0, picture_q=0;
    always @(posedge clk) begin
        if(reset) begin
            geometry_match_q<=0; base_gain<=16; strength_q<=0;
            active_q<=0; picture_q<=0;
        end else if(ce) begin
            geometry_match_q<={geometry[71:60]==geometry_frame[71:60],
                              geometry[59:48]==geometry_frame[59:48],
                              geometry[47:36]==geometry_frame[47:36],
                              geometry[35:24]==geometry_frame[35:24],
                              geometry[23:12]==geometry_frame[23:12],
                              geometry[11:0]==geometry_frame[11:0]};
            base_gain<=cell_gain(scale,xphase,yphase);
            strength_q<=control_frame[1:0];
            active_q<=control_frame[2] && scale!=0;
            picture_q<=picture;
        end
    end
    reg [6:0] gain;
    always_comb begin
        gain=64;
        if(active_q && (&geometry_match_q) && picture_q) begin
            case(strength_q)
                1:gain=7'd32+{1'b0,base_gain,1'b0};
                2:gain={base_gain,2'b0};
                3:gain=base_gain<4 ? 7'd0 : ({base_gain,2'b0}+{2'b0,base_gain}-7'd16);
                default:gain=64;
            endcase
        end
    end

    always @(posedge clk) begin
        control_meta<={enable_async,strength_async};
        control_sync<=control_meta;
        if(reset) begin
            control_frame<=0; geometry_frame<=0; scale<=0;
            scaled_w<=0; scaled_h<=0; scale_step<=0;
            xphase<=0; yphase<=0; picture_prev<=0; vs_prev<=0;
        end else if(ce) begin
            vs_prev<=vs_in;
            picture_prev<=picture;
            if(vs_in && !vs_prev) begin
                geometry_frame<=geometry;
                control_frame<={control_sync[2] && standard_mode,control_sync[1:0]};
                scale<=0;
                scaled_w<={2'd0,source_width,1'b0};
                scaled_h<={2'd0,source_height,1'b0};
                scale_step<=source_width!=0 && source_height!=0 &&
                    image_width<=raster_width && image_height<=raster_height ? 3'd2 : 3'd0;
            end else if(scale_step!=0) begin
                if(scaled_w=={3'd0,geometry_frame[47:36]} &&
                   scaled_h=={3'd0,geometry_frame[35:24]}) begin
                    scale<=scale_step;
                    scale_step<=0;
                end else if(scale_step==5) scale_step<=0;
                else begin
                    scaled_w<=scaled_w+{3'd0,geometry_frame[71:60]};
                    scaled_h<=scaled_h+{3'd0,geometry_frame[59:48]};
                    scale_step<=scale_step+1'b1;
                end
            end
            if(!picture || xphase+3'd1>=scale) xphase<=0;
            else xphase<=xphase+1'b1;
            if(vs_in) yphase<=0;
            else if(picture_prev && !picture)
                yphase<=yphase+3'd1>=scale ? 3'd0 : yphase+1'b1;
        end
    end

    // Four matched stages, including bypass: mask/pixel, gain/pixel, DSP
    // product, rounded/saturated output. Keep CE identical on RGB and sync.
    reg [3:0] hs_pipe=0, vs_pipe=0, de_pipe=0;
    reg [6:0] gain_q=64;
    always @(posedge clk) begin
        if(reset) begin hs_pipe<=0; vs_pipe<=0; de_pipe<=0; gain_q<=64; end
        else if(ce) begin
            hs_pipe<={hs_pipe[2:0],hs_in};
            vs_pipe<={vs_pipe[2:0],vs_in};
            de_pipe<={de_pipe[2:0],de_in};
            gain_q<=gain;
        end
    end
    assign hs_out=hs_pipe[3];
    assign vs_out=vs_pipe[3];
    assign de_out=de_pipe[3];
    genvar c;
    generate for(c=0;c<3;c=c+1) begin: channel
        reg [7:0] pixel_in=0, pixel=0, result=0;
        // Unsigned 8x7 fits a Cyclone V 9x9 multiplier. Force DSP inference
        // so global area optimization cannot rebuild this in general logic.
        (* multstyle = "dsp" *) wire [14:0] multiply = pixel * gain_q;
        reg [14:0] product=0;
        wire [14:0] rounded=product+15'd32;
        always @(posedge clk) begin
            if(reset) begin
                pixel_in<=0; pixel<=0; result<=0; product<=0;
            end else if(ce) begin
                pixel_in<=din[c*8+:8];
                pixel<=pixel_in;
                product<=multiply;
                result<=rounded[14] ? 8'd255 : rounded[13:6];
            end
        end
        assign dout[c*8+:8]=result;
    end endgenerate
endmodule
