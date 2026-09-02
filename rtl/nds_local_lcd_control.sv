// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// Small FPGA owner for the Nintendo DS LCD control cadence. The base cadence,
// register masks, and 2130/1584/263 timing constants derive from
// Nitro_DarkSide's nds_gpu_timing.vhd. Natural-VCOUNT VBlank ordering follows
// melonDS. Rendering remains outside this module.

`timescale 1ns/1ps
`default_nettype none

module nds_local_lcd_control #(
    parameter bit ENABLED = 1'b0,
    parameter integer LINE_CYCLES = 2130,
    parameter integer HBLANK_START = 1584,
    parameter integer FRAME_LINES = 263,
    parameter integer VISIBLE_LINES = 192
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,

    // Absolute shared DS time.  The controller catches up locally, at one
    // boundary per fabric clock.  Queue backpressure is not an input.
    input  logic        time_valid,
    input  logic [63:0] shared_timestamp,

    // Direct register seam. Access: 00 byte, 01 halfword, 10 word.
    input  logic        request,
    input  logic        cpu_is_arm9,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic        selected,
    output logic [31:0] read_data,
    output logic        done,

    // A completed blocking HPS write can be mirrored here.  This lets the
    // local read/IRQ owner coexist with the present renderer during rollout.
    input  logic        mirror_write_valid,
    input  logic        mirror_write_cpu_arm9,
    input  logic [31:0] mirror_write_address,
    input  logic [1:0]  mirror_write_access,
    input  logic [31:0] mirror_write_data,

    output logic [8:0]  vcount,
    output logic [15:0] dispstat9,
    output logic [15:0] dispstat7,

    output logic [31:0] irq9_set_mask,
    output logic [31:0] irq7_set_mask,
    output logic        dma9_hblank_trigger,
    output logic        dma9_vblank_trigger,
    output logic        dma9_display_trigger,
    output logic        dma9_display_stop,
    output logic        dma7_vblank_trigger,

    // One pulse for each ordered phase. Kind 0 is scanline start, kind 1 is
    // HBlank start, and kind 2 is frame wrap plus line-zero start.
    output logic        event_valid,
    output logic [31:0] event_sequence,
    output logic [63:0] event_timestamp,
    output logic [1:0]  event_kind,
    output logic [8:0]  event_line,
    output logic [8:0]  event_vcount,
    output logic [15:0] event_dispstat9,
    output logic [15:0] event_dispstat7,
    output logic [31:0] event_frame_sequence,

    // High only after every phase due at shared_timestamp is applied.
    // An enabled CPU scheduler must wait while this output is low.
    output logic        caught_up,
    output logic        protocol_error
);
    localparam logic [1:0] SCANLINE_START = 2'd0;
    localparam logic [1:0] HBLANK_START_KIND = 2'd1;
    localparam logic [1:0] FRAME_WRAP = 2'd2;
    localparam logic [31:0] LCD_BASE = 32'h04000004;
    localparam logic [31:0] LCD_WRITABLE_MASK = 32'h01ffffb8;

    logic started, started_n;
    logic [63:0] next_timestamp, next_timestamp_n;
    logic [1:0] next_kind, next_kind_n;
    logic [8:0] line, line_n;
    logic [8:0] vcount_n;
    logic [15:0] dispstat9_n, dispstat7_n;
    logic vcount_write_pending, vcount_write_pending_n;
    logic [8:0] vcount_write_value, vcount_write_value_n;
    logic [31:0] source_sequence, source_sequence_n;
    logic [31:0] frame_sequence, frame_sequence_n;
    logic last_time_valid, last_time_valid_n;
    logic [63:0] last_timestamp, last_timestamp_n;
    logic protocol_error_n;

    logic register_hit;
    logic access_legal;
    logic [31:0] live_register;
    logic write_fire;
    logic write_cpu_arm9;
    logic [31:0] write_address_selected;
    logic [1:0] write_access_selected;
    logic [31:0] write_data_selected;
    logic write_register_hit;
    logic write_access_legal;
    logic [31:0] write_lane_mask;
    logic [31:0] write_lane_data;
    logic [31:0] writable_lane_mask;
    logic [8:0] natural_vcount;
    logic [8:0] scanline_vcount;

    logic [31:0] irq9_set_mask_n, irq7_set_mask_n;
    logic dma9_hblank_trigger_n, dma9_vblank_trigger_n;
    logic dma9_display_trigger_n, dma9_display_stop_n;
    logic dma7_vblank_trigger_n;
    logic event_valid_n;
    logic [31:0] event_sequence_n;
    logic [63:0] event_timestamp_n;
    logic [1:0] event_kind_n;
    logic [8:0] event_line_n, event_vcount_n;
    logic [15:0] event_dispstat9_n, event_dispstat7_n;
    logic [31:0] event_frame_sequence_n;

    assign register_hit = address[31:2] == LCD_BASE[31:2];
    always_comb begin
        access_legal = 1'b0;
        case (access)
            2'b00: access_legal = 1'b1;
            2'b01: access_legal = address[0] == 1'b0;
            2'b10: access_legal = address[1:0] == 2'b00;
            default: access_legal = 1'b0;
        endcase
    end
    assign selected = ENABLED && enable && request && register_hit &&
                      access_legal;
    assign done = selected;
    assign caught_up = !ENABLED || !enable ||
        (time_valid && started && !protocol_error &&
         shared_timestamp < next_timestamp && !event_valid &&
         irq9_set_mask == 0 && irq7_set_mask == 0 &&
         !dma9_hblank_trigger && !dma9_vblank_trigger &&
         !dma9_display_trigger && !dma9_display_stop &&
         !dma7_vblank_trigger);
    assign live_register = cpu_is_arm9
        ? {{7{1'b0}}, vcount, dispstat9}
        : {{7{1'b0}}, vcount, dispstat7};

    always_comb begin
        read_data = 32'd0;
        if (selected && read_not_write) begin
            case (access)
                2'b00: begin
                    case (address[1:0])
                        2'd0: read_data[7:0] = live_register[7:0];
                        2'd1: read_data[7:0] = live_register[15:8];
                        2'd2: read_data[7:0] = live_register[23:16];
                        default: read_data[7:0] = live_register[31:24];
                    endcase
                end
                2'b01: read_data[15:0] = address[1]
                    ? live_register[31:16] : live_register[15:0];
                2'b10: read_data = live_register;
                default: read_data = 32'd0;
            endcase
        end
    end

    // A mirror write has priority only because integration never presents a
    // direct write on the same clock.  The deterministic choice fails safe in
    // a simulator if that rule is broken.
    always_comb begin
        write_fire = mirror_write_valid ||
                     (selected && !read_not_write);
        write_cpu_arm9 = mirror_write_valid
            ? mirror_write_cpu_arm9 : cpu_is_arm9;
        write_address_selected = mirror_write_valid
            ? mirror_write_address : address;
        write_access_selected = mirror_write_valid
            ? mirror_write_access : access;
        write_data_selected = mirror_write_valid
            ? mirror_write_data : write_data;
        write_register_hit =
            write_address_selected[31:2] == LCD_BASE[31:2];
        write_access_legal = 1'b0;
        case (write_access_selected)
            2'b00: write_access_legal = 1'b1;
            2'b01: write_access_legal =
                write_address_selected[0] == 1'b0;
            2'b10: write_access_legal =
                write_address_selected[1:0] == 2'b00;
            default: write_access_legal = 1'b0;
        endcase

        write_lane_mask = 32'd0;
        write_lane_data = 32'd0;
        case (write_access_selected)
            2'b00: begin
                write_lane_mask[write_address_selected[1:0]*8 +: 8] = 8'hff;
                write_lane_data[write_address_selected[1:0]*8 +: 8] =
                    write_data_selected[7:0];
            end
            2'b01: begin
                write_lane_mask[write_address_selected[1]*16 +: 16] =
                    16'hffff;
                write_lane_data[write_address_selected[1]*16 +: 16] =
                    write_data_selected[15:0];
            end
            2'b10: begin
                write_lane_mask = 32'hffff_ffff;
                write_lane_data = write_data_selected;
            end
            default: begin end
        endcase
        writable_lane_mask = write_lane_mask & LCD_WRITABLE_MASK;
    end

    always_comb begin
        // Physical LCD timing follows the raster line. A software VCOUNT
        // override changes the visible register and VMatch only. It must not
        // move VBlank or display-DMA start/stop pulses.
        natural_vcount = line;
        if (line == 0)
            scanline_vcount = 9'd0;
        else if (vcount_write_pending)
            scanline_vcount = vcount_write_value;
        else
            scanline_vcount = vcount + 9'd1;
    end

    always_comb begin
        started_n = started;
        next_timestamp_n = next_timestamp;
        next_kind_n = next_kind;
        line_n = line;
        vcount_n = vcount;
        dispstat9_n = dispstat9;
        dispstat7_n = dispstat7;
        vcount_write_pending_n = vcount_write_pending;
        vcount_write_value_n = vcount_write_value;
        source_sequence_n = source_sequence;
        frame_sequence_n = frame_sequence;
        last_time_valid_n = last_time_valid;
        last_timestamp_n = last_timestamp;
        protocol_error_n = protocol_error;

        irq9_set_mask_n = 32'd0;
        irq7_set_mask_n = 32'd0;
        dma9_hblank_trigger_n = 1'b0;
        dma9_vblank_trigger_n = 1'b0;
        dma9_display_trigger_n = 1'b0;
        dma9_display_stop_n = 1'b0;
        dma7_vblank_trigger_n = 1'b0;
        event_valid_n = 1'b0;
        event_sequence_n = event_sequence;
        event_timestamp_n = event_timestamp;
        event_kind_n = event_kind;
        event_line_n = event_line;
        event_vcount_n = event_vcount;
        event_dispstat9_n = event_dispstat9;
        event_dispstat7_n = event_dispstat7;
        event_frame_sequence_n = event_frame_sequence;

        if (ENABLED && enable && time_valid) begin
            if (last_time_valid && shared_timestamp < last_timestamp)
                protocol_error_n = 1'b1;
            last_time_valid_n = 1'b1;
            last_timestamp_n = shared_timestamp;

            if (!protocol_error_n &&
                (!started || shared_timestamp >= next_timestamp)) begin
                started_n = 1'b1;
                source_sequence_n = source_sequence + 32'd1;
                event_valid_n = 1'b1;
                event_sequence_n = source_sequence + 32'd1;
                event_timestamp_n = next_timestamp;
                event_kind_n = next_kind;
                event_line_n = line;
                event_frame_sequence_n = frame_sequence;

                case (next_kind)
                    SCANLINE_START, FRAME_WRAP: begin
                        vcount_n = scanline_vcount;
                        vcount_write_pending_n = 1'b0;
                        dispstat9_n[1] = 1'b0;
                        dispstat7_n[1] = 1'b0;

                        // VBlank follows the natural raster count. A delayed
                        // VCOUNT write affects VMatch, but it cannot move the
                        // physical VBlank start or end.
                        if (natural_vcount == 9'd192) begin
                            dispstat9_n[0] = 1'b1;
                            dispstat7_n[0] = 1'b1;
                            dma9_vblank_trigger_n = 1'b1;
                            dma7_vblank_trigger_n = 1'b1;
                            if (dispstat9[3]) irq9_set_mask_n[0] = 1'b1;
                            if (dispstat7[3]) irq7_set_mask_n[0] = 1'b1;
                        end else if (natural_vcount == 9'd262) begin
                            dispstat9_n[0] = 1'b0;
                            dispstat7_n[0] = 1'b0;
                        end

                        // ARM9 display-start DMA is valid on scanlines
                        // 2 through 193. Scanline 194 disables that mode.
                        if (natural_vcount >= 9'd2 &&
                            natural_vcount < 9'd194)
                            dma9_display_trigger_n = 1'b1;
                        else if (natural_vcount == 9'd194)
                            dma9_display_stop_n = 1'b1;

                        if (scanline_vcount ==
                            {dispstat9[7], dispstat9[15:8]}) begin
                            dispstat9_n[2] = 1'b1;
                            if (dispstat9[5]) irq9_set_mask_n[2] = 1'b1;
                        end else begin
                            dispstat9_n[2] = 1'b0;
                        end
                        if (scanline_vcount ==
                            {dispstat7[7], dispstat7[15:8]}) begin
                            dispstat7_n[2] = 1'b1;
                            if (dispstat7[5]) irq7_set_mask_n[2] = 1'b1;
                        end else begin
                            dispstat7_n[2] = 1'b0;
                        end

                        if (next_kind == FRAME_WRAP) begin
                            frame_sequence_n = frame_sequence + 32'd1;
                            event_frame_sequence_n =
                                frame_sequence + 32'd1;
                        end
                        next_kind_n = HBLANK_START_KIND;
                        next_timestamp_n =
                            next_timestamp + HBLANK_START;
                    end
                    HBLANK_START_KIND: begin
                        dispstat9_n[1] = 1'b1;
                        dispstat7_n[1] = 1'b1;
                        if (dispstat9[4]) irq9_set_mask_n[1] = 1'b1;
                        if (dispstat7[4]) irq7_set_mask_n[1] = 1'b1;
                        if (vcount < VISIBLE_LINES) begin
                            dma9_hblank_trigger_n = 1'b1;
                        end
                        next_timestamp_n = next_timestamp +
                            (LINE_CYCLES - HBLANK_START);
                        if (line == FRAME_LINES - 1) begin
                            line_n = 9'd0;
                            next_kind_n = FRAME_WRAP;
                        end else begin
                            line_n = line + 9'd1;
                            next_kind_n = SCANLINE_START;
                        end
                    end
                    default: protocol_error_n = 1'b1;
                endcase

                // The descriptor is the state directly after this phase and
                // directly before any same-clock CPU register write.
                event_vcount_n = vcount_n;
                event_dispstat9_n = dispstat9_n;
                event_dispstat7_n = dispstat7_n;
            end
        end else if (!time_valid) begin
            last_time_valid_n = 1'b0;
        end

        // CPU register effects follow an equal-time LCD phase. Status bits
        // 0..2 and reserved bit 6 remain read-only.
        if (ENABLED && enable && write_fire && write_register_hit &&
            write_access_legal) begin
            if (write_cpu_arm9)
                dispstat9_n = (dispstat9_n &
                    ~writable_lane_mask[15:0]) |
                    (write_lane_data[15:0] & writable_lane_mask[15:0]);
            else
                dispstat7_n = (dispstat7_n &
                    ~writable_lane_mask[15:0]) |
                    (write_lane_data[15:0] & writable_lane_mask[15:0]);

            if (|writable_lane_mask[24:16]) begin
                vcount_write_pending_n = 1'b1;
                vcount_write_value_n =
                    (vcount_write_value_n &
                     ~writable_lane_mask[24:16]) |
                    (write_lane_data[24:16] &
                     writable_lane_mask[24:16]);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset || !ENABLED) begin
            started <= 1'b0;
            next_timestamp <= 64'd0;
            next_kind <= SCANLINE_START;
            line <= 9'd0;
            vcount <= 9'd0;
            dispstat9 <= 16'd0;
            dispstat7 <= 16'd0;
            vcount_write_pending <= 1'b0;
            vcount_write_value <= 9'd0;
            source_sequence <= 32'd0;
            frame_sequence <= 32'd0;
            last_time_valid <= 1'b0;
            last_timestamp <= 64'd0;
            protocol_error <= 1'b0;
            irq9_set_mask <= 32'd0;
            irq7_set_mask <= 32'd0;
            dma9_hblank_trigger <= 1'b0;
            dma9_vblank_trigger <= 1'b0;
            dma9_display_trigger <= 1'b0;
            dma9_display_stop <= 1'b0;
            dma7_vblank_trigger <= 1'b0;
            event_valid <= 1'b0;
            event_sequence <= 32'd0;
            event_timestamp <= 64'd0;
            event_kind <= SCANLINE_START;
            event_line <= 9'd0;
            event_vcount <= 9'd0;
            event_dispstat9 <= 16'd0;
            event_dispstat7 <= 16'd0;
            event_frame_sequence <= 32'd0;
        end else begin
            started <= started_n;
            next_timestamp <= next_timestamp_n;
            next_kind <= next_kind_n;
            line <= line_n;
            vcount <= vcount_n;
            dispstat9 <= dispstat9_n;
            dispstat7 <= dispstat7_n;
            vcount_write_pending <= vcount_write_pending_n;
            vcount_write_value <= vcount_write_value_n;
            source_sequence <= source_sequence_n;
            frame_sequence <= frame_sequence_n;
            last_time_valid <= last_time_valid_n;
            last_timestamp <= last_timestamp_n;
            protocol_error <= protocol_error_n;
            irq9_set_mask <= irq9_set_mask_n;
            irq7_set_mask <= irq7_set_mask_n;
            dma9_hblank_trigger <= dma9_hblank_trigger_n;
            dma9_vblank_trigger <= dma9_vblank_trigger_n;
            dma9_display_trigger <= dma9_display_trigger_n;
            dma9_display_stop <= dma9_display_stop_n;
            dma7_vblank_trigger <= dma7_vblank_trigger_n;
            event_valid <= event_valid_n;
            event_sequence <= event_sequence_n;
            event_timestamp <= event_timestamp_n;
            event_kind <= event_kind_n;
            event_line <= event_line_n;
            event_vcount <= event_vcount_n;
            event_dispstat9 <= event_dispstat9_n;
            event_dispstat7 <= event_dispstat7_n;
            event_frame_sequence <= event_frame_sequence_n;
        end
    end
endmodule

`default_nettype wire
