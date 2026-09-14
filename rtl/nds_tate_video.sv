// SPDX-License-Identifier: GPL-3.0-or-later
// Optional HDMI rotation. Four or eight source rows are transposed in
// ping-pong strip RAM, then written as full 128-bit beats on the scaler port.
// No access uses the console's DDR port. A late strip drops the unpublished
// display frame; it never stalls the DS or publishes partially written data.
module nds_tate_video #(
    parameter integer CCW_ONLY = 0,
    parameter integer TILE_ROWS = 4, // 4 or 8; one or two full DDR beats
    parameter [27:0] RAM_BASE = 28'h2400000 // byte 0x24000000, 3 x 1 MiB
) (
    input  wire reset,
    input  wire i_clk, i_ce, i_de, i_vs,
    input  wire [23:0] i_rgb,
    input  wire [1:0] rotation, // 0=Off, 1=CW, 2=CCW
    input  wire [9:0] source_width, source_height,
    input  wire avl_clk,
    input  wire o_clk, o_vbl,
    output wire fb_enable,
    output wire [1:0] rotation_applied,
    output reg [9:0] fb_width, fb_height,
    output wire [31:0] fb_base,
    output reg [13:0] fb_stride,
    output wire [27:0] wr_address,
    output wire [127:0] wr_data,
    output wire wr_valid,
    input  wire wr_ready,
    output reg overflow = 0
);
    localparam ROW_BITS = $clog2(TILE_ROWS);
    localparam DEST_BITS = 10 - ROW_BITS;
    reg old_vs = 1, frame_pending = 1, live = 0;
    reg [1:0] mode = 0;
    reg [9:0] width = 0, height = 0, x = 0, y = 0;
    reg [ROW_BITS-1:0] row_lane = 0;
    reg bank = 0, request = 0;
    reg acknowledge = 0;
    (* async_reg = "true" *) reg [1:0] ack_sync = 0;
    reg req_bank, req_last;
    reg [1:0] req_mode;
    reg [9:0] req_width, req_height;
    reg [DEST_BITS-1:0] req_dest_strip;
    wire starting = i_ce && i_de && frame_pending;
    wire want = (!CCW_ONLY && rotation == 1) || rotation == 2;
    wire busy = request != ack_sync[1];
    wire pixel_write = i_ce && i_de &&
        (starting ? (want && !busy) : live);
    wire [9:0] pixel_x = starting ? 10'd0 : x;
    wire [ROW_BITS-1:0] pixel_lane = starting ?
        (!CCW_ONLY && rotation == 1 ? source_height[ROW_BITS-1:0] - 1'b1 : {ROW_BITS{1'b0}}) : row_lane;
    wire [10:0] write_index = {bank,pixel_x};
    wire last_line = y == height - 1'b1;
    wire [9:0] cw_dest_x = height - 1'b1 - y;

    always @(posedge i_clk or posedge reset) begin
        if (reset) begin
            old_vs <= 1; frame_pending <= 1; live <= 0;
            mode <= 0; width <= 0; height <= 0; x <= 0;
            y <= 0; row_lane <= 0;
            bank <= 0; request <= 0; ack_sync <= 0; overflow <= 0;
        end else begin
            ack_sync <= {ack_sync[0],acknowledge};
            if (i_ce) begin
                old_vs <= i_vs;
                if (old_vs && !i_vs) begin
                    frame_pending <= 1;
                    live <= 0;
                end
                if (i_de) begin
                    if (frame_pending) begin
                        frame_pending <= 0;
                        live <= want && !busy;
                        mode <= CCW_ONLY ? 2'd2 : rotation; width <= source_width;
                        height <= source_height; x <= 1;
                        y <= 0; row_lane <= !CCW_ONLY && rotation == 1 ? source_height[ROW_BITS-1:0] - 1'b1 : {ROW_BITS{1'b0}};
                        if (want && busy) overflow <= 1;
                    end else if (live) begin
                        if (x == width - 1'b1) begin
                            x <= 0;
                            y <= y + 1'b1;
                            row_lane <= mode == 1 ? row_lane - 1'b1 : row_lane + 1'b1;
                            if ((mode == 1 ? row_lane == 0 : row_lane == TILE_ROWS-1) || last_line) begin
                                if (busy) begin
                                    live <= 0; overflow <= 1;
                                end else begin
                                    req_bank <= bank; req_mode <= CCW_ONLY ? 2'd2 : mode;
                                    req_width <= width; req_height <= height;
                                    req_dest_strip <= mode == 1 ? cw_dest_x[9:ROW_BITS] : y[9:ROW_BITS];
                                    req_last <= last_line;
                                    request <= ~request;
                                    bank <= ~bank;
                                    if (last_line) live <= 0;
                                end
                            end
                        end else x <= x + 1'b1;
                    end
                end
            end
        end
    end

    reg [9:0] column = 0;
    reg read_bank = 0;
    wire [10:0] read_index = {read_bank,column};
    // The native scanout expands each RGB666 channel by repeating its high
    // two bits, including the black/white/red overlays. VGA_SL is tied Off
    // in this core, so its scaler input preserves that exact relationship.
    // Store the original six bits and reconstruct them without quantization.
    wire [17:0] lane_q [0:TILE_ROWS-1];
    genvar lane;
    generate for (lane=0; lane<TILE_ROWS; lane=lane+1) begin: strips
        // RAM has no reset. The request/acknowledge handshake keeps the
        // published strip immutable across the two clocks until drained.
        (* ramstyle = "M10K, no_rw_check" *) reg [17:0] pixels [0:2047];
        reg [17:0] q;
        always @(posedge i_clk)
            if (pixel_write && pixel_lane == lane)
                pixels[write_index] <= {i_rgb[23:18],i_rgb[15:10],i_rgb[7:2]};
        always @(posedge avl_clk) q <= pixels[read_index];
        assign lane_q[lane] = q;
    end endgenerate

    (* async_reg = "true" *) reg [1:0] request_sync = 0;
    (* async_reg = "true" *) reg [1:0] display_ack_sync = 0;
    (* async_reg = "true" *) reg [1:0] display_bank_meta = 2, display_bank_sync = 2;
    reg [1:0] write_fb = 0, ready_fb = 0, display_fb = 2;
    reg completed = 0, display_ack = 0;
    reg [9:0] ready_width, ready_height;
    reg [13:0] ready_stride;
    reg [1:0] ready_mode;
    // Every native layout fits within one 1-MiB frame slot. Keep the slot
    // separate from its word offset so row stepping needs only a 16-bit adder.
    reg [15:0] address = 0;
    reg [2:0] state = 0;
    reg [9:0] strip_width;
    reg [8:0] stride_words;
    reg strip_last;
    reg [1:0] strip_mode;
    localparam IDLE=0, RAM_WAIT=1, RAM_LOAD=2, BEAT0=3, BEAT1=4;

    function automatic [1:0] free_bank(input [1:0] a, b);
        if (a != 0 && b != 0) free_bank = 0;
        else if (a != 1 && b != 1) free_bank = 1;
        else free_bank = 2;
    endfunction
    function automatic [31:0] pixel_word(input [17:0] rgb);
        pixel_word = {8'd0,rgb[5:0],rgb[5:4],rgb[11:6],rgb[11:10],rgb[17:12],rgb[17:16]};
    endfunction
    assign wr_address = RAM_BASE + {10'd0,write_fb,address};
    assign wr_valid = state == BEAT0 || state == BEAT1;
    // The RAM address is held through both beats and through waitrequest.
    // Its registered outputs already retain the pixels; a second bank of
    // pixel registers would duplicate that storage. Padding columns lie
    // outside fb_width and do not need a separate zero-fill data path.
    generate if (TILE_ROWS == 8) begin: two_beats
    assign wr_data = state == BEAT1 ?
        {pixel_word(lane_q[7]),pixel_word(lane_q[6]),pixel_word(lane_q[5]),pixel_word(lane_q[4])} :
        {pixel_word(lane_q[3]),pixel_word(lane_q[2]),pixel_word(lane_q[1]),pixel_word(lane_q[0])};
    end else begin: one_beat
        assign wr_data = {pixel_word(lane_q[3]),pixel_word(lane_q[2]),pixel_word(lane_q[1]),pixel_word(lane_q[0])};
    end endgenerate

    always @(posedge avl_clk or posedge reset) begin
        if (reset) begin
            request_sync <= 0; acknowledge <= 0; state <= IDLE;
            display_ack_sync <= 0; display_bank_meta <= 2; display_bank_sync <= 2;
            write_fb <= 0; completed <= 0; ready_fb <= 0;
            address <= 0; column <= 0; read_bank <= 0;
        end else begin
            request_sync <= {request_sync[0],request};
            display_ack_sync <= {display_ack_sync[0],display_ack};
            display_bank_meta <= display_fb;
            display_bank_sync <= display_bank_meta;
            case (state)
                IDLE: if (request_sync[1] != acknowledge) begin
                    read_bank <= req_bank;
                    column <= req_mode == 2 ? req_width - 1'b1 : 10'd0;
                    strip_width <= req_width;
                    strip_mode <= req_mode; strip_last <= req_last;
                    // Width padded to the selected tile size; CW's first partial strip
                    // makes every destination strip naturally aligned.
                    stride_words <= (({1'b0,req_height} + 11'(TILE_ROWS-1)) >> ROW_BITS) << (ROW_BITS-2);
                    address <= {{(16-DEST_BITS){1'b0}},req_dest_strip} << (ROW_BITS-2);
                    state <= RAM_WAIT;
                end
                RAM_WAIT: state <= TILE_ROWS == 4 ? BEAT0 : RAM_LOAD;
                RAM_LOAD: state <= BEAT0;
                BEAT0: if (wr_ready && TILE_ROWS == 8) state <= BEAT1;
                BEAT1: begin end
                default: state <= IDLE;
            endcase
            if (wr_ready && (state == BEAT1 || (state == BEAT0 && TILE_ROWS == 4))) begin
                    if (strip_mode == 2 ? column == 0 : column == strip_width - 1'b1) begin
                        acknowledge <= request_sync[1];
                        state <= IDLE;
                        if (strip_last && completed == display_ack_sync[1]) begin
                            ready_fb <= write_fb;
                            ready_width <= req_height; ready_height <= strip_width;
                            ready_stride <= {stride_words,4'd0};
                            ready_mode <= strip_mode;
                            completed <= ~completed;
                            write_fb <= free_bank(write_fb,display_bank_sync);
                        end
                    end else begin
                        column <= strip_mode == 2 ? column - 1'b1 : column + 1'b1;
                        address <= address + stride_words;
                        state <= RAM_WAIT;
                    end
            end
        end
    end

    (* async_reg = "true" *) reg [1:0] completed_sync = 0;
    (* async_reg = "true" *) reg [1:0] mode_meta = 0, mode_sync = 0;
    reg old_vbl = 0, have_frame = 0;
    reg [1:0] displayed_mode = 0;
    always @(posedge o_clk or posedge reset) begin
        if (reset) begin
            completed_sync <= 0; display_ack <= 0; display_fb <= 2;
            mode_meta <= 0; mode_sync <= 0; old_vbl <= 0; have_frame <= 0;
            fb_width <= 0; fb_height <= 0; fb_stride <= 0; displayed_mode <= 0;
        end else begin
            completed_sync <= {completed_sync[0],completed};
            mode_meta <= rotation; mode_sync <= mode_meta;
            old_vbl <= o_vbl;
            if (!old_vbl && o_vbl) begin
                if (mode_sync == 0 || mode_sync == 3) have_frame <= 0;
                if (completed_sync[1] != display_ack) begin
                    display_ack <= completed_sync[1];
                    if (ready_mode == mode_sync && mode_sync != 0 && mode_sync != 3) begin
                        display_fb <= ready_fb; fb_width <= ready_width;
                        fb_height <= ready_height; fb_stride <= ready_stride;
                        displayed_mode <= ready_mode; have_frame <= 1;
                    end
                end
            end
        end
    end
    assign fb_enable = have_frame;
    assign rotation_applied = have_frame ? displayed_mode : 2'd0;
    assign fb_base = {RAM_BASE,4'd0} + {10'd0,display_fb,20'd0};
endmodule

// Share only the scaler port. Preserve an accepted normal write burst until
// its final beat, then give scaler reads priority over rotation writes.
// With rotation idle this is a combinational pass-through, with no added
// request cycle, register stage or traffic on the core's DDR port.
module nds_tate_scaler_arbiter #(parameter integer TATE_BEATS = 2) (
    input wire clk, reset,
    input wire s_read, s_write,
    input wire [27:0] s_address,
    input wire [7:0] s_burstcount,
    input wire [127:0] s_writedata,
    input wire [15:0] s_byteenable,
    output wire s_waitrequest,
    input wire t_write,
    input wire [27:0] t_address,
    input wire [127:0] t_writedata,
    output wire t_ready,
    output wire m_read, m_write,
    output wire [27:0] m_address,
    output wire [7:0] m_burstcount,
    output wire [127:0] m_writedata,
    output wire [15:0] m_byteenable,
    input wire m_waitrequest
);
    reg t_second = 0, t_owned = 0;
    reg [7:0] s_remaining = 0;
    wire choose_t = t_owned ||
        (t_write && s_remaining == 0 && !s_read && !s_write);
    assign m_read = !choose_t && s_read;
    assign m_write = choose_t ? t_write : s_write;
    assign m_address = choose_t ? t_address : s_address;
    assign m_burstcount = choose_t ? 8'(TATE_BEATS) : s_burstcount;
    assign m_writedata = choose_t ? t_writedata : s_writedata;
    assign m_byteenable = choose_t ? 16'hffff : s_byteenable;
    assign s_waitrequest = choose_t || m_waitrequest;
    assign t_ready = choose_t && !m_waitrequest;
    always @(posedge clk or posedge reset) begin
        if (reset) begin t_second <= 0; t_owned <= 0; s_remaining <= 0; end
        else begin
            // Ownership starts when offered, not when accepted: Avalon
            // forbids preempting even the first beat under waitrequest.
            if (choose_t && t_write) begin
                t_owned <= TATE_BEATS == 1 ? m_waitrequest : !(t_second && !m_waitrequest);
                if (!m_waitrequest && TATE_BEATS == 2) t_second <= !t_second;
            end
            if (!m_waitrequest && !choose_t && s_write)
                s_remaining <= s_remaining == 0 ? s_burstcount - 1'b1 :
                               s_remaining - 1'b1;
        end
    end
endmodule
