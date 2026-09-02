module nds_cpu_ddram #(
    parameter logic [28:0] BASE_WORD = 29'h05820000
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        request,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,
    output logic        done,

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
    localparam logic [1:0] ACCESS_8 = 2'b00;
    localparam logic [1:0] ACCESS_16 = 2'b01;
    typedef enum logic [1:0] {IDLE, ISSUE, WAIT_READ, WAIT_RELEASE} state_t;
    state_t state;
    logic latched_rnw;
    logic [1:0] latched_access;
    logic [2:0] latched_offset;
    logic [31:0] latched_write_data;

    assign ddram_burst_count = 8'd1;
    assign ddram_read = state == ISSUE && latched_rnw;
    assign ddram_write = state == ISSUE && !latched_rnw;

    always_comb begin
        ddram_byte_enable = 8'h00;
        ddram_write_data = 64'h0;
        case (latched_access)
            ACCESS_8: begin
                ddram_byte_enable = 8'h01 << latched_offset;
                ddram_write_data = {56'h0, latched_write_data[7:0]} << (latched_offset * 8);
            end
            ACCESS_16: begin
                ddram_byte_enable = 8'h03 << latched_offset;
                ddram_write_data = {48'h0, latched_write_data[15:0]} << (latched_offset * 8);
            end
            default: begin
                ddram_byte_enable = 8'h0f << latched_offset;
                ddram_write_data = {32'h0, latched_write_data} << (latched_offset * 8);
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            done <= 1'b0;
            ddram_address <= BASE_WORD;
            read_data <= 32'h0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (request) begin
                    latched_rnw <= read_not_write;
                    latched_access <= access;
                    latched_offset <= address[2:0];
                    latched_write_data <= write_data;
                    ddram_address <= BASE_WORD + address[31:3];
                    state <= ISSUE;
                end
                ISSUE: if (!ddram_busy) begin
                    if (latched_rnw) begin
                        state <= WAIT_READ;
                    end else begin
                        done <= 1'b1;
                        state <= WAIT_RELEASE;
                    end
                end
                WAIT_READ: if (ddram_read_data_ready) begin
                    case (latched_access)
                        ACCESS_8: read_data <= (ddram_read_data >> (latched_offset * 8)) & 32'h000000ff;
                        ACCESS_16: read_data <= (ddram_read_data >> (latched_offset * 8)) & 32'h0000ffff;
                        default: read_data <= ddram_read_data >> (latched_offset * 8);
                    endcase
                    done <= 1'b1;
                    state <= WAIT_RELEASE;
                end
                WAIT_RELEASE: if (!request) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
