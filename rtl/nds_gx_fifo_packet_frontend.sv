// Standalone architectural GX command FIFO and packet frontend.
//
// Accepted ARM9 GXFIFO and direct-command writes are normalized with the same
// packed-command rules as nds_gx_command_frontend, then retained in a real
// 256-entry FIFO until the packet sink accepts them.  Occupancy is therefore
// the number of normalized command records pending downstream, not raw bus
// writes.  The input ready signal may stall both CPU and DMA sources; a source
// must hold valid and payload until acceptance.
//
// Packet ABI:
//   [  7:  0] kind = 1 (GX_COMMAND)
//   [ 15:  8] normalized command id
//   [ 19: 16] byte enable = 0
//   [ 31: 20] reserved = 0
//   [ 63: 32] address/aux = 0
//   [ 95: 64] parameter
//   [127: 96] reserved = 0
//
// record_frame_end pulses with the accepted SWAP_BUFFERS (0x50) command
// record.  A downstream writer closes the frame only after accepting that
// record; no separate marker is allowed to pass it.
module nds_gx_fifo_packet_frontend #(
    parameter integer FIFO_DEPTH = 256
) (
    input  logic         clk,
    input  logic         reset,

    input  logic         write_valid,
    output logic         write_ready,
    input  logic         write_is_dma,
    input  logic [31:0]  write_address,
    input  logic [1:0]   write_access,
    input  logic [31:0]  write_data,
    input  logic [31:0]  write_frame,
    input  logic [63:0]  write_timestamp,

    output logic         record_valid,
    input  logic         record_ready,
    output logic [127:0] record,
    output logic [31:0]  record_frame,
    output logic [63:0]  record_timestamp,
    output logic         record_frame_end,
    output logic         swap_enqueued,
    output logic         swap_pending,
    output logic [63:0]  oldest_swap_timestamp,

    output logic [8:0]   fifo_level,
    output logic         fifo_empty,
    output logic         fifo_below_half,
    output logic         fifo_full,
    output logic         packed_active,
    output logic         protocol_error
);
    localparam integer POINTER_WIDTH =
        FIFO_DEPTH <= 2 ? 1 : $clog2(FIFO_DEPTH);
    localparam integer COUNT_WIDTH = $clog2(FIFO_DEPTH + 1);
    localparam logic [COUNT_WIDTH-1:0] FIFO_DEPTH_COUNT =
        COUNT_WIDTH'(FIFO_DEPTH);
    localparam logic [POINTER_WIDTH-1:0] LAST_POINTER =
        POINTER_WIDTH'(FIFO_DEPTH - 1);

    // Exact copy of the normalization table in nds_gx_command_frontend.sv,
    // itself pinned against melonDS GPU3D.cpp CmdNumParams by its test runner.
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

    logic [7:0] command_memory [0:FIFO_DEPTH-1];
    logic [31:0] parameter_memory [0:FIFO_DEPTH-1];
    logic [31:0] frame_memory [0:FIFO_DEPTH-1];
    logic [63:0] timestamp_memory [0:FIFO_DEPTH-1];
    logic [POINTER_WIDTH-1:0] write_pointer;
    logic [POINTER_WIDTH-1:0] read_pointer;
    logic [COUNT_WIDTH-1:0] count;

    logic [31:0] packed_commands;
    logic [2:0] packed_command_count;
    logic [5:0] packed_parameters_remaining;
    logic [31:0] packed_trigger_parameter;
    logic [31:0] packed_word_frame;
    logic [63:0] packed_word_timestamp;

    // SWAPs may be hidden behind arbitrary non-SWAP command records. Keep a
    // compact ordered timestamp queue for only those closure records so a
    // downstream boundary arbiter can identify the oldest real promise
    // without scanning or adding a second read port to the main GX FIFO.
    logic [63:0] swap_timestamp_memory [0:FIFO_DEPTH-1];
    logic [POINTER_WIDTH-1:0] swap_write_pointer;
    logic [POINTER_WIDTH-1:0] swap_read_pointer;
    logic [COUNT_WIDTH-1:0] swap_count;

    wire word_access = write_access == 2'b10;
    wire aligned_access = write_address[1:0] == 2'b00;
    wire fifo_aperture =
        write_address >= 32'h04000400 &&
        write_address < 32'h04000440;
    wire direct_aperture =
        write_address >= 32'h04000440 &&
        write_address < 32'h040005cc;
    wire gx_aperture = fifo_aperture || direct_aperture;
    wire qualified_cpu_fifo_write =
        !write_is_dma && word_access && aligned_access && fifo_aperture;
    wire qualified_dma_fifo_write =
        write_is_dma && word_access && aligned_access && fifo_aperture;
    wire qualified_cpu_direct_write =
        !write_is_dma && word_access && aligned_access && direct_aperture;
    wire qualified_dma_direct_write =
        write_is_dma && word_access && aligned_access && direct_aperture;
    wire qualified_fifo_write =
        qualified_cpu_fifo_write || qualified_dma_fifo_write;
    wire qualified_direct_write =
        qualified_cpu_direct_write || qualified_dma_direct_write;
    wire qualified_write =
        qualified_fifo_write || qualified_direct_write;

    assign record_valid = count != 0;
    assign record = record_valid
        ? {32'd0, parameter_memory[read_pointer], 32'd0, 12'd0, 4'd0,
           command_memory[read_pointer], 8'd1}
        : 128'd0;
    assign record_frame = record_valid
        ? frame_memory[read_pointer] : 32'd0;
    assign record_timestamp = record_valid
        ? timestamp_memory[read_pointer] : 64'd0;
    assign record_frame_end =
        record_valid && record_ready &&
        command_memory[read_pointer] == 8'h50;

    assign fifo_level = 9'(count);
    assign fifo_empty = count == 0;
    assign fifo_below_half = count <= COUNT_WIDTH'(127);
    assign fifo_full = count == FIFO_DEPTH_COUNT;
    assign packed_active = packed_command_count != 0;

    wire output_pop = record_valid && record_ready;
    wire swap_output_pop = record_frame_end;
    wire fifo_has_space = !fifo_full || output_pop;
    wire packed_zero_phase =
        packed_command_count != 0 &&
        packed_parameters_remaining == 0;
    wire packed_zero_emits =
        packed_commands[7:0] != 0 ||
        (packed_command_count == 4 && packed_commands == 0);
    wire packed_zero_advance =
        packed_zero_phase && (!packed_zero_emits || fifo_has_space);

    // An initial packed command word is one internal word of buffering, so it
    // remains acceptable at full FIFO occupancy. A subsequent parameter or a
    // direct command needs a FIFO slot. Non-GX writes are accepted and ignored
    // so a shared observed write stream is not blocked by this frontend.
    always_comb begin
        if (!qualified_write) begin
            write_ready = 1'b1;
        end else if (packed_zero_phase) begin
            write_ready = 1'b0;
        end else if (qualified_fifo_write &&
                     packed_command_count == 0) begin
            write_ready = 1'b1;
        end else begin
            write_ready = fifo_has_space;
        end
    end

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

    wire [7:0] enqueue_command =
        direct_enqueue ? write_address[9:2] : packed_commands[7:0];
    wire [31:0] enqueue_parameter =
        packed_zero_enqueue ? packed_trigger_parameter : write_data;
    wire [31:0] enqueue_frame = packed_zero_enqueue
        ? packed_word_frame : write_frame;
    wire [63:0] enqueue_timestamp = packed_zero_enqueue
        ? packed_word_timestamp : write_timestamp;
    assign swap_enqueued = enqueue && enqueue_command == 8'h50;
    assign swap_pending = swap_count != 0;
    assign oldest_swap_timestamp = swap_pending
        ? swap_timestamp_memory[swap_read_pointer] : 64'd0;

    initial begin
        if (FIFO_DEPTH != 256)
            $error("nds_gx_fifo_packet_frontend FIFO_DEPTH must be 256");
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            write_pointer <= 0;
            read_pointer <= 0;
            count <= 0;
            packed_commands <= 0;
            packed_command_count <= 0;
            packed_parameters_remaining <= 0;
            packed_trigger_parameter <= 0;
            packed_word_frame <= 0;
            packed_word_timestamp <= 0;
            swap_write_pointer <= 0;
            swap_read_pointer <= 0;
            swap_count <= 0;
            protocol_error <= 0;
        end else begin
            if (write_valid && gx_aperture &&
                (!word_access || !aligned_access))
                protocol_error <= 1'b1;

            if (enqueue) begin
                command_memory[write_pointer] <= enqueue_command;
                parameter_memory[write_pointer] <= enqueue_parameter;
                frame_memory[write_pointer] <= enqueue_frame;
                timestamp_memory[write_pointer] <= enqueue_timestamp;
                if (write_pointer == LAST_POINTER)
                    write_pointer <= 0;
                else
                    write_pointer <= write_pointer + 1'b1;
            end

            if (swap_enqueued) begin
                swap_timestamp_memory[swap_write_pointer] <= enqueue_timestamp;
                if (swap_write_pointer == LAST_POINTER)
                    swap_write_pointer <= 0;
                else
                    swap_write_pointer <= swap_write_pointer + 1'b1;
            end

            if (swap_output_pop) begin
                if (swap_read_pointer == LAST_POINTER)
                    swap_read_pointer <= 0;
                else
                    swap_read_pointer <= swap_read_pointer + 1'b1;
            end

            case ({swap_enqueued, swap_output_pop})
                2'b10: begin
                    if (swap_count == FIFO_DEPTH_COUNT)
                        protocol_error <= 1'b1;
                    else
                        swap_count <= swap_count + 1'b1;
                end
                2'b01: begin
                    if (swap_count == 0)
                        protocol_error <= 1'b1;
                    else
                        swap_count <= swap_count - 1'b1;
                end
                default: swap_count <= swap_count;
            endcase

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

            // Exact state transition order from the existing frontend and
            // melonDS GPU3D::WriteToGXFIFO normalization.
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
                    packed_trigger_parameter <= write_data;
                    packed_word_frame <= write_frame;
                    packed_word_timestamp <= write_timestamp;
                end else begin
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
