// Standalone shadow frontend for Nintendo DS geometry command writes.
//
// This module deliberately does not provide architectural GXSTAT responses or
// connect to the production CPU memory path.  It only normalizes accepted ARM9
// GXFIFO/direct-command writes into the same {command, parameter} stream used
// by melonDS's HGS1 type-3 records.  The output queue is a transport queue; its
// level must not be exposed as the DS geometry FIFO level.
module nds_gx_command_frontend #(
    parameter integer QUEUE_DEPTH = 16
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        write_valid,
    output logic        write_ready,
    input  logic        cpu_is_arm9,
    input  logic [31:0] address,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    input  logic [31:0] frame,
    input  logic [63:0] timestamp,

    output logic        command_valid,
    input  logic        command_ready,
    output logic [31:0] command_frame,
    output logic [63:0] command_timestamp,
    output logic [7:0]  command_id,
    output logic [31:0] command_parameter,

    output logic [$clog2(QUEUE_DEPTH + 1)-1:0] queue_level,
    output logic        queue_empty,
    output logic        queue_full,
    output logic        packed_active,
    output logic        busy,
    output logic        protocol_error
);
    localparam integer POINTER_WIDTH =
        QUEUE_DEPTH <= 2 ? 1 : $clog2(QUEUE_DEPTH);
    localparam integer COUNT_WIDTH = $clog2(QUEUE_DEPTH + 1);
    localparam logic [COUNT_WIDTH-1:0] QUEUE_DEPTH_COUNT =
        COUNT_WIDTH'(QUEUE_DEPTH);
    localparam logic [POINTER_WIDTH-1:0] LAST_POINTER =
        POINTER_WIDTH'(QUEUE_DEPTH - 1);

    // Exact copy of melonDS GPU3D.cpp CmdNumParams.  The test runner compares
    // all 256 entries and its SHA-256 against that authoritative source.
    function automatic logic [5:0] command_parameter_count(
        input logic [7:0] command
    );
        begin
            case (command)
                8'h10: command_parameter_count = 6'd1;
                8'h12: command_parameter_count = 6'd1;
                8'h13: command_parameter_count = 6'd1;
                8'h14: command_parameter_count = 6'd1;
                8'h16: command_parameter_count = 6'd16;
                8'h17: command_parameter_count = 6'd12;
                8'h18: command_parameter_count = 6'd16;
                8'h19: command_parameter_count = 6'd12;
                8'h1a: command_parameter_count = 6'd9;
                8'h1b: command_parameter_count = 6'd3;
                8'h1c: command_parameter_count = 6'd3;
                8'h20: command_parameter_count = 6'd1;
                8'h21: command_parameter_count = 6'd1;
                8'h22: command_parameter_count = 6'd1;
                8'h23: command_parameter_count = 6'd2;
                8'h24: command_parameter_count = 6'd1;
                8'h25: command_parameter_count = 6'd1;
                8'h26: command_parameter_count = 6'd1;
                8'h27: command_parameter_count = 6'd1;
                8'h28: command_parameter_count = 6'd1;
                8'h29: command_parameter_count = 6'd1;
                8'h2a: command_parameter_count = 6'd1;
                8'h2b: command_parameter_count = 6'd1;
                8'h30: command_parameter_count = 6'd1;
                8'h31: command_parameter_count = 6'd1;
                8'h32: command_parameter_count = 6'd1;
                8'h33: command_parameter_count = 6'd1;
                8'h34: command_parameter_count = 6'd32;
                8'h40: command_parameter_count = 6'd1;
                8'h50: command_parameter_count = 6'd1;
                8'h60: command_parameter_count = 6'd1;
                8'h70: command_parameter_count = 6'd3;
                8'h71: command_parameter_count = 6'd2;
                8'h72: command_parameter_count = 6'd1;
                default: command_parameter_count = 6'd0;
            endcase
        end
    endfunction

    logic [31:0] frame_memory [0:QUEUE_DEPTH-1];
    logic [63:0] timestamp_memory [0:QUEUE_DEPTH-1];
    logic [7:0] command_memory [0:QUEUE_DEPTH-1];
    logic [31:0] parameter_memory [0:QUEUE_DEPTH-1];
    logic [POINTER_WIDTH-1:0] write_pointer;
    logic [POINTER_WIDTH-1:0] read_pointer;
    logic [COUNT_WIDTH-1:0] count;

    logic [31:0] packed_commands;
    logic [2:0] packed_command_count;
    logic [5:0] packed_parameters_remaining;
    logic [31:0] packed_trigger_frame;
    logic [63:0] packed_trigger_timestamp;
    logic [31:0] packed_trigger_parameter;

    wire word_access = access == 2'b10;
    wire aligned_access = address[1:0] == 2'b00;
    wire fifo_aperture =
        address >= 32'h04000400 && address < 32'h04000440;
    wire direct_aperture =
        address >= 32'h04000440 && address < 32'h040005cc;
    wire gx_aperture = fifo_aperture || direct_aperture;
    wire qualified_fifo_write =
        cpu_is_arm9 && word_access && aligned_access && fifo_aperture;
    wire qualified_direct_write =
        cpu_is_arm9 && word_access && aligned_access && direct_aperture;
    wire qualified_write =
        qualified_fifo_write || qualified_direct_write;

    assign command_valid = count != 0;
    assign command_frame = frame_memory[read_pointer];
    assign command_timestamp = timestamp_memory[read_pointer];
    assign command_id = command_memory[read_pointer];
    assign command_parameter = parameter_memory[read_pointer];
    assign queue_level = count;
    assign queue_empty = count == 0;
    assign queue_full = count == QUEUE_DEPTH_COUNT;
    assign packed_active = packed_command_count != 0;

    wire output_pop = command_valid && command_ready;
    wire queue_has_space = !queue_full || output_pop;
    wire packed_zero_phase =
        packed_command_count != 0 &&
        packed_parameters_remaining == 0;
    wire packed_zero_emits =
        packed_commands[7:0] != 0 ||
        (packed_command_count == 4 && packed_commands == 0);
    wire packed_zero_advance =
        packed_zero_phase && (!packed_zero_emits || queue_has_space);

    // Non-GX traffic is accepted and ignored so this module can observe a
    // complete write stream.  A packed command word is one word of internal
    // buffering and can be accepted even when the output queue is full.
    always_comb begin
        if (!qualified_write) begin
            write_ready = 1'b1;
        end else if (packed_zero_phase) begin
            write_ready = 1'b0;
        end else if (qualified_fifo_write &&
                     packed_command_count == 0) begin
            write_ready = 1'b1;
        end else begin
            write_ready = queue_has_space;
        end
    end

    assign busy = packed_zero_phase || queue_full;

    wire write_accept = write_valid && write_ready;
    wire direct_enqueue =
        write_accept && qualified_direct_write;
    wire packed_parameter_enqueue =
        write_accept && qualified_fifo_write &&
        packed_command_count != 0;
    wire packed_zero_enqueue =
        packed_zero_advance && packed_zero_emits;
    wire enqueue =
        direct_enqueue || packed_parameter_enqueue || packed_zero_enqueue;

    wire [31:0] enqueue_frame =
        packed_zero_enqueue ? packed_trigger_frame : frame;
    wire [63:0] enqueue_timestamp =
        packed_zero_enqueue ? packed_trigger_timestamp : timestamp;
    wire [7:0] enqueue_command =
        direct_enqueue ? address[9:2] :
        packed_commands[7:0];
    wire [31:0] enqueue_parameter =
        packed_zero_enqueue ? packed_trigger_parameter : write_data;

    initial begin
        if (QUEUE_DEPTH < 2)
            $error("nds_gx_command_frontend QUEUE_DEPTH must be at least 2");
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            write_pointer <= 0;
            read_pointer <= 0;
            count <= 0;
            packed_commands <= 0;
            packed_command_count <= 0;
            packed_parameters_remaining <= 0;
            packed_trigger_frame <= 0;
            packed_trigger_timestamp <= 0;
            packed_trigger_parameter <= 0;
            protocol_error <= 0;
        end else begin
            if (write_accept && cpu_is_arm9 && gx_aperture &&
                (!word_access || !aligned_access))
                protocol_error <= 1'b1;

            if (enqueue) begin
                frame_memory[write_pointer] <= enqueue_frame;
                timestamp_memory[write_pointer] <= enqueue_timestamp;
                command_memory[write_pointer] <= enqueue_command;
                parameter_memory[write_pointer] <= enqueue_parameter;
                if (write_pointer == LAST_POINTER)
                    write_pointer <= 0;
                else
                    write_pointer <= write_pointer + 1'b1;
            end

            if (output_pop) begin
                if (read_pointer == LAST_POINTER)
                    read_pointer <= 0;
                else
                    read_pointer <= read_pointer + 1'b1;
            end

            case ({enqueue, output_pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            // Packed writes use the exact state transition order from
            // melonDS GPU3D::WriteToGXFIFO.  Zero-parameter commands are
            // emitted using the word that triggered their discovery.
            if (packed_zero_advance) begin
                if (packed_command_count == 1) begin
                    packed_commands <= 0;
                    packed_command_count <= 0;
                    packed_parameters_remaining <= 0;
                end else begin
                    packed_commands <= packed_commands >> 8;
                    packed_command_count <= packed_command_count - 1'b1;
                    packed_parameters_remaining <=
                        command_parameter_count(packed_commands[15:8]);
                end
            end else if (write_accept && qualified_fifo_write) begin
                if (packed_command_count == 0) begin
                    packed_commands <= write_data;
                    packed_command_count <= 4;
                    packed_parameters_remaining <=
                        command_parameter_count(write_data[7:0]);
                    packed_trigger_frame <= frame;
                    packed_trigger_timestamp <= timestamp;
                    packed_trigger_parameter <= write_data;
                end else begin
                    packed_trigger_frame <= frame;
                    packed_trigger_timestamp <= timestamp;
                    packed_trigger_parameter <= write_data;
                    if (packed_parameters_remaining == 1) begin
                        if (packed_command_count == 1) begin
                            packed_commands <= 0;
                            packed_command_count <= 0;
                            packed_parameters_remaining <= 0;
                        end else begin
                            packed_commands <= packed_commands >> 8;
                            packed_command_count <=
                                packed_command_count - 1'b1;
                            packed_parameters_remaining <=
                                command_parameter_count(
                                    packed_commands[15:8]);
                        end
                    end else begin
                        packed_parameters_remaining <=
                            packed_parameters_remaining - 1'b1;
                    end
                end
            end
        end
    end
endmodule
