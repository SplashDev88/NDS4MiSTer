`timescale 1ns/1ps

// Nintendo DS ARM9 DIV/SQRT MMIO block.
//
// The externally visible behavior follows the melonDS implementation in
// third_party/melonDS/src/NDS.cpp (DivDone/StartDiv, SqrtDone/StartSqrt and
// ARM9IORead/Write{8,16,32}):
//   * DIV mode 0 completes after 18 ARM9 cycles; modes 1/2/3 after 34.
//   * SQRT completes after 13 ARM9 cycles.
//   * every supported control/operand write cancels and restarts its unit.
//   * byte operand/control writes and halfword operand writes are ignored.
//   * quotient, remainder and square-root result stay unchanged while busy.
//
// cycle_advance uses the existing ARM9 emulated-cycle credit seam. Arithmetic
// iterates on clk, but architectural BUSY consumes the complete 8-bit credit
// atomically instead of accidentally timing the unit at clk_sys (60 MHz).
// The production gba_cpu seam reports a credit only after retiring an
// instruction, so the iterative datapath receives intervening clk_sys ticks.
// At the densest one-credit-per-tick cadence, DIV needs 16/32 ticks before its
// 18/34-credit deadline and SQRT needs 11 before 13. A synthetic source that
// injects an entire deadline immediately may exhaust time before calculation;
// BUSY then clears as soon as the iterative result is ready, without inferring
// a large combinational divider.
module nds_arm9_math_unit (
    input  logic        clk,
    input  logic        reset,
    input  logic [7:0]  cycle_advance,
    input  logic        cycle_advance_valid,

    input  logic        request,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic        selected,
    output logic [31:0] read_data,
    output logic        done,

    output logic        div_busy,
    output logic        sqrt_busy
);
    localparam logic [31:0] DIVCNT      = 32'h04000280;
    localparam logic [31:0] DIV_NUMER_L = 32'h04000290;
    localparam logic [31:0] DIV_NUMER_H = 32'h04000294;
    localparam logic [31:0] DIV_DENOM_L = 32'h04000298;
    localparam logic [31:0] DIV_DENOM_H = 32'h0400029c;
    localparam logic [31:0] DIV_RESULT_L= 32'h040002a0;
    localparam logic [31:0] DIV_RESULT_H= 32'h040002a4;
    localparam logic [31:0] DIVREM_L    = 32'h040002a8;
    localparam logic [31:0] DIVREM_H    = 32'h040002ac;
    localparam logic [31:0] SQRTCNT     = 32'h040002b0;
    localparam logic [31:0] SQRT_RESULT = 32'h040002b4;
    localparam logic [31:0] SQRT_PARAM_L= 32'h040002b8;
    localparam logic [31:0] SQRT_PARAM_H= 32'h040002bc;

    logic [15:0] div_cnt;
    logic [63:0] div_numerator;
    logic [63:0] div_denominator;
    logic [63:0] div_quotient;
    logic [63:0] div_remainder;

    logic [15:0] sqrt_cnt;
    logic [63:0] sqrt_parameter;
    logic [31:0] sqrt_result;

    logic bus_active;
    logic bus_response_pending;
    logic bus_response_read;
    logic [31:0] bus_read_address;
    logic [1:0] bus_read_access;
    wire bus_accept = request && selected && !bus_active;

    // Defined bytes are selected locally. Undefined holes such as
    // 0x04000284..0x0400028f remain available to the parent bus.
    always_comb begin
        selected = 1'b0;
        case (access)
            2'b00: selected =
                (address >= DIVCNT && address <= DIVCNT + 32'd1) ||
                (address >= DIV_NUMER_L && address <= DIVREM_H + 32'd3) ||
                (address >= SQRTCNT && address <= SQRTCNT + 32'd1) ||
                (address >= SQRT_RESULT &&
                 address <= SQRT_PARAM_H + 32'd3);
            2'b01: selected = !address[0] &&
                ((address == DIVCNT) ||
                 (address >= DIV_NUMER_L && address <= DIVREM_H + 32'd2) ||
                 (address == SQRTCNT) ||
                 (address >= SQRT_RESULT &&
                  address <= SQRT_PARAM_H + 32'd2));
            2'b10: selected = address[1:0] == 2'b00 &&
                ((address == DIVCNT) ||
                 (address >= DIV_NUMER_L && address <= DIVREM_H) ||
                 (address == SQRTCNT) ||
                 (address >= SQRT_RESULT && address <= SQRT_PARAM_H));
            default: selected = 1'b0;
        endcase
    end

    wire [31:0] read_mux_address = bus_response_pending
        ? bus_read_address : address;
    wire [1:0] read_mux_access = bus_response_pending
        ? bus_read_access : access;
    logic [31:0] addressed_word;
    logic [31:0] formatted_read_data;
    always_comb begin
        addressed_word = 32'd0;
        case ({read_mux_address[31:2], 2'b00})
            DIVCNT:       addressed_word = {16'd0, div_cnt};
            DIV_NUMER_L:  addressed_word = div_numerator[31:0];
            DIV_NUMER_H:  addressed_word = div_numerator[63:32];
            DIV_DENOM_L:  addressed_word = div_denominator[31:0];
            DIV_DENOM_H:  addressed_word = div_denominator[63:32];
            DIV_RESULT_L: addressed_word = div_quotient[31:0];
            DIV_RESULT_H: addressed_word = div_quotient[63:32];
            DIVREM_L:     addressed_word = div_remainder[31:0];
            DIVREM_H:     addressed_word = div_remainder[63:32];
            SQRTCNT:      addressed_word = {16'd0, sqrt_cnt};
            SQRT_RESULT:  addressed_word = sqrt_result;
            SQRT_PARAM_L: addressed_word = sqrt_parameter[31:0];
            SQRT_PARAM_H: addressed_word = sqrt_parameter[63:32];
            default:      addressed_word = 32'd0;
        endcase

        case (read_mux_access)
            2'b00: begin
                case (read_mux_address[1:0])
                    2'd0: formatted_read_data =
                        {24'd0, addressed_word[7:0]};
                    2'd1: formatted_read_data =
                        {24'd0, addressed_word[15:8]};
                    2'd2: formatted_read_data =
                        {24'd0, addressed_word[23:16]};
                    default: formatted_read_data =
                        {24'd0, addressed_word[31:24]};
                endcase
            end
            2'b01: formatted_read_data = read_mux_address[1]
                ? {16'd0, addressed_word[31:16]}
                : {16'd0, addressed_word[15:0]};
            default: formatted_read_data = addressed_word;
        endcase
    end

    // Only the write forms implemented by melonDS restart the arithmetic.
    wire div_control_write = bus_accept && !read_not_write &&
        address == DIVCNT && (access == 2'b01 || access == 2'b10);
    wire div_operand_write = bus_accept && !read_not_write &&
        access == 2'b10 &&
        (address == DIV_NUMER_L || address == DIV_NUMER_H ||
         address == DIV_DENOM_L || address == DIV_DENOM_H);
    wire div_start = div_control_write || div_operand_write;

    wire sqrt_control_write = bus_accept && !read_not_write &&
        address == SQRTCNT && (access == 2'b01 || access == 2'b10);
    wire sqrt_operand_write = bus_accept && !read_not_write &&
        access == 2'b10 &&
        (address == SQRT_PARAM_L || address == SQRT_PARAM_H);
    wire sqrt_start = sqrt_control_write || sqrt_operand_write;

    logic [15:0] div_start_cnt;
    logic [63:0] div_start_numerator;
    logic [63:0] div_start_denominator;
    always_comb begin
        div_start_cnt = div_cnt;
        div_start_numerator = div_numerator;
        div_start_denominator = div_denominator;
        if (div_control_write)
            div_start_cnt = write_data[15:0];
        if (div_operand_write) begin
            case (address)
                DIV_NUMER_L: div_start_numerator[31:0] = write_data;
                DIV_NUMER_H: div_start_numerator[63:32] = write_data;
                DIV_DENOM_L: div_start_denominator[31:0] = write_data;
                DIV_DENOM_H: div_start_denominator[63:32] = write_data;
                default: begin end
            endcase
        end
    end

    wire [1:0] div_start_mode = div_start_cnt[1:0];
    wire [63:0] div_start_signed_numerator = div_start_mode == 2'd0
        ? {{32{div_start_numerator[31]}}, div_start_numerator[31:0]}
        : div_start_numerator;
    wire [63:0] div_start_signed_denominator = div_start_mode == 2'd2
        ? div_start_denominator
        : {{32{div_start_denominator[31]}}, div_start_denominator[31:0]};
    wire div_start_numerator_negative = div_start_signed_numerator[63];
    wire div_start_denominator_negative = div_start_signed_denominator[63];
    wire [63:0] div_start_numerator_magnitude =
        div_start_numerator_negative
            ? (~div_start_signed_numerator + 64'd1)
            : div_start_signed_numerator;
    wire [63:0] div_start_denominator_magnitude =
        div_start_denominator_negative
            ? (~div_start_signed_denominator + 64'd1)
            : div_start_signed_denominator;
    wire div_start_effective_zero = div_start_signed_denominator == 64'd0;
    wire div_start_flag_zero = div_start_denominator == 64'd0;
    wire div_start_overflow = div_start_mode == 2'd0
        ? (div_start_numerator[31:0] == 32'h80000000 &&
           div_start_denominator[31:0] == 32'hffffffff)
        : (div_start_numerator == 64'h8000000000000000 &&
           div_start_signed_denominator == 64'hffffffffffffffff);

    logic div_running;
    logic [5:0] div_pairs;
    logic [5:0] div_iterations;
    logic [63:0] div_dividend_shift;
    logic [65:0] div_remainder_work;
    logic [63:0] div_quotient_work;
    logic [63:0] div_denominator_magnitude;
    logic div_numerator_negative;
    logic div_result_negative;
    logic div_flag_zero;
    logic [5:0] div_cycles_remaining;
    logic div_time_done;
    logic div_calculation_done;
    logic [63:0] div_pending_quotient;
    logic [63:0] div_pending_remainder;

    // One radix-4 step emits two quotient bits. This gives 16 clk_sys steps
    // for 32/32 and 32 for either 64-bit mode, without inferring '/' or '%'.
    function automatic [193:0] div_radix4_step;
        input [63:0] dividend;
        input [65:0] remainder;
        input [63:0] quotient;
        input [63:0] denominator;
        reg [65:0] shifted_remainder;
        reg [65:0] denominator_one;
        reg [65:0] denominator_two;
        reg [65:0] denominator_three;
        reg [65:0] next_remainder;
        reg [1:0] digit;
        begin
            shifted_remainder =
                (remainder << 2) | {64'd0, dividend[63:62]};
            denominator_one = {2'd0, denominator};
            denominator_two = denominator_one << 1;
            denominator_three = denominator_two + denominator_one;
            if (shifted_remainder >= denominator_three) begin
                digit = 2'd3;
                next_remainder = shifted_remainder - denominator_three;
            end else if (shifted_remainder >= denominator_two) begin
                digit = 2'd2;
                next_remainder = shifted_remainder - denominator_two;
            end else if (shifted_remainder >= denominator_one) begin
                digit = 2'd1;
                next_remainder = shifted_remainder - denominator_one;
            end else begin
                digit = 2'd0;
                next_remainder = shifted_remainder;
            end
            div_radix4_step = {
                dividend << 2,
                next_remainder,
                (quotient << 2) | {62'd0, digit}
            };
        end
    endfunction

    wire [193:0] div_step = div_radix4_step(
        div_dividend_shift, div_remainder_work, div_quotient_work,
        div_denominator_magnitude);
    wire div_calculation_finishes_now = div_running &&
        !div_calculation_done && div_iterations < div_pairs &&
        div_iterations + 1'b1 == div_pairs;
    wire [63:0] div_final_step_quotient = div_result_negative
        ? (~div_step[63:0] + 64'd1) : div_step[63:0];
    wire [63:0] div_final_step_remainder = div_numerator_negative
        ? (~div_step[127:64] + 64'd1) : div_step[127:64];
    wire div_credit_finishes_now = div_running && !div_time_done &&
        cycle_advance_valid &&
        {1'b0, cycle_advance} >= {3'd0, div_cycles_remaining};
    wire div_time_ready_now = div_time_done || div_credit_finishes_now;
    wire div_calculation_ready_now = div_calculation_done ||
        div_calculation_finishes_now;
    wire div_operation_completes_now = div_running &&
        div_time_ready_now && div_calculation_ready_now;
    wire [15:0] div_completed_cnt = (div_cnt & 16'h3fff) |
        (div_flag_zero ? 16'h4000 : 16'h0000);
    wire [63:0] div_completion_quotient = div_calculation_done
        ? div_pending_quotient : div_final_step_quotient;
    wire [63:0] div_completion_remainder = div_calculation_done
        ? div_pending_remainder : div_final_step_remainder;

    logic [15:0] sqrt_start_cnt;
    logic [63:0] sqrt_start_parameter;
    always_comb begin
        sqrt_start_cnt = sqrt_cnt;
        sqrt_start_parameter = sqrt_parameter;
        if (sqrt_control_write)
            sqrt_start_cnt = write_data[15:0];
        if (sqrt_operand_write) begin
            if (address == SQRT_PARAM_L)
                sqrt_start_parameter[31:0] = write_data;
            else
                sqrt_start_parameter[63:32] = write_data;
        end
    end

    logic sqrt_running;
    logic [5:0] sqrt_total_iterations;
    logic [5:0] sqrt_iterations;
    logic [63:0] sqrt_value_shift;
    logic [65:0] sqrt_remainder_work;
    logic [31:0] sqrt_root_work;
    logic [3:0] sqrt_cycles_remaining;
    logic sqrt_time_done;
    logic sqrt_calculation_done;
    logic [31:0] sqrt_pending_result;

    // Three radix-2 square-root iterations per clk_sys tick produce all 32
    // result bits independently of the fixed 13-credit completion point.
    function automatic [161:0] sqrt_advance_three;
        input [63:0] value_shift;
        input [65:0] remainder;
        input [31:0] root;
        input [5:0] remaining;
        reg [63:0] next_value;
        reg [65:0] next_remainder;
        reg [31:0] next_root;
        reg [65:0] trial;
        integer iteration;
        begin
            next_value = value_shift;
            next_remainder = remainder;
            next_root = root;
            for (iteration = 0; iteration < 3; iteration = iteration + 1) begin
                if (iteration < remaining) begin
                    next_remainder = (next_remainder << 2) |
                        {64'd0, next_value[63:62]};
                    next_value = next_value << 2;
                    next_root = next_root << 1;
                    trial = ({34'd0, next_root} << 1) + 66'd1;
                    if (next_remainder >= trial) begin
                        next_remainder = next_remainder - trial;
                        next_root = next_root + 1'b1;
                    end
                end
            end
            sqrt_advance_three = {next_value, next_remainder, next_root};
        end
    endfunction

    wire [5:0] sqrt_remaining =
        sqrt_total_iterations - sqrt_iterations;
    wire [2:0] sqrt_steps_this_cycle = sqrt_remaining >= 6'd3
        ? 3'd3 : sqrt_remaining[2:0];
    wire [161:0] sqrt_step = sqrt_advance_three(
        sqrt_value_shift, sqrt_remainder_work, sqrt_root_work,
        sqrt_remaining);
    wire sqrt_calculation_finishes_now = sqrt_running &&
        !sqrt_calculation_done &&
        sqrt_iterations < sqrt_total_iterations &&
        sqrt_iterations + {3'd0, sqrt_steps_this_cycle} >=
            sqrt_total_iterations;
    wire sqrt_credit_finishes_now = sqrt_running && !sqrt_time_done &&
        cycle_advance_valid &&
        {1'b0, cycle_advance} >= {5'd0, sqrt_cycles_remaining};
    wire sqrt_time_ready_now = sqrt_time_done || sqrt_credit_finishes_now;
    wire sqrt_calculation_ready_now = sqrt_calculation_done ||
        sqrt_calculation_finishes_now;
    wire [31:0] sqrt_completion_result = sqrt_calculation_done
        ? sqrt_pending_result : sqrt_step[31:0];

    assign div_busy = div_cnt[15];
    assign sqrt_busy = sqrt_cnt[15];

    always_ff @(posedge clk) begin
        if (reset) begin
            bus_active <= 1'b0;
            bus_response_pending <= 1'b0;
            bus_response_read <= 1'b0;
            bus_read_address <= 32'd0;
            bus_read_access <= 2'd0;
            read_data <= 32'd0;
            done <= 1'b0;

            div_cnt <= 16'd0;
            div_numerator <= 64'd0;
            div_denominator <= 64'd0;
            div_quotient <= 64'd0;
            div_remainder <= 64'd0;
            div_running <= 1'b0;
            div_pairs <= 6'd16;
            div_iterations <= 6'd0;
            div_dividend_shift <= 64'd0;
            div_remainder_work <= 66'd0;
            div_quotient_work <= 64'd0;
            div_denominator_magnitude <= 64'd0;
            div_numerator_negative <= 1'b0;
            div_result_negative <= 1'b0;
            div_flag_zero <= 1'b0;
            div_cycles_remaining <= 6'd0;
            div_time_done <= 1'b0;
            div_calculation_done <= 1'b0;
            div_pending_quotient <= 64'd0;
            div_pending_remainder <= 64'd0;

            sqrt_cnt <= 16'd0;
            sqrt_parameter <= 64'd0;
            sqrt_result <= 32'd0;
            sqrt_running <= 1'b0;
            sqrt_total_iterations <= 6'd16;
            sqrt_iterations <= 6'd0;
            sqrt_value_shift <= 64'd0;
            sqrt_remainder_work <= 66'd0;
            sqrt_root_work <= 32'd0;
            sqrt_cycles_remaining <= 4'd0;
            sqrt_time_done <= 1'b0;
            sqrt_calculation_done <= 1'b0;
            sqrt_pending_result <= 32'd0;
        end else begin
            done <= 1'b0;

            // Defer the read snapshot until the response edge. Therefore an
            // emulated-cycle credit accepted with the request is visible to
            // that access, matching HPS's advance-before-MMIO ordering.
            if (!bus_active && request && selected) begin
                bus_active <= 1'b1;
                bus_response_pending <= 1'b1;
                bus_response_read <= read_not_write;
                bus_read_address <= address;
                bus_read_access <= access;
            end else if (bus_active && bus_response_pending) begin
                if (bus_response_read)
                    read_data <= formatted_read_data;
                done <= 1'b1;
                bus_response_pending <= 1'b0;
            end else if (bus_active && !request) begin
                bus_active <= 1'b0;
            end

            // Arithmetic advances on clk_sys. Architectural time consumes a
            // complete 8-bit ARM9 credit atomically and saturates at zero.
            if (div_running) begin
                if (!div_calculation_done && div_iterations < div_pairs) begin
                    div_dividend_shift <= div_step[193:130];
                    div_remainder_work <= div_step[129:64];
                    div_quotient_work <= div_step[63:0];
                    div_iterations <= div_iterations + 1'b1;
                    if (div_calculation_finishes_now) begin
                        div_calculation_done <= 1'b1;
                        div_pending_quotient <= div_final_step_quotient;
                        div_pending_remainder <= div_final_step_remainder;
                    end
                end

                if (!div_time_done && cycle_advance_valid) begin
                    if (div_credit_finishes_now) begin
                        div_cycles_remaining <= 6'd0;
                        div_time_done <= 1'b1;
                    end else begin
                        div_cycles_remaining <= div_cycles_remaining -
                            cycle_advance[5:0];
                    end
                end

                if (div_operation_completes_now) begin
                    div_running <= 1'b0;
                    div_cnt <= div_completed_cnt;
                    div_quotient <= div_completion_quotient;
                    div_remainder <= div_completion_remainder;
                end
            end

            // A same-edge credit belongs to the old operation. The access is
            // applied afterward, and a write begins a fresh full deadline.
            if (div_start) begin
                // Operand writes preserve DIVCNT. If the old operation also
                // completes on this edge, preserve its just-produced DIV0
                // status rather than the stale pre-edge copy. A control write
                // explicitly replaces DIVCNT and therefore remains dominant.
                div_cnt <= div_operand_write &&
                    div_operation_completes_now
                    ? div_completed_cnt | 16'h8000
                    : div_start_cnt | 16'h8000;
                div_numerator <= div_start_numerator;
                div_denominator <= div_start_denominator;
                div_running <= 1'b1;
                div_pairs <= div_start_mode == 2'd0 ? 6'd16 : 6'd32;
                div_iterations <= 6'd0;
                div_dividend_shift <= div_start_mode == 2'd0
                    ? {div_start_numerator_magnitude[31:0], 32'd0}
                    : div_start_numerator_magnitude;
                div_remainder_work <= 66'd0;
                div_quotient_work <= 64'd0;
                div_denominator_magnitude <=
                    div_start_denominator_magnitude;
                div_numerator_negative <= div_start_numerator_negative;
                div_result_negative <= div_start_numerator_negative ^
                    div_start_denominator_negative;
                div_flag_zero <= div_start_flag_zero;
                div_cycles_remaining <= div_start_mode == 2'd0
                    ? 6'd18 : 6'd34;
                div_time_done <= 1'b0;
                if (div_start_effective_zero) begin
                    div_calculation_done <= 1'b1;
                    // Mode 0 sign-expands +/-1 and then inverts its high word.
                    // Modes 1/2/3 return the ordinary signed 64-bit value.
                    if (div_start_mode == 2'd0)
                        div_pending_quotient <=
                            div_start_numerator_negative
                                ? 64'hffffffff00000001
                                : 64'h00000000ffffffff;
                    else
                        div_pending_quotient <=
                            div_start_numerator_negative
                                ? 64'd1 : 64'hffffffffffffffff;
                    div_pending_remainder <= div_start_signed_numerator;
                end else if (div_start_overflow) begin
                    div_calculation_done <= 1'b1;
                    div_pending_quotient <= div_start_mode == 2'd0
                        ? 64'h0000000080000000
                        : 64'h8000000000000000;
                    div_pending_remainder <= 64'd0;
                end else begin
                    div_calculation_done <= 1'b0;
                    div_pending_quotient <= 64'd0;
                    div_pending_remainder <= 64'd0;
                end
            end

            if (sqrt_running) begin
                if (!sqrt_calculation_done &&
                    sqrt_iterations < sqrt_total_iterations) begin
                    sqrt_value_shift <= sqrt_step[161:98];
                    sqrt_remainder_work <= sqrt_step[97:32];
                    sqrt_root_work <= sqrt_step[31:0];
                    sqrt_iterations <= sqrt_iterations +
                        {3'd0, sqrt_steps_this_cycle};
                    if (sqrt_calculation_finishes_now) begin
                        sqrt_calculation_done <= 1'b1;
                        sqrt_pending_result <= sqrt_step[31:0];
                    end
                end

                if (!sqrt_time_done && cycle_advance_valid) begin
                    if (sqrt_credit_finishes_now) begin
                        sqrt_cycles_remaining <= 4'd0;
                        sqrt_time_done <= 1'b1;
                    end else begin
                        sqrt_cycles_remaining <= sqrt_cycles_remaining -
                            cycle_advance[3:0];
                    end
                end

                if (sqrt_time_ready_now && sqrt_calculation_ready_now) begin
                    sqrt_running <= 1'b0;
                    sqrt_cnt <= sqrt_cnt & 16'h7fff;
                    sqrt_result <= sqrt_completion_result;
                end
            end

            if (sqrt_start) begin
                sqrt_cnt <= sqrt_start_cnt | 16'h8000;
                sqrt_parameter <= sqrt_start_parameter;
                sqrt_running <= 1'b1;
                sqrt_total_iterations <= sqrt_start_cnt[0] ? 6'd32 : 6'd16;
                sqrt_iterations <= 6'd0;
                sqrt_value_shift <= sqrt_start_cnt[0]
                    ? sqrt_start_parameter
                    : {sqrt_start_parameter[31:0], 32'd0};
                sqrt_remainder_work <= 66'd0;
                sqrt_root_work <= 32'd0;
                sqrt_cycles_remaining <= 4'd13;
                sqrt_time_done <= 1'b0;
                sqrt_calculation_done <= 1'b0;
                sqrt_pending_result <= 32'd0;
            end
        end
    end
endmodule
