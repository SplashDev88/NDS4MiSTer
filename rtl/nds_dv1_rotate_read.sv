// SPDX-License-Identifier: GPL-3.0-or-later
// Native DV1 scanout of the existing transposed framebuffer. Two RGB666
// scanlines (18,432 bits) suffice; the console DDR port and ARM are untouched.
module nds_dv1_rotate_read (
    input wire reset, clk, avl_clk, enable, fb_enable,
    input wire [9:0] fb_width, fb_height,
    input wire [31:0] fb_base,
    input wire [13:0] fb_stride,
    input wire [1:0] fb_rotation,
    output wire frame_boundary,
    output reg active = 0,
    output reg [1:0] rotation = 0,
    output reg ce = 0, de = 0, hs = 0, vs = 0,
    output reg [23:0] rgb = 0,
    output reg underrun = 0,
    output wire rd,
    output wire [27:0] rd_address,
    output wire [7:0] rd_count,
    input wire rd_wait, rd_valid,
    input wire [127:0] rd_data
);
    // All modes have 1,006,080 transport clocks/frame (~59.64 Hz at 60 MHz).
    // The longer raster accommodates rotated side-by-side layouts, including
    // the largest screen gap. Syncs stay at the end of blanking, so DV1 crop
    // offsets remain representable even with a short image in a tall raster.
    reg [9:0] x = 0, y = 0, width = 256, height = 192;
    reg [9:0] total = 262;
    reg [9:0] pending_width = 256, pending_height = 192;
    reg pending_active = 0;
    reg [1:0] pending_rotation = 0;
    reg [2:0] divider = 0, repeat_count = 6;
    reg [27:0] base = 0, next_row_address = 0;
    reg [9:0] stride = 0;
    wire pixel = divider == 0;
    wire line_start = pixel && x == 0;
    wire prepare = line_start && y == total - 2;
    wire in_picture = x >= 16 && x < 16 + width && y < height;
    wire [8:0] picture_x = x - 10'd16;

    reg request = 0, acknowledge = 0;
    reg [27:0] request_address = 0;
    reg [7:0] request_count = 0;
    reg request_bank = 0;
    reg [9:0] request_row = 0;
    (* async_reg = "true" *) reg [1:0] ack_sync = 0;
    reg ack_settled = 0, ack_seen = 0;
    wire idle = request == ack_settled;
    // A descriptor can be released only after its last read has returned.
    // Close adoption before row-zero prefetch. Its completion must not
    // create a second boundary that releases the bank we just prefetched.
    assign frame_boundary = y >= height && y < total - 2 && idle;
    reg [1:0] ready = 0;
    reg [9:0] bank_row [0:1];
    reg display_bank = 0, line_valid = 0;
    wire descriptor_valid = enable && fb_enable && fb_width != 0 &&
        fb_width <= 512 && fb_height != 0 && fb_height <= 600;

    (* ramstyle = "M10K, no_rw_check" *) reg [71:0] pixels [0:255];
    reg [71:0] q;
    always @(posedge clk) q <= pixels[{display_bank,picture_x[8:2]}];
    reg [1:0] lane = 0;
    reg [3:0] ctl = 0;
    wire [17:0] dot = q[lane*18 +: 18];
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            x <= 0; y <= 0; width <= 256; height <= 192;
            total <= 262; repeat_count <= 6; divider <= 0;
            pending_width <= 256; pending_height <= 192;
            pending_active <= 0; pending_rotation <= 0;
            base <= 0; stride <= 0; next_row_address <= 0;
            request <= 0; request_address <= 0; request_count <= 0;
            request_bank <= 0; request_row <= 0;
            ack_sync <= 0; ack_settled <= 0; ack_seen <= 0;
            ready <= 0; display_bank <= 0; line_valid <= 0;
            active <= 0; rotation <= 0; underrun <= 0;
            ce <= 0; de <= 0; hs <= 0; vs <= 0; rgb <= 0;
            lane <= 0; ctl <= 0;
        end else begin
            ack_sync <= {ack_sync[0],acknowledge};
            ack_settled <= ack_sync[1];
            if (ack_settled != ack_seen) begin
                ack_seen <= ack_settled;
                ready[request_bank] <= 1;
                bank_row[request_bank] <= request_row;
            end
            divider <= divider == repeat_count - 1'b1 ? 3'd0 : divider + 1'b1;
            if (pixel) begin
                if (x == 639) begin
                    x <= 0; y <= y == total - 1'b1 ? 10'd0 : y + 1'b1;
                end else x <= x + 1'b1;
            end
            if (prepare) begin
                // Stage the descriptor and fetch row zero during blanking.
                // A taller next frame must not turn this frame's blanking
                // into active rows before its counters wrap.
                pending_active <= descriptor_valid && idle;
                pending_rotation <= descriptor_valid ? fb_rotation : 2'd0;
                ready <= 0;
                if (descriptor_valid && idle) begin
                    pending_width <= fb_width; pending_height <= fb_height;
                    base <= fb_base[31:4]; stride <= fb_stride[13:4];
                    request_address <= fb_base[31:4];
                    next_row_address <= fb_base[31:4] + fb_stride[13:4];
                    request_count <= ({1'b0,fb_width}+11'd3) >> 2;
                    request_bank <= 0; request_row <= 0; request <= ~request;
                end
            end
            if (pixel && x == 639 && y == total - 1'b1) begin
                width <= pending_width; height <= pending_height;
                active <= pending_active; rotation <= pending_rotation;
                total <= pending_height > 500 ? 10'd786 : pending_height > 256 ? 10'd524 : 10'd262;
                repeat_count <= pending_height > 500 ? 3'd2 : pending_height > 256 ? 3'd3 : 3'd6;
                divider <= 0;
            end
            if (line_start && y < height) begin
                display_bank <= y[0];
                line_valid <= active && ready[y[0]] && bank_row[y[0]] == y;
                if (active && !(ready[y[0]] && bank_row[y[0]] == y)) underrun <= 1;
                if (active && y + 1'b1 < height && idle) begin
                    request_address <= next_row_address;
                    next_row_address <= next_row_address + stride;
                    request_bank <= ~y[0]; request_row <= y + 1'b1;
                    request <= ~request;
                    ready[~y[0]] <= 0;
                end else if (active && y + 1'b1 < height) begin
                    // A late row is black for the entire line. Never acquire
                    // a buffer that DDR is still changing underneath scanout.
                    next_row_address <= next_row_address + stride;
                end
            end
            lane <= picture_x[1:0];
            ctl <= {pixel,in_picture,x >= 592 && x < 624,y >= total - 4 && y < total - 1};
            {ce,de,hs,vs} <= ctl;
            rgb <= ctl[2] && line_valid ?
                {dot[17:12],dot[17:16],dot[11:6],dot[11:10],dot[5:0],dot[5:4]} : 24'd0;
        end
    end

    (* async_reg = "true" *) reg [1:0] req_sync = 0;
    reg [1:0] state = 0;
    reg [7:0] beat = 0, count = 0;
    reg bank = 0;
    reg [27:0] address = 0;
    assign rd = state == 1;
    assign rd_address = address;
    assign rd_count = count;
    wire receiving = state == 2 || (state == 1 && !rd_wait);
    always @(posedge avl_clk or posedge reset) begin
        if (reset) begin
            req_sync <= 0; acknowledge <= 0; state <= 0;
            beat <= 0; count <= 0; bank <= 0; address <= 0;
        end else begin
            req_sync <= {req_sync[0],request};
            if (state == 0 && req_sync[1] != acknowledge) begin
                address <= request_address; count <= request_count;
                bank <= request_bank; beat <= 0; state <= 1;
            end
            if (state == 1 && !rd_wait) state <= 2;
            if (receiving && rd_valid) begin
                beat <= beat + 1'b1;
                if (beat == count - 1'b1) begin
                    state <= 0; acknowledge <= req_sync[1];
                end
            end
        end
    end
    genvar p;
    wire [71:0] compact_pixels;
    generate for(p=0;p<4;p=p+1) begin: unpack
        assign compact_pixels[p*18 +: 18] =
            {rd_data[p*32+2 +: 6],rd_data[p*32+10 +: 6],rd_data[p*32+18 +: 6]};
    end endgenerate
    always @(posedge avl_clk)
        if (receiving && rd_valid) pixels[{bank,beat[6:0]}] <= compact_pixels;
endmodule

// Add a read client around the existing scaler/write arbiter. Every accepted
// read response is routed to its owner; ownership changes only after draining
// responses and any write burst. Normal operation is a combinational bypass.
module nds_dv1_read_arbiter (
    input wire clk, reset,
    input wire s_read, s_write,
    input wire [27:0] s_address,
    input wire [7:0] s_burstcount,
    input wire [127:0] s_writedata,
    input wire [15:0] s_byteenable,
    output wire s_waitrequest, s_readdatavalid,
    input wire n_read,
    input wire [27:0] n_address,
    input wire [7:0] n_burstcount,
    output wire n_waitrequest, n_readdatavalid,
    output wire m_read, m_write,
    output wire [27:0] m_address,
    output wire [7:0] m_burstcount,
    output wire [127:0] m_writedata,
    output wire [15:0] m_byteenable,
    input wire m_waitrequest, m_readdatavalid
);
    reg native_owned = 0, normal_held = 0;
    reg [15:0] reads_pending = 0;
    reg [7:0] writes_remaining = 0, native_remaining = 0;
    wire drain = n_read && !normal_held && writes_remaining == 0;
    wire choose_native = native_owned || (drain && reads_pending == 0);
    wire normal_offer = !choose_native && (!drain || normal_held || writes_remaining != 0);
    assign m_read = choose_native ? n_read && native_remaining == 0 : normal_offer && s_read;
    assign m_write = normal_offer && s_write;
    assign m_address = choose_native ? n_address : s_address;
    assign m_burstcount = choose_native ? n_burstcount : s_burstcount;
    assign m_writedata = s_writedata;
    assign m_byteenable = choose_native ? 16'hffff : s_byteenable;
    assign s_waitrequest = !normal_offer || m_waitrequest;
    assign n_waitrequest = !choose_native || native_remaining != 0 || m_waitrequest;
    assign s_readdatavalid = m_readdatavalid && !choose_native;
    assign n_readdatavalid = m_readdatavalid && choose_native;
    wire take_normal = m_read && !m_waitrequest && !choose_native;
    wire take_native = m_read && !m_waitrequest && choose_native;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            native_owned <= 0; normal_held <= 0;
            reads_pending <= 0; writes_remaining <= 0; native_remaining <= 0;
        end else begin
            normal_held <= normal_offer && (s_read || s_write) && m_waitrequest;
            reads_pending <= reads_pending + (take_normal ? s_burstcount : 16'd0) -
                             (s_readdatavalid ? 16'd1 : 16'd0);
            if (m_write && !m_waitrequest)
                writes_remaining <= writes_remaining == 0 ? s_burstcount - 1'b1 : writes_remaining - 1'b1;
            if (choose_native) begin
                native_owned <= 1;
                if (take_native) native_remaining <= n_burstcount - n_readdatavalid;
                else if (n_readdatavalid) native_remaining <= native_remaining - 1'b1;
                if (n_readdatavalid && (take_native ? n_burstcount == 1 : native_remaining == 1))
                    native_owned <= 0;
            end
        end
    end
endmodule
