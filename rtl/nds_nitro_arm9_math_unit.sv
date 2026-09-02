`timescale 1ns/1ps

// Nintendo DS ARM9 DIV/SQRT MMIO block.
//
// The externally visible behavior follows the melonDS implementation in
// third_party/melonDS/src/NDS.cpp (DivDone/StartDiv, SqrtDone/StartSqrt and
// ARM9IORead/Write{8,16,32}):
//   * DIV mode 0 remains busy for at least 18 ARM9 cycles; modes 1/2/3 for
//     at least 34.  The serial fit-oriented engine can extend this to 32/64
//     hardware clocks when the arithmetic has not finished yet.
//   * SQRT remains busy for at least 13 ARM9 cycles.  Its serial engine can
//     extend this to 16/32 hardware clocks for 32/64-bit parameters.
//   * every supported control/operand write cancels and restarts its unit.
//   * byte operand/control writes and halfword operand writes are ignored.
//   * quotient, remainder and square-root result stay unchanged while busy.
//
// cycle_advance uses the existing ARM9 emulated-cycle credit seam. Arithmetic
// iterates on clk, while architectural time consumes the complete 8-bit credit
// atomically.  Completion waits for both the minimum DS credit deadline and
// the one-bit-per-clock arithmetic engine.  This intentionally trades exact
// first-beta DIV/SQRT timing for a much smaller datapath: one compare/subtract
// lane is reused instead of radix-4 divide and three-way square-root logic.
module nds_nitro_arm9_math_unit #(
    // The donor IO tree completes accesses from an address-claim wired OR,
    // rather than the two-cycle request/done protocol used by the legacy
    // bridge.  Keep the tested legacy behavior as the default and expose the
    // live register image only for the Nitro console island.
    parameter bit COMBINATIONAL_READ = 1'b0
) (
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
    logic [31:0] registered_read_data;
    // The legacy bridge holds request until the registered response and needs
    // the level guard. Nitro's wired-OR IO level is produced at clk1x but this
    // block runs at clk2x, so one physical access is sampled on two rising
    // edges. DMA may also keep ena continuously high while it changes from its
    // RD transaction to its WR transaction. Track that transaction signature:
    // stable samples dedupe, while address/RNW/size transitions remain distinct.
    // Update on unselected IO too, because an intervening non-math DMA read must
    // re-arm a repeated fixed-destination math write.
    logic product_signature_valid;
    logic [31:0] product_signature_address;
    logic product_signature_rnw;
    logic [1:0] product_signature_access;
    wire product_signature_changed = !product_signature_valid ||
        address != product_signature_address ||
        read_not_write != product_signature_rnw ||
        access != product_signature_access;
    wire bus_accept = request && selected &&
        (COMBINATIONAL_READ ? product_signature_changed : !bus_active);

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

    always_comb begin
        read_data = COMBINATIONAL_READ
            ? formatted_read_data : registered_read_data;
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
    logic [6:0] div_total_iterations;
    logic [6:0] div_iterations;
    logic [64:0] div_remainder_work;
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

    // Restoring unsigned divide, one quotient bit per clk.  Signed behavior
    // is handled only at the input/output boundaries, so the live datapath is
    // a single 65-bit compare/subtract lane with no divide, modulo, or wide
    // multiply operators.  div_quotient_work is the conventional combined
    // dividend/quotient shift register: unread dividend bits leave at the top
    // while completed quotient bits enter at the bottom.
    wire [64:0] div_shifted_remainder =
        (div_remainder_work << 1) |
        {{64{1'b0}}, div_quotient_work[63]};
    wire [64:0] div_denominator_extended =
        {1'b0, div_denominator_magnitude};
    wire div_step_subtract =
        div_shifted_remainder >= div_denominator_extended;
    wire [64:0] div_step_remainder = div_step_subtract
        ? div_shifted_remainder - div_denominator_extended
        : div_shifted_remainder;
    wire [63:0] div_step_quotient =
        {div_quotient_work[62:0], div_step_subtract};
    wire div_calculation_finishes_now = div_running &&
        !div_calculation_done &&
        div_iterations < div_total_iterations &&
        div_iterations + 1'b1 == div_total_iterations;
    wire [63:0] div_final_step_quotient = div_result_negative
        ? (~div_step_quotient + 64'd1) : div_step_quotient;
    wire [63:0] div_final_step_remainder = div_numerator_negative
        ? (~div_step_remainder[63:0] + 64'd1)
        : div_step_remainder[63:0];
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
    logic [33:0] sqrt_remainder_work;
    logic [31:0] sqrt_root_work;
    logic [3:0] sqrt_cycles_remaining;
    logic sqrt_time_done;
    logic sqrt_calculation_done;
    logic [31:0] sqrt_pending_result;

    // Digit-by-digit unsigned integer square root, one root bit per clk.  A
    // 34-bit remainder is sufficient for all 64 input bits and avoids the
    // duplicated three-iteration combinational network used previously.
    wire [33:0] sqrt_shifted_remainder =
        (sqrt_remainder_work << 2) |
        {{32{1'b0}}, sqrt_value_shift[63:62]};
    wire [31:0] sqrt_shifted_root =
        {sqrt_root_work[30:0], 1'b0};
    wire [33:0] sqrt_trial =
        ({2'd0, sqrt_shifted_root} << 1) + 34'd1;
    wire sqrt_step_subtract = sqrt_shifted_remainder >= sqrt_trial;
    wire [33:0] sqrt_step_remainder = sqrt_step_subtract
        ? sqrt_shifted_remainder - sqrt_trial
        : sqrt_shifted_remainder;
    wire [31:0] sqrt_step_root =
        {sqrt_shifted_root[31:1], sqrt_step_subtract};
    wire [63:0] sqrt_step_value =
        {sqrt_value_shift[61:0], 2'b00};
    wire sqrt_calculation_finishes_now = sqrt_running &&
        !sqrt_calculation_done &&
        sqrt_iterations < sqrt_total_iterations &&
        sqrt_iterations + 1'b1 == sqrt_total_iterations;
    wire sqrt_credit_finishes_now = sqrt_running && !sqrt_time_done &&
        cycle_advance_valid &&
        {1'b0, cycle_advance} >= {5'd0, sqrt_cycles_remaining};
    wire sqrt_time_ready_now = sqrt_time_done || sqrt_credit_finishes_now;
    wire sqrt_calculation_ready_now = sqrt_calculation_done ||
        sqrt_calculation_finishes_now;
    wire [31:0] sqrt_completion_result = sqrt_calculation_done
        ? sqrt_pending_result : sqrt_step_root;

    assign div_busy = div_cnt[15];
    assign sqrt_busy = sqrt_cnt[15];

    always_ff @(posedge clk) begin
        if (reset) begin
            bus_active <= 1'b0;
            bus_response_pending <= 1'b0;
            bus_response_read <= 1'b0;
            bus_read_address <= 32'd0;
            bus_read_access <= 2'd0;
            registered_read_data <= 32'd0;
            done <= 1'b0;
            product_signature_valid <= 1'b0;
            product_signature_address <= 32'd0;
            product_signature_rnw <= 1'b1;
            product_signature_access <= 2'd0;

            div_cnt <= 16'd0;
            div_numerator <= 64'd0;
            div_denominator <= 64'd0;
            div_quotient <= 64'd0;
            div_remainder <= 64'd0;
            div_running <= 1'b0;
            div_total_iterations <= 7'd32;
            div_iterations <= 7'd0;
            div_remainder_work <= 65'd0;
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
            sqrt_remainder_work <= 34'd0;
            sqrt_root_work <= 32'd0;
            sqrt_cycles_remaining <= 4'd0;
            sqrt_time_done <= 1'b0;
            sqrt_calculation_done <= 1'b0;
            sqrt_pending_result <= 32'd0;
        end else begin
            done <= 1'b0;

            if (!request) begin
                product_signature_valid <= 1'b0;
            end else if (product_signature_changed) begin
                product_signature_valid <= 1'b1;
                product_signature_address <= address;
                product_signature_rnw <= read_not_write;
                product_signature_access <= access;
            end

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
                    registered_read_data <= formatted_read_data;
                done <= 1'b1;
                bus_response_pending <= 1'b0;
            end else if (bus_active && !request) begin
                bus_active <= 1'b0;
            end

            // Arithmetic advances on clk_sys. Architectural time consumes a
            // complete 8-bit ARM9 credit atomically and saturates at zero.
            if (div_running) begin
                if (!div_calculation_done &&
                    div_iterations < div_total_iterations) begin
                    div_remainder_work <= div_step_remainder;
                    div_quotient_work <= div_step_quotient;
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
                div_total_iterations <= div_start_mode == 2'd0
                    ? 7'd32 : 7'd64;
                div_iterations <= 7'd0;
                div_remainder_work <= 65'd0;
                div_quotient_work <= div_start_mode == 2'd0
                    ? {div_start_numerator_magnitude[31:0], 32'd0}
                    : div_start_numerator_magnitude;
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
                    sqrt_value_shift <= sqrt_step_value;
                    sqrt_remainder_work <= sqrt_step_remainder;
                    sqrt_root_work <= sqrt_step_root;
                    sqrt_iterations <= sqrt_iterations + 1'b1;
                    if (sqrt_calculation_finishes_now) begin
                        sqrt_calculation_done <= 1'b1;
                        sqrt_pending_result <= sqrt_step_root;
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
                sqrt_remainder_work <= 34'd0;
                sqrt_root_work <= 32'd0;
                sqrt_cycles_remaining <= 4'd13;
                sqrt_time_done <= 1'b0;
                sqrt_calculation_done <= 1'b0;
                sqrt_pending_result <= 32'd0;
            end
        end
    end
endmodule
