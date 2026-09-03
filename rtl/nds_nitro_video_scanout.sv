// SPDX-License-Identifier: GPL-3.0-or-later
// Native integer-layout scanout derived from Nitro_DarkSide NDS.sv d2dabe.
// Engine A/3D and the ARM-rendered Engine B plane are selected per physical
// DS panel. Layout and screen order affect placement only; panel one remains
// the physical touchscreen even when POWCNT1 swaps the two GPU engines.
//
// The touch pointer is deliberately a scanout-only overlay. It consumes the
// already-mapped DS coordinates below and therefore adds no framebuffer writes
// or DDR traffic. It is enabled only over physical panel one, so it follows
// screen-order and single-screen layout choices without appearing on the top
// non-touch display.
module nds_nitro_touch_pointer #(
    parameter integer LINGER_FRAMES = 30
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       frame_boundary,
    input  logic       touch_pressed,
    input  logic [7:0] touch_x,
    input  logic [7:0] touch_y,
    input  logic       pixel_valid,
    input  logic [7:0] pixel_x,
    input  logic [7:0] pixel_y,
    output logic       pointer_visible,
    output logic       pointer_white_pixel,
    output logic       pointer_red_pixel,
    output logic       pointer_outline_pixel
);
    localparam integer LINGER_BITS = LINGER_FRAMES < 2 ? 1 :
                                      $clog2(LINGER_FRAMES + 1);
    localparam logic [LINGER_BITS-1:0] LINGER_RELOAD = LINGER_FRAMES;

    logic [7:0] pointer_x;
    logic [7:0] pointer_y;
    logic [LINGER_BITS-1:0] linger_count;
    logic signed [8:0] delta_x;
    logic signed [8:0] delta_y;
    logic pointer_inner;
    logic pointer_outer;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            // Signed MiSTer stick zero maps to the DS screen center.
            pointer_x <= 8'd128;
            pointer_y <= 8'd96;
            linger_count <= '0;
        end else if (frame_boundary) begin
            // Sampling once per display frame prevents a pointer from tearing
            // between mirrored copies and makes the half-second hold exact.
            if (touch_x != pointer_x || touch_y != pointer_y)
                linger_count <= LINGER_RELOAD;
            else if (linger_count != 0)
                linger_count <= linger_count - 1'b1;
            pointer_x <= touch_x;
            pointer_y <= touch_y;
        end
    end

    always_comb begin
        // One signed subtract per axis is smaller than the previous absolute
        // distance implementation, which needed a compare, two subtracts, and
        // a mux for each coordinate. The inclusive bounds preserve the exact
        // 11x11 crosshair footprint, including at screen edges.
        delta_x = $signed({1'b0,pixel_x}) - $signed({1'b0,pointer_x});
        delta_y = $signed({1'b0,pixel_y}) - $signed({1'b0,pointer_y});
        // An 11x11 maximum footprint: a one-pixel cross with a one-pixel black
        // surround. The native-coordinate test scales with the DS image.
        pointer_inner =
            (delta_x == 0 && delta_y >= -9'sd4 && delta_y <= 9'sd4) ||
            (delta_y == 0 && delta_x >= -9'sd4 && delta_x <= 9'sd4);
        pointer_outer =
            (delta_x >= -9'sd1 && delta_x <= 9'sd1 &&
             delta_y >= -9'sd5 && delta_y <= 9'sd5) ||
            (delta_y >= -9'sd1 && delta_y <= 9'sd1 &&
             delta_x >= -9'sd5 && delta_x <= 9'sd5);
        pointer_visible = touch_pressed || linger_count != 0;
        pointer_red_pixel = pixel_valid && pointer_visible && touch_pressed &&
                            pointer_inner;
        pointer_white_pixel = pixel_valid && pointer_visible &&
                              !touch_pressed && pointer_inner;
        pointer_outline_pixel = pixel_valid && pointer_visible &&
                                pointer_outer && !pointer_inner;
    end
endmodule

module nds_nitro_video_scanout #(
    parameter integer FPS_WINDOW_FRAMES = 60
) (
    input  logic        clk_video,
    input  logic        reset,
    input  logic [1:0]  layout_select,
    input  logic        screen_order_select,
    input  logic [1:0]  gap_select,
    input  logic        fps_select,
    input  logic        touch_pressed,
    input  logic [7:0]  touch_x,
    input  logic [7:0]  touch_y,
    output logic [1:0]  layout_active,
    output logic        screen_order_active,
    output logic [1:0]  gap_active,
    output logic        fps_active,
    output logic        pf_tgl,
    output logic        pf_scr,
    output logic [7:0]  pf_line,
    output logic        pf_bank,
    output logic [1:0]  pf_frame_bank,
    output logic        pf_external,
    input  logic        published_frame_toggle,
    input  logic [1:0]  published_frame_bank,
    input  logic        external_screen_toggle,
    input  logic [1:0]  external_screen_bank,
    input  logic        external_screen_select,
    output logic        external_screen_adopted_toggle,
    // Toggles once for every distinct completed HPS 3D descriptor that has
    // reached the FPGA pixel domain.  This is intentionally separate from
    // the 2D framebuffer publication used for scanout bank ownership.
    input  logic        effective_3d_frame_toggle,
    output logic [8:0]  lb_raddr,
    input  logic [35:0] lb_q,
    output logic        ce_pixel,
    output logic        de,
    output logic        hsync,
    output logic        vsync,
    output logic [7:0]  red,
    output logic [7:0]  green,
    output logic [7:0]  blue
);
    localparam logic [1:0] LAYOUT_SIDE   = 2'd0;
    localparam logic [1:0] LAYOUT_STACK  = 2'd1;
    localparam logic [1:0] LAYOUT_LEFT   = 2'd2;
    localparam logic [1:0] LAYOUT_RIGHT  = 2'd3;
    localparam integer H_TOTAL = 640;
    localparam logic [15:0] V_EXTRA_STEP_NORMAL = 16'd11379;
    localparam logic [15:0] V_EXTRA_STEP_STACK  = 16'd22758;

    logic [9:0] hcount;
    logic [9:0] vcount;
    logic [2:0] pixel_divider;
    logic [15:0] frame_phase;
    logic frame_extra;
    (* async_reg = "true" *) logic [1:0] published_toggle_sync;
    (* async_reg = "true" *) logic [1:0] published_bank_sync_0;
    (* async_reg = "true" *) logic [1:0] published_bank_sync_1;
    (* async_reg = "true" *) logic [1:0] effective_3d_toggle_sync;
    (* async_reg = "true" *) logic [1:0] external_toggle_sync;
    (* async_reg = "true" *) logic [1:0] external_bank_sync_0;
    (* async_reg = "true" *) logic [1:0] external_bank_sync_1;
    (* async_reg = "true" *) logic [1:0] external_screen_sync;
    logic published_toggle_seen;
    logic effective_3d_toggle_seen;
    logic external_toggle_seen;
    logic pending_frame_valid;
    logic [1:0] pending_frame_bank;
    logic pending_external_valid;
    logic [1:0] pending_external_bank;
    logic pending_external_screen;
    logic [1:0] active_normal_bank;
    logic [1:0] active_screen_bank [0:1];
    logic active_screen_external [0:1];
    logic active_external_valid;
    logic active_external_screen;
    logic lb_half;

    logic screen_pixel;
    logic [7:0] local_x;
    logic [7:0] local_y;
    logic local_screen;
    logic next_screen_line;
    logic [7:0] next_local_y;
    logic next_local_screen;
    logic next_second_screen_line;
    logic next_second_local_screen;
    logic fps_font_pixel;
    logic [3:0] fps_count_tens;
    logic [3:0] fps_count_ones;
    logic [3:0] fps_display_tens;
    logic [3:0] fps_display_ones;
    logic [5:0] fps_window_frames;
    logic pointer_visible;
    logic pointer_white_pixel;
    logic pointer_red_pixel;
    logic pointer_outline_pixel;

    wire [4:0] gap_pixels = {gap_active,3'b000};
    wire [9:0] screen_top = fps_active ? 10'd6 : 10'd0;
    wire [9:0] second_x = 10'd256 + gap_pixels;
    wire [9:0] second_y = screen_top + 10'd192 + gap_pixels;
    wire [9:0] canvas_width = layout_active == LAYOUT_SIDE ?
                              10'd512 + gap_pixels : 10'd256;
    wire [9:0] canvas_height = layout_active == LAYOUT_STACK ?
        10'd384 + gap_pixels + (fps_active ? 10'd6 : 10'd0) :
        10'd192 + (fps_active ? 10'd6 : 10'd0);
    wire [9:0] vertical_total = layout_active == LAYOUT_STACK ?
                                10'd522 : 10'd261;
    wire [2:0] pixel_divider_limit = layout_active == LAYOUT_STACK ?
                                     3'd2 : 3'd5;
    wire [15:0] frame_step = layout_active == LAYOUT_STACK ?
                             V_EXTRA_STEP_STACK : V_EXTRA_STEP_NORMAL;
    wire [16:0] frame_sum = {1'b0,frame_phase} + {1'b0,frame_step};
    wire frame_end = vcount == vertical_total - 1'b1 + frame_extra;
    wire [9:0] vnext = frame_end ? 10'd0 : vcount + 1'b1;
    wire [9:0] hsync_begin = canvas_width + 10'd16;
    wire [9:0] hsync_end = canvas_width + 10'd64;
    wire [9:0] vsync_begin = canvas_height + 10'd3;
    wire [9:0] vsync_end = canvas_height + 10'd9;
    wire publication_event =
        published_toggle_sync[1] != published_toggle_seen;
    wire effective_3d_frame_event =
        effective_3d_toggle_sync[1] != effective_3d_toggle_seen;
    wire publication_available = publication_event || pending_frame_valid;
    wire [1:0] publication_bank = publication_event ?
        published_bank_sync_1 : pending_frame_bank;
    wire external_event =
        external_toggle_sync[1] != external_toggle_seen;
    wire external_available = external_event || pending_external_valid;
    wire [1:0] external_bank_for_boundary = external_event ?
        external_bank_sync_1 : pending_external_bank;
    wire external_screen_for_boundary = external_event ?
        external_screen_sync[1] : pending_external_screen;
    wire first_screen = screen_order_active;
    wire second_screen = !screen_order_active;

    function automatic logic [1:0] request_frame_bank(
        input logic requested_screen
    );
        logic [1:0] normal_bank;
        begin
            normal_bank = publication_available ?
                publication_bank : active_normal_bank;
            if (frame_end && external_available)
                request_frame_bank =
                    requested_screen == external_screen_for_boundary ?
                        external_bank_for_boundary : normal_bank;
            else if (frame_end && publication_available &&
                     (!active_external_valid ||
                      requested_screen != active_external_screen))
                request_frame_bank = normal_bank;
            else
                request_frame_bank = active_screen_bank[requested_screen];
        end
    endfunction

    function automatic logic request_is_external(
        input logic requested_screen
    );
        begin
            if (frame_end && external_available)
                request_is_external =
                    requested_screen == external_screen_for_boundary;
            else
                request_is_external =
                    active_screen_external[requested_screen];
        end
    endfunction

    function automatic logic [6:0] digit_segments(input logic [3:0] digit);
        case (digit)
            4'd0: digit_segments = 7'b1111110;
            4'd1: digit_segments = 7'b0110000;
            4'd2: digit_segments = 7'b1101101;
            4'd3: digit_segments = 7'b1111001;
            4'd4: digit_segments = 7'b0110011;
            4'd5: digit_segments = 7'b1011011;
            4'd6: digit_segments = 7'b1011111;
            4'd7: digit_segments = 7'b1110000;
            4'd8: digit_segments = 7'b1111111;
            default: digit_segments = 7'b1111011;
        endcase
    endfunction

    function automatic logic three_by_five_segment_pixel(
        input logic [2:0] x,
        input logic [2:0] y,
        input logic [6:0] segments
    );
        three_by_five_segment_pixel =
            (segments[6] && y == 0) ||
            (segments[5] && x == 2 && y == 1) ||
            (segments[4] && x == 2 && y == 3) ||
            (segments[3] && y == 4) ||
            (segments[2] && x == 0 && y == 3) ||
            (segments[1] && x == 0 && y == 1) ||
            (segments[0] && y == 2);
    endfunction

    // Map the current output dot into one of the two physical DS screens.
    always_comb begin
        screen_pixel = 1'b0;
        local_x = 8'd0;
        local_y = 8'd0;
        local_screen = first_screen;
        case (layout_active)
            LAYOUT_SIDE: begin
                if (vcount >= screen_top && vcount < screen_top + 10'd192) begin
                    local_y = vcount - screen_top;
                    if (hcount < 10'd256) begin
                        screen_pixel = 1'b1;
                        local_x = hcount[7:0];
                        local_screen = first_screen;
                    end else if (hcount >= second_x &&
                                 hcount < second_x + 10'd256) begin
                        screen_pixel = 1'b1;
                        local_x = hcount - second_x;
                        local_screen = second_screen;
                    end
                end
            end
            LAYOUT_STACK: begin
                if (hcount < 10'd256) begin
                    local_x = hcount[7:0];
                    if (vcount >= screen_top &&
                        vcount < screen_top + 10'd192) begin
                        screen_pixel = 1'b1;
                        local_y = vcount - screen_top;
                        local_screen = first_screen;
                    end else if (vcount >= second_y &&
                                 vcount < second_y + 10'd192) begin
                        screen_pixel = 1'b1;
                        local_y = vcount - second_y;
                        local_screen = second_screen;
                    end
                end
            end
            default: begin // Left-only and right-only are one 256x192 slot.
                if (hcount < 10'd256 && vcount >= screen_top &&
                    vcount < screen_top + 10'd192) begin
                    screen_pixel = 1'b1;
                    local_x = hcount[7:0];
                    local_y = vcount - screen_top;
                    local_screen = layout_active == LAYOUT_RIGHT ?
                        second_screen : first_screen;
                end
            end
        endcase
    end

    // Schedule the line(s) needed by the next raster row. Side-by-side fetches
    // both independent screens; stacked and single layouts fetch only the
    // screen visible on that output row.
    always_comb begin
        next_screen_line = 1'b0;
        next_local_y = 8'd0;
        next_local_screen = first_screen;
        next_second_screen_line = 1'b0;
        next_second_local_screen = second_screen;
        if (layout_active == LAYOUT_STACK) begin
            if (vnext >= screen_top && vnext < screen_top + 10'd192) begin
                next_screen_line = 1'b1;
                next_local_y = vnext - screen_top;
                next_local_screen = first_screen;
            end else if (vnext >= second_y &&
                         vnext < second_y + 10'd192) begin
                next_screen_line = 1'b1;
                next_local_y = vnext - second_y;
                next_local_screen = second_screen;
            end
        end else if (vnext >= screen_top &&
                     vnext < screen_top + 10'd192) begin
            next_screen_line = 1'b1;
            next_local_y = vnext - screen_top;
            if (layout_active == LAYOUT_SIDE) begin
                next_local_screen = first_screen;
                next_second_screen_line = 1'b1;
            end else begin
                next_local_screen = layout_active == LAYOUT_RIGHT ?
                    second_screen : first_screen;
            end
        end
    end

    always_comb begin
        fps_font_pixel = 1'b0;
        if (fps_active && vcount < 10'd5) begin
            // Tiny "F" plus two 3x5 decimal digits: an FPS label and value
            // outside the DS canvas for substantially less routing than 5x7.
            if (hcount < 10'd3)
                fps_font_pixel = hcount == 0 || vcount == 0 || vcount == 2;
            else if (hcount >= 10'd4 && hcount < 10'd7)
                fps_font_pixel = three_by_five_segment_pixel(hcount - 10'd4,
                    vcount[2:0], digit_segments(fps_display_tens));
            else if (hcount >= 10'd8 && hcount < 10'd11)
                fps_font_pixel = three_by_five_segment_pixel(hcount - 10'd8,
                    vcount[2:0], digit_segments(fps_display_ones));
        end
    end

    always_comb lb_raddr = {local_y[0], local_screen, local_x[7:1]};

    nds_nitro_touch_pointer touch_pointer (
        .clk(clk_video),
        .reset(reset),
        .frame_boundary(pixel_divider == pixel_divider_limit &&
                        hcount == H_TOTAL-1 && frame_end),
        .touch_pressed,
        .touch_x,
        .touch_y,
        .pixel_valid(screen_pixel && local_screen == 1'b1),
        .pixel_x(local_x),
        .pixel_y(local_y),
        .pointer_visible,
        .pointer_white_pixel,
        .pointer_red_pixel,
        .pointer_outline_pixel
    );

    always_ff @(posedge clk_video or posedge reset) begin
        if (reset) begin
            hcount <= 0;
            vcount <= 0;
            pixel_divider <= 0;
            frame_phase <= 0;
            frame_extra <= 0;
            layout_active <= LAYOUT_SIDE;
            screen_order_active <= 1'b0;
            gap_active <= 2'd0;
            fps_active <= 1'b0;
            published_toggle_sync <= 0;
            published_bank_sync_0 <= 0;
            published_bank_sync_1 <= 0;
            effective_3d_toggle_sync <= 0;
            external_toggle_sync <= 0;
            external_bank_sync_0 <= 0;
            external_bank_sync_1 <= 0;
            external_screen_sync <= 0;
            published_toggle_seen <= 0;
            effective_3d_toggle_seen <= 0;
            external_toggle_seen <= 0;
            pending_frame_valid <= 0;
            pending_frame_bank <= 0;
            pending_external_valid <= 0;
            pending_external_bank <= 0;
            pending_external_screen <= 0;
            active_normal_bank <= 0;
            active_screen_bank[0] <= 0;
            active_screen_bank[1] <= 0;
            active_screen_external[0] <= 0;
            active_screen_external[1] <= 0;
            active_external_valid <= 0;
            active_external_screen <= 0;
            external_screen_adopted_toggle <= 0;
            fps_count_tens <= 0;
            fps_count_ones <= 0;
            fps_display_tens <= 0;
            fps_display_ones <= 0;
            fps_window_frames <= 0;
            ce_pixel <= 0;
            hsync <= 1;
            vsync <= 1;
            de <= 0;
            red <= 0;
            green <= 0;
            blue <= 0;
            lb_half <= 0;
            pf_tgl <= 0;
            pf_scr <= 0;
            pf_line <= 0;
            pf_bank <= 0;
            pf_frame_bank <= 0;
            pf_external <= 0;
        end else begin
            published_toggle_sync <= {published_toggle_sync[0],
                                      published_frame_toggle};
            published_bank_sync_0 <= published_frame_bank;
            published_bank_sync_1 <= published_bank_sync_0;
            effective_3d_toggle_sync <= {effective_3d_toggle_sync[0],
                                         effective_3d_frame_toggle};
            external_toggle_sync <= {external_toggle_sync[0],
                                     external_screen_toggle};
            external_bank_sync_0 <= external_screen_bank;
            external_bank_sync_1 <= external_bank_sync_0;
            external_screen_sync <= {external_screen_sync[0],
                                     external_screen_select};
            if (publication_event) begin
                published_toggle_seen <= published_toggle_sync[1];
                pending_frame_valid <= 1'b1;
                pending_frame_bank <= published_bank_sync_1;
            end
            if (effective_3d_frame_event) begin
                effective_3d_toggle_seen <= effective_3d_toggle_sync[1];
                if (fps_count_ones == 4'd9) begin
                    fps_count_ones <= 0;
                    if (fps_count_tens != 4'd9)
                        fps_count_tens <= fps_count_tens + 1'b1;
                end else begin
                    fps_count_ones <= fps_count_ones + 1'b1;
                end
            end
            if (external_event) begin
                external_toggle_seen <= external_toggle_sync[1];
                pending_external_valid <= 1'b1;
                pending_external_bank <= external_bank_sync_1;
                pending_external_screen <= external_screen_sync[1];
            end

            lb_half <= local_x[0];
            ce_pixel <= pixel_divider == pixel_divider_limit;
            if (pixel_divider == pixel_divider_limit) begin
                pixel_divider <= 0;
                hsync <= !(hcount >= hsync_begin && hcount < hsync_end);
                vsync <= !(vcount >= vsync_begin && vcount < vsync_end);
                de <= hcount < canvas_width && vcount < canvas_height;
                if (fps_font_pixel) begin
                    red <= 8'hff; green <= 8'hff; blue <= 8'hff;
                end else if (pointer_red_pixel) begin
                    red <= 8'hff; green <= 8'h00; blue <= 8'h00;
                end else if (pointer_white_pixel) begin
                    red <= 8'hff; green <= 8'hff; blue <= 8'hff;
                end else if (pointer_outline_pixel) begin
                    red <= 8'h00; green <= 8'h00; blue <= 8'h00;
                end else if (screen_pixel) begin
                    {blue, green, red} <= lb_half
                        ? {lb_q[35:30],lb_q[35:34],lb_q[29:24],lb_q[29:28],
                           lb_q[23:18],lb_q[23:22]}
                        : {lb_q[17:12],lb_q[17:16],lb_q[11:6],lb_q[11:10],
                           lb_q[5:0],lb_q[5:4]};
                end else begin
                    red <= 0; green <= 0; blue <= 0;
                end

                if (hcount == 0 && frame_end) begin
                    if (publication_available) begin
                        active_normal_bank <= publication_bank;
                        pending_frame_valid <= 1'b0;
                    end
                    if (external_available) begin
                        active_screen_bank[external_screen_for_boundary] <=
                            external_bank_for_boundary;
                        active_screen_bank[!external_screen_for_boundary] <=
                            publication_available ? publication_bank :
                                active_normal_bank;
                        active_screen_external[
                            external_screen_for_boundary] <= 1'b1;
                        active_screen_external[
                            !external_screen_for_boundary] <= 1'b0;
                        active_external_valid <= 1'b1;
                        active_external_screen <=
                            external_screen_for_boundary;
                        pending_external_valid <= 1'b0;
                        external_screen_adopted_toggle <=
                            ~external_screen_adopted_toggle;
                    end else if (publication_available) begin
                        if (active_external_valid)
                            active_screen_bank[!active_external_screen] <=
                                publication_bank;
                        else begin
                            active_screen_bank[0] <= publication_bank;
                            active_screen_bank[1] <= publication_bank;
                        end
                    end
                end
                if (hcount == 0 && next_screen_line) begin
                    pf_scr <= next_local_screen;
                    pf_line <= next_local_y;
                    pf_bank <= next_local_y[0];
                    pf_frame_bank <= request_frame_bank(next_local_screen);
                    pf_external <= request_is_external(next_local_screen);
                    pf_tgl <= ~pf_tgl;
                end else if (hcount == 64 &&
                             next_second_screen_line) begin
                    pf_scr <= next_second_local_screen;
                    pf_line <= next_local_y;
                    pf_bank <= next_local_y[0];
                    pf_frame_bank <=
                        request_frame_bank(next_second_local_screen);
                    pf_external <=
                        request_is_external(next_second_local_screen);
                    pf_tgl <= ~pf_tgl;
                end

                if (hcount == H_TOTAL-1) begin
                    hcount <= 0;
                    vcount <= vnext;
                    if (frame_end) begin
                        // hps_io and this scanout both run on clk_sys; the OSD
                        // controls therefore need no redundant CDC pipeline.
                        {fps_active,gap_active,screen_order_active,
                         layout_active} <= {fps_select,gap_select,
                                            screen_order_select,layout_select};
                        if (fps_window_frames == FPS_WINDOW_FRAMES-1) begin
                            fps_window_frames <= 0;
                            if (effective_3d_frame_event) begin
                                if (fps_count_ones == 4'd9) begin
                                    fps_display_ones <= 0;
                                    fps_display_tens <= fps_count_tens == 4'd9 ?
                                                        4'd9 : fps_count_tens + 1'b1;
                                end else begin
                                    fps_display_ones <= fps_count_ones + 1'b1;
                                    fps_display_tens <= fps_count_tens;
                                end
                            end else begin
                                fps_display_ones <= fps_count_ones;
                                fps_display_tens <= fps_count_tens;
                            end
                            fps_count_ones <= 0;
                            fps_count_tens <= 0;
                        end else begin
                            fps_window_frames <= fps_window_frames + 1'b1;
                        end
                        if (frame_sum >= 17'd65536) begin
                            frame_phase <= frame_sum - 17'd65536;
                            frame_extra <= 1;
                        end else begin
                            frame_phase <= frame_sum[15:0];
                            frame_extra <= 0;
                        end
                    end
                end else begin
                    hcount <= hcount + 1'b1;
                end
            end else begin
                pixel_divider <= pixel_divider + 1'b1;
            end
        end
    end
endmodule

// Request a large exact integer multiple for the standard 720p/1080p/1440p/4K
// HDMI modes used by MiSTer. The explicit shift/add table deliberately avoids
// a variable multiplier and divider: this nearly-full Cyclone V cannot afford
// the generalized arithmetic cone. Bit 12 selects explicit-size mode.
module nds_nitro_integer_scale (
    input  logic [11:0] hdmi_width,
    input  logic [11:0] hdmi_height,
    input  logic [1:0]  layout,
    input  logic [1:0]  gap,
    input  logic        fps_enabled,
    output logic [12:0] video_arx,
    output logic [12:0] video_ary
);
    logic [9:0] source_width;
    logic [9:0] source_height;
    logic [3:0] scale;
    logic [2:0] resolution_tier;
    wire [12:0] source_width_13 = {3'd0,source_width};
    wire [12:0] source_height_13 = {3'd0,source_height};

    always_comb begin
        source_width = layout == 2'd0 ? 10'd512 + {gap,3'b000} : 10'd256;
        source_height = layout == 2'd1 ?
            10'd384 + {gap,3'b000} + (fps_enabled ? 10'd6 : 10'd0) :
            10'd192 + (fps_enabled ? 10'd6 : 10'd0);
        // Standard MiSTer modes are distinguishable from the upper height
        // bits alone: 720p, 1080p, 1440p and 2160p. Avoid twelve-bit
        // magnitude comparators on every layout branch.
        if (hdmi_height[11])
            resolution_tier = 3'd4;
        else if (hdmi_height[10] && (hdmi_height[9] || hdmi_height[8]))
            resolution_tier = 3'd3;
        else if (hdmi_height[10])
            resolution_tier = 3'd2;
        else if (hdmi_height[9])
            resolution_tier = 3'd1;
        else
            resolution_tier = 3'd0;
        scale = 0;
        case (layout)
            2'd0: begin
                case (resolution_tier)
                    4: scale = 7;
                    3: scale = gap == 0 && !fps_enabled ? 5 : 4;
                    2: scale = 3;
                    1: scale = 2;
                    default: scale = 0;
                endcase
            end
            2'd1: begin
                case (resolution_tier)
                    4: scale = 5;
                    3: scale = 3;
                    2: scale = 2;
                    1: scale = 1;
                    default: scale = 0;
                endcase
            end
            default: begin
                case (resolution_tier)
                    4: scale = fps_enabled ? 10 : 11;
                    3: scale = 7;
                    2: scale = 5;
                    1: scale = 3;
                    default: scale = 0;
                endcase
            end
        endcase

        case (scale)
            1: begin
                video_arx = 13'h1000 + source_width_13;
                video_ary = 13'h1000 + source_height_13;
            end
            2: begin
                video_arx = 13'h1000 + (source_width_13 << 1);
                video_ary = 13'h1000 + (source_height_13 << 1);
            end
            3: begin
                video_arx = 13'h1000 + (source_width_13 << 1) + source_width_13;
                video_ary = 13'h1000 + (source_height_13 << 1) + source_height_13;
            end
            4: begin
                video_arx = 13'h1000 + (source_width_13 << 2);
                video_ary = 13'h1000 + (source_height_13 << 2);
            end
            5: begin
                video_arx = 13'h1000 + (source_width_13 << 2) + source_width_13;
                video_ary = 13'h1000 + (source_height_13 << 2) + source_height_13;
            end
            7: begin
                video_arx = 13'h1000 + (source_width_13 << 3) - source_width_13;
                video_ary = 13'h1000 + (source_height_13 << 3) - source_height_13;
            end
            10: begin
                video_arx = 13'h1000 + (source_width_13 << 3) +
                            (source_width_13 << 1);
                video_ary = 13'h1000 + (source_height_13 << 3) +
                            (source_height_13 << 1);
            end
            11: begin
                video_arx = 13'h1000 + (source_width_13 << 3) +
                            (source_width_13 << 1) + source_width_13;
                video_ary = 13'h1000 + (source_height_13 << 3) +
                            (source_height_13 << 1) + source_height_13;
            end
            default: begin
                video_arx = source_width;
                video_ary = source_height;
            end
        endcase
    end
endmodule
