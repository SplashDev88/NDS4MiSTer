// Lossless DDR producer for Hybrid 3D ABI H3D1 events.
//
// The product receives records through the H3D1 clock-crossing input FIFO and
// connects this producer to its dedicated outer-DDR-fabric client.
//
// Shared-DDR layout uses 64-bit word addresses:
//
//   BASE_WORD + CONSUMER_WORD_OFFSET:
//     low 32 bits are the greatest contiguous event sequence consumed by HPS;
//     high 32 bits are reserved zero
//   BASE_WORD + PRODUCER_WORD_OFFSET:
//     low 32 bits are the greatest contiguous event sequence published by
//     FPGA; high 32 bits are reserved zero
//
//   BASE_WORD + HEADER_WORDS64 + (slot * 4):
//     beat 0 = {data[31:0], address[31:0]}
//     beat 1 = {flags[16:0], byte_enable[3:0], width[1:0], cpu,
//               type[7:0], frame[31:0]}
//     beat 2 = timestamp[63:0]
//     beat 3 = {32'd0, sequence[31:0]}        -- commit fence
//
// Sequence N occupies slot (N - 1) modulo ENTRY_COUNT.  Input sequences must
// be contiguous, start at one after reset, and stop before 0xffffffff.
// The first three beats are accepted physically before the commit beat can be
// presented.  After commit acceptance, the producer header is updated.  The
// event retires only after that header write is physically accepted.  The DDR
// path must preserve accepted write order.
//
// The source holds event_valid and all event fields until event_ready is high.
// A full ring keeps event_ready low and polls the HPS consumer sequence.  No
// event is discarded.  A bad sequence or impossible consumer sequence sets a
// sticky fault.  Fault is fail-closed: no later event is accepted before
// reset.
//
// Software must clear the consumer word and every slot commit word before it
// releases the FPGA session.  HPS acquire-loads the commit beat twice around
// copying beats 0..2, applies the event, then release-stores the consumed
// sequence to the consumer word.  The shared mapping must be uncached or use
// the platform's required cache maintenance.
module nds_h3d_event_ring #(
    // FPGA byte address 0x0fc00000 divided by the 64-bit DDR word size.
    parameter logic [28:0] BASE_WORD = 29'h01f80000,
    parameter integer ENTRY_COUNT = 16384,
    // H3D1 event slots start at byte offset 0x80.
    parameter integer HEADER_WORDS64 = 16,
    // H3D1 consumer sequence is at byte offset 0x18.
    parameter integer CONSUMER_WORD_OFFSET = 3,
    // H3D1 producer sequence is at byte offset 0x10.
    parameter integer PRODUCER_WORD_OFFSET = 2
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        event_valid,
    output logic        event_ready,
    input  logic [31:0] event_address,
    input  logic [31:0] event_data,
    input  logic [31:0] event_frame,
    input  logic [7:0]  event_type,
    input  logic        event_cpu,
    input  logic [1:0]  event_width,
    input  logic [3:0]  event_byte_enable,
    input  logic [16:0] event_flags,
    input  logic [63:0] event_timestamp,
    input  logic [31:0] event_sequence,

    output logic        active,
    output logic        ddram_active,
    output logic        full,
    output logic        event_done,
    output logic [31:0] producer_sequence,
    output logic [31:0] consumer_sequence,
    output logic        fault,

    output logic        ddram_read,
    output logic        ddram_write,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    output logic [63:0] ddram_write_data,
    output logic [7:0]  ddram_byte_enable,
    input  logic        ddram_busy,
    input  logic        ddram_command_accepted,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready
);
    localparam integer INDEX_BITS =
        ENTRY_COUNT <= 2 ? 1 : $clog2(ENTRY_COUNT);
    localparam logic [31:0] ENTRY_COUNT_32 = 32'(ENTRY_COUNT);
    localparam logic [28:0] HEADER_OFFSET_WORDS = 29'(HEADER_WORDS64);
    localparam logic [28:0] CONSUMER_OFFSET_WORDS =
        29'(CONSUMER_WORD_OFFSET);
    localparam logic [28:0] PRODUCER_OFFSET_WORDS =
        29'(PRODUCER_WORD_OFFSET);
    localparam logic [63:0] BASE_WORD_64 = {35'd0, BASE_WORD};
    localparam logic [63:0] RING_END_WORD_64 =
        BASE_WORD_64 + 64'(HEADER_WORDS64) +
        (64'(ENTRY_COUNT) << 2);

    typedef enum logic [3:0] {
        IDLE,
        READ_CONSUMER_ISSUE,
        READ_CONSUMER_WAIT,
        WRITE_BEAT0,
        WRITE_BEAT1,
        WRITE_BEAT2,
        WRITE_COMMIT,
        WRITE_PRODUCER
    } state_t;
    state_t state;

    logic [31:0] saved_address;
    logic [31:0] saved_data;
    logic [31:0] saved_frame;
    logic [7:0]  saved_type;
    logic        saved_cpu;
    logic [1:0]  saved_width;
    logic [3:0]  saved_byte_enable;
    logic [16:0] saved_flags;
    logic [63:0] saved_timestamp;
    logic [31:0] saved_sequence;
    logic [INDEX_BITS-1:0] saved_index;
    logic [28:0] entry_index_words;
    logic [28:0] entry_base;
    logic [31:0] outstanding;
    logic [31:0] expected_sequence;
    logic        sequence_matches;

    initial begin
        if (ENTRY_COUNT < 2 ||
            (ENTRY_COUNT & (ENTRY_COUNT - 1)) != 0)
            $fatal(1,
                "H3D event ring ENTRY_COUNT must be a power of two >= 2");
        if (HEADER_WORDS64 < 1)
            $fatal(1, "H3D event ring requires at least one header word");
        if (CONSUMER_WORD_OFFSET < 0 ||
            CONSUMER_WORD_OFFSET >= HEADER_WORDS64)
            $fatal(1,
                "H3D consumer word must be inside the control header");
        if (PRODUCER_WORD_OFFSET < 0 ||
            PRODUCER_WORD_OFFSET >= HEADER_WORDS64)
            $fatal(1,
                "H3D producer word must be inside the control header");
        if (PRODUCER_WORD_OFFSET == CONSUMER_WORD_OFFSET)
            $fatal(1,
                "H3D producer and consumer words must be separate");
        if (RING_END_WORD_64 > 64'd536870912)
            $fatal(1,
                "H3D event ring exceeds the 29-bit DDR word address space");
    end

    always_comb begin
        outstanding = producer_sequence - consumer_sequence;
        expected_sequence = producer_sequence + 1'b1;
        sequence_matches =
            producer_sequence != 32'hffffffff &&
            event_sequence == expected_sequence;
        full = outstanding >= ENTRY_COUNT_32;
        event_ready =
            state == IDLE && !fault && !full &&
            (!event_valid || sequence_matches);

        entry_index_words = saved_index * 29'd4;
        entry_base =
            BASE_WORD + HEADER_OFFSET_WORDS + entry_index_words;

        active = state != IDLE;
        ddram_active =
            state == READ_CONSUMER_ISSUE ||
            state == READ_CONSUMER_WAIT ||
            state == WRITE_BEAT0 ||
            state == WRITE_BEAT1 ||
            state == WRITE_BEAT2 ||
            state == WRITE_COMMIT ||
            state == WRITE_PRODUCER;
        ddram_read = 1'b0;
        ddram_write = 1'b0;
        ddram_burst_count = 8'd1;
        ddram_address = BASE_WORD + CONSUMER_OFFSET_WORDS;
        ddram_write_data = 64'd0;
        ddram_byte_enable = 8'hff;

        case (state)
            READ_CONSUMER_ISSUE: begin
                ddram_address = BASE_WORD + CONSUMER_OFFSET_WORDS;
                ddram_read = !ddram_busy;
            end
            WRITE_BEAT0: begin
                ddram_address = entry_base;
                ddram_write_data = {saved_data, saved_address};
                ddram_write = !ddram_busy;
            end
            WRITE_BEAT1: begin
                ddram_address = entry_base + 29'd1;
                ddram_write_data = {
                    saved_flags,
                    saved_byte_enable,
                    saved_width,
                    saved_cpu,
                    saved_type,
                    saved_frame
                };
                ddram_write = !ddram_busy;
            end
            WRITE_BEAT2: begin
                ddram_address = entry_base + 29'd2;
                ddram_write_data = saved_timestamp;
                ddram_write = !ddram_busy;
            end
            WRITE_COMMIT: begin
                ddram_address = entry_base + 29'd3;
                ddram_write_data = {32'd0, saved_sequence};
                ddram_write = !ddram_busy;
            end
            WRITE_PRODUCER: begin
                ddram_address = BASE_WORD + PRODUCER_OFFSET_WORDS;
                ddram_write_data = {32'd0, saved_sequence};
                ddram_write = !ddram_busy;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            event_done <= 1'b0;
            producer_sequence <= 32'd0;
            consumer_sequence <= 32'd0;
            fault <= 1'b0;
            saved_address <= 32'd0;
            saved_data <= 32'd0;
            saved_frame <= 32'd0;
            saved_type <= 8'd0;
            saved_cpu <= 1'b0;
            saved_width <= 2'd0;
            saved_byte_enable <= 4'd0;
            saved_flags <= 17'd0;
            saved_timestamp <= 64'd0;
            saved_sequence <= 32'd0;
            saved_index <= '0;
        end else begin
            event_done <= 1'b0;

            case (state)
                IDLE: begin
                    if (!fault && event_valid) begin
                        if (full) begin
                            // A held event stays pending while the producer
                            // refreshes HPS progress.
                            state <= READ_CONSUMER_ISSUE;
                        end else if (!sequence_matches) begin
                            // Do not publish any part of an ambiguous event.
                            fault <= 1'b1;
                        end else begin
                            saved_address <= event_address;
                            saved_data <= event_data;
                            saved_frame <= event_frame;
                            saved_type <= event_type;
                            saved_cpu <= event_cpu;
                            saved_width <= event_width;
                            saved_byte_enable <= event_byte_enable;
                            saved_flags <= event_flags;
                            saved_timestamp <= event_timestamp;
                            saved_sequence <= event_sequence;
                            // Sequence N uses zero-based slot N-1.  The
                            // current producer low bits equal that slot.
                            saved_index <=
                                producer_sequence[INDEX_BITS-1:0];
                            state <= WRITE_BEAT0;
                        end
                    end
                end

                READ_CONSUMER_ISSUE: begin
                    // Advance only on the arbiter's physical acceptance
                    // pulse.  A one-beat read may return on the same edge.
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            if (ddram_read_data[63:32] != 0 ||
                                ddram_read_data[31:0] > producer_sequence) begin
                                fault <= 1'b1;
                            end else if (
                                ddram_read_data[31:0] > consumer_sequence
                            ) begin
                                consumer_sequence <= ddram_read_data[31:0];
                            end
                            state <= IDLE;
                        end else begin
                            state <= READ_CONSUMER_WAIT;
                        end
                    end
                end

                READ_CONSUMER_WAIT: begin
                    if (ddram_read_data_ready) begin
                        // Backward values are stale.  A value beyond the last
                        // commit is corrupt and cannot release a slot.
                        if (ddram_read_data[63:32] != 0 ||
                            ddram_read_data[31:0] > producer_sequence) begin
                            fault <= 1'b1;
                        end else if (
                            ddram_read_data[31:0] > consumer_sequence
                        ) begin
                            consumer_sequence <= ddram_read_data[31:0];
                        end
                        state <= IDLE;
                    end
                end

                WRITE_BEAT0: begin
                    if (ddram_command_accepted)
                        state <= WRITE_BEAT1;
                end

                WRITE_BEAT1: begin
                    if (ddram_command_accepted)
                        state <= WRITE_BEAT2;
                end

                WRITE_BEAT2: begin
                    if (ddram_command_accepted)
                        state <= WRITE_COMMIT;
                end

                WRITE_COMMIT: begin
                    // Commit the slot before publishing the producer upper
                    // bound in the control header.
                    if (ddram_command_accepted) begin
                        state <= WRITE_PRODUCER;
                    end
                end

                WRITE_PRODUCER: begin
                    // Retire only after both the slot commit and producer
                    // header update have been physically accepted.
                    if (ddram_command_accepted) begin
                        producer_sequence <= saved_sequence;
                        event_done <= 1'b1;
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
