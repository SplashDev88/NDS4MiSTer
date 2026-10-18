// Standalone architectural GX command FIFO and packet frontend.
//
// Accepted ARM9 GXFIFO and direct-command writes are normalized with the same
// packed-command rules as nds_gx_command_frontend, then retained in a real
// 256-entry FIFO until the packet sink accepts them. With optional SWAP
// retirement, occupancy also retains commands waiting behind a SWAP until
// native VBlank. Counts represent normalized command records, not bus writes.
// Input ready may stall CPU and DMA; sources hold their payload until accepted.
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
    parameter integer FIFO_DEPTH = 256,
    parameter bit SWAP_VBLANK_RETIREMENT = 0,
    parameter bit EXPERIMENTAL_CHECKPOINT = 0
) (
    input  logic         clk,
    input  logic         reset,
    // Native source-clock pulse, independent of queued transport markers.
    input  logic         lcd_vblank,
    input  logic         geometry_enabled,

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
    // Minimum architectural busy state, including an empty FIFO whose SWAP
    // is still waiting for native VBlank. Ordinary command latency is not
    // modeled by this experiment. Power-off freezes an existing wait.
    output logic         geometry_busy,
    output logic         packed_active,
    // Autonomous packed-command expansion still owed for accepted input.
    // Unlike packed_active, this excludes commands waiting for future params.
    output logic         normalization_pending,
    output logic         protocol_error,

    // GXSTAT matrix-stack view (bits 8..13 and 15), tracked from the
    // normalized command stream in submission order. stack_ack is a GXSTAT
    // write with bit 15 set: clear the error and reset the projection and
    // texture stack pointers, as melonDS does.
    input  logic         stack_ack,
    output logic [4:0]   pos_stack_level,
    output logic         proj_stack_level,
    output logic         stack_error,

    // Source-domain component transport. The owner stops new sources, drains
    // delivery, then holds this request through readout. Retirement is NOT a
    // delivery queue: retain its SWAP waits even after ARM received the record.
    input  logic         checkpoint_request,
    input  logic         checkpoint_producers_stopped,
    output logic         checkpoint_stopped,
    input  logic [8:0]   checkpoint_address,
    output logic [31:0]  checkpoint_data,
    output logic         checkpoint_valid,
    input  logic         checkpoint_restore,
    input  logic         checkpoint_write,
    input  logic [31:0]  checkpoint_write_data,
    output logic         checkpoint_restore_ready,
    output logic         checkpoint_restore_error
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

    logic [1:0] matrix_mode;
    logic [5:0] pos_pointer;
    logic       proj_pointer;
    logic       tex_pointer;
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

    wire checkpoint_loading, checkpoint_hold;
    assign record_valid = count != 0 && !checkpoint_loading;
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

    // Transport acceptance is not geometry retirement. A SWAP stalls the
    // geometry engine until the next native VBlank, even if ARM has already
    // received its record. Keep a separate one-bit command-order queue for
    // this minimum architectural barrier. Ordinary command execution latency
    // is not modeled here. Never hold transport at SWAP: doing so can block
    // the ordered LCD events needed by the renderer to complete that SWAP.
    logic [COUNT_WIDTH-1:0] retirement_count;
    logic retirement_pop;

    // Report the larger pressure from the two queues. Disabled-geometry
    // writes still travel to ARM, which ignores them; they consume no new
    // retirement slots and must not be blocked by an older geometry wait.
    wire [COUNT_WIDTH-1:0] visible_count =
        count > retirement_count ? count : retirement_count;
    assign fifo_level = 9'(visible_count);
    assign fifo_empty = visible_count == 0;
    assign fifo_below_half = visible_count <= COUNT_WIDTH'(127);
    assign fifo_full = visible_count == FIFO_DEPTH_COUNT;
    assign packed_active = packed_command_count != 0;

    wire output_pop = record_valid && record_ready;
    wire swap_output_pop = record_frame_end;
    wire fifo_has_space =
        (count != FIFO_DEPTH_COUNT || output_pop) &&
        (!geometry_enabled || retirement_count != FIFO_DEPTH_COUNT || retirement_pop);
    wire packed_zero_phase =
        packed_command_count != 0 &&
        packed_parameters_remaining == 0;
    assign normalization_pending = packed_zero_phase;
    wire packed_zero_emits =
        packed_commands[7:0] != 0 ||
        (packed_command_count == 4 && packed_commands == 0);
    wire packed_zero_advance =
        packed_zero_phase && (!packed_zero_emits || fifo_has_space) &&
        !checkpoint_hold && !checkpoint_loading;

    // An initial packed command word is one internal word of buffering, so it
    // remains acceptable at full FIFO occupancy. A subsequent parameter or a
    // direct command needs a FIFO slot. Non-GX writes are accepted and ignored
    // so a shared observed write stream is not blocked by this frontend.
    always_comb begin
        if (checkpoint_loading || checkpoint_hold) begin
            write_ready = 1'b0;
        end else if (!qualified_write) begin
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
    // MTX_POP's parameter is a signed 6-bit count; modulo-64 subtraction of
    // its raw bits is the same as melonDS's sign-extended subtraction.
    wire [5:0] pos_after_pop = pos_pointer - enqueue_parameter[5:0];
    assign pos_stack_level = pos_pointer[4:0];
    assign proj_stack_level = proj_pointer;
    assign swap_enqueued = enqueue && enqueue_command == 8'h50;
    assign swap_pending = swap_count != 0;
    assign oldest_swap_timestamp = swap_pending
        ? swap_timestamp_memory[swap_read_pointer] : 64'd0;

    // Capture only canonical empty delivery queues. Partial packed commands
    // (including an autonomous zero-param phase blocked by retirement) remain
    // live and are serialized. Freezing here must not wait for future VBlank.
    assign checkpoint_loading = EXPERIMENTAL_CHECKPOINT && checkpoint_restore;
    assign checkpoint_hold = EXPERIMENTAL_CHECKPOINT && checkpoint_request &&
        checkpoint_producers_stopped && !reset && !checkpoint_loading &&
        !write_valid && !lcd_vblank && !stack_ack && !protocol_error &&
        count == 0 && swap_count == 0;
    logic [1:0] checkpoint_quiet;
    logic [8:0] restore_count;
    logic restore_error;
    wire restore_safe = reset && checkpoint_request &&
        checkpoint_producers_stopped && !write_valid && !lcd_vblank && !stack_ack;
    wire [7:0] restored_tail = checkpoint_write_data[7:0] +
        checkpoint_write_data[23:16];
    wire restore_value_valid = checkpoint_address < 9'd263 &&
        (checkpoint_address != 5 ||
            (checkpoint_write_data[31:20] == 0 &&
             checkpoint_write_data[2:0] <= 4 &&
             checkpoint_write_data[8:3] <= 32 &&
             (checkpoint_write_data[2:0] != 0 ||
              checkpoint_write_data[8:3] == 0))) &&
        (checkpoint_address != 6 ||
            (checkpoint_write_data[31:26] == 0 &&
             checkpoint_write_data[24:16] <= 256 &&
             checkpoint_write_data[15:8] == restored_tail)) &&
        (checkpoint_address < 7 || checkpoint_write_data[31:1] == 0) &&
        (SWAP_VBLANK_RETIREMENT || checkpoint_address < 6 ||
            checkpoint_write_data == 0);
    wire restore_accept = checkpoint_loading && restore_safe &&
        checkpoint_write && !restore_error &&
        checkpoint_address == restore_count && restore_value_valid;
    assign checkpoint_stopped = checkpoint_hold && checkpoint_quiet == 2;
    assign checkpoint_restore_error = EXPERIMENTAL_CHECKPOINT && restore_error;
    assign checkpoint_restore_ready = checkpoint_loading && restore_safe &&
        !restore_error && restore_count == 9'd263 && !checkpoint_write;
    assign checkpoint_valid = EXPERIMENTAL_CHECKPOINT && checkpoint_address < 9'd263 &&
        (checkpoint_stopped || checkpoint_restore_ready);
    logic [31:0] retirement_checkpoint_data;
    always_comb begin
        checkpoint_data = 0;
        if (checkpoint_valid) begin
            case (checkpoint_address)
                0: checkpoint_data = packed_commands;
                1: checkpoint_data = packed_trigger_parameter;
                2: checkpoint_data = packed_word_frame;
                3: checkpoint_data = packed_word_timestamp[31:0];
                4: checkpoint_data = packed_word_timestamp[63:32];
                5: checkpoint_data = {12'd0, stack_error, tex_pointer,
                    proj_pointer, pos_pointer, matrix_mode,
                    packed_parameters_remaining, packed_command_count};
                default: checkpoint_data = retirement_checkpoint_data;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if (!checkpoint_hold) checkpoint_quiet <= 0;
        else if (checkpoint_quiet != 2) checkpoint_quiet <= checkpoint_quiet + 1'b1;
        if (!checkpoint_loading) begin
            restore_count <= 0;
            restore_error <= 0;
        end else if (!restore_safe ||
                     (checkpoint_write && !restore_accept)) begin
            restore_error <= 1;
        end else if (restore_accept) restore_count <= restore_count + 1'b1;
    end

    generate if (SWAP_VBLANK_RETIREMENT) begin : swap_retirement
        logic swap_memory [0:FIFO_DEPTH-1];
        logic [POINTER_WIDTH-1:0] pointer, tail;
        logic waiting_vblank;
        assign geometry_busy = waiting_vblank || retirement_count != 0;
        wire retirement_enqueue = enqueue && geometry_enabled;
        assign retirement_pop =
            retirement_count != 0 && !waiting_vblank && geometry_enabled &&
            !checkpoint_hold && !checkpoint_loading;
        // Reuse a one-bit RAM port; avoid a 256-bit variable serializer mux.
        // Inactive cells are not observable by retirement and read as zero.
        wire [7:0] checkpoint_cell = 8'(checkpoint_address - 9'd7);
        wire [7:0] checkpoint_distance = checkpoint_cell - pointer;
        wire [POINTER_WIDTH-1:0] memory_read_address =
            checkpoint_valid && checkpoint_address >= 7 ? checkpoint_cell : pointer;
        wire memory_read_bit = swap_memory[memory_read_address];
        always_comb begin
            retirement_checkpoint_data = 0;
            if (checkpoint_address == 6)
                retirement_checkpoint_data = {6'd0, waiting_vblank,
                    9'(retirement_count), 8'(tail), 8'(pointer)};
            else if (checkpoint_address >= 7 && checkpoint_address < 263 &&
                     {1'b0, checkpoint_distance} < retirement_count)
                retirement_checkpoint_data = {31'd0, memory_read_bit};
        end
        always_ff @(posedge clk) begin
            if (checkpoint_loading) begin
                if (restore_accept && checkpoint_address == 6) begin
                    pointer <= checkpoint_write_data[7:0];
                    tail <= checkpoint_write_data[15:8];
                    retirement_count <= checkpoint_write_data[24:16];
                    waiting_vblank <= checkpoint_write_data[25];
                end
                if (restore_accept && checkpoint_address >= 7)
                    swap_memory[checkpoint_cell] <= checkpoint_write_data[0];
            end else if (reset) begin
                pointer <= 0;
                tail <= 0;
                retirement_count <= 0;
                waiting_vblank <= 0;
            end else begin
                if (retirement_enqueue) begin
                    swap_memory[tail] <= enqueue_command == 8'h50;
                    if (tail == LAST_POINTER) tail <= 0;
                    else tail <= tail + 1'b1;
                end
                if (waiting_vblank && lcd_vblank && geometry_enabled && !checkpoint_hold)
                    waiting_vblank <= 0;
                if (retirement_pop) begin
                    // A SWAP starting on VBlank waits for the NEXT pulse.
                    if (memory_read_bit) waiting_vblank <= 1;
                    if (pointer == LAST_POINTER) pointer <= 0;
                    else pointer <= pointer + 1'b1;
                end
                case ({retirement_enqueue, retirement_pop})
                    2'b10: retirement_count <= retirement_count + 1'b1;
                    2'b01: retirement_count <= retirement_count - 1'b1;
                    default: ;
                endcase
            end
        end
    end else begin : transport_only
        assign retirement_checkpoint_data = 0;
        assign retirement_count = 0;
        assign retirement_pop = 0;
        assign geometry_busy = 0;
    end endgenerate

    initial begin
        if (FIFO_DEPTH != 256)
            $error("nds_gx_fifo_packet_frontend FIFO_DEPTH must be 256");
    end

    always_ff @(posedge clk) begin
        if (checkpoint_loading) begin
            // The captured delivery and SWAP-timestamp queues were empty.
            // Reset indices together; their stale payload RAM is unreachable.
            if (reset) begin
                write_pointer <= 0;
                read_pointer <= 0;
                count <= 0;
                swap_write_pointer <= 0;
                swap_read_pointer <= 0;
                swap_count <= 0;
                protocol_error <= 0;
            end
            if (restore_accept) begin
                case (checkpoint_address)
                    0: packed_commands <= checkpoint_write_data;
                    1: packed_trigger_parameter <= checkpoint_write_data;
                    2: packed_word_frame <= checkpoint_write_data;
                    3: packed_word_timestamp[31:0] <= checkpoint_write_data;
                    4: packed_word_timestamp[63:32] <= checkpoint_write_data;
                    5: begin
                        packed_command_count <= checkpoint_write_data[2:0];
                        packed_parameters_remaining <= checkpoint_write_data[8:3];
                        matrix_mode <= checkpoint_write_data[10:9];
                        pos_pointer <= checkpoint_write_data[16:11];
                        proj_pointer <= checkpoint_write_data[17];
                        tex_pointer <= checkpoint_write_data[18];
                        stack_error <= checkpoint_write_data[19];
                    end
                    default: ;
                endcase
            end
        end else if (reset) begin
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
            matrix_mode <= 0;
            pos_pointer <= 0;
            proj_pointer <= 0;
            tex_pointer <= 0;
            stack_error <= 0;
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

            // Matrix stacks, mirroring melonDS GPU3D MTX_PUSH/MTX_POP. Games
            // such as GTA: Chinatown Wars read the position-stack level from
            // GXSTAT and pop exactly that many at the start of each frame; a
            // constant zero level lets the pointer drift until it wraps onto
            // the camera slot.
            if (stack_ack) begin
                stack_error <= 1'b0;
                proj_pointer <= 1'b0;
                tex_pointer <= 1'b0;
            end
            if (enqueue) begin
                case (enqueue_command)
                    8'h10: matrix_mode <= enqueue_parameter[1:0];
                    8'h11: begin
                        if (matrix_mode == 2'd0) begin
                            if (proj_pointer) stack_error <= 1'b1;
                            proj_pointer <= ~proj_pointer;
                        end else if (matrix_mode == 2'd3) begin
                            if (tex_pointer) stack_error <= 1'b1;
                            tex_pointer <= ~tex_pointer;
                        end else begin
                            if (pos_pointer > 6'd30) stack_error <= 1'b1;
                            pos_pointer <= pos_pointer + 6'd1;
                        end
                    end
                    8'h12: begin
                        if (matrix_mode == 2'd0) begin
                            if (!proj_pointer) stack_error <= 1'b1;
                            proj_pointer <= ~proj_pointer;
                        end else if (matrix_mode == 2'd3) begin
                            if (!tex_pointer) stack_error <= 1'b1;
                            tex_pointer <= ~tex_pointer;
                        end else begin
                            if (pos_after_pop > 6'd30) stack_error <= 1'b1;
                            pos_pointer <= pos_after_pop;
                        end
                    end
                    default: ;
                endcase
            end

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
