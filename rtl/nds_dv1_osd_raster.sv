// SPDX-License-Identifier: GPL-3.0-or-later
// Address the native DV1 menu in game pixels, not HDMI transport samples.
// Each font pixel therefore has the same aspect as a game pixel, including
// after external rotation. Bitmap RAM and the four-clock RGB pipeline are
// shared with the existing OSD; no framebuffer or extra bitmap is needed.
module nds_dv1_osd_raster #(parameter COMPACT_WIDTH = 0) (
    input wire clk, ce, de, vs, enable, info,
    input wire [1:0] rotation, // applied game rotation: 1=CW, 2=CCW
    input wire [11:0] info_x, info_y, width, height,
    output wire [12:0] address,
    output reg active = 0,
    output reg [2:0] bit_select = 0
);
    reg de_d = 0, vs_d = 0, frame_pending = 1;
    reg [9:0] x = 0, y = 0, canvas_width = 0, canvas_height = 0;
    wire line_start = de && !de_d;
    wire [9:0] next_x = line_start ? 10'd0 : ce && de ? x + 1'b1 : x;
    wire [9:0] next_y = line_start ? (frame_pending ? 10'd0 : y + 1'b1) : y;
    wire turned = rotation == 1 || rotation == 2;
    wire [11:0] source_width = turned ? {2'b0,canvas_height} : {2'b0,canvas_width};
    wire [11:0] source_height = turned ? {2'b0,canvas_width} : {2'b0,canvas_height};
    wire [11:0] source_x = rotation == 1 ? {2'b0,next_y} :
        rotation == 2 ? source_width - 1'b1 - next_y : {2'b0,next_x};
    wire [11:0] source_y = rotation == 1 ? source_height - 1'b1 - next_x :
        rotation == 2 ? {2'b0,next_x} : {2'b0,next_y};
    // Retain the side menu's 128-game-pixel footprint. Both bitmap columns
    // of each pair are read together and averaged in the OSD color stage.
    wire [11:0] display_width = COMPACT_WIDTH ? width >> 1 : width;
    wire [11:0] left = info ? info_x : source_width >= display_width ?
                      (source_width - display_width) >> 1 : 12'd0;
    wire [11:0] top = info ? info_y : source_height >= height ?
                     (source_height - height) >> 1 : 12'd0;
    wire [11:0] bx = source_x - left;
    wire [11:0] by = source_y - top;
    wire [7:0] bitmap_x = COMPACT_WIDTH ? {bx[6:0],1'b0} : bx[7:0];
    assign address = {by[7:3],bitmap_x};
    always @(posedge clk) begin
        de_d <= de;
        vs_d <= vs;
        // Both sync edges occur in blanking. Accept either polarity and
        // defer the frame origin until the first actual active pixel.
        if(vs != vs_d) frame_pending <= 1;
        if(line_start && frame_pending) begin
            canvas_height <= y + 1'b1;
            frame_pending <= 0;
        end
        if(!de && de_d) canvas_width <= x + 1'b1;
        x <= next_x;
        y <= next_y;
        // These registers accompany the synchronous bitmap read. The next
        // color stage uses the corresponding background pixel, not a later
        // sample, so RGB/DE/HS/VS keep their original four-clock latency.
        bit_select <= by[2:0];
        active <= enable && de && canvas_width != 0 && canvas_height != 0 &&
                  bx < display_width && by < height;
    end
endmodule
