module nds_boot_descriptor_reader #(
    parameter logic [28:0] BASE_WORD = 29'h05800200,
    parameter integer RETRY_DELAY_CYCLES = 1024
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,
    output logic        valid,
    output logic        format_error,
    output logic [31:0] generation,
    output logic [31:0] arm9_dtcm_irq_vector,
    output logic [31:0] arm9_trace_trigger,
    output logic [31:0] arm9_entry,
    output logic [31:0] arm7_entry,
    output logic [31:0] arm9_current_sp,
    output logic [31:0] arm9_irq_sp,
    output logic [31:0] arm9_saved_sp,
    output logic [31:0] arm7_current_sp,
    output logic [31:0] arm7_irq_sp,
    output logic [31:0] arm7_saved_sp,
    output logic [31:0] initial_cpsr,

    output logic        ddram_read,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    input  logic        ddram_busy,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready
);
    typedef enum logic [3:0] {
        IDLE, ISSUE_BURST, RECEIVE_BURST, CHECK_CRC,
        ISSUE_RECHECK, WAIT_RECHECK, ACCEPTED, REJECTED
    } state_t;
    state_t state;
    logic [31:0] words [0:15];
    logic [7:0] descriptor_bytes [0:63];
    logic [2:0] beat_index;
    logic [5:0] byte_index;
    logic [31:0] crc;
    integer retry_count;

    function automatic logic [31:0] crc32_byte(
        input logic [31:0] current, input logic [7:0] value);
        logic [31:0] next;
        integer bit_index;
        begin
            next = current ^ value;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                next = (next >> 1) ^
                    (32'hedb88320 & {32{next[0]}});
            return next;
        end
    endfunction

    wire [31:0] next_crc = crc32_byte(crc, descriptor_bytes[byte_index]);
    wire fixed_fields_ok =
        words[0] == 32'h4253444e &&
        words[1] == 32'd3 &&
        words[2] != 32'd0 &&
        words[3][1:0] == 2'b00 &&
        words[3] != 32'd0 &&
        words[4] == 32'h00400000 &&
        words[14] == 32'h000000d3;

    assign ddram_read = ((state == ISSUE_BURST) ||
                         (state == ISSUE_RECHECK)) && !ddram_busy;
    assign ddram_burst_count = state == ISSUE_BURST ? 8'd8 : 8'd1;
    assign ddram_address = state == ISSUE_RECHECK
        ? BASE_WORD + 29'd1 : BASE_WORD;
    assign valid = state == ACCEPTED;
    assign format_error = state == REJECTED;
    assign generation = words[2];
    assign arm9_dtcm_irq_vector = words[3];
    assign arm9_trace_trigger = words[5];
    assign arm9_entry = words[6];
    assign arm7_entry = words[7];
    assign arm9_current_sp = words[8];
    assign arm9_irq_sp = words[9];
    assign arm9_saved_sp = words[10];
    assign arm7_current_sp = words[11];
    assign arm7_irq_sp = words[12];
    assign arm7_saved_sp = words[13];
    assign initial_cpsr = words[14];

    always_ff @(posedge clk) begin
        if (reset || !enable) begin
            state <= IDLE;
            beat_index <= 0;
            byte_index <= 0;
            crc <= 32'hffffffff;
            retry_count <= 0;
            for (integer index = 0; index < 16; index = index + 1)
                words[index] <= 0;
            for (integer index = 0; index < 64; index = index + 1)
                descriptor_bytes[index] <= 0;
        end else begin
            case (state)
                IDLE: state <= ISSUE_BURST;
                ISSUE_BURST: if (!ddram_busy) begin
                    beat_index <= 0;
                    state <= RECEIVE_BURST;
                end
                RECEIVE_BURST: if (ddram_read_data_ready) begin
                    words[{beat_index,1'b0}] <= ddram_read_data[31:0];
                    words[{beat_index,1'b1}] <= ddram_read_data[63:32];
                    for (integer lane = 0; lane < 8; lane = lane + 1)
                        descriptor_bytes[beat_index*8+lane] <=
                            ddram_read_data[lane*8 +: 8];
                    if (beat_index == 7) begin
                        byte_index <= 0;
                        crc <= 32'hffffffff;
                        state <= CHECK_CRC;
                    end else begin
                        beat_index <= beat_index + 1'b1;
                    end
                end
                CHECK_CRC: begin
                    crc <= next_crc;
                    if (byte_index == 59) begin
                        if (fixed_fields_ok && ~next_crc == words[15])
                            state <= ISSUE_RECHECK;
                        else
                            state <= REJECTED;
                    end else begin
                        byte_index <= byte_index + 1'b1;
                    end
                end
                ISSUE_RECHECK: if (!ddram_busy) state <= WAIT_RECHECK;
                WAIT_RECHECK: if (ddram_read_data_ready) begin
                    // BASE_WORD+1 contains generation in its low half. A
                    // mismatch means HPS republished while the burst was read.
                    if (ddram_read_data[31:0] == words[2])
                        state <= ACCEPTED;
                    else
                        state <= REJECTED;
                end
                ACCEPTED: state <= ACCEPTED;
                REJECTED: begin
                    // HPS may still be copying RAM or publishing generation
                    // when the menu enables standalone mode. Retry without
                    // requiring a user-visible reset or toggle.
                    if (RETRY_DELAY_CYCLES <= 1 ||
                        retry_count >= RETRY_DELAY_CYCLES - 1) begin
                        retry_count <= 0;
                        state <= IDLE;
                    end else begin
                        retry_count <= retry_count + 1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
