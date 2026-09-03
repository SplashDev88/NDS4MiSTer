`timescale 1ns/1ps

// Ordered clk1x record normalizer and CDC transport for H3B1 frame packets.
// One source is accepted per source-clock edge. Raw GPU geometry writes pass
// through the exact standalone GX normalizer; other GPU and VRAM writes are
// converted directly to the shared 128-bit record ABI. A 162-bit asynchronous
// FIFO transports {boundary, frame_end, logical_frame, record} to DDR.
module nds_h3d_frame_record_cdc #(
    parameter integer ASYNC_LGDEPTH = 4,
    // Production Engine-B scanout needs LCD phase information, but sending
    // all 263 HBlank markers per frame can fill the old source queue during a
    // transient HPS stall. Sparse mode admits only line 0 and line 192 on a
    // best-effort basis; per-record scanline tags recover exact ordering once
    // transport resumes, so timing pulses never backpressure the console.
    parameter bit SPARSE_HBLANK = 0,
    parameter bit SCANLINE_TAGS = 0
) (
    input  logic         source_clk,
    input  logic         ddr_clk,
    input  logic         reset,
    input  logic         session_flush,

    input  logic         gpu_valid,
    output logic         gpu_ready,
    input  logic [27:0]  gpu_address,
    input  logic [1:0]   gpu_access,
    input  logic [3:0]   gpu_byte_enable,
    input  logic [31:0]  gpu_data,
    input  logic [63:0]  gpu_timestamp,

    input  logic         arm9_vram_valid,
    output logic         arm9_vram_ready,
    input  logic [27:0]  arm9_vram_address,
    input  logic [1:0]   arm9_vram_access,
    input  logic [3:0]   arm9_vram_byte_enable,
    input  logic [31:0]  arm9_vram_data,
    input  logic [63:0]  arm9_vram_timestamp,

    input  logic         arm7_vram_valid,
    output logic         arm7_vram_ready,
    input  logic [27:0]  arm7_vram_address,
    input  logic [1:0]   arm7_vram_access,
    input  logic [3:0]   arm7_vram_byte_enable,
    input  logic [31:0]  arm7_vram_data,
    input  logic [63:0]  arm7_vram_timestamp,

    input  logic         hblank_valid,
    output logic         hblank_ready,
    input  logic [8:0]   hblank_line,
    input  logic [31:0]  hblank_frame,
    input  logic [63:0]  hblank_timestamp,

    input  logic         frame_valid,
    output logic         frame_ready,
    input  logic [31:0]  frame_number,
    input  logic [63:0]  frame_timestamp,

    output logic         source_active,
    output logic         ddr_active,
    output logic         source_fault,
    output logic [3:0]   source_fault_reason,
    output logic         ddr_fault,
    output logic [3:0]   ddr_fault_reason,
    output logic [8:0]   fifo_level,
    output logic         fifo_empty,
    output logic         fifo_below_half,
    output logic         fifo_full,

    output logic         record_valid,
    input  logic         record_ready,
    output logic [127:0] record,
    output logic [31:0]  record_frame,
    output logic         record_frame_end,
    output logic         boundary_valid,
    input  logic         boundary_ready,
    output logic [31:0]  boundary_frame
);
    // {boundary, frame_end, logical_frame, scanline_valid, scanline, record}.
    // Keep scanline metadata outside the record proper so the common GX
    // structural checks and 128-bit record mux stay identical to beta.6.
    localparam integer CDC_WIDTH = 172;
    localparam logic [7:0] KIND_GX_COMMAND = 8'd1;
    localparam logic [7:0] KIND_GX_REGISTER = 8'd2;
    localparam logic [7:0] KIND_VRAM_WRITE = 8'd3;
    localparam logic [7:0] KIND_VRAM_MAP = 8'd4;
    localparam logic [7:0] KIND_GPU2D_REGISTER = 8'd5;
    localparam logic [7:0] KIND_PALETTE_WRITE = 8'd6;
    localparam logic [7:0] KIND_OAM_WRITE = 8'd7;
    localparam logic [7:0] KIND_HBLANK = 8'd8;
    localparam logic [7:0] KIND_GX_PACKED = 8'd9;

    function automatic logic [1:0] address_low(
        input logic [3:0] byte_enable
    );
        begin
            case (byte_enable)
                4'b0010: address_low = 2'd1;
                4'b0100,
                4'b1100: address_low = 2'd2;
                4'b1000: address_low = 2'd3;
                default: address_low = 2'd0;
            endcase
        end
    endfunction

    function automatic logic [127:0] pack_record(
        input logic [7:0] kind,
        input logic [7:0] tag,
        input logic [3:0] byte_enable,
        input logic [31:0] address_or_aux,
        input logic [31:0] data
    );
        pack_record = {
            32'd0, data, address_or_aux,
            12'd0, byte_enable, tag, kind
        };
    endfunction

    wire [1:0] gpu_low = address_low(gpu_byte_enable);
    wire [27:0] gpu_arch_address =
        {gpu_address[27:2], 2'b00} | 28'(gpu_low);
    wire [31:0] gpu_full_address =
        32'h04000000 | {4'd0, gpu_arch_address};
    wire gpu_disp3d = gpu_arch_address >= 28'h0000060 &&
        gpu_arch_address <= 28'h0000063;
    wire gpu_2d =
        (gpu_arch_address <= 28'h000005f) ||
        (gpu_arch_address >= 28'h0000064 &&
         gpu_arch_address <= 28'h000006f) ||
        (gpu_arch_address >= 28'h0001000 &&
         gpu_arch_address <= 28'h000106f);
    wire gpu_palette = gpu_arch_address >= 28'h1000000 &&
        gpu_arch_address <= 28'h10007ff;
    wire gpu_oam = gpu_arch_address >= 28'h3000000 &&
        gpu_arch_address <= 28'h30007ff;
    wire gpu_vramcnt = gpu_arch_address >= 28'h0000240 &&
        gpu_arch_address <= 28'h0000249;
    wire gpu_powcnt1 = gpu_arch_address >= 28'h0000304 &&
        gpu_arch_address <= 28'h0000307;
    wire gpu_renderer = gpu_arch_address >= 28'h0000320 &&
        gpu_arch_address <= 28'h00003bf;
    wire gpu_geometry = gpu_arch_address >= 28'h0000400 &&
        gpu_arch_address <= 28'h00005cb;
    wire gpu_gxstat = gpu_arch_address >= 28'h0000600 &&
        gpu_arch_address <= 28'h0000613;
    wire gpu_qualified = gpu_2d || gpu_palette || gpu_oam || gpu_disp3d ||
        gpu_vramcnt || gpu_powcnt1 || gpu_renderer || gpu_geometry ||
        gpu_gxstat;

    wire [127:0] gpu_direct_record = pack_record(
        gpu_palette ? KIND_PALETTE_WRITE :
        gpu_oam ? KIND_OAM_WRITE :
        gpu_vramcnt ? KIND_VRAM_MAP :
        gpu_2d ? KIND_GPU2D_REGISTER : KIND_GX_REGISTER,
        {6'd0, gpu_access}, gpu_byte_enable,
        gpu_full_address, gpu_data);
    wire [127:0] arm9_record = pack_record(
        KIND_VRAM_WRITE, {6'd0, arm9_vram_access},
        arm9_vram_byte_enable, {4'd0, arm9_vram_address},
        arm9_vram_data);
    wire [127:0] arm7_record = pack_record(
        KIND_VRAM_WRITE, {5'd0, 1'b1, arm7_vram_access},
        arm7_vram_byte_enable, {4'd0, arm7_vram_address},
        arm7_vram_data);
    // The ARM video receiver owns a complete mirror of mapped VRAM. Reject
    // malformed non-VRAM source addresses, but retain every architectural
    // 0x06 write including BG/OBJ apertures that the old 3D-only path skipped.
    wire arm9_vram_needed_by_h3d =
        arm9_vram_address[27:24] == 4'h6;

    wire reset_async = reset || session_flush;
    logic [2:0] source_reset_pipe;
    logic [2:0] ddr_reset_pipe;
    wire source_reset_local = source_reset_pipe[2];
    wire ddr_reset_local = ddr_reset_pipe[2];

    always_ff @(posedge source_clk or posedge reset_async) begin
        if (reset_async)
            source_reset_pipe <= 3'b111;
        else
            source_reset_pipe <= {source_reset_pipe[1:0], 1'b0};
    end
    always_ff @(posedge ddr_clk or posedge reset_async) begin
        if (reset_async)
            ddr_reset_pipe <= 3'b111;
        else
            ddr_reset_pipe <= {ddr_reset_pipe[1:0], 1'b0};
    end

    logic source_up;
    logic ddr_up;
    (* async_reg = "true" *) logic ddr_up_source_meta;
    (* async_reg = "true" *) logic ddr_up_source_sync;
    (* async_reg = "true" *) logic source_up_ddr_meta;
    (* async_reg = "true" *) logic source_up_ddr_sync;

    always_ff @(posedge source_clk or posedge source_reset_local) begin
        if (source_reset_local) begin
            source_up <= 0;
            ddr_up_source_meta <= 0;
            ddr_up_source_sync <= 0;
        end else begin
            source_up <= 1;
            ddr_up_source_meta <= ddr_up;
            ddr_up_source_sync <= ddr_up_source_meta;
        end
    end
    always_ff @(posedge ddr_clk or posedge ddr_reset_local) begin
        if (ddr_reset_local) begin
            ddr_up <= 0;
            source_up_ddr_meta <= 0;
            source_up_ddr_sync <= 0;
        end else begin
            ddr_up <= 1;
            source_up_ddr_meta <= source_up;
            source_up_ddr_sync <= source_up_ddr_meta;
        end
    end

    logic gx_write_valid;
    logic gx_write_ready;
    logic gx_record_valid;
    logic gx_record_ready;
    logic [127:0] gx_record;
    logic [63:0] gx_record_timestamp;
    logic gx_record_frame_end;
    logic gx_swap_pending;
    logic [63:0] gx_oldest_swap_timestamp;
    logic gx_packed_active;
    logic gx_protocol_error;
    logic [31:0] logical_frame;

    nds_gx_fifo_packet_frontend gx_frontend (
        .clk(source_clk),
        .reset(source_reset_local),
        .write_valid(gx_write_valid),
        .write_ready(gx_write_ready),
        .write_is_dma(1'b0),
        .write_address(gpu_full_address),
        .write_access(gpu_access),
        .write_data(gpu_data),
        .write_frame(logical_frame),
        .write_timestamp(gpu_timestamp),
        .record_valid(gx_record_valid),
        .record_ready(gx_record_ready),
        .record(gx_record),
        .record_frame(),
        .record_timestamp(gx_record_timestamp),
        .record_frame_end(gx_record_frame_end),
        .swap_enqueued(),
        .swap_pending(gx_swap_pending),
        .oldest_swap_timestamp(gx_oldest_swap_timestamp),
        .fifo_level(fifo_level),
        .fifo_empty(fifo_empty),
        .fifo_below_half(fifo_below_half),
        .fifo_full(fifo_full),
        .packed_active(gx_packed_active),
        .protocol_error(gx_protocol_error)
    );

    logic async_write_valid;
    logic async_write_ready;
    logic [CDC_WIDTH-1:0] async_write_data;
    logic async_read_valid;
    logic async_read_ready;
    logic [CDC_WIDTH-1:0] async_read_data;

    // Sparse mode still has to deliver a line-0 marker before Engine B can
    // start a complete frame.  The former "advisory" path acknowledged the
    // LCD pulse even when ordered GPU/VRAM traffic was present, so a busy game
    // could lose every line-0 and line-192 marker forever.  Retain one exact
    // boundary locally and give it normal timestamp arbitration.  A prolonged
    // downstream stall may coalesce later timing-only markers, but it can no
    // longer starve the renderer's first complete-frame anchor.
    wire phase_input_valid = SPARSE_HBLANK ?
        (hblank_valid && (hblank_line == 9'd0 || hblank_line == 9'd192)) :
        hblank_valid;
    logic sparse_phase_pending;
    logic sparse_phase_visible_end;
    logic [31:0] sparse_phase_frame;
    wire phase_valid = SPARSE_HBLANK ?
        (sparse_phase_pending || phase_input_valid) : phase_input_valid;
    wire [8:0] phase_line =
        SPARSE_HBLANK && sparse_phase_pending ?
            (sparse_phase_visible_end ? 9'd192 : 9'd0) : hblank_line;
    wire [31:0] phase_frame =
        SPARSE_HBLANK && sparse_phase_pending ?
            sparse_phase_frame : hblank_frame;
    // Sparse markers are only two fixed lines and always win arbitration.
    // Their timestamp therefore needs no retained 64-bit payload; this keeps
    // the full FPGA cost to one line bit plus the display-frame number.
    wire [63:0] phase_timestamp = hblank_timestamp;
    wire [127:0] hblank_record = pack_record(
        KIND_HBLANK, 8'd0, 4'd0, {23'd0, phase_line}, phase_frame);

    logic select_gpu;
    logic select_arm9;
    logic select_arm7;
    logic select_hblank;
    logic select_frame;
    logic select_gx_head;
    logic promised_swap_boundary;
    logic [63:0] selected_raw_timestamp;
    logic selected_raw_valid;
    wire gpu_fire = gpu_valid && gpu_ready;
    wire arm9_fire = arm9_vram_valid && arm9_vram_ready;
    wire arm7_fire = arm7_vram_valid && arm7_vram_ready;
    wire frame_fire = frame_valid && frame_ready;
    wire gx_record_fire = gx_record_valid && gx_record_ready;
    // Sparse phase markers use their retained timestamp and therefore can
    // precede a same-edge HDMA write exactly like the full diagnostic mode.
    // Selecting them here costs no wide comparator: the boundary is only two
    // records per display frame and the held marker simply arbitrates before
    // raw state until accepted. The state sources already provide lossless
    // backpressure.
    wire phase_precedes_raw = SPARSE_HBLANK ?
        1'b1 :
        ((!gpu_valid || phase_timestamp <= gpu_timestamp) &&
         (!arm9_vram_valid || phase_timestamp <= arm9_vram_timestamp) &&
         (!arm7_vram_valid || phase_timestamp <= arm7_vram_timestamp) &&
         (!frame_valid || phase_timestamp <= frame_timestamp));

    always_comb begin
        select_gpu = 0;
        select_arm9 = 0;
        select_arm7 = 0;
        select_hblank = 0;
        select_frame = 0;
        selected_raw_valid = 0;
        selected_raw_timestamp = '0;

        // Oldest held source wins. HBlank wins an equal timestamp so the ARM
        // shadow snapshots the pre-HDMA line before a same-edge register or
        // memory update takes effect for the following line.
        if (phase_valid && phase_precedes_raw) begin
            select_hblank = 1;
            selected_raw_valid = 1;
            selected_raw_timestamp = phase_timestamp;
        end else if (gpu_valid &&
            (!arm9_vram_valid ||
             gpu_timestamp <= arm9_vram_timestamp) &&
            (!arm7_vram_valid ||
             gpu_timestamp <= arm7_vram_timestamp) &&
            (!frame_valid ||
             gpu_timestamp <= frame_timestamp)) begin
            select_gpu = 1;
            selected_raw_valid = 1;
            selected_raw_timestamp = gpu_timestamp;
        end else if (arm9_vram_valid &&
                     (!arm7_vram_valid ||
                      arm9_vram_timestamp <= arm7_vram_timestamp) &&
                     (!frame_valid ||
                      arm9_vram_timestamp <= frame_timestamp)) begin
            select_arm9 = 1;
            selected_raw_valid = 1;
            selected_raw_timestamp = arm9_vram_timestamp;
        end else if (arm7_vram_valid &&
                     (!frame_valid ||
                      arm7_vram_timestamp <= frame_timestamp)) begin
            select_arm7 = 1;
            selected_raw_valid = 1;
            selected_raw_timestamp = arm7_vram_timestamp;
        end else if (frame_valid) begin
            select_frame = 1;
            selected_raw_valid = 1;
            selected_raw_timestamp = frame_timestamp;
        end

        // A retained normalized GX record competes with direct sources by
        // its original source timestamp. GX wins ties. A geometry raw write
        // may simultaneously enter the independent 256-entry GX FIFO.
        select_gx_head = gx_record_valid &&
            !(SPARSE_HBLANK && select_hblank) &&
            (!selected_raw_valid ||
             gx_record_timestamp < selected_raw_timestamp ||
             (gx_record_timestamp == selected_raw_timestamp &&
              !select_hblank));
        // The oldest fully normalized SWAP ordered at or before this boundary
        // is a promise that the equal/current frame will close. It may be
        // hidden behind older non-SWAP GX records or followed by a SWAP for a
        // later frame; neither case may make this boundary wait for the head.
        // The selected-head clause preserves the direct stable-record proof
        // independently of the ordered SWAP timestamp queue.
        // logical_frame still advances only when the SWAP itself is accepted.
        promised_swap_boundary = frame_valid &&
            frame_number == logical_frame &&
            ((gx_swap_pending &&
              gx_oldest_swap_timestamp <= frame_timestamp) ||
             (select_gx_head && gx_record[15:8] == 8'h50));

        gpu_ready = 0;
        arm9_vram_ready = 0;
        arm7_vram_ready = 0;
        hblank_ready = SPARSE_HBLANK ? 1'b1 : 1'b0;
        frame_ready = 0;
        gx_write_valid = 0;
        gx_record_ready = 0;
        async_write_valid = 0;
        async_write_data = '0;

        if (source_active && !source_fault) begin
            // A SWAP accepted into the final ordered stream has already
            // closed every earlier frame.  Its later VBlank token is therefore
            // a local no-op and must not sit behind older traffic or a full
            // async FIFO: doing so can occupy the console's sole boundary slot
            // until the next VBlank and raise a false source overrun.  Consume
            // only strictly stale tokens here; equal/current boundaries retain
            // the normal timestamp-ordered, lossless path below.
            if (frame_valid && frame_number < logical_frame) begin
                frame_ready = 1;
            end else begin
                if (select_gx_head) begin
                    async_write_valid = 1;
                    async_write_data = {
                        1'b0,
                        gx_record[15:8] == 8'h50,
                        logical_frame,
                        10'd0,
                        gx_record
                    };
                    gx_record_ready = async_write_ready;
                end

                if (promised_swap_boundary)
                    frame_ready = 1;

                if (select_gpu && gpu_geometry) begin
                    gx_write_valid = gpu_valid;
                    gpu_ready = gx_write_ready;
                end else if (!select_gx_head) begin
                    if (select_hblank) begin
                        async_write_valid = phase_valid;
                        async_write_data = {
                            1'b0, 1'b0, logical_frame, 10'd0,
                            hblank_record};
                        if (!SPARSE_HBLANK)
                            hblank_ready = async_write_ready;
                    end else if (select_gpu) begin
                        if (!gpu_qualified) begin
                            gpu_ready = 1;
                        end else begin
                            async_write_valid = gpu_valid;
                            async_write_data = {
                                1'b0, 1'b0, logical_frame,
                                SCANLINE_TAGS, hblank_line,
                                gpu_direct_record};
                            gpu_ready = async_write_ready;
                        end
                    end else if (select_arm9) begin
                        if (!arm9_vram_needed_by_h3d) begin
                            arm9_vram_ready = 1;
                        end else begin
                            async_write_valid = arm9_vram_valid;
                            async_write_data = {
                                1'b0, 1'b0, logical_frame,
                                SCANLINE_TAGS, hblank_line, arm9_record};
                            arm9_vram_ready = async_write_ready;
                        end
                    end else if (select_arm7) begin
                        async_write_valid = arm7_vram_valid;
                        async_write_data = {
                            1'b0, 1'b0, logical_frame,
                            SCANLINE_TAGS, hblank_line, arm7_record};
                        arm7_vram_ready = async_write_ready;
                    end else if (select_frame) begin
                        async_write_valid = frame_valid;
                        async_write_data = {
                            1'b1, 1'b0, frame_number, 10'd0, 128'd0};
                        frame_ready = async_write_ready;
                    end
                end
            end
        end
    end

    wire sparse_phase_fire = SPARSE_HBLANK && select_hblank &&
        async_write_valid && async_write_ready;
    always_ff @(posedge source_clk or posedge source_reset_local) begin
        if (source_reset_local) begin
            sparse_phase_pending <= 1'b0;
            sparse_phase_visible_end <= 1'b0;
            sparse_phase_frame <= '0;
        end else if (SPARSE_HBLANK) begin
            if (sparse_phase_pending) begin
                if (sparse_phase_fire) begin
                    if (phase_input_valid) begin
                        sparse_phase_pending <= 1'b1;
                        sparse_phase_visible_end <= hblank_line == 9'd192;
                        sparse_phase_frame <= hblank_frame;
                    end else begin
                        sparse_phase_pending <= 1'b0;
                    end
                end
            end else if (phase_input_valid && !sparse_phase_fire) begin
                sparse_phase_pending <= 1'b1;
                sparse_phase_visible_end <= hblank_line == 9'd192;
                sparse_phase_frame <= hblank_frame;
            end
        end else begin
            sparse_phase_pending <= 1'b0;
        end
    end

    logic gpu_stalled;
    logic arm9_stalled;
    logic arm7_stalled;
    logic hblank_stalled;
    logic frame_stalled;
    logic [129:0] gpu_stalled_payload;
    logic [129:0] arm9_stalled_payload;
    logic [129:0] arm7_stalled_payload;
    logic [104:0] hblank_stalled_payload;
    logic [95:0] frame_stalled_payload;
    wire [129:0] gpu_source_payload = {
        gpu_timestamp, gpu_data, gpu_byte_enable, gpu_access, gpu_address};
    wire [129:0] arm9_source_payload = {
        arm9_vram_timestamp, arm9_vram_data, arm9_vram_byte_enable,
        arm9_vram_access, arm9_vram_address};
    wire [129:0] arm7_source_payload = {
        arm7_vram_timestamp, arm7_vram_data, arm7_vram_byte_enable,
        arm7_vram_access, arm7_vram_address};
    wire [104:0] hblank_source_payload = {
        hblank_timestamp, hblank_frame, hblank_line};
    wire [95:0] frame_source_payload = {frame_timestamp, frame_number};

    // Preserve the first exact source invariant that failed. The production
    // control word carries this nibble with the existing record-CDC fault bit,
    // so a board freeze can be diagnosed without SignalTap or behavior changes.
    wire frame_counter_fault =
        (gx_record_fire && gx_record_frame_end &&
         logical_frame == 32'hffffffff) ||
        (frame_fire && !promised_swap_boundary &&
         frame_number == 32'hffffffff);
    wire gpu_stability_fault = gpu_stalled &&
        (!gpu_valid || gpu_source_payload != gpu_stalled_payload);
    wire arm9_stability_fault = arm9_stalled &&
        (!arm9_vram_valid || arm9_source_payload != arm9_stalled_payload);
    wire arm7_stability_fault = arm7_stalled &&
        (!arm7_vram_valid || arm7_source_payload != arm7_stalled_payload);
    wire hblank_stability_fault = hblank_stalled &&
        (!hblank_valid || hblank_source_payload != hblank_stalled_payload);
    wire frame_stability_fault = frame_stalled &&
        (!frame_valid || frame_source_payload != frame_stalled_payload);
    logic [3:0] source_fault_reason_now;
    always_comb begin
        source_fault_reason_now = 4'd0;
        if (gx_protocol_error)
            source_fault_reason_now = 4'd1;
        else if (frame_counter_fault)
            source_fault_reason_now = 4'd2;
        else if (gpu_stability_fault)
            source_fault_reason_now = 4'd3;
        else if (arm9_stability_fault)
            source_fault_reason_now = 4'd4;
        else if (arm7_stability_fault)
            source_fault_reason_now = 4'd5;
        else if (hblank_stability_fault)
            source_fault_reason_now = 4'd6;
        else if (frame_stability_fault)
            source_fault_reason_now = 4'd7;
    end

    always_ff @(posedge source_clk or posedge source_reset_local) begin
        if (source_reset_local) begin
            logical_frame <= 32'd1;
            source_fault <= 0;
            source_fault_reason <= 0;
            gpu_stalled <= 0;
            arm9_stalled <= 0;
            arm7_stalled <= 0;
            hblank_stalled <= 0;
            frame_stalled <= 0;
            gpu_stalled_payload <= 0;
            arm9_stalled_payload <= 0;
            arm7_stalled_payload <= 0;
            hblank_stalled_payload <= 0;
            frame_stalled_payload <= 0;
        end else begin
            if (!source_fault && source_fault_reason_now != 0) begin
                source_fault <= 1;
                source_fault_reason <= source_fault_reason_now;
            end

            // Frame ownership follows the final timestamp-ordered stream,
            // not the earlier instant at which a command entered the GX
            // normalization FIFO. A VBlank may legitimately sort ahead of a
            // later-timestamp buffered GX command; output-time tagging keeps
            // that command in the new frame. Likewise, commands buffered
            // behind SWAP_BUFFERS move to the next frame only after the SWAP
            // record itself is accepted by the CDC.
            if (gx_record_fire && gx_record_frame_end) begin
                if (logical_frame != 32'hffffffff &&
                    frame_fire && frame_number != 32'hffffffff &&
                         logical_frame + 1'b1 < frame_number + 1'b1)
                    logical_frame <= frame_number + 1'b1;
                else if (logical_frame != 32'hffffffff)
                    logical_frame <= logical_frame + 1'b1;
            end else if (frame_fire && !promised_swap_boundary) begin
                if (frame_number != 32'hffffffff &&
                    logical_frame < frame_number + 1'b1)
                    logical_frame <= frame_number + 1'b1;
            end

            if (gpu_valid && !gpu_ready && !gpu_stalled) begin
                gpu_stalled <= 1;
                gpu_stalled_payload <= gpu_source_payload;
            end else if (gpu_valid && gpu_ready) begin
                gpu_stalled <= 0;
            end
            if (arm9_vram_valid && !arm9_vram_ready && !arm9_stalled) begin
                arm9_stalled <= 1;
                arm9_stalled_payload <= arm9_source_payload;
            end else if (arm9_vram_valid && arm9_vram_ready) begin
                arm9_stalled <= 0;
            end
            if (arm7_vram_valid && !arm7_vram_ready && !arm7_stalled) begin
                arm7_stalled <= 1;
                arm7_stalled_payload <= arm7_source_payload;
            end else if (arm7_vram_valid && arm7_vram_ready) begin
                arm7_stalled <= 0;
            end
            if (hblank_valid && !hblank_ready && !hblank_stalled) begin
                hblank_stalled <= 1;
                hblank_stalled_payload <= hblank_source_payload;
            end else if (hblank_valid && hblank_ready) begin
                hblank_stalled <= 0;
            end
            if (frame_valid && !frame_ready && !frame_stalled) begin
                frame_stalled <= 1;
                frame_stalled_payload <= frame_source_payload;
            end else if (frame_valid && frame_ready) begin
                frame_stalled <= 0;
            end
        end
    end

    assign source_active = source_up && ddr_up_source_sync &&
        !source_reset_local && !source_fault;

    nds_h3d_event_async_fifo #(
        .WIDTH(CDC_WIDTH),
        .LGDEPTH(ASYNC_LGDEPTH)
    ) crossing (
        .write_clk(source_clk),
        .write_reset(source_reset_local),
        .write_valid(async_write_valid),
        .write_ready(async_write_ready),
        .write_data(async_write_data),
        .read_clk(ddr_clk),
        .read_reset(ddr_reset_local),
        .read_valid(async_read_valid),
        .read_ready(async_read_ready),
        .read_data(async_read_data)
    );

    (* async_reg = "true" *) logic source_fault_ddr_meta;
    (* async_reg = "true" *) logic source_fault_ddr_sync;
    (* async_reg = "true" *) logic [3:0] source_fault_reason_ddr_meta;
    (* async_reg = "true" *) logic [3:0] source_fault_reason_ddr_sync;
    always_ff @(posedge ddr_clk or posedge ddr_reset_local) begin
        if (ddr_reset_local) begin
            source_fault_ddr_meta <= 0;
            source_fault_ddr_sync <= 0;
            source_fault_reason_ddr_meta <= 0;
            source_fault_reason_ddr_sync <= 0;
            ddr_fault <= 0;
            ddr_fault_reason <= 0;
        end else begin
            source_fault_ddr_meta <= source_fault;
            source_fault_ddr_sync <= source_fault_ddr_meta;
            source_fault_reason_ddr_meta <= source_fault_reason;
            source_fault_reason_ddr_sync <= source_fault_reason_ddr_meta;
            if (source_fault_ddr_sync) begin
                ddr_fault <= 1;
                if (!ddr_fault)
                    ddr_fault_reason <= source_fault_reason_ddr_sync;
            end
        end
    end

    assign ddr_active = ddr_up && source_up_ddr_sync &&
        !ddr_reset_local && !ddr_fault;
    // The measured NSMB Koopa frames contain roughly 6,800 records and more
    // than 99.8% are normalized GX commands. Their old record representation
    // used only one 32-bit word out of each 128-bit DDR payload. Buffer up to
    // two ordered commands and encode three complete {tag,data} pairs in one
    // record. Keep a one/two-command tail until the next ordered event instead
    // of flushing it after an arbitrary DDR-idle gap. Geometry is observable
    // only at an ordering fence (a non-GX record or frame boundary), and both
    // fences already drain the tail first. This lets ordinary CPU command
    // writes pack just as densely as DMA bursts without changing GX order.
    logic [1:0] gx_pack_count;
    logic [127:0] gx_pack_first;
    logic [127:0] gx_pack_second;
    logic [31:0] gx_pack_frame;
    logic pack_capture_first;
    logic pack_capture_second;
    logic pack_emit_three;
    logic pack_flush_one;

    wire async_head_boundary = async_read_data[171];
    wire async_head_structural_gx = !async_head_boundary &&
        async_read_data[7:0] == KIND_GX_COMMAND &&
        async_read_data[31:16] == 16'd0 &&
        async_read_data[63:32] == 32'd0 &&
        async_read_data[127:96] == 32'd0;
    wire async_head_same_frame =
        async_read_data[169:138] == gx_pack_frame;

    always_comb begin
        record_valid = 1'b0;
        record = 128'd0;
        record_frame = 32'd0;
        record_frame_end = 1'b0;
        boundary_valid = 1'b0;
        boundary_frame = 32'd0;
        async_read_ready = 1'b0;
        pack_capture_first = 1'b0;
        pack_capture_second = 1'b0;
        pack_emit_three = 1'b0;
        pack_flush_one = 1'b0;

        if (ddr_active && !ddr_fault) begin
            if (gx_pack_count == 0) begin
                if (async_read_valid && async_head_boundary) begin
                    boundary_valid = 1'b1;
                    boundary_frame = async_read_data[169:138];
                    async_read_ready = boundary_ready;
                end else if (async_read_valid &&
                             async_head_structural_gx &&
                             !async_read_data[170]) begin
                    // Private buffering is the completed CDC handshake.
                    async_read_ready = 1'b1;
                    pack_capture_first = 1'b1;
                end else if (async_read_valid) begin
                    record_valid = 1'b1;
                    record = async_read_data[127:0];
                    if (async_read_data[137])
                        record[29:20] = {
                            1'b1, async_read_data[136:128]};
                    record_frame = async_read_data[169:138];
                    record_frame_end = async_read_data[170];
                    async_read_ready = record_ready;
                end
            end else if (async_read_valid &&
                         async_head_structural_gx &&
                         async_head_same_frame) begin
                if (gx_pack_count == 1 && !async_read_data[170]) begin
                    async_read_ready = 1'b1;
                    pack_capture_second = 1'b1;
                end else if (gx_pack_count == 2) begin
                    record_valid = 1'b1;
                    record = {
                        async_read_data[95:64],
                        gx_pack_second[95:64],
                        gx_pack_first[95:64],
                        async_read_data[15:8],
                        gx_pack_second[15:8],
                        gx_pack_first[15:8],
                        KIND_GX_PACKED
                    };
                    record_frame = gx_pack_frame;
                    record_frame_end = async_read_data[170];
                    async_read_ready = record_ready;
                    pack_emit_three = record_ready;
                end else begin
                    // A SWAP cannot be buffered as command two because no
                    // later same-frame command exists to complete the triplet.
                    record_valid = 1'b1;
                    record = gx_pack_first;
                    record_frame = gx_pack_frame;
                    pack_flush_one = record_ready;
                end
            end else if (async_read_valid) begin
                // Preserve order by draining the tail before the held
                // non-GX/different-frame record or boundary.
                record_valid = 1'b1;
                record = gx_pack_first;
                record_frame = gx_pack_frame;
                pack_flush_one = record_ready;
            end
        end
    end

    always_ff @(posedge ddr_clk or posedge ddr_reset_local) begin
        if (ddr_reset_local) begin
            gx_pack_count <= 0;
            gx_pack_first <= 0;
            gx_pack_second <= 0;
            gx_pack_frame <= 0;
        end else begin
            if (pack_capture_first) begin
                gx_pack_first <= async_read_data[127:0];
                gx_pack_frame <= async_read_data[169:138];
                gx_pack_count <= 1;
            end else if (pack_capture_second) begin
                gx_pack_second <= async_read_data[127:0];
                gx_pack_count <= 2;
            end else if (pack_emit_three) begin
                gx_pack_count <= 0;
            end else if (pack_flush_one) begin
                if (gx_pack_count == 2) begin
                    gx_pack_first <= gx_pack_second;
                    gx_pack_count <= 1;
                end else begin
                    gx_pack_count <= 0;
                end
            end
        end
    end
endmodule
