// Lossless, simulator-first DDR transport for normalized Nintendo DS geometry
// commands.  This block is intentionally standalone: it is not connected to
// the production memory system or included by the MiSTer Quartus project.
//
// The producer and DDR port are synchronous to clk.  A future integration must
// use the existing DDR arbiter's physical ddram_command_accepted indication;
// ddram_busy alone is only admission/backpressure and cannot retire a beat.
//
// Shared-DDR layout (64-bit word addresses):
//
//   BASE_WORD + CONSUMER_WORD_OFFSET:
//     bits 63:0  greatest contiguous fence fully consumed by HPS
//
//   BASE_WORD + HEADER_WORDS64 + (slot * 4):
//     beat 0 = {24'd0, command[7:0], parameter[31:0]}
//     beat 1 = timestamp[63:0]
//     beat 2 = {epoch[31:0], frame[31:0]}
//     beat 3 = fence[63:0]                    -- atomic commit marker
//
// The input fence must be contiguous, beginning at one after reset.  HPS
// consumes slots in fence order, validates beat 3 against its expected fence,
// and publishes that fence to the consumer control word only after it has
// copied/processed the complete packet.  The producer never overwrites a slot
// until that control word proves enough consumer progress.
//
// Session and HPS memory-ordering contract:
//
// * Before reset is released, software/loader must zero the consumer control
//   word and every slot's beat-3 commit word, then complete the platform's
//   required cache clean/barrier operations.  Otherwise an old fence value
//   left by an earlier FPGA session could look like a newly committed packet.
//   The packet epoch is metadata for higher-level resets; it does not replace
//   this transport initialization.
// * The consumer control word is naturally 64-bit aligned and HPS publishes it
//   with a single-copy atomic 64-bit store.  A software implementation that
//   cannot guarantee that must change the control encoding (for example to a
//   sequence/complement pair); two unrelated 32-bit stores are not this ABI.
// * For expected fence N, HPS performs an acquire load of beat 3, copies beats
//   0..2 only when it reads N, then acquire-loads beat 3 again and accepts the
//   packet only if the second value is still N.  After processing/copying the
//   complete packet, HPS release-stores N to the consumer control word.
// * The mapped DDR region must be uncached or use the appropriate explicit
//   cache maintenance.  These ordering requirements are part of the eventual
//   software consumer ABI and cannot be enforced by this standalone RTL.
// * The shared DDR path must preserve visibility order for physically accepted
//   writes from this client.  Beat 3 is an atomic publication marker only under
//   that ordinary ordered-write guarantee.
module nds_gx_ddr_command_ring #(
    parameter logic [28:0] BASE_WORD = 29'h05810000,
    parameter integer ENTRY_COUNT = 1024,
    parameter integer HEADER_WORDS64 = 8,
    parameter integer CONSUMER_WORD_OFFSET = 0
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        command_valid,
    output logic        command_ready,
    input  logic [31:0] command_frame,
    input  logic [63:0] command_timestamp,
    input  logic [7:0]  command_id,
    input  logic [31:0] command_parameter,
    input  logic [31:0] command_epoch,
    input  logic [63:0] command_fence,

    output logic        active,
    output logic        ddram_active,
    output logic        full,
    output logic        packet_done,
    output logic [63:0] producer_fence,
    output logic [63:0] consumer_fence,
    output logic        protocol_error,

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
    localparam logic [63:0] ENTRY_COUNT_64 = 64'(ENTRY_COUNT);
    localparam logic [28:0] HEADER_OFFSET_WORDS = 29'(HEADER_WORDS64);
    localparam logic [28:0] CONSUMER_OFFSET_WORDS =
        29'(CONSUMER_WORD_OFFSET);
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
        WRITE_COMMIT
    } state_t;
    state_t state;

    logic [31:0] saved_frame;
    logic [63:0] saved_timestamp;
    logic [7:0]  saved_command;
    logic [31:0] saved_parameter;
    logic [31:0] saved_epoch;
    logic [63:0] saved_fence;
    logic [INDEX_BITS-1:0] saved_index;
    logic [28:0] entry_index_words;
    logic [28:0] entry_base;
    logic [63:0] outstanding;
    logic [63:0] expected_fence;
    logic        fence_matches;

    initial begin
        if (ENTRY_COUNT < 2 ||
            (ENTRY_COUNT & (ENTRY_COUNT - 1)) != 0)
            $fatal(1,
                "GX DDR ring ENTRY_COUNT must be a power of two >= 2");
        if (HEADER_WORDS64 < 1)
            $fatal(1, "GX DDR ring requires at least one header word");
        if (CONSUMER_WORD_OFFSET < 0 ||
            CONSUMER_WORD_OFFSET >= HEADER_WORDS64)
            $fatal(1,
                "GX DDR ring consumer word must be inside the header");
        if (RING_END_WORD_64 > 64'd536870912)
            $fatal(1,
                "GX DDR ring exceeds the 29-bit DDR word address space");
    end

    always_comb begin
        outstanding = producer_fence - consumer_fence;
        expected_fence = producer_fence + 1'b1;
        fence_matches =
            producer_fence != 64'hffffffffffffffff &&
            command_fence == expected_fence;
        full = outstanding >= ENTRY_COUNT_64;
        command_ready =
            state == IDLE && !full &&
            (!command_valid || fence_matches);

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
            state == WRITE_COMMIT;
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
                ddram_write_data =
                    {24'd0, saved_command, saved_parameter};
                ddram_write = !ddram_busy;
            end
            WRITE_BEAT1: begin
                ddram_address = entry_base + 29'd1;
                ddram_write_data = saved_timestamp;
                ddram_write = !ddram_busy;
            end
            WRITE_BEAT2: begin
                ddram_address = entry_base + 29'd2;
                ddram_write_data = {saved_epoch, saved_frame};
                ddram_write = !ddram_busy;
            end
            WRITE_COMMIT: begin
                ddram_address = entry_base + 29'd3;
                ddram_write_data = saved_fence;
                ddram_write = !ddram_busy;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            packet_done <= 1'b0;
            producer_fence <= 64'd0;
            consumer_fence <= 64'd0;
            protocol_error <= 1'b0;
            saved_frame <= 32'd0;
            saved_timestamp <= 64'd0;
            saved_command <= 8'd0;
            saved_parameter <= 32'd0;
            saved_epoch <= 32'd0;
            saved_fence <= 64'd0;
            saved_index <= '0;
        end else begin
            packet_done <= 1'b0;

            case (state)
                IDLE: begin
                    if (command_valid) begin
                        if (full) begin
                            // Refresh only when stale progress blocks a real
                            // producer.  A held valid packet remains pending.
                            state <= READ_CONSUMER_ISSUE;
                        end else if (!fence_matches) begin
                            // Fail closed: do not publish an ambiguous slot.
                            // The source may correct its held packet or reset.
                            protocol_error <= 1'b1;
                        end else begin
                            saved_frame <= command_frame;
                            saved_timestamp <= command_timestamp;
                            saved_command <= command_id;
                            saved_parameter <= command_parameter;
                            saved_epoch <= command_epoch;
                            saved_fence <= command_fence;
                            // Fence N occupies zero-based slot N-1.  Since
                            // expected_fence=producer+1, the current producer
                            // low bits are exactly that slot.
                            saved_index <=
                                producer_fence[INDEX_BITS-1:0];
                            state <= WRITE_BEAT0;
                        end
                    end
                end

                READ_CONSUMER_ISSUE: begin
                    // Retire the read request only when the shared arbiter
                    // reports physical command acceptance.  MiSTer's bridge
                    // may return a one-beat read on that same edge.
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            if (ddram_read_data > producer_fence) begin
                                protocol_error <= 1'b1;
                            end else if (
                                ddram_read_data > consumer_fence
                            ) begin
                                consumer_fence <= ddram_read_data;
                            end
                            state <= IDLE;
                        end else begin
                            state <= READ_CONSUMER_WAIT;
                        end
                    end
                end

                READ_CONSUMER_WAIT: begin
                    if (ddram_read_data_ready) begin
                        // Ignore backward/stale values.  A value beyond the
                        // last committed producer fence is corrupt and must
                        // never open capacity for overwrite.
                        if (ddram_read_data > producer_fence) begin
                            protocol_error <= 1'b1;
                        end else if (ddram_read_data > consumer_fence) begin
                            consumer_fence <= ddram_read_data;
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
                    // Fence publication is retired only on the physical
                    // acceptance edge of the final beat.
                    if (ddram_command_accepted) begin
                        producer_fence <= saved_fence;
                        packet_done <= 1'b1;
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
