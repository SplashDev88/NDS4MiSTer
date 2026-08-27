module nds_hps_posted_write_ring #(
    parameter logic [28:0] BASE_WORD = 29'h05806000,
    parameter integer ENTRY_COUNT = 1024,
    parameter integer HEADER_WORDS64 = 8,
    // The legacy DDR-only transport has no session epoch and leaves the
    // commit upper word at zero.  NDS2 lightweight builds require a live
    // two-phase session and tag every atomic commit with its cookie so stale
    // DDR entries cannot be mistaken for work from the current core load.
    parameter bit REQUIRE_EPOCH_SESSION = 0,
    // Default-off ABI seam for future serialized IRQ-register commands. The
    // legacy posted-write format must keep control bit zero clear even when
    // the otherwise-unused input is unknown or left unconnected.
    parameter bit IRQ_FORWARD_ENABLE = 0,
    // Default-off auxiliary payload in the 28 control-word bits which legacy
    // entries keep zero. The first ETW IF candidate carries the predicted
    // final low 28 IF bits here so HPS can validate the FPGA-local result.
    parameter bit AUXILIARY_PAYLOAD_ENABLE = 0
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        request,
    input  logic        read_not_write,
    input  logic        cpu_is_arm9,
    input  logic [31:0] elapsed_cycles,
    input  logic [31:0] address,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    input  logic [27:0] auxiliary_payload,
    input  logic [31:0] session_epoch,
    input  logic [31:0] session_capabilities,
    input  logic        consumer_ack,
    input  logic [31:0] consumer_ack_epoch,
    input  logic [31:0] consumer_ack_sequence,
    output logic        accepted,
    // Sequence owned by this admission pulse. It is intentionally zero in
    // every cycle where accepted is low; physical commit still occurs later.
    output logic [31:0] accepted_sequence,
    output logic        active,
    output logic        ddram_active,
    output logic        done,
    output logic [31:0] producer_sequence,
    // Sticky current-ABI exhaustion diagnostic. Sequence zero is the
    // uncommitted marker, so this ring must stop permanently after publishing
    // 0xffffffff rather than aliasing the next entry to zero. A future
    // session-generation ABI is required before wrap can be supported.
    output logic        sequence_exhausted,
    // Sticky fault for an acknowledgement beyond produced work. Regressing
    // physical header reads may be stale because an LW ACK can overtake an
    // already-issued DDR read; those are ignored without losing newer credit.
    output logic        consumer_protocol_error,

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
    localparam integer INDEX_BITS = $clog2(ENTRY_COUNT);
    localparam logic [28:0] HEADER_OFFSET_WORDS = HEADER_WORDS64;
    typedef enum logic [3:0] {
        IDLE,
        CHECK_SPACE,
        READ_CONSUMER_ISSUE,
        READ_CONSUMER_WAIT,
        WRITE_ADDRESS_DATA,
        WRITE_CYCLES_CONTROL,
        WRITE_SEQUENCE,
        WAIT_RELEASE
    } state_t;
    state_t state;

    logic [31:0] saved_address, saved_write_data, saved_cycles;
    logic [31:0] saved_epoch, saved_capabilities;
    logic [3:0] saved_control;
    logic [27:0] saved_auxiliary_payload;
    logic [31:0] pending_sequence;
    logic [31:0] consumer_sequence;
    logic [INDEX_BITS-1:0] pending_index;
    logic [28:0] entry_base;
    logic [28:0] entry_index_words;
    logic consumer_ack_valid;

    wire session_contract_valid = !REQUIRE_EPOCH_SESSION ||
        (session_epoch != 0 && session_capabilities[0] &&
         session_capabilities[2] && session_capabilities[3]);
    wire saved_session_still_valid = !REQUIRE_EPOCH_SESSION ||
        (session_contract_valid && session_epoch == saved_epoch &&
         session_capabilities == saved_capabilities);

    assign consumer_ack_valid = consumer_ack &&
        (!REQUIRE_EPOCH_SESSION ||
         consumer_ack_epoch == session_epoch) &&
        consumer_ack_sequence >= consumer_sequence &&
        consumer_ack_sequence <= producer_sequence;

    initial begin
        if (ENTRY_COUNT < 2 || (ENTRY_COUNT & (ENTRY_COUNT - 1)) != 0)
            $fatal(1, "posted-write ENTRY_COUNT must be a power of two");
    end

    assign active = state != IDLE;
    assign ddram_active =
        state == READ_CONSUMER_ISSUE ||
        state == READ_CONSUMER_WAIT ||
        state == WRITE_ADDRESS_DATA ||
        state == WRITE_CYCLES_CONTROL ||
        state == WRITE_SEQUENCE;
    assign ddram_burst_count = 8'd1;
    assign ddram_byte_enable = 8'hff;
    always_comb begin
        entry_index_words = pending_index * 29'd3;
        entry_base = BASE_WORD + HEADER_OFFSET_WORDS + entry_index_words;
        ddram_read = 1'b0;
        ddram_write = 1'b0;
        ddram_address = BASE_WORD;
        ddram_write_data = 64'h0;
        case (state)
            READ_CONSUMER_ISSUE: begin
                // Header word2 (low half of BASE_WORD+1) is the latest HPS
                // consumer sequence.
                ddram_address = BASE_WORD + 29'd1;
                ddram_read = !ddram_busy;
            end
            WRITE_ADDRESS_DATA: begin
                ddram_address = entry_base;
                ddram_write_data = {saved_write_data, saved_address};
                ddram_write = !ddram_busy;
            end
            WRITE_CYCLES_CONTROL: begin
                ddram_address = entry_base + 29'd1;
                ddram_write_data = {
                    saved_auxiliary_payload, saved_control, saved_cycles};
                ddram_write = !ddram_busy;
            end
            WRITE_SEQUENCE: begin
                // The full sequence is written last and is the atomic commit
                // marker observed by HPS. NDS2 carries the active session
                // epoch in the upper word; legacy DDR sessions supply zero.
                ddram_address = entry_base + 29'd2;
                ddram_write_data = {
                    REQUIRE_EPOCH_SESSION ? saved_epoch : 32'h0,
                    pending_sequence};
                ddram_write = !ddram_busy && saved_session_still_valid;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            accepted <= 1'b0;
            accepted_sequence <= 32'h0;
            done <= 1'b0;
            producer_sequence <= 32'h0;
            sequence_exhausted <= 1'b0;
            consumer_protocol_error <= 1'b0;
            consumer_sequence <= 32'h0;
            pending_sequence <= 32'h0;
            pending_index <= '0;
            saved_epoch <= 32'h0;
            saved_capabilities <= 32'h0;
            saved_auxiliary_payload <= 28'd0;
        end else begin
            accepted <= 1'b0;
            accepted_sequence <= 32'h0;
            done <= 1'b0;
            if (state != IDLE && !saved_session_still_valid) begin
                // An epoch/capability change without transport reset makes
                // ownership unknowable. Any earlier payload beats remain
                // harmless because the commit marker is never published.
                consumer_protocol_error <= 1'b1;
                state <= IDLE;
            end else case (state)
                IDLE: if (request) begin
                    if (consumer_protocol_error) begin
                        // A corrupt credit source makes slot ownership
                        // unknowable. Stall this request without touching DDR
                        // until the whole transport session is reset.
                    end else if (producer_sequence == 32'hffffffff) begin
                        // Fail closed before accepting, resetting the CPU's
                        // cycle bucket, issuing DDR, or publishing commit zero.
                        sequence_exhausted <= 1'b1;
                    end else if (!session_contract_valid) begin
                        // A NDS2 ring must never publish outside an armed,
                        // capability-compatible session.
                        consumer_protocol_error <= 1'b1;
                    end else begin
                        saved_address <= address;
                        saved_write_data <= write_data;
                        saved_cycles <= elapsed_cycles;
                        saved_control <=
                            {cpu_is_arm9, access,
                             IRQ_FORWARD_ENABLE ? read_not_write : 1'b0};
                        saved_auxiliary_payload <=
                            AUXILIARY_PAYLOAD_ENABLE
                                ? auxiliary_payload : 28'd0;
                        saved_epoch <= session_epoch;
                        saved_capabilities <= session_capabilities;
                        pending_sequence <= producer_sequence + 1'b1;
                        pending_index <= producer_sequence[INDEX_BITS-1:0];
                        state <= CHECK_SPACE;
                    end
                end
                CHECK_SPACE: begin
                    if (consumer_protocol_error) begin
                        state <= IDLE;
                    end else if (producer_sequence - consumer_sequence <
                        ENTRY_COUNT - 1) begin
                        accepted <= 1'b1;
                        accepted_sequence <= pending_sequence;
                        state <= WRITE_ADDRESS_DATA;
                    end else begin
                        state <= READ_CONSUMER_ISSUE;
                    end
                end
                READ_CONSUMER_ISSUE: if (!ddram_busy)
                    state <= READ_CONSUMER_WAIT;
                READ_CONSUMER_WAIT: if (ddram_read_data_ready) begin
                    // A validated bridge ACK has priority over an older DDR
                    // header response on the same edge. A response that lands
                    // just after such an ACK may legitimately be stale, so it
                    // is ignored. Future credit is never trusted.
                    if (!consumer_ack_valid) begin
                        if (ddram_read_data[31:0] > producer_sequence)
                            consumer_protocol_error <= 1'b1;
                        else if (ddram_read_data[31:0] >= consumer_sequence)
                            consumer_sequence <= ddram_read_data[31:0];
                    end
                    state <= CHECK_SPACE;
                end
                WRITE_ADDRESS_DATA: if (ddram_command_accepted)
                    state <= WRITE_CYCLES_CONTROL;
                WRITE_CYCLES_CONTROL: if (ddram_command_accepted)
                    state <= WRITE_SEQUENCE;
                WRITE_SEQUENCE: if (ddram_command_accepted) begin
                    producer_sequence <= pending_sequence;
                    if (pending_sequence == 32'hffffffff)
                        sequence_exhausted <= 1'b1;
                    done <= 1'b1;
                    state <= WAIT_RELEASE;
                end
                WAIT_RELEASE: if (!request)
                    state <= IDLE;
                default: state <= IDLE;
            endcase

            // A completed mailbox fence or a validated LW sequence ACK proves
            // HPS consumed every entry through this sequence. This assignment
            // deliberately follows the state machine so it wins over a stale
            // in-flight DDR header response on the same edge.
            if (consumer_ack) begin
                if (consumer_ack_valid)
                    consumer_sequence <= consumer_ack_sequence;
                else
                    consumer_protocol_error <= 1'b1;
            end
        end
    end
endmodule
