// Fail-closed timing guard between the exactly-once Robert register-write
// seam and nds_sound_output_adapter.
//
// nds_sound_output_control_shadow observes a write when it is released to the
// held-request driver.  Robert's VHDL register bank consumes that write only
// on the later completion edge, and its registered select/master/output path
// needs three further clocks before sound_out_* reflects the new controls.
// This guard therefore invalidates audio ownership as soon as a relevant
// request appears and requalifies it only after the matching completion plus
// a conservative number of full clocks.

`timescale 1ns/1ps
`default_nettype none

module nds_sound_output_settle_guard #(
    parameter integer SETTLE_CYCLES = 4
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        engine_cpu_request,
    input  logic        engine_cpu_write,
    input  logic [31:0] engine_cpu_address,
    input  logic [1:0]  engine_cpu_access,
    input  logic        engine_cpu_done,
    input  logic        engine_cpu_rejected,

    output logic        controls_settled,
    output logic        protocol_error
);
    localparam integer COUNT_WIDTH =
        SETTLE_CYCLES < 2 ? 1 : $clog2(SETTLE_CYCLES + 1);
    localparam logic [31:0] SETTLE_COUNT_32 = SETTLE_CYCLES;

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_PENDING,
        STATE_WAIT_RELEASE
    } state_t;
    state_t state;

    logic pending_relevant;
    logic qualification_completed;
    logic [COUNT_WIDTH-1:0] settle_count;
    logic current_request_known;
    logic current_request_relevant;

    initial begin
        if (SETTLE_CYCLES < 3)
            $fatal(1,
                "sound output settle guard requires at least three clocks");
    end

    function automatic logic vector_known_32(input logic [31:0] value);
        vector_known_32 = (^value !== 1'bx);
    endfunction

    function automatic logic vector_known_2(input logic [1:0] value);
        vector_known_2 = (^value !== 1'bx);
    endfunction

    function automatic logic is_relevant_control_write (
        input logic        write_enable,
        input logic [31:0] address,
        input logic [1:0]  access
    );
        begin
            is_relevant_control_write = 1'b0;
            if (write_enable == 1'b1 &&
                vector_known_32(address) &&
                vector_known_2(access)) begin
                case (access)
                    // Only the low two lanes hold defined output controls.
                    2'b00:
                        if (address == 32'h04000500 ||
                            address == 32'h04000501 ||
                            address == 32'h04000504 ||
                            address == 32'h04000505 ||
                            address == 32'h04000508 ||
                            address == 32'h04000509)
                            is_relevant_control_write = 1'b1;
                    2'b01, 2'b10:
                        if (address == 32'h04000500 ||
                            address == 32'h04000504 ||
                            address == 32'h04000508)
                            is_relevant_control_write = 1'b1;
                    default: is_relevant_control_write = 1'b0;
                endcase
            end
        end
    endfunction

    always_comb begin
        current_request_known = 1'b0;
        if (engine_cpu_request == 1'b0)
            current_request_known = 1'b1;
        else if (engine_cpu_request == 1'b1 &&
                 engine_cpu_write == 1'b1 &&
                 vector_known_32(engine_cpu_address) &&
                 vector_known_2(engine_cpu_access))
            current_request_known = 1'b1;

        current_request_relevant = 1'b0;
        if (engine_cpu_request == 1'b1)
            current_request_relevant = is_relevant_control_write(
                engine_cpu_write,
                engine_cpu_address,
                engine_cpu_access);

        // Request launch blocks combinationally in the same post-edge delta in
        // which the control shadow commits its released write.  Requalification
        // is entirely registered and completion-relative.
        controls_settled = 1'b0;
        if (reset == 1'b0 &&
            protocol_error == 1'b0 &&
            qualification_completed == 1'b1 &&
            settle_count == 0 &&
            !(state == STATE_PENDING && pending_relevant) &&
            current_request_known == 1'b1 &&
            current_request_relevant == 1'b0)
            controls_settled = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= STATE_IDLE;
            pending_relevant <= 1'b0;
            qualification_completed <= 1'b0;
            settle_count <= '0;
            protocol_error <= 1'b0;
        end else begin
            if (settle_count != 0)
                settle_count <= settle_count - 1'b1;

            case (state)
                STATE_IDLE: begin
                    if (engine_cpu_done === 1'b1 ||
                        engine_cpu_rejected === 1'b1) begin
                        qualification_completed <= 1'b0;
                        settle_count <= '0;
                        protocol_error <= 1'b1;
                    end else if (engine_cpu_done !== 1'b0 ||
                                 engine_cpu_rejected !== 1'b0 ||
                                 !current_request_known) begin
                        qualification_completed <= 1'b0;
                        settle_count <= '0;
                        protocol_error <= 1'b1;
                    end else if (engine_cpu_request === 1'b1) begin
                        state <= STATE_PENDING;
                        pending_relevant <= current_request_relevant;
                        if (current_request_relevant) begin
                            qualification_completed <= 1'b0;
                            settle_count <= '0;
                        end
                    end
                end

                STATE_PENDING: begin
                    if (engine_cpu_request !== 1'b1) begin
                        qualification_completed <= 1'b0;
                        settle_count <= '0;
                        protocol_error <= 1'b1;
                    end else if (engine_cpu_rejected === 1'b1) begin
                        state <= STATE_WAIT_RELEASE;
                        if (pending_relevant) begin
                            qualification_completed <= 1'b0;
                            settle_count <= '0;
                        end
                        protocol_error <= 1'b1;
                    end else if (engine_cpu_rejected !== 1'b0 ||
                                 engine_cpu_done !== 1'b0 &&
                                 engine_cpu_done !== 1'b1) begin
                        qualification_completed <= 1'b0;
                        settle_count <= '0;
                        protocol_error <= 1'b1;
                    end else if (engine_cpu_done === 1'b1) begin
                        state <= STATE_WAIT_RELEASE;
                        if (pending_relevant) begin
                            qualification_completed <= 1'b1;
                            settle_count <=
                                SETTLE_COUNT_32[COUNT_WIDTH-1:0];
                        end
                    end
                end

                STATE_WAIT_RELEASE: begin
                    if (engine_cpu_done === 1'b1 ||
                        engine_cpu_rejected === 1'b1) begin
                        qualification_completed <= 1'b0;
                        settle_count <= '0;
                        protocol_error <= 1'b1;
                    end else if (engine_cpu_done !== 1'b0 ||
                                 engine_cpu_rejected !== 1'b0 ||
                                 engine_cpu_request !== 1'b0 &&
                                 engine_cpu_request !== 1'b1) begin
                        qualification_completed <= 1'b0;
                        settle_count <= '0;
                        protocol_error <= 1'b1;
                    end else if (engine_cpu_request === 1'b0) begin
                        state <= STATE_IDLE;
                        pending_relevant <= 1'b0;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                    pending_relevant <= 1'b0;
                    qualification_completed <= 1'b0;
                    settle_count <= '0;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
