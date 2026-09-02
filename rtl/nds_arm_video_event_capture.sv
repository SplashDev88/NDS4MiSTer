`timescale 1ns/1ps

// Shadow-only ordered formatter for the first ARM full-video producer slice.
// Sources use held ready/valid. Timestamps share the console clk1x counter;
// HBlank wins an equal-timestamp tie so the ARM renderer snapshots the line
// before a same-edge HDMA register write affects the following line.
module nds_arm_video_event_capture (
    input  logic         clk,
    input  logic         reset,

    input  logic         gpu_valid,
    output logic         gpu_ready,
    input  logic [31:0]  gpu_address,
    input  logic [1:0]   gpu_access,
    input  logic [3:0]   gpu_byte_enable,
    input  logic [31:0]  gpu_data,
    input  logic [31:0]  gpu_frame,
    input  logic [63:0]  gpu_timestamp,

    input  logic         palette_valid,
    output logic         palette_ready,
    input  logic [31:0]  palette_address,
    input  logic [1:0]   palette_access,
    input  logic [3:0]   palette_byte_enable,
    input  logic [31:0]  palette_data,
    input  logic [31:0]  palette_frame,
    input  logic [63:0]  palette_timestamp,

    input  logic         oam_valid,
    output logic         oam_ready,
    input  logic [31:0]  oam_address,
    input  logic [1:0]   oam_access,
    input  logic [3:0]   oam_byte_enable,
    input  logic [31:0]  oam_data,
    input  logic [31:0]  oam_frame,
    input  logic [63:0]  oam_timestamp,

    input  logic         hblank_valid,
    output logic         hblank_ready,
    input  logic [8:0]   hblank_line,
    input  logic [31:0]  hblank_frame,
    input  logic [63:0]  hblank_timestamp,

    output logic         event_valid,
    input  logic         event_ready,
    output logic [127:0] event_record,
    output logic [31:0]  event_frame,
    output logic [63:0]  event_timestamp
);
    localparam logic [7:0] KIND_GPU2D_REGISTER = 8'd5;
    localparam logic [7:0] KIND_PALETTE_WRITE = 8'd6;
    localparam logic [7:0] KIND_OAM_WRITE = 8'd7;
    localparam logic [7:0] KIND_HBLANK = 8'd8;

    localparam logic [2:0] SELECT_NONE = 3'd0;
    localparam logic [2:0] SELECT_GPU = 3'd1;
    localparam logic [2:0] SELECT_PALETTE = 3'd2;
    localparam logic [2:0] SELECT_OAM = 3'd3;
    localparam logic [2:0] SELECT_HBLANK = 3'd4;

    function automatic logic [127:0] pack_record(
        input logic [7:0] kind,
        input logic [1:0] access,
        input logic [3:0] byte_enable,
        input logic [31:0] address_or_line,
        input logic [31:0] data
    );
        pack_record = {
            32'd0, data, address_or_line,
            12'd0, byte_enable, 6'd0, access, kind
        };
    endfunction

    logic pending_valid;
    logic [127:0] pending_record;
    logic [31:0] pending_frame;
    logic [63:0] pending_timestamp;
    logic can_accept;
    logic [2:0] selected;
    logic [63:0] selected_timestamp;
    logic [127:0] selected_record;
    logic [31:0] selected_frame;

    always_comb begin
        // Establish reverse priority, then replace on <= so equal timestamps
        // finish with HBlank > GPU > palette > OAM.
        selected = SELECT_NONE;
        selected_timestamp = 64'hffffffffffffffff;
        selected_record = 128'd0;
        selected_frame = 32'd0;
        if (oam_valid) begin
            selected = SELECT_OAM;
            selected_timestamp = oam_timestamp;
            selected_record = pack_record(
                KIND_OAM_WRITE, oam_access, oam_byte_enable,
                oam_address, oam_data);
            selected_frame = oam_frame;
        end
        if (palette_valid && palette_timestamp <= selected_timestamp) begin
            selected = SELECT_PALETTE;
            selected_timestamp = palette_timestamp;
            selected_record = pack_record(
                KIND_PALETTE_WRITE, palette_access, palette_byte_enable,
                palette_address, palette_data);
            selected_frame = palette_frame;
        end
        if (gpu_valid && gpu_timestamp <= selected_timestamp) begin
            selected = SELECT_GPU;
            selected_timestamp = gpu_timestamp;
            selected_record = pack_record(
                KIND_GPU2D_REGISTER, gpu_access, gpu_byte_enable,
                gpu_address, gpu_data);
            selected_frame = gpu_frame;
        end
        if (hblank_valid && hblank_timestamp <= selected_timestamp) begin
            selected = SELECT_HBLANK;
            selected_timestamp = hblank_timestamp;
            selected_record = pack_record(
                KIND_HBLANK, 2'd0, 4'd0,
                {23'd0, hblank_line}, hblank_frame);
            selected_frame = hblank_frame;
        end

        can_accept = !reset && (!pending_valid || event_ready);
        gpu_ready = can_accept && selected == SELECT_GPU;
        palette_ready = can_accept && selected == SELECT_PALETTE;
        oam_ready = can_accept && selected == SELECT_OAM;
        hblank_ready = can_accept && selected == SELECT_HBLANK;

        event_valid = pending_valid && !reset;
        event_record = pending_record;
        event_frame = pending_frame;
        event_timestamp = pending_timestamp;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            pending_valid <= 1'b0;
            pending_record <= 128'd0;
            pending_frame <= 32'd0;
            pending_timestamp <= 64'd0;
        end else if (can_accept) begin
            if (selected != SELECT_NONE) begin
                pending_valid <= 1'b1;
                pending_record <= selected_record;
                pending_frame <= selected_frame;
                pending_timestamp <= selected_timestamp;
            end else begin
                pending_valid <= 1'b0;
            end
        end
    end
endmodule
