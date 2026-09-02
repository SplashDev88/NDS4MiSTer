`timescale 1ns/1ps

// Global ordered H3D1 event queue and clk1x-to-DDR clock crossing.
//
// All four producers use ordinary ready/valid semantics.  Once valid is high,
// the producer must hold valid and every payload field until ready is sampled
// high.  Simultaneous inputs form one atomic batch.  The entire batch is
// accepted in this fixed order or the entire batch is backpressured:
//
//   1. ARM9 GPU I/O write
//   2. ARM9 virtual-VRAM write
//   3. ARM7 virtual-VRAM write
//   4. video frame boundary
//
// A four-or-larger source-domain queue accepts up to four records per clk1x
// edge.  Non-frame-only traffic cannot consume its final slot.  This reserves
// capacity for a lone frame boundary; a simultaneous batch containing a frame
// still waits until the whole batch fits, preserving the order above.
//
// One record per clk1x cycle drains into a Gray-pointer asynchronous FIFO.
// The DDR-domain output is a held ready/valid record.  Its sequence starts at
// one after every common reset/session flush and advances only on output
// handshake, making it directly suitable for nds_h3d_event_ring.
//
// reset and session_flush asynchronously stop both domains.  Their release is
// synchronized independently in each clock domain, and traffic remains
// stopped until both domains have observed release.  A producer that drops or
// mutates a stalled record raises a sticky source fault.  That fault crosses
// to DDR and suppresses every later output until the next reset/session flush.
module nds_h3d_event_queue_cdc #(
    parameter integer LOCAL_DEPTH = 4,
    parameter integer ASYNC_LGDEPTH = 4
) (
    input  logic        source_clk,
    input  logic        ddr_clk,
    input  logic        reset,
    input  logic        session_flush,

    input  logic        gpu_valid,
    output logic        gpu_ready,
    input  logic [31:0] gpu_address,
    input  logic [31:0] gpu_data,
    input  logic [31:0] gpu_frame,
    input  logic [1:0]  gpu_width,
    input  logic [3:0]  gpu_byte_enable,
    input  logic [16:0] gpu_flags,
    input  logic [63:0] gpu_timestamp,

    input  logic        arm9_vram_valid,
    output logic        arm9_vram_ready,
    input  logic [31:0] arm9_vram_address,
    input  logic [31:0] arm9_vram_data,
    input  logic [31:0] arm9_vram_frame,
    input  logic [1:0]  arm9_vram_width,
    input  logic [3:0]  arm9_vram_byte_enable,
    input  logic [16:0] arm9_vram_flags,
    input  logic [63:0] arm9_vram_timestamp,

    input  logic        arm7_vram_valid,
    output logic        arm7_vram_ready,
    input  logic [31:0] arm7_vram_address,
    input  logic [31:0] arm7_vram_data,
    input  logic [31:0] arm7_vram_frame,
    input  logic [1:0]  arm7_vram_width,
    input  logic [3:0]  arm7_vram_byte_enable,
    input  logic [16:0] arm7_vram_flags,
    input  logic [63:0] arm7_vram_timestamp,

    input  logic        frame_valid,
    output logic        frame_ready,
    input  logic [31:0] frame_number,
    input  logic [16:0] frame_flags,
    input  logic [63:0] frame_timestamp,

    output logic        source_active,
    output logic        ddr_active,
    output logic        source_fault,
    output logic        ddr_fault,
    output logic        fault,
    output logic [$clog2(LOCAL_DEPTH + 1)-1:0] source_occupancy,

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
    output logic [63:0] event_timestamp,
    output logic [31:0] event_sequence
);
    localparam integer EVENT_WIDTH = 192;
    localparam integer LOCAL_PTR_WIDTH =
        LOCAL_DEPTH <= 2 ? 1 : $clog2(LOCAL_DEPTH);
    localparam integer LOCAL_COUNT_WIDTH = $clog2(LOCAL_DEPTH + 1);
    localparam logic [LOCAL_COUNT_WIDTH:0] LOCAL_DEPTH_EXT =
        (LOCAL_COUNT_WIDTH + 1)'(LOCAL_DEPTH);
    localparam logic [7:0] EVENT_GPU_IO = 8'd1;
    localparam logic [7:0] EVENT_ARM9_VRAM = 8'd2;
    localparam logic [7:0] EVENT_ARM7_VRAM = 8'd3;
    localparam logic [7:0] EVENT_FRAME = 8'd4;

    initial begin
        if (LOCAL_DEPTH < 4 ||
            (LOCAL_DEPTH & (LOCAL_DEPTH - 1)) != 0)
            $fatal(1,
                "H3D local event depth must be a power of two >= 4");
        if (ASYNC_LGDEPTH < 4)
            $fatal(1, "H3D asynchronous event depth must be at least 16");
    end

    function automatic logic [EVENT_WIDTH-1:0] pack_event(
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [31:0] frame,
        input logic [7:0]  event_kind,
        input logic        arm7,
        input logic [1:0]  width,
        input logic [3:0]  byte_enable,
        input logic [16:0] flags,
        input logic [63:0] timestamp
    );
        pack_event = {
            timestamp, flags, byte_enable, width, arm7, event_kind,
            frame, data, address
        };
    endfunction

    wire [EVENT_WIDTH-1:0] gpu_payload = pack_event(
        gpu_address, gpu_data, gpu_frame, EVENT_GPU_IO, 1'b0,
        gpu_width, gpu_byte_enable, gpu_flags, gpu_timestamp);
    wire [EVENT_WIDTH-1:0] arm9_payload = pack_event(
        arm9_vram_address, arm9_vram_data, arm9_vram_frame,
        EVENT_ARM9_VRAM, 1'b0, arm9_vram_width,
        arm9_vram_byte_enable, arm9_vram_flags, arm9_vram_timestamp);
    wire [EVENT_WIDTH-1:0] arm7_payload = pack_event(
        arm7_vram_address, arm7_vram_data, arm7_vram_frame,
        EVENT_ARM7_VRAM, 1'b1, arm7_vram_width,
        arm7_vram_byte_enable, arm7_vram_flags, arm7_vram_timestamp);
    wire [EVENT_WIDTH-1:0] frame_payload = pack_event(
        32'd0, 32'd0, frame_number, EVENT_FRAME, 1'b0,
        2'd0, 4'd0, frame_flags, frame_timestamp);

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
            source_up <= 1'b0;
            ddr_up_source_meta <= 1'b0;
            ddr_up_source_sync <= 1'b0;
        end else begin
            source_up <= 1'b1;
            ddr_up_source_meta <= ddr_up;
            ddr_up_source_sync <= ddr_up_source_meta;
        end
    end

    always_ff @(posedge ddr_clk or posedge ddr_reset_local) begin
        if (ddr_reset_local) begin
            ddr_up <= 1'b0;
            source_up_ddr_meta <= 1'b0;
            source_up_ddr_sync <= 1'b0;
        end else begin
            ddr_up <= 1'b1;
            source_up_ddr_meta <= source_up;
            source_up_ddr_sync <= source_up_ddr_meta;
        end
    end

    logic [EVENT_WIDTH-1:0] local_memory [0:LOCAL_DEPTH-1];
    logic [LOCAL_PTR_WIDTH-1:0] local_write_pointer;
    logic [LOCAL_PTR_WIDTH-1:0] local_read_pointer;
    logic [LOCAL_COUNT_WIDTH-1:0] local_count;

    logic async_write_valid;
    logic async_write_ready;
    logic [EVENT_WIDTH-1:0] async_write_data;
    logic async_read_valid;
    logic async_read_ready;
    logic [EVENT_WIDTH-1:0] async_read_data;

    wire local_pop = source_active && local_count != 0 &&
        async_write_ready;
    logic [2:0] valid_count;
    logic [1:0] arm9_enqueue_offset;
    logic [1:0] arm7_enqueue_offset;
    logic [1:0] frame_enqueue_offset;
    logic [LOCAL_COUNT_WIDTH:0] free_after_pop;
    logic [LOCAL_COUNT_WIDTH:0] required_slots;
    logic batch_ready;
    wire batch_valid = gpu_valid || arm9_vram_valid ||
        arm7_vram_valid || frame_valid;
    wire batch_fire = batch_valid && batch_ready;

    always_comb begin
        valid_count = {2'd0, gpu_valid} +
            {2'd0, arm9_vram_valid} +
            {2'd0, arm7_vram_valid} +
            {2'd0, frame_valid};
        arm9_enqueue_offset = {1'b0, gpu_valid};
        arm7_enqueue_offset =
            {1'b0, gpu_valid} + {1'b0, arm9_vram_valid};
        frame_enqueue_offset =
            {1'b0, gpu_valid} + {1'b0, arm9_vram_valid} +
            {1'b0, arm7_vram_valid};
        free_after_pop = LOCAL_DEPTH_EXT -
            (LOCAL_COUNT_WIDTH + 1)'(local_count) +
            (LOCAL_COUNT_WIDTH + 1)'(local_pop);
        // Keep one slot unused by non-frame-only traffic.  When there is no
        // current request, report the capacity each source would receive if it
        // asserted valid in this cycle.
        required_slots = (LOCAL_COUNT_WIDTH + 1)'(valid_count);
        if (!frame_valid)
            required_slots =
                (LOCAL_COUNT_WIDTH + 1)'(valid_count) + 1'b1;
        batch_ready = source_active && !source_fault &&
            free_after_pop >= required_slots;

        if (batch_valid) begin
            gpu_ready = batch_ready;
            arm9_vram_ready = batch_ready;
            arm7_vram_ready = batch_ready;
            frame_ready = batch_ready;
        end else begin
            gpu_ready = source_active && !source_fault &&
                free_after_pop >= 2;
            arm9_vram_ready = gpu_ready;
            arm7_vram_ready = gpu_ready;
            frame_ready = source_active && !source_fault &&
                free_after_pop >= 1;
        end

        async_write_valid = source_active && local_count != 0;
        async_write_data = local_memory[local_read_pointer];
        source_occupancy = local_count;
    end

    // A stalled producer must retain its exact record.  This catches a pulse-
    // only frame source (or any other source) before an event can disappear.
    logic gpu_stalled;
    logic arm9_stalled;
    logic arm7_stalled;
    logic frame_stalled;
    logic [EVENT_WIDTH-1:0] gpu_stalled_payload;
    logic [EVENT_WIDTH-1:0] arm9_stalled_payload;
    logic [EVENT_WIDTH-1:0] arm7_stalled_payload;
    logic [EVENT_WIDTH-1:0] frame_stalled_payload;

    always_ff @(posedge source_clk or posedge source_reset_local) begin
        if (source_reset_local) begin
            local_write_pointer <= '0;
            local_read_pointer <= '0;
            local_count <= '0;
            source_fault <= 1'b0;
            gpu_stalled <= 1'b0;
            arm9_stalled <= 1'b0;
            arm7_stalled <= 1'b0;
            frame_stalled <= 1'b0;
            gpu_stalled_payload <= '0;
            arm9_stalled_payload <= '0;
            arm7_stalled_payload <= '0;
            frame_stalled_payload <= '0;
        end else begin
            if (local_pop)
                local_read_pointer <= local_read_pointer + 1'b1;

            if (batch_fire) begin
                if (gpu_valid) begin
                    local_memory[local_write_pointer] <= gpu_payload;
                end
                if (arm9_vram_valid) begin
                    local_memory[LOCAL_PTR_WIDTH'(
                        local_write_pointer +
                        LOCAL_PTR_WIDTH'(arm9_enqueue_offset))] <=
                        arm9_payload;
                end
                if (arm7_vram_valid) begin
                    local_memory[LOCAL_PTR_WIDTH'(
                        local_write_pointer +
                        LOCAL_PTR_WIDTH'(arm7_enqueue_offset))] <=
                        arm7_payload;
                end
                if (frame_valid) begin
                    local_memory[LOCAL_PTR_WIDTH'(
                        local_write_pointer +
                        LOCAL_PTR_WIDTH'(frame_enqueue_offset))] <=
                        frame_payload;
                end
                local_write_pointer <=
                    local_write_pointer + LOCAL_PTR_WIDTH'(valid_count);
            end
            case ({batch_fire, local_pop})
                2'b10: local_count <= local_count +
                    LOCAL_COUNT_WIDTH'(valid_count);
                2'b01: local_count <= local_count - 1'b1;
                2'b11: local_count <= local_count +
                    LOCAL_COUNT_WIDTH'(valid_count) - 1'b1;
                default: begin end
            endcase

            if (gpu_stalled &&
                (!gpu_valid || gpu_payload != gpu_stalled_payload))
                source_fault <= 1'b1;
            if (arm9_stalled &&
                (!arm9_vram_valid || arm9_payload != arm9_stalled_payload))
                source_fault <= 1'b1;
            if (arm7_stalled &&
                (!arm7_vram_valid || arm7_payload != arm7_stalled_payload))
                source_fault <= 1'b1;
            if (frame_stalled &&
                (!frame_valid || frame_payload != frame_stalled_payload))
                source_fault <= 1'b1;

            if (gpu_valid && !gpu_ready && !gpu_stalled) begin
                gpu_stalled <= 1'b1;
                gpu_stalled_payload <= gpu_payload;
            end else if (gpu_valid && gpu_ready) begin
                gpu_stalled <= 1'b0;
            end
            if (arm9_vram_valid && !arm9_vram_ready && !arm9_stalled) begin
                arm9_stalled <= 1'b1;
                arm9_stalled_payload <= arm9_payload;
            end else if (arm9_vram_valid && arm9_vram_ready) begin
                arm9_stalled <= 1'b0;
            end
            if (arm7_vram_valid && !arm7_vram_ready && !arm7_stalled) begin
                arm7_stalled <= 1'b1;
                arm7_stalled_payload <= arm7_payload;
            end else if (arm7_vram_valid && arm7_vram_ready) begin
                arm7_stalled <= 1'b0;
            end
            if (frame_valid && !frame_ready && !frame_stalled) begin
                frame_stalled <= 1'b1;
                frame_stalled_payload <= frame_payload;
            end else if (frame_valid && frame_ready) begin
                frame_stalled <= 1'b0;
            end
        end
    end

    // Both directions must observe the other's reset release before either
    // side can move a FIFO pointer.  External valid/ready is gated by these
    // same signals, so an arbitrarily skewed clock/reset release cannot expose
    // a stale pointer or memory entry.
    assign source_active = source_up && ddr_up_source_sync &&
        !source_reset_local && !source_fault;

    nds_h3d_event_async_fifo #(
        .WIDTH(EVENT_WIDTH),
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
    logic [31:0] next_sequence;
    wire output_fire = event_valid && event_ready;

    always_ff @(posedge ddr_clk or posedge ddr_reset_local) begin
        if (ddr_reset_local) begin
            source_fault_ddr_meta <= 1'b0;
            source_fault_ddr_sync <= 1'b0;
            ddr_fault <= 1'b0;
            next_sequence <= 32'd1;
        end else begin
            source_fault_ddr_meta <= source_fault;
            source_fault_ddr_sync <= source_fault_ddr_meta;
            if (source_fault_ddr_sync)
                ddr_fault <= 1'b1;
            if (output_fire) begin
                if (next_sequence == 32'hffffffff)
                    ddr_fault <= 1'b1;
                else
                    next_sequence <= next_sequence + 1'b1;
            end
        end
    end

    // Icarus emits false sensitivity warnings for constant part-selects in
    // always_comb.  This is the same combinational process written as @*.
    always @* begin
        // Only the synchronized copy of the source fault participates in DDR
        // logic.  The unsynchronized source_fault output is for its own clock
        // domain and diagnostics, never as a DDR-domain control input.
        ddr_active = ddr_up && source_up_ddr_sync &&
            !ddr_reset_local && !ddr_fault && !source_fault_ddr_sync;
        event_valid = async_read_valid && ddr_active;
        async_read_ready = event_ready && ddr_active;
        event_address = async_read_data[31:0];
        event_data = async_read_data[63:32];
        event_frame = async_read_data[95:64];
        event_type = async_read_data[103:96];
        event_cpu = async_read_data[104];
        event_width = async_read_data[106:105];
        event_byte_enable = async_read_data[110:107];
        event_flags = async_read_data[127:111];
        event_timestamp = async_read_data[191:128];
        event_sequence = next_sequence;
        fault = source_fault || ddr_fault;
    end
endmodule
