// Common one-outstanding adapter for Nintendo DS sound sample reads whose
// local MiSTer DDR beat address and 32-bit lane have already been translated.
//
// A request is a one-cycle pulse. The translated command is retained until
// the shared arbiter reports physical acceptance, and the selected 32-bit
// word is returned whether the DDR data arrives on that acceptance edge or
// later. Reset enters an explicit transport quarantine so a response from a
// retired DDR epoch can never complete a new sound request.
//
// This simulator-first primitive is intentionally absent from the production
// MiSTer top and Quartus project.
module nds_sound_ddr_word_read_adapter #(
    parameter logic [28:0] RESET_DDRAM_ADDRESS = 29'h05820000
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        request,
    input  logic        request_supported,
    input  logic [28:0] request_ddram_address,
    input  logic        request_upper_word,
    output logic        request_done,
    output logic [31:0] request_data,
    output logic        request_busy,
    output logic        protocol_error,

    output logic        ddram_read,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    input  logic        ddram_command_accepted,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready,
    // Must remain low after reset until the outer arbiter and physical DDR
    // response path have discarded/drained every pre-reset transaction.
    input  logic        ddram_epoch_quiescent
);
    typedef enum logic [1:0] {
        QUARANTINE,
        IDLE,
        ISSUE,
        WAIT_RESPONSE
    } state_t;

    state_t state;
    logic upper_word;
    logic epoch_low_seen;
    logic quarantine_request_pending;
    logic quarantine_request_supported;
    logic [28:0] quarantine_ddram_address;
    logic quarantine_upper_word;

    assign request_busy = state != IDLE;
    assign ddram_read = state == ISSUE;
    assign ddram_burst_count = 8'd1;

    function automatic logic [31:0] selected_word(
        input logic [63:0] data,
        input logic        upper
    );
        selected_word = upper ? data[63:32] : data[31:0];
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= QUARANTINE;
            upper_word <= 1'b0;
            epoch_low_seen <= 1'b0;
            quarantine_request_pending <= 1'b0;
            quarantine_request_supported <= 1'b0;
            quarantine_ddram_address <= RESET_DDRAM_ADDRESS;
            quarantine_upper_word <= 1'b0;
            ddram_address <= RESET_DDRAM_ADDRESS;
            request_done <= 1'b0;
            request_data <= 32'd0;
            protocol_error <= 1'b0;
        end else begin
            request_done <= 1'b0;

            // The sound engine may not replace an outstanding request.
            if (request &&
                (state == ISSUE || state == WAIT_RESPONSE ||
                 (state == QUARANTINE &&
                  quarantine_request_pending)))
                protocol_error <= 1'b1;

            case (state)
                QUARANTINE: begin
                    // Command/data pulses here belong to the retired epoch.
                    // Ignore them. The integration wrapper owns the stronger
                    // proof that no still-later response remains in flight.
                    // A stale-high level across reset is insufficient.
                    if (!ddram_epoch_quiescent)
                        epoch_low_seen <= 1'b1;
                    if (epoch_low_seen && ddram_epoch_quiescent &&
                        !ddram_command_accepted &&
                        !ddram_read_data_ready) begin
                        // Robert's engine has no request-ready input: once it
                        // pulses req_ena it waits for req_done. Retain one new
                        // epoch request during transport quarantine so reset
                        // ordering cannot strand the sound engine forever.
                        if (quarantine_request_pending) begin
                            quarantine_request_pending <= 1'b0;
                            if (quarantine_request_supported) begin
                                ddram_address <=
                                    quarantine_ddram_address;
                                upper_word <= quarantine_upper_word;
                                state <= ISSUE;
                            end else begin
                                protocol_error <= 1'b1;
                                request_data <= 32'd0;
                                request_done <= 1'b1;
                                state <= IDLE;
                            end
                        end else if (request) begin
                            // A request coincident with the release edge can
                            // proceed directly without an extra idle cycle.
                            if (request_supported) begin
                                ddram_address <=
                                    request_ddram_address;
                                upper_word <= request_upper_word;
                                state <= ISSUE;
                            end else begin
                                protocol_error <= 1'b1;
                                request_data <= 32'd0;
                                request_done <= 1'b1;
                                state <= IDLE;
                            end
                        end else begin
                            state <= IDLE;
                        end
                    end else if (request &&
                                 !quarantine_request_pending) begin
                        quarantine_request_pending <= 1'b1;
                        quarantine_request_supported <=
                            request_supported;
                        quarantine_ddram_address <=
                            request_ddram_address;
                        quarantine_upper_word <= request_upper_word;
                    end
                end

                IDLE: begin
                    if (ddram_read_data_ready)
                        protocol_error <= 1'b1;
                    if (request) begin
                        // Test the asserted case directly: an unknown mapping
                        // qualifier is rejected in four-state simulation
                        // rather than becoming an address with X bits.
                        if (request_supported) begin
                            ddram_address <= request_ddram_address;
                            upper_word <= request_upper_word;
                            state <= ISSUE;
                        end else begin
                            // Unsupported and malformed accesses complete
                            // locally as zero and never reach DDR.
                            protocol_error <= 1'b1;
                            request_data <= 32'd0;
                            request_done <= 1'b1;
                        end
                    end
                end

                ISSUE: begin
                    if (ddram_read_data_ready &&
                        !ddram_command_accepted)
                        protocol_error <= 1'b1;
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            request_data <= selected_word(
                                ddram_read_data, upper_word);
                            request_done <= 1'b1;
                            state <= IDLE;
                        end else begin
                            state <= WAIT_RESPONSE;
                        end
                    end
                end

                WAIT_RESPONSE: begin
                    if (ddram_command_accepted)
                        protocol_error <= 1'b1;
                    if (ddram_read_data_ready) begin
                        request_data <= selected_word(
                            ddram_read_data, upper_word);
                        request_done <= 1'b1;
                        state <= IDLE;
                    end
                end

                default: begin
                    state <= IDLE;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end
endmodule
