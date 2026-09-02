// Four-slot commit-last DDR writer for the Hybrid 3D H3B1 frame-packet ABI.
//
// Control words are retained at the existing H3D control base:
//   word +1: {reserved=0, active_session}
//   word +2: {reserved=0, last committed packet sequence} (FPGA-owned)
//   word +3: {reserved=0, last applied packet sequence}   (HPS-owned)
//
// Four 64-KiB slots begin at SLOT_BASE_WORD. Each packet contains a 64-byte
// header followed by opaque 16-byte records. Payload is written first, header
// beats 0..6 second, the slot commit beat last, and the producer control word
// only after the slot commit is physically accepted. A packet therefore costs
// one shared publication/acknowledgement instead of one per source event.
//
module nds_h3d_frame_packet_writer #(
    // HPS physical 0x3fc00000 appears as FPGA byte 0x0fc00000.
    parameter logic [28:0] CONTROL_BASE_WORD = 29'h01f80000,
    // HPS physical 0x3fc10000 appears as FPGA byte 0x0fc10000.
    parameter logic [28:0] SLOT_BASE_WORD = 29'h01f82000,
    parameter integer SLOT_COUNT = 4,
    parameter integer SLOT_STRIDE_WORDS = 8192,
    parameter integer MAX_RECORDS = 3840
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         session_flush,
    input  logic [31:0]  session,

    input  logic         record_valid,
    output logic         record_ready,
    input  logic [127:0] record,
    input  logic [31:0]  record_frame,
    input  logic         record_frame_end,
    // Ordered VBlank token from the source CDC. A boundary closes the
    // current frame even when it contains no records or SWAP_BUFFERS.
    input  logic         boundary_valid,
    output logic         boundary_ready,
    input  logic [31:0]  boundary_frame,

    output logic         active,
    output logic         full,
    output logic         packet_done,
    output logic [31:0]  producer_sequence,
    output logic [31:0]  acknowledged_sequence,
    output logic         fault,
    // Sticky first-fault discriminator.  This is surfaced in the console
    // fault word so hardware failures identify the exact rejected invariant.
    output logic [4:0]   fault_reason,

    output logic         ddram_read,
    output logic         ddram_write,
    output logic [7:0]   ddram_burst_count,
    output logic [28:0]  ddram_address,
    output logic [63:0]  ddram_write_data,
    output logic [7:0]   ddram_byte_enable,
    input  logic         ddram_busy,
    input  logic         ddram_command_accepted,
    input  logic [63:0]  ddram_read_data,
    input  logic         ddram_read_data_ready
);
    localparam logic [28:0] SESSION_WORD = CONTROL_BASE_WORD + 29'd1;
    localparam logic [28:0] PRODUCER_WORD = CONTROL_BASE_WORD + 29'd2;
    localparam logic [28:0] ACK_WORD = CONTROL_BASE_WORD + 29'd3;
    localparam integer COUNT_WIDTH =
        MAX_RECORDS <= 1 ? 1 : $clog2(MAX_RECORDS + 1);
    localparam logic [COUNT_WIDTH-1:0] MAX_RECORDS_COUNT =
        COUNT_WIDTH'(MAX_RECORDS);
    localparam logic [31:0] SLOT_COUNT_32 = 32'(SLOT_COUNT);
    localparam logic [31:0] FLAG_CONT = 32'h00000001;
    localparam logic [31:0] FLAG_FRAME_END = 32'h00000002;

    typedef enum logic [4:0] {
        WAIT_SESSION,
        READ_SESSION_ISSUE,
        READ_SESSION_WAIT,
        READ_PRODUCER_ISSUE,
        READ_PRODUCER_WAIT,
        READ_ACK_INIT_ISSUE,
        READ_ACK_INIT_WAIT,
        COLLECT,
        READ_ACK_ISSUE,
        READ_ACK_WAIT,
        WRITE_PAYLOAD_LOW,
        WRITE_PAYLOAD_HIGH,
        WRITE_HEADER0,
        WRITE_HEADER1,
        WRITE_HEADER2,
        WRITE_HEADER3,
        WRITE_HEADER4,
        WRITE_HEADER5,
        WRITE_HEADER6,
        WRITE_COMMIT,
        WRITE_PRODUCER
    } state_t;

    state_t state;
    logic [31:0] latched_session;
    logic [127:0] saved_record;
    logic saved_frame_end;
    logic [31:0] packet_frame;
    logic [31:0] packet_sequence;
    logic [31:0] close_flags;
    logic [COUNT_WIDTH-1:0] record_count;
    logic chain_active;
    logic [31:0] chain_frame;

    logic [1:0] slot_index;
    logic [28:0] slot_base;
    logic [28:0] payload_word_offset;
    logic [31:0] outstanding;
    logic session_changed;
    logic refreshed_ack_fault;

    initial begin
        if (SLOT_COUNT != 4)
            $fatal(1, "H3B1 writer requires exactly four slots");
        if (SLOT_STRIDE_WORDS != 8192)
            $fatal(1, "H3B1 writer requires 64-KiB slot stride");
        if (MAX_RECORDS < 1 || MAX_RECORDS > 3840)
            $fatal(1, "H3B1 writer MAX_RECORDS must be 1..3840");
    end

    always_comb begin
        outstanding = producer_sequence - acknowledged_sequence;
        full = outstanding >= SLOT_COUNT_32;
        session_changed =
            latched_session != 0 && session != latched_session;
        refreshed_ack_fault = ddram_read_data[63:32] != 0 ||
            ddram_read_data[31:0] > producer_sequence ||
            ddram_read_data[31:0] < acknowledged_sequence ||
            producer_sequence - ddram_read_data[31:0] > SLOT_COUNT_32;

        slot_index = (packet_sequence - 1'b1) & 2'b11;
        slot_base = SLOT_BASE_WORD +
            (29'(slot_index) * 29'(SLOT_STRIDE_WORDS));
        payload_word_offset = 29'd8 + (29'(record_count) << 1);

        record_ready =
            state == COLLECT && !fault && !full &&
            latched_session != 0 && !session_changed &&
            producer_sequence != 32'hffffffff && !boundary_valid;
        boundary_ready =
            state == COLLECT && !fault && !full &&
            latched_session != 0 && !session_changed &&
            producer_sequence != 32'hffffffff && !record_valid;
        active = state != WAIT_SESSION && state != COLLECT;

        ddram_read = 1'b0;
        ddram_write = 1'b0;
        ddram_burst_count = 8'd1;
        ddram_address = CONTROL_BASE_WORD;
        ddram_write_data = 64'd0;
        ddram_byte_enable = 8'hff;

        case (state)
            READ_SESSION_ISSUE: begin
                ddram_address = SESSION_WORD;
                ddram_read = !ddram_busy;
            end
            READ_PRODUCER_ISSUE: begin
                ddram_address = PRODUCER_WORD;
                ddram_read = !ddram_busy;
            end
            READ_ACK_INIT_ISSUE,
            READ_ACK_ISSUE: begin
                ddram_address = ACK_WORD;
                ddram_read = !ddram_busy;
            end
            WRITE_PAYLOAD_LOW: begin
                ddram_address = slot_base + payload_word_offset;
                ddram_write_data = saved_record[63:0];
                ddram_write = !ddram_busy;
            end
            WRITE_PAYLOAD_HIGH: begin
                ddram_address = slot_base + payload_word_offset + 29'd1;
                ddram_write_data = saved_record[127:64];
                ddram_write = !ddram_busy;
            end
            WRITE_HEADER0: begin
                ddram_address = slot_base;
                ddram_write_data = {32'h00400001, 32'h31423348};
                ddram_write = !ddram_busy;
            end
            WRITE_HEADER1: begin
                ddram_address = slot_base + 29'd1;
                ddram_write_data = {32'd0, latched_session};
                ddram_write = !ddram_busy;
            end
            WRITE_HEADER2: begin
                ddram_address = slot_base + 29'd2;
                ddram_write_data = {32'd0, packet_sequence};
                ddram_write = !ddram_busy;
            end
            WRITE_HEADER3: begin
                ddram_address = slot_base + 29'd3;
                ddram_write_data = {close_flags, packet_frame};
                ddram_write = !ddram_busy;
            end
            WRITE_HEADER4: begin
                ddram_address = slot_base + 29'd4;
                ddram_write_data = {
                    32'(record_count),
                    (32'(record_count) << 4)
                };
                ddram_write = !ddram_busy;
            end
            WRITE_HEADER5: begin
                ddram_address = slot_base + 29'd5;
                ddram_write_data = {32'd0, 30'd0, slot_index};
                ddram_write = !ddram_busy;
            end
            WRITE_HEADER6: begin
                ddram_address = slot_base + 29'd6;
                ddram_write_data = 64'd0;
                ddram_write = !ddram_busy;
            end
            WRITE_COMMIT: begin
                ddram_address = slot_base + 29'd7;
                ddram_write_data = {32'd0, packet_sequence};
                ddram_write = !ddram_busy;
            end
            WRITE_PRODUCER: begin
                ddram_address = PRODUCER_WORD;
                ddram_write_data = {32'd0, packet_sequence};
                ddram_write = !ddram_busy;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset || session_flush) begin
            state <= WAIT_SESSION;
            latched_session <= 0;
            saved_record <= 0;
            saved_frame_end <= 0;
            packet_frame <= 0;
            packet_sequence <= 0;
            close_flags <= 0;
            record_count <= 0;
            chain_active <= 0;
            chain_frame <= 0;
            producer_sequence <= 0;
            acknowledged_sequence <= 0;
            packet_done <= 0;
            fault <= 0;
            fault_reason <= 0;
        end else begin
            packet_done <= 0;

            if (session_changed && !fault) begin
                fault <= 1'b1;
                fault_reason <= 5'd1;
            end

            case (state)
                WAIT_SESSION: begin
                    if (!fault && session != 0)
                        state <= READ_SESSION_ISSUE;
                end

                READ_SESSION_ISSUE: begin
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            if (ddram_read_data[63:32] != 0 ||
                                ddram_read_data[31:0] == 0 ||
                                ddram_read_data[31:0] != session) begin
                                fault <= 1'b1;
                                if (ddram_read_data[63:32] != 0)
                                    fault_reason <= 5'd2;
                                else if (ddram_read_data[31:0] == 0)
                                    fault_reason <= 5'd3;
                                else
                                    fault_reason <= 5'd4;
                                state <= WAIT_SESSION;
                            end else begin
                                latched_session <= ddram_read_data[31:0];
                                state <= READ_PRODUCER_ISSUE;
                            end
                        end else begin
                            state <= READ_SESSION_WAIT;
                        end
                    end
                end

                READ_SESSION_WAIT: begin
                    if (ddram_read_data_ready) begin
                        if (ddram_read_data[63:32] != 0 ||
                            ddram_read_data[31:0] == 0 ||
                            ddram_read_data[31:0] != session) begin
                            fault <= 1'b1;
                            if (ddram_read_data[63:32] != 0)
                                fault_reason <= 5'd2;
                            else if (ddram_read_data[31:0] == 0)
                                fault_reason <= 5'd3;
                            else
                                fault_reason <= 5'd4;
                            state <= WAIT_SESSION;
                        end else begin
                            latched_session <= ddram_read_data[31:0];
                            state <= READ_PRODUCER_ISSUE;
                        end
                    end
                end

                READ_PRODUCER_ISSUE: begin
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            if (ddram_read_data[63:32] != 0) begin
                                fault <= 1'b1;
                                fault_reason <= 5'd5;
                                state <= WAIT_SESSION;
                            end else begin
                                producer_sequence <= ddram_read_data[31:0];
                                state <= READ_ACK_INIT_ISSUE;
                            end
                        end else begin
                            state <= READ_PRODUCER_WAIT;
                        end
                    end
                end

                READ_PRODUCER_WAIT: begin
                    if (ddram_read_data_ready) begin
                        if (ddram_read_data[63:32] != 0) begin
                            fault <= 1'b1;
                            fault_reason <= 5'd5;
                            state <= WAIT_SESSION;
                        end else begin
                            producer_sequence <= ddram_read_data[31:0];
                            state <= READ_ACK_INIT_ISSUE;
                        end
                    end
                end

                READ_ACK_INIT_ISSUE: begin
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            if (ddram_read_data[63:32] != 0 ||
                                ddram_read_data[31:0] > producer_sequence ||
                                producer_sequence - ddram_read_data[31:0] >
                                    SLOT_COUNT_32) begin
                                fault <= 1'b1;
                                if (ddram_read_data[63:32] != 0)
                                    fault_reason <= 5'd6;
                                else if (ddram_read_data[31:0] >
                                         producer_sequence)
                                    fault_reason <= 5'd7;
                                else
                                    fault_reason <= 5'd8;
                                state <= WAIT_SESSION;
                            end else begin
                                acknowledged_sequence <=
                                    ddram_read_data[31:0];
                                state <= COLLECT;
                            end
                        end else begin
                            state <= READ_ACK_INIT_WAIT;
                        end
                    end
                end

                READ_ACK_INIT_WAIT: begin
                    if (ddram_read_data_ready) begin
                        if (ddram_read_data[63:32] != 0 ||
                            ddram_read_data[31:0] > producer_sequence ||
                            producer_sequence - ddram_read_data[31:0] >
                                SLOT_COUNT_32) begin
                            fault <= 1'b1;
                            if (ddram_read_data[63:32] != 0)
                                fault_reason <= 5'd6;
                            else if (ddram_read_data[31:0] >
                                     producer_sequence)
                                fault_reason <= 5'd7;
                            else
                                fault_reason <= 5'd8;
                            state <= WAIT_SESSION;
                        end else begin
                            acknowledged_sequence <= ddram_read_data[31:0];
                            state <= COLLECT;
                        end
                    end
                end

                COLLECT: begin
                    if (record_valid && boundary_valid) begin
                        fault <= 1'b1;
                        fault_reason <= 5'd9;
                    end else if (!fault && full) begin
                        state <= READ_ACK_ISSUE;
                    end else if (!fault && producer_sequence == 32'hffffffff) begin
                        fault <= 1'b1;
                        fault_reason <= 5'd10;
                    end else if (boundary_valid && boundary_ready) begin
                        if ((record_count == 0 && chain_active &&
                             boundary_frame != chain_frame) ||
                            (record_count != 0 &&
                             boundary_frame != packet_frame)) begin
                            fault <= 1'b1;
                            if (record_count == 0)
                                fault_reason <= 5'd11;
                            else
                                fault_reason <= 5'd12;
                        end else begin
                            if (record_count == 0) begin
                                packet_frame <= boundary_frame;
                                packet_sequence <=
                                    producer_sequence + 1'b1;
                            end
                            close_flags <= FLAG_FRAME_END;
                            state <= WRITE_HEADER0;
                        end
                    end else if (record_valid && record_ready) begin
                        if ((record_count == 0 && chain_active &&
                             record_frame != chain_frame) ||
                            (record_count != 0 &&
                             record_frame != packet_frame)) begin
                            fault <= 1'b1;
                            if (record_count == 0)
                                fault_reason <= 5'd13;
                            else
                                fault_reason <= 5'd14;
                        end else begin
                            saved_record <= record;
                            saved_frame_end <= record_frame_end;
                            if (record_count == 0) begin
                                packet_frame <= record_frame;
                                packet_sequence <= producer_sequence + 1'b1;
                            end
                            state <= WRITE_PAYLOAD_LOW;
                        end
                    end
                end

                READ_ACK_ISSUE: begin
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            if (refreshed_ack_fault) begin
                                fault <= 1'b1;
                                if (ddram_read_data[63:32] != 0)
                                    fault_reason <= 5'd15;
                                else if (ddram_read_data[31:0] >
                                         producer_sequence)
                                    fault_reason <= 5'd16;
                                else if (ddram_read_data[31:0] <
                                         acknowledged_sequence)
                                    fault_reason <= 5'd17;
                                else
                                    fault_reason <= 5'd18;
                                state <= WAIT_SESSION;
                            end else begin
                                acknowledged_sequence <=
                                    ddram_read_data[31:0];
                                state <= COLLECT;
                            end
                        end else begin
                            state <= READ_ACK_WAIT;
                        end
                    end
                end

                READ_ACK_WAIT: begin
                    if (ddram_read_data_ready) begin
                        if (refreshed_ack_fault) begin
                            fault <= 1'b1;
                            if (ddram_read_data[63:32] != 0)
                                fault_reason <= 5'd15;
                            else if (ddram_read_data[31:0] >
                                     producer_sequence)
                                fault_reason <= 5'd16;
                            else if (ddram_read_data[31:0] <
                                     acknowledged_sequence)
                                fault_reason <= 5'd17;
                            else
                                fault_reason <= 5'd18;
                            state <= WAIT_SESSION;
                        end else begin
                            acknowledged_sequence <= ddram_read_data[31:0];
                            state <= COLLECT;
                        end
                    end
                end

                WRITE_PAYLOAD_LOW: begin
                    if (ddram_command_accepted)
                        state <= WRITE_PAYLOAD_HIGH;
                end

                WRITE_PAYLOAD_HIGH: begin
                    if (ddram_command_accepted) begin
                        record_count <= record_count + 1'b1;
                        if (saved_frame_end) begin
                            close_flags <= FLAG_FRAME_END;
                            state <= WRITE_HEADER0;
                        end else if (
                            record_count + 1'b1 == MAX_RECORDS_COUNT
                        ) begin
                            close_flags <= FLAG_CONT;
                            state <= WRITE_HEADER0;
                        end else begin
                            state <= COLLECT;
                        end
                    end
                end

                WRITE_HEADER0: if (ddram_command_accepted)
                    state <= WRITE_HEADER1;
                WRITE_HEADER1: if (ddram_command_accepted)
                    state <= WRITE_HEADER2;
                WRITE_HEADER2: if (ddram_command_accepted)
                    state <= WRITE_HEADER3;
                WRITE_HEADER3: if (ddram_command_accepted)
                    state <= WRITE_HEADER4;
                WRITE_HEADER4: if (ddram_command_accepted)
                    state <= WRITE_HEADER5;
                WRITE_HEADER5: if (ddram_command_accepted)
                    state <= WRITE_HEADER6;
                WRITE_HEADER6: if (ddram_command_accepted)
                    state <= WRITE_COMMIT;
                WRITE_COMMIT: if (ddram_command_accepted)
                    state <= WRITE_PRODUCER;

                WRITE_PRODUCER: begin
                    if (ddram_command_accepted) begin
                        producer_sequence <= packet_sequence;
                        packet_done <= 1'b1;
                        record_count <= 0;
                        if (close_flags == FLAG_CONT) begin
                            chain_active <= 1'b1;
                            chain_frame <= packet_frame;
                        end else begin
                            chain_active <= 1'b0;
                            chain_frame <= 0;
                        end
                        state <= COLLECT;
                    end
                end

                default: state <= WAIT_SESSION;
            endcase
        end
    end
endmodule
