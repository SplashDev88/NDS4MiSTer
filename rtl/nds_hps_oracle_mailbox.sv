module nds_hps_oracle_mailbox #(
    parameter logic [28:0] BASE_WORD = 29'h05800000,
    parameter integer POLL_DELAY_CYCLES = 64
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        request,
    input  logic        cpu_is_arm9,
    input  logic [31:0] elapsed_cycles,
    input  logic [31:0] fence_sequence,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,
    output logic        irq_arm9,
    output logic        irq_arm7,
    output logic        halt_arm9,
    output logic        halt_arm7,
    output logic        done,
    output logic [31:0] completed_fence_sequence,
    output logic [3:0]  debug_state,

    output logic        ddram_read,
    output logic        ddram_write,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    output logic [63:0] ddram_write_data,
    output logic [7:0]  ddram_byte_enable,
    input  logic        ddram_busy,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready
);
    localparam logic [31:0] MAGIC = 32'h4f53444e; // "NDSO" in little-endian memory.
    typedef enum logic [3:0] {
        IDLE, WRITE_TRANSACTION, WRITE_CONTROL, WRITE_FENCE, WRITE_HEADER,
        POLL_DELAY, POLL_ISSUE, POLL_RESPONSE, POLL_IRQ,
        POLL_STALE_DRAIN, WAIT_RELEASE
    } state_t;
    state_t state;
    logic [31:0] sequence_counter, request_sequence;
    logic [31:0] saved_address, saved_write_data;
    logic saved_rnw, saved_cpu;
    logic [1:0] saved_access;
    logic [31:0] saved_cycles, saved_fence;
    integer poll_count;

    // Passive state export for bounded hardware diagnostics. This signal is
    // not consumed by the mailbox or any functional control path.
    assign debug_state = state;

    assign ddram_burst_count =
        (state == POLL_ISSUE || state == POLL_RESPONSE ||
         state == POLL_IRQ || state == POLL_STALE_DRAIN) ? 8'd2 : 8'd1;
    assign ddram_byte_enable = 8'hff;

    always_comb begin
        ddram_read = 1'b0;
        ddram_write = 1'b0;
        ddram_address = BASE_WORD;
        ddram_write_data = 64'h0;
        case (state)
            WRITE_TRANSACTION: begin
                ddram_address = BASE_WORD + 29'd1;
                ddram_write_data = {saved_write_data, saved_address};
                ddram_write = !ddram_busy;
            end
            WRITE_CONTROL: begin
                ddram_address = BASE_WORD + 29'd2;
                ddram_write_data = {
                    saved_cycles, 28'h0, saved_cpu, saved_access, saved_rnw};
                ddram_write = !ddram_busy;
            end
            WRITE_FENCE: begin
                // Word 9 records the latest posted-write sequence that must
                // be consumed before HPS may process this request. Clear
                // response-status word 8 at the same time; the request header
                // remains the atomic publication point.
                ddram_address = BASE_WORD + 29'd4;
                ddram_write_data = {saved_fence, 32'h0};
                ddram_write = !ddram_busy;
            end
            WRITE_HEADER: begin
                ddram_address = BASE_WORD;
                ddram_write_data = {request_sequence, MAGIC};
                ddram_write = !ddram_busy;
            end
            POLL_ISSUE: begin
                ddram_address = BASE_WORD + 29'd3;
                ddram_read = !ddram_busy;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            sequence_counter <= 32'h0;
            request_sequence <= 32'h0;
            done <= 1'b0;
            read_data <= 32'h0;
            irq_arm9 <= 1'b0;
            irq_arm7 <= 1'b0;
            halt_arm9 <= 1'b0;
            halt_arm7 <= 1'b0;
            completed_fence_sequence <= 32'h0;
            poll_count <= 0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (request) begin
                    sequence_counter <= sequence_counter + 1'b1;
                    request_sequence <= sequence_counter + 1'b1;
                    saved_address <= address;
                    saved_write_data <= write_data;
                    saved_rnw <= read_not_write;
                    saved_access <= access;
                    saved_cpu <= cpu_is_arm9;
                    saved_cycles <= elapsed_cycles;
                    saved_fence <= fence_sequence;
                    state <= WRITE_TRANSACTION;
                end
                WRITE_TRANSACTION: if (!ddram_busy) state <= WRITE_CONTROL;
                WRITE_CONTROL: if (!ddram_busy) state <= WRITE_FENCE;
                WRITE_FENCE: if (!ddram_busy) state <= WRITE_HEADER;
                WRITE_HEADER: if (!ddram_busy) begin
                    poll_count <= POLL_DELAY_CYCLES;
                    state <= POLL_DELAY;
                end
                POLL_DELAY: if (poll_count == 0) state <= POLL_ISSUE;
                            else poll_count <= poll_count - 1;
                POLL_ISSUE: if (!ddram_busy) state <= POLL_RESPONSE;
                POLL_RESPONSE: if (ddram_read_data_ready) begin
                    if (ddram_read_data[63:32] == request_sequence) begin
                        read_data <= ddram_read_data[31:0];
                        state <= POLL_IRQ;
                    end else begin
                        state <= POLL_STALE_DRAIN;
                    end
                end
                POLL_IRQ: if (ddram_read_data_ready) begin
                    irq_arm9 <= ddram_read_data[0];
                    irq_arm7 <= ddram_read_data[1];
                    halt_arm9 <= ddram_read_data[2];
                    halt_arm7 <= ddram_read_data[3];
                    // HPS drains every posted write through saved_fence
                    // before publishing this response. Return that exact
                    // ordering point to the FPGA ring with the completion.
                    completed_fence_sequence <= saved_fence;
                    done <= 1'b1;
                    state <= WAIT_RELEASE;
                end
                POLL_STALE_DRAIN: if (ddram_read_data_ready) begin
                    poll_count <= POLL_DELAY_CYCLES;
                    state <= POLL_DELAY;
                end
                WAIT_RELEASE: if (!request) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
