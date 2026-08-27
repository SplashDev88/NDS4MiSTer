// FPGA consumer for the simulator-first HPS->FPGA consumed-credit ACK ring.
//
// This block is intentionally default-off and disconnected from production:
// ENABLED defaults to zero, the MiSTer top does not instantiate it, and the
// Quartus project does not list it.  A future integration may set ENABLED=1
// only after assigning a DDR region, an arbiter client, and a session/CDC
// handshake.
//
// Shared DDR layout (64-bit word addresses):
//
//   BASE_WORD + CONSUMER_WORD_OFFSET:
//     {session_epoch[31:0], greatest_consumed_sequence[31:0]}
//
//   BASE_WORD + DESCRIPTOR_WORD_OFFSET:
//     {32'h4341434b ("CACK"), session_epoch[31:0]}
//
//   BASE_WORD + HEADER_WORDS64 + slot*3:
//     beat 0 = {cycles[31:0], source_id[31:0]}
//     beat 1 = {session_epoch[31:0], 29'd0, kind[1:0], cpu_arm9}
//     beat 2 = {32'd0, sequence[31:0]} -- 32-bit commit written last
//
// HPS clears the complete region while both endpoints are quiescent, then
// release-publishes the descriptor.  On session_begin, FPGA validates that
// descriptor epoch is one atomic 32-bit HPS store; its magic payload is
// written first.  FPGA scans every commit word for zero, revalidates the descriptor,
// and finally publishes {epoch, INITIAL_CONSUMER_SEQUENCE}.  Normal sessions
// use the default initial sequence zero.
//
// For each record FPGA acquire-reads commit, copies payload, and re-reads the
// commit before asserting ack_valid.  After the downstream ready/valid
// transfer, FPGA clears the slot commit before advancing the consumer control
// word.  Consequently a lower nonzero sequence is a real duplicate/stale
// protocol violation rather than an uncleared slot left by normal reuse.
module nds_hps_consumed_credit_ddr_ring #(
    parameter bit          ENABLED = 1'b0,
    parameter logic [28:0] BASE_WORD = 29'h05818000,
    parameter integer      ENTRY_COUNT = 1024,
    parameter integer      HEADER_WORDS64 = 8,
    parameter integer      CONSUMER_WORD_OFFSET = 0,
    parameter integer      DESCRIPTOR_WORD_OFFSET = 1,
    parameter integer      POLL_BACKOFF_CYCLES = 64,
    // Regression-only near-wrap seed.  Integration must leave this at zero.
    parameter logic [31:0] INITIAL_CONSUMER_SEQUENCE = 32'd0
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        session_begin_valid,
    output logic        session_begin_ready,
    input  logic [31:0] session_begin_epoch,
    // Supplied by a future persistent session coordinator.  After any FPGA or
    // HPS reset it may assert only for a never-reused replacement epoch.
    input  logic        session_epoch_fresh,
    input  logic        transport_quiescent,
    output logic        session_started,
    output logic        session_active,
    output logic [31:0] active_epoch,
    output logic [31:0] consumer_sequence,

    output logic        ack_valid,
    input  logic        ack_ready,
    output logic [31:0] ack_epoch,
    output logic [31:0] ack_sequence,
    output logic        ack_cpu_arm9,
    output logic [31:0] ack_cycles,
    output logic [1:0]  ack_kind,
    output logic [31:0] ack_source_id,

    output logic        active,
    output logic        ddram_active,
    output logic        sequence_exhausted,
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
    localparam logic [31:0] DESCRIPTOR_MAGIC = 32'h4341434b;
    localparam integer INDEX_BITS =
        ENTRY_COUNT <= 2 ? 1 : $clog2(ENTRY_COUNT);
    localparam integer SCAN_BITS =
        ENTRY_COUNT <= 2 ? 1 : $clog2(ENTRY_COUNT);
    localparam logic [28:0] HEADER_OFFSET_WORDS =
        29'(HEADER_WORDS64);
    localparam logic [28:0] CONSUMER_OFFSET_WORDS =
        29'(CONSUMER_WORD_OFFSET);
    localparam logic [28:0] DESCRIPTOR_OFFSET_WORDS =
        29'(DESCRIPTOR_WORD_OFFSET);
    localparam logic [63:0] BASE_WORD_64 = {35'd0, BASE_WORD};
    localparam logic [63:0] RING_END_WORD_64 =
        BASE_WORD_64 + 64'(HEADER_WORDS64) +
        64'(ENTRY_COUNT * 3);

    typedef enum logic [4:0] {
        IDLE,
        READ_DESCRIPTOR_ISSUE,
        READ_DESCRIPTOR_WAIT,
        SCAN_COMMIT_ISSUE,
        SCAN_COMMIT_WAIT,
        RECHECK_DESCRIPTOR_ISSUE,
        RECHECK_DESCRIPTOR_WAIT,
        WRITE_INITIAL_CONTROL,
        POLL_BACKOFF,
        POLL_COMMIT_ISSUE,
        POLL_COMMIT_WAIT,
        READ_PAYLOAD0_ISSUE,
        READ_PAYLOAD0_WAIT,
        READ_PAYLOAD1_ISSUE,
        READ_PAYLOAD1_WAIT,
        RECHECK_COMMIT_ISSUE,
        RECHECK_COMMIT_WAIT,
        RECHECK_RECORD_DESCRIPTOR_ISSUE,
        RECHECK_RECORD_DESCRIPTOR_WAIT,
        OUTPUT_WAIT,
        CLEAR_COMMIT,
        WRITE_CONSUMER_CONTROL
    } state_t;
    state_t state;

    logic [31:0] requested_epoch;
    logic [31:0] last_epoch;
    logic [31:0] expected_sequence;
    logic [63:0] saved_commit;
    logic [63:0] saved_payload0;
    logic [63:0] saved_payload1;
    logic        buffered_read_valid;
    logic [63:0] buffered_read_data;
    logic [31:0] poll_backoff_count;
    logic [SCAN_BITS-1:0] scan_index;
    logic [INDEX_BITS-1:0] expected_index;
    logic [28:0] scan_entry_base;
    logic [28:0] expected_entry_base;
    logic        read_response_valid;
    logic [63:0] read_response_data;

    initial begin
        if (ENTRY_COUNT < 2 ||
            (ENTRY_COUNT & (ENTRY_COUNT - 1)) != 0)
            $fatal(1,
                "consumed-credit DDR ENTRY_COUNT must be power of two >= 2");
        if (HEADER_WORDS64 < 2)
            $fatal(1,
                "consumed-credit DDR ring requires two header words");
        if (CONSUMER_WORD_OFFSET < 0 ||
            CONSUMER_WORD_OFFSET >= HEADER_WORDS64 ||
            DESCRIPTOR_WORD_OFFSET < 0 ||
            DESCRIPTOR_WORD_OFFSET >= HEADER_WORDS64 ||
            CONSUMER_WORD_OFFSET == DESCRIPTOR_WORD_OFFSET)
            $fatal(1, "consumed-credit DDR header offsets invalid");
        if (INITIAL_CONSUMER_SEQUENCE == 32'hffffffff)
            $fatal(1,
                "initial consumed sequence cannot be terminal value");
        if (RING_END_WORD_64 > 64'd536870912)
            $fatal(1,
                "consumed-credit DDR ring exceeds address space");
    end

    always_comb begin
        expected_index =
            expected_sequence[INDEX_BITS-1:0] - 1'b1;
        scan_entry_base =
            BASE_WORD + HEADER_OFFSET_WORDS +
            (29'(scan_index) * 29'd3);
        expected_entry_base =
            BASE_WORD + HEADER_OFFSET_WORDS +
            (29'(expected_index) * 29'd3);

        session_begin_ready =
            ENABLED && state == IDLE && !session_active &&
            transport_quiescent && session_epoch_fresh &&
            !protocol_error &&
            !sequence_exhausted;
        active = state != IDLE;
        ddram_active =
            state != IDLE && state != OUTPUT_WAIT &&
            state != POLL_BACKOFF;
        ddram_read = 1'b0;
        ddram_write = 1'b0;
        ddram_burst_count = 8'd1;
        ddram_address = BASE_WORD;
        ddram_write_data = 64'd0;
        ddram_byte_enable = 8'hff;
        read_response_valid =
            buffered_read_valid || ddram_read_data_ready;
        read_response_data = buffered_read_valid
            ? buffered_read_data : ddram_read_data;

        case (state)
            READ_DESCRIPTOR_ISSUE,
            RECHECK_DESCRIPTOR_ISSUE,
            RECHECK_RECORD_DESCRIPTOR_ISSUE: begin
                ddram_address =
                    BASE_WORD + DESCRIPTOR_OFFSET_WORDS;
                ddram_read = 1'b1;
            end
            SCAN_COMMIT_ISSUE: begin
                ddram_address = scan_entry_base + 29'd2;
                ddram_read = 1'b1;
            end
            POLL_COMMIT_ISSUE,
            RECHECK_COMMIT_ISSUE: begin
                ddram_address = expected_entry_base + 29'd2;
                ddram_read = 1'b1;
            end
            READ_PAYLOAD0_ISSUE: begin
                ddram_address = expected_entry_base;
                ddram_read = 1'b1;
            end
            READ_PAYLOAD1_ISSUE: begin
                ddram_address = expected_entry_base + 29'd1;
                ddram_read = 1'b1;
            end
            WRITE_INITIAL_CONTROL: begin
                ddram_address =
                    BASE_WORD + CONSUMER_OFFSET_WORDS;
                ddram_write_data =
                    {requested_epoch, INITIAL_CONSUMER_SEQUENCE};
                ddram_write = 1'b1;
            end
            CLEAR_COMMIT: begin
                ddram_address = expected_entry_base + 29'd2;
                ddram_write_data = 64'd0;
                ddram_byte_enable = 8'h0f;
                ddram_write = 1'b1;
            end
            WRITE_CONSUMER_CONTROL: begin
                ddram_address =
                    BASE_WORD + CONSUMER_OFFSET_WORDS;
                ddram_write_data =
                    {active_epoch, expected_sequence};
                ddram_write = 1'b1;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            requested_epoch <= 32'd0;
            last_epoch <= 32'd0;
            expected_sequence <= 32'd1;
            saved_commit <= 64'd0;
            saved_payload0 <= 64'd0;
            saved_payload1 <= 64'd0;
            buffered_read_valid <= 1'b0;
            buffered_read_data <= 64'd0;
            poll_backoff_count <= 32'd0;
            scan_index <= '0;
            session_started <= 1'b0;
            session_active <= 1'b0;
            active_epoch <= 32'd0;
            consumer_sequence <= 32'd0;
            ack_valid <= 1'b0;
            ack_epoch <= 32'd0;
            ack_sequence <= 32'd0;
            ack_cpu_arm9 <= 1'b0;
            ack_cycles <= 32'd0;
            ack_kind <= 2'd0;
            ack_source_id <= 32'd0;
            sequence_exhausted <= 1'b0;
            protocol_error <= 1'b0;
        end else if (!ENABLED) begin
            state <= IDLE;
            session_started <= 1'b0;
            session_active <= 1'b0;
            ack_valid <= 1'b0;
            buffered_read_valid <= 1'b0;
        end else begin
            session_started <= 1'b0;
            // A legal MiSTer DDR bridge may return the first read beat on the
            // same edge as command acceptance.  ISSUE states cannot decode it
            // until the following state, so retain that beat exactly once.
            if (ddram_command_accepted && ddram_read &&
                ddram_read_data_ready) begin
                buffered_read_valid <= 1'b1;
                buffered_read_data <= ddram_read_data;
            end
            case (state)
                IDLE: begin
                    if (session_begin_valid &&
                        session_begin_ready) begin
                        if (session_begin_epoch == 0 ||
                            session_begin_epoch == last_epoch) begin
                            protocol_error <= 1'b1;
                        end else begin
                            requested_epoch <=
                                session_begin_epoch;
                            scan_index <= '0;
                            state <= READ_DESCRIPTOR_ISSUE;
                        end
                    end
                end
                READ_DESCRIPTOR_ISSUE:
                    if (ddram_command_accepted)
                        state <= READ_DESCRIPTOR_WAIT;
                READ_DESCRIPTOR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data[31:0] == 0) begin
                            // The high-half magic is payload; the low 32-bit
                            // epoch is the Cortex-A9 atomic session commit.
                            state <= READ_DESCRIPTOR_ISSUE;
                        end else if (read_response_data ==
                            {DESCRIPTOR_MAGIC, requested_epoch}) begin
                            scan_index <= '0;
                            state <= SCAN_COMMIT_ISSUE;
                        end else begin
                            protocol_error <= 1'b1;
                            state <= IDLE;
                        end
                    end
                SCAN_COMMIT_ISSUE:
                    if (ddram_command_accepted)
                        state <= SCAN_COMMIT_WAIT;
                SCAN_COMMIT_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != 64'd0) begin
                            protocol_error <= 1'b1;
                            state <= IDLE;
                        end else if (scan_index ==
                                     ENTRY_COUNT - 1) begin
                            state <= RECHECK_DESCRIPTOR_ISSUE;
                        end else begin
                            scan_index <= scan_index + 1'b1;
                            state <= SCAN_COMMIT_ISSUE;
                        end
                    end
                RECHECK_DESCRIPTOR_ISSUE:
                    if (ddram_command_accepted)
                        state <= RECHECK_DESCRIPTOR_WAIT;
                RECHECK_DESCRIPTOR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                            {DESCRIPTOR_MAGIC, requested_epoch}) begin
                            protocol_error <= 1'b1;
                            state <= IDLE;
                        end else begin
                            state <= WRITE_INITIAL_CONTROL;
                        end
                    end
                WRITE_INITIAL_CONTROL:
                    if (ddram_command_accepted) begin
                        active_epoch <= requested_epoch;
                        last_epoch <= requested_epoch;
                        consumer_sequence <=
                            INITIAL_CONSUMER_SEQUENCE;
                        expected_sequence <=
                            INITIAL_CONSUMER_SEQUENCE + 1'b1;
                        session_active <= 1'b1;
                        session_started <= 1'b1;
                        state <= POLL_COMMIT_ISSUE;
                    end
                POLL_BACKOFF:
                    if (poll_backoff_count == 0)
                        state <= POLL_COMMIT_ISSUE;
                    else
                        poll_backoff_count <=
                            poll_backoff_count - 1'b1;
                POLL_COMMIT_ISSUE:
                    if (ddram_command_accepted)
                        state <= POLL_COMMIT_WAIT;
                POLL_COMMIT_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data == 64'd0) begin
                            if (POLL_BACKOFF_CYCLES == 0) begin
                                state <= POLL_COMMIT_ISSUE;
                            end else begin
                                poll_backoff_count <=
                                    POLL_BACKOFF_CYCLES - 1;
                                state <= POLL_BACKOFF;
                            end
                        end else if (
                            read_response_data[63:32] != 0 ||
                            read_response_data[31:0] == 0 ||
                            read_response_data[31:0] !=
                                expected_sequence) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= IDLE;
                        end else begin
                            saved_commit <= read_response_data;
                            state <= READ_PAYLOAD0_ISSUE;
                        end
                    end
                READ_PAYLOAD0_ISSUE:
                    if (ddram_command_accepted)
                        state <= READ_PAYLOAD0_WAIT;
                READ_PAYLOAD0_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        saved_payload0 <= read_response_data;
                        state <= READ_PAYLOAD1_ISSUE;
                    end
                READ_PAYLOAD1_ISSUE:
                    if (ddram_command_accepted)
                        state <= READ_PAYLOAD1_WAIT;
                READ_PAYLOAD1_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        saved_payload1 <= read_response_data;
                        state <= RECHECK_COMMIT_ISSUE;
                    end
                RECHECK_COMMIT_ISSUE:
                    if (ddram_command_accepted)
                        state <= RECHECK_COMMIT_WAIT;
                RECHECK_COMMIT_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != saved_commit ||
                            saved_payload1[63:32] != active_epoch ||
                            saved_payload1[31:3] != 0 ||
                            saved_payload1[2:1] == 2'd3) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= IDLE;
                        end else begin
                            state <=
                                RECHECK_RECORD_DESCRIPTOR_ISSUE;
                        end
                    end
                RECHECK_RECORD_DESCRIPTOR_ISSUE:
                    if (ddram_command_accepted)
                        state <=
                            RECHECK_RECORD_DESCRIPTOR_WAIT;
                RECHECK_RECORD_DESCRIPTOR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                            {DESCRIPTOR_MAGIC, active_epoch}) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= IDLE;
                        end else begin
                            ack_epoch <= active_epoch;
                            ack_sequence <= saved_commit[31:0];
                            ack_cpu_arm9 <= saved_payload1[0];
                            ack_kind <= saved_payload1[2:1];
                            ack_cycles <= saved_payload0[63:32];
                            ack_source_id <= saved_payload0[31:0];
                            ack_valid <= 1'b1;
                            state <= OUTPUT_WAIT;
                        end
                    end
                OUTPUT_WAIT:
                    if (ack_valid && ack_ready) begin
                        ack_valid <= 1'b0;
                        state <= CLEAR_COMMIT;
                    end
                CLEAR_COMMIT:
                    if (ddram_command_accepted)
                        state <= WRITE_CONSUMER_CONTROL;
                WRITE_CONSUMER_CONTROL:
                    if (ddram_command_accepted) begin
                        consumer_sequence <= expected_sequence;
                        if (expected_sequence == 32'hffffffff) begin
                            sequence_exhausted <= 1'b1;
                            session_active <= 1'b0;
                            state <= IDLE;
                        end else begin
                            expected_sequence <=
                                expected_sequence + 1'b1;
                            state <= POLL_COMMIT_ISSUE;
                        end
                    end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
