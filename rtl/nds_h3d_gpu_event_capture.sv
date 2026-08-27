`timescale 1ns/1ps

// Raw, width-preserving ARM9 GPU write normalizer for H3D1.
//
// The input is the already-held ARM9 IO event stream from
// nds_h3d_console_event_gate.  This block only restores byte-address lanes and
// qualifies the GPU register ranges; it deliberately adds no second elastic
// buffer.  Backpressure therefore reaches the console gate directly, so a
// later frame boundary cannot pass an older GPU write hidden in another skid.
// The module does not decode packed GXFIFO command words. HPS sends the raw
// write to melonDS, which keeps its proven packed-command state machine.
module nds_h3d_gpu_event_capture (
    input  logic        clk,
    input  logic        reset,
    input  logic        write_valid,
    output logic        write_ready,
    input  logic        cpu_is_arm9,
    input  logic        write_not_read,
    input  logic [27:0] io_address,
    input  logic [1:0]  access_width,
    input  logic [3:0]  byte_enable,
    input  logic [31:0] write_data,
    input  logic [31:0] frame,
    input  logic [63:0] timestamp,

    output logic        event_valid,
    input  logic        event_ready,
    output logic [31:0] event_address,
    output logic [31:0] event_data,
    output logic [31:0] event_frame,
    output logic [7:0]  event_type,
    output logic        event_cpu,
    output logic [1:0]  event_width,
    output logic [3:0]  event_byte_enable,
    output logic [16:0] event_flags,
    output logic [63:0] event_timestamp
);
    localparam logic [7:0] EVENT_ARM9_GPU_IO_WRITE = 8'd1;

    // nds_membus9 aligns io_bus9.Adr to a word and records the original
    // byte/halfword lane in bEna. Din is already placed in that lane. Restore
    // the architectural low address bits before publishing the raw write.
    logic [1:0] write_low;
    wire [27:0] architectural_address =
        {io_address[27:2], 2'b00} | write_low;
    always_comb begin
        case (byte_enable)
            4'b0010: write_low = 2'd1;
            4'b0100,
            4'b1100: write_low = 2'd2;
            4'b1000: write_low = 2'd3;
            default: write_low = 2'd0;
        endcase
    end

    wire disp3d_hit = architectural_address >= 28'h0000060 &&
        architectural_address <= 28'h0000063;
    wire vramcnt_hit = architectural_address >= 28'h0000240 &&
        architectural_address <= 28'h0000249;
    wire powcnt1_hit = architectural_address >= 28'h0000304 &&
        architectural_address <= 28'h0000307;
    wire renderer_register_hit = architectural_address >= 28'h0000320 &&
        architectural_address <= 28'h00003bf;
    wire geometry_port_hit = architectural_address >= 28'h0000400 &&
        architectural_address <= 28'h00005cb;
    wire gxstat_write_hit = architectural_address >= 28'h0000600 &&
        architectural_address <= 28'h0000613;
    wire gpu_write_hit = disp3d_hit || vramcnt_hit || powcnt1_hit ||
        renderer_register_hit || geometry_port_hit || gxstat_write_hit;
    wire qualified_level = cpu_is_arm9 && write_not_read && gpu_write_hit;
    wire qualified_pulse = write_valid && qualified_level;
    wire [31:0] live_address =
        {4'h0, architectural_address} | 32'h04000000;

    always_comb begin
        // Non-GPU and idle traffic is never delayed. A qualified transaction
        // retires only with the global queue's ready, while the upstream
        // console gate holds its complete record stable across backpressure.
        write_ready = !qualified_pulse || (!reset && event_ready);
        event_valid = !reset && qualified_pulse;
        event_address = live_address;
        event_data = write_data;
        event_frame = frame;
        event_type = EVENT_ARM9_GPU_IO_WRITE;
        event_cpu = 1'b0;
        event_width = access_width;
        event_byte_enable = byte_enable;
        event_flags = 17'd0;
        event_timestamp = timestamp;
    end
endmodule
