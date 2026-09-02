// r211-only passive witness for the ARM9 KEYINPUT consumption path.
//
// The observer never drives or gates the mailbox, CPU, input, or retirement
// seams.  It recognizes one exact ARM9 halfword read of KEYINPUT, snapshots
// the value visible only when the HPS mailbox and CPU bus complete on the
// same edge with the target request's exact fence, then records the first and
// a later retired ARM9 PC. A newer transaction before completion fails closed.
//
// The serializer emits one atomic 32-bit page over four held phases:
//   [15:0]  latest known mailbox/CPU KEYINPUT response
//   [23:16] retirements observed for this witness
//   [31:24] request/mailbox/CPU/match/first/later/PC-change/error-free flags
//
// F0 means that the atomic snapshot is absent or a sticky fault invalidated
// it. F1 publishes the last complete witness; its payload and exact first/
// later PC outputs remain frozen across newer incomplete requests. Physical
// joystick bits 11:0 pass through without substitution.
`timescale 1ns/1ps
`default_nettype none

module nds_r211_keyinput_consumption_observer #(
    parameter integer LATER_RETIRE_COUNT = 8
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        mailbox_request,
    input  logic [31:0] mailbox_address,
    input  logic        mailbox_read_not_write,
    input  logic [1:0]  mailbox_access,
    input  logic        mailbox_cpu_arm9,
    input  logic [31:0] mailbox_fence_sequence,
    input  logic        mailbox_done,
    input  logic [31:0] mailbox_completed_fence_sequence,

    input  logic [31:0] cpu9_rdata,
    input  logic        cpu9_done,
    input  logic        cpu9_cycles_valid,
    input  logic [31:0] cpu9_debug_pc_raw,
    input  logic [11:0] joystick,

    output logic        target_active,
    output logic        mailbox_completion_seen,
    output logic        cpu_completion_seen,
    output logic        first_retire_seen,
    output logic        later_retire_seen,
    output logic        observer_fault_seen,
    output logic        witness_complete,
    output logic [7:0]  target_request_count,
    output logic [7:0]  mailbox_completion_count,
    output logic [7:0]  cpu_completion_count,
    output logic [7:0]  retirement_event_count,
    output logic [7:0]  abandoned_witness_count,
    output logic [7:0]  witness_retire_count,
    output logic [11:0] request_joystick,
    output logic [31:0] request_pc,
    output logic [31:0] request_fence_sequence,
    output logic [31:0] completion_fence_sequence,
    output logic [31:0] mailbox_response,
    output logic [31:0] cpu_response,
    output logic [31:0] first_retire_pc,
    output logic [31:0] later_retire_pc,
    output logic [31:0] diagnostic_payload,
    output logic        completed_valid,
    output logic [31:0] completed_payload,
    output logic [31:0] completed_first_retire_pc,
    output logic [31:0] completed_later_retire_pc
);
    logic request_armed;
    logic witness_error;
    logic request_fields_known;
    logic request_pc_known;
    logic request_joystick_known;
    logic response_values_known;
    logic response_values_match;
    logic retire_pcs_known;
    logic retire_pc_changed;
    logic request_launch;
    logic start_target;
    logic post_completion_retirement_window;
    logic accept_target_start;
    logic completion_pair_valid;
    logic [7:0] diagnostic_status;
    logic [15:0] diagnostic_response;
    localparam logic [7:0] LATER_RETIRE_THRESHOLD =
        LATER_RETIRE_COUNT[7:0] - 8'd1;

    function automatic logic [7:0] saturating_increment (
        input logic [7:0] value
    );
        begin
            saturating_increment = (&value) ? value : value + 1'b1;
        end
    endfunction

    assign request_fields_known =
        (^mailbox_address !== 1'bx) &&
        (mailbox_read_not_write === 1'b0 ||
         mailbox_read_not_write === 1'b1) &&
        (^mailbox_access !== 1'bx) &&
        (mailbox_cpu_arm9 === 1'b0 ||
         mailbox_cpu_arm9 === 1'b1) &&
        (^mailbox_fence_sequence !== 1'bx);
    assign request_pc_known = (^cpu9_debug_pc_raw !== 1'bx);
    assign request_joystick_known = (^joystick !== 1'bx);

    // Case equality ensures an unknown qualifier can never manufacture an
    // exact KEYINPUT request.
    assign request_launch =
        request_armed &&
        mailbox_request === 1'b1;
    assign start_target =
        request_launch &&
        request_fields_known &&
        mailbox_address === 32'h0400_0130 &&
        mailbox_read_not_write === 1'b1 &&
        mailbox_access === 2'd1 &&
        mailbox_cpu_arm9 === 1'b1;
    assign post_completion_retirement_window =
        target_active &&
        mailbox_completion_seen &&
        cpu_completion_seen &&
        !witness_complete;
    assign accept_target_start =
        start_target &&
        !post_completion_retirement_window;
    assign completion_pair_valid =
        mailbox_done === 1'b1 &&
        cpu9_done === 1'b1 &&
        (^cpu9_rdata !== 1'bx) &&
        (^mailbox_completed_fence_sequence !== 1'bx) &&
        mailbox_completed_fence_sequence === request_fence_sequence;

    assign response_values_known =
        (^mailbox_response !== 1'bx) &&
        (^cpu_response !== 1'bx);
    assign response_values_match =
        mailbox_completion_seen &&
        cpu_completion_seen &&
        response_values_known &&
        mailbox_response === cpu_response;
    assign retire_pcs_known =
        (^first_retire_pc !== 1'bx) &&
        (^later_retire_pc !== 1'bx);
    assign retire_pc_changed =
        first_retire_seen &&
        later_retire_seen &&
        retire_pcs_known &&
        first_retire_pc != later_retire_pc;

    assign diagnostic_status = {
        target_active === 1'b1,
        mailbox_completion_seen === 1'b1,
        cpu_completion_seen === 1'b1,
        response_values_match === 1'b1,
        first_retire_seen === 1'b1,
        later_retire_seen === 1'b1,
        retire_pc_changed === 1'b1,
        witness_error === 1'b0 &&
            observer_fault_seen === 1'b0
    };
    assign diagnostic_response =
        cpu_completion_seen === 1'b1 &&
        (^cpu_response !== 1'bx) ? cpu_response[15:0] :
        mailbox_completion_seen === 1'b1 &&
        (^mailbox_response !== 1'bx) ? mailbox_response[15:0] :
        16'd0;
    assign diagnostic_payload = {
        diagnostic_status,
        witness_retire_count,
        diagnostic_response
    };

    assign witness_complete =
        target_active === 1'b1 &&
        mailbox_completion_seen === 1'b1 &&
        cpu_completion_seen === 1'b1 &&
        response_values_match === 1'b1 &&
        first_retire_seen === 1'b1 &&
        later_retire_seen === 1'b1 &&
        witness_error === 1'b0 &&
        observer_fault_seen === 1'b0;

    initial begin
        if (LATER_RETIRE_COUNT < 2 || LATER_RETIRE_COUNT > 255)
            $fatal(1, "LATER_RETIRE_COUNT must be in 2..255");
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            request_armed <= 1'b1;
            target_active <= 1'b0;
            mailbox_completion_seen <= 1'b0;
            cpu_completion_seen <= 1'b0;
            first_retire_seen <= 1'b0;
            later_retire_seen <= 1'b0;
            observer_fault_seen <= 1'b0;
            witness_error <= 1'b0;

            target_request_count <= 8'd0;
            mailbox_completion_count <= 8'd0;
            cpu_completion_count <= 8'd0;
            retirement_event_count <= 8'd0;
            abandoned_witness_count <= 8'd0;
            witness_retire_count <= 8'd0;

            request_joystick <= 12'd0;
            request_pc <= 32'd0;
            request_fence_sequence <= 32'd0;
            completion_fence_sequence <= 32'd0;
            mailbox_response <= 32'd0;
            cpu_response <= 32'd0;
            first_retire_pc <= 32'd0;
            later_retire_pc <= 32'd0;
            completed_valid <= 1'b0;
            completed_payload <= 32'd0;
            completed_first_retire_pc <= 32'd0;
            completed_later_retire_pc <= 32'd0;
        end else begin
            // A sticky observer fault invalidates, but never tears down, the
            // last atomically captured completed witness.
            if (observer_fault_seen)
                completed_valid <= 1'b0;

            // One armed edge represents one mailbox transaction even when the
            // request remains asserted until completion.
            if (mailbox_request === 1'b0) begin
                request_armed <= 1'b1;
            end else if (mailbox_request === 1'b1) begin
                if (request_armed && !request_fields_known) begin
                    observer_fault_seen <= 1'b1;
                    completed_valid <= 1'b0;
                end
                request_armed <= 1'b0;
            end else begin
                request_armed <= 1'b0;
                observer_fault_seen <= 1'b1;
                completed_valid <= 1'b0;
            end

            if (accept_target_start) begin
                if (target_active && !witness_complete) begin
                    abandoned_witness_count <=
                        saturating_increment(abandoned_witness_count);
                    observer_fault_seen <= 1'b1;
                    completed_valid <= 1'b0;
                end

                target_request_count <=
                    saturating_increment(target_request_count);
                target_active <= 1'b1;
                mailbox_completion_seen <= 1'b0;
                cpu_completion_seen <= 1'b0;
                first_retire_seen <= 1'b0;
                later_retire_seen <= 1'b0;
                witness_error <= target_active && !witness_complete;
                witness_retire_count <= 8'd0;

                request_joystick <= joystick;
                request_pc <= cpu9_debug_pc_raw;
                request_fence_sequence <= mailbox_fence_sequence;
                completion_fence_sequence <= 32'd0;
                mailbox_response <= 32'd0;
                cpu_response <= 32'd0;
                first_retire_pc <= 32'd0;
                later_retire_pc <= 32'd0;

                if (!request_pc_known || !request_joystick_known) begin
                    witness_error <= 1'b1;
                    observer_fault_seen <= 1'b1;
                    completed_valid <= 1'b0;
                end
            end else if (request_launch &&
                         target_active &&
                         !witness_complete &&
                         !(mailbox_completion_seen &&
                           cpu_completion_seen)) begin
                // The mailbox is serialized. Any newer transaction before
                // the target's exact completion destroys transaction
                // identity; never let that newer response satisfy KEYINPUT.
                target_active <= 1'b0;
                witness_error <= 1'b1;
                observer_fault_seen <= 1'b1;
                completed_valid <= 1'b0;
                abandoned_witness_count <=
                    saturating_increment(abandoned_witness_count);
            end else if (target_active && !witness_complete) begin
                // The ARM9 bus and memory-system mailbox expose the same
                // ext_done edge. A complete witness therefore requires both
                // done indications on one edge and the exact fence captured
                // at the target request. Separated, unknown, or wrong-fence
                // completion is diagnostic evidence, but can never become F1.
                if (!mailbox_completion_seen ||
                    !cpu_completion_seen) begin
                    if (mailbox_done === 1'b1 &&
                        !mailbox_completion_seen) begin
                        mailbox_completion_seen <= 1'b1;
                        mailbox_completion_count <= saturating_increment(
                            mailbox_completion_count);
                        if (^cpu9_rdata !== 1'bx) begin
                            mailbox_response <= cpu9_rdata;
                        end else begin
                            witness_error <= 1'b1;
                            observer_fault_seen <= 1'b1;
                            completed_valid <= 1'b0;
                        end
                    end

                    if (cpu9_done === 1'b1 &&
                        !cpu_completion_seen) begin
                        cpu_completion_seen <= 1'b1;
                        cpu_completion_count <= saturating_increment(
                            cpu_completion_count);
                        if (^cpu9_rdata !== 1'bx) begin
                            cpu_response <= cpu9_rdata;
                        end else begin
                            witness_error <= 1'b1;
                            observer_fault_seen <= 1'b1;
                            completed_valid <= 1'b0;
                        end
                    end

                    if (mailbox_done !== 1'b0 ||
                        cpu9_done !== 1'b0) begin
                        if (^mailbox_completed_fence_sequence !== 1'bx)
                            completion_fence_sequence <=
                                mailbox_completed_fence_sequence;
                        if (!completion_pair_valid) begin
                            witness_error <= 1'b1;
                            observer_fault_seen <= 1'b1;
                            completed_valid <= 1'b0;
                        end
                    end
                end

                // The load may retire on the same edge that cpu9_done is
                // asserted, so treat that edge as consumption-eligible.
                if (cpu_completion_seen || completion_pair_valid) begin
                    if (cpu9_cycles_valid === 1'b1) begin
                        if (^cpu9_debug_pc_raw !== 1'bx) begin
                            if (!later_retire_seen) begin
                                witness_retire_count <=
                                    saturating_increment(
                                        witness_retire_count);
                                retirement_event_count <=
                                    saturating_increment(
                                        retirement_event_count);
                                if (!first_retire_seen) begin
                                    first_retire_seen <= 1'b1;
                                    first_retire_pc <= cpu9_debug_pc_raw;
                                end
                                if (witness_retire_count >=
                                    LATER_RETIRE_THRESHOLD) begin
                                    later_retire_seen <= 1'b1;
                                    later_retire_pc <= cpu9_debug_pc_raw;

                                    // Freeze all externally consumed fields on
                                    // the exact threshold retirement. They
                                    // remain stable through later requests
                                    // until a newer complete witness replaces
                                    // them or a sticky fault clears valid.
                                    if (mailbox_completion_seen &&
                                        cpu_completion_seen &&
                                        response_values_match &&
                                        first_retire_seen &&
                                        !witness_error &&
                                        !observer_fault_seen &&
                                        (^first_retire_pc !== 1'bx)) begin
                                        completed_valid <= 1'b1;
                                        completed_payload <= {
                                            6'b11_1111,
                                            first_retire_pc !=
                                                cpu9_debug_pc_raw,
                                            1'b1,
                                            saturating_increment(
                                                witness_retire_count),
                                            cpu_response[15:0]
                                        };
                                        completed_first_retire_pc <=
                                            first_retire_pc;
                                        completed_later_retire_pc <=
                                            cpu9_debug_pc_raw;
                                    end
                                end
                            end
                        end else begin
                            witness_error <= 1'b1;
                            observer_fault_seen <= 1'b1;
                            completed_valid <= 1'b0;
                        end
                    end else if (cpu9_cycles_valid !== 1'b0) begin
                        witness_error <= 1'b1;
                        observer_fault_seen <= 1'b1;
                        completed_valid <= 1'b0;
                    end
                end
            end
        end
    end
endmodule


module nds_r211_keyinput_consumption_serializer #(
    parameter integer PHASE_DIVIDER_WIDTH = 15
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        witness_complete,
    input  logic [31:0] live_payload,
    input  logic [11:0] joystick,

    output logic [1:0]  diagnostic_phase,
    output logic [7:0]  diagnostic_marker,
    output logic [31:0] diagnostic_snapshot,
    output logic        diagnostic_snapshot_strobe,
    output logic [31:0] diagnostic_word
);
    logic [PHASE_DIVIDER_WIDTH-1:0] phase_divider;
    logic [31:0] shifted_snapshot;
    logic [7:0] rotated_byte;

    assign shifted_snapshot =
        diagnostic_snapshot >> (diagnostic_phase * 8);
    assign rotated_byte = shifted_snapshot[7:0];
    assign diagnostic_word = {
        diagnostic_marker,
        1'b0,
        diagnostic_phase,
        1'b0,
        rotated_byte,
        joystick
    };

    initial begin
        if (PHASE_DIVIDER_WIDTH < 1)
            $fatal(1, "PHASE_DIVIDER_WIDTH must be positive");
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            phase_divider <= '0;
            diagnostic_phase <= 2'd0;
            diagnostic_marker <= 8'hf0;
            diagnostic_snapshot <= 32'd0;
            diagnostic_snapshot_strobe <= 1'b0;
        end else begin
            diagnostic_snapshot_strobe <= 1'b0;
            if (&phase_divider) begin
                phase_divider <= '0;
                if (diagnostic_phase == 2'd3) begin
                    // Payload and completion marker are captured together.
                    // They remain immutable for the following four phases.
                    diagnostic_phase <= 2'd0;
                    diagnostic_snapshot <=
                        (^live_payload !== 1'bx) ?
                        live_payload : 32'd0;
                    diagnostic_marker <=
                        witness_complete === 1'b1 &&
                        (^live_payload !== 1'bx) &&
                        (^joystick !== 1'bx) ? 8'hf1 : 8'hf0;
                    diagnostic_snapshot_strobe <= 1'b1;
                end else begin
                    diagnostic_phase <= diagnostic_phase + 1'b1;
                end
            end else begin
                phase_divider <= phase_divider + 1'b1;
            end
        end
    end
endmodule


module nds_r211_keyinput_consumption_diagnostic #(
    parameter integer LATER_RETIRE_COUNT = 8,
    parameter integer PHASE_DIVIDER_WIDTH = 15
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        mailbox_request,
    input  logic [31:0] mailbox_address,
    input  logic        mailbox_read_not_write,
    input  logic [1:0]  mailbox_access,
    input  logic        mailbox_cpu_arm9,
    input  logic [31:0] mailbox_fence_sequence,
    input  logic        mailbox_done,
    input  logic [31:0] mailbox_completed_fence_sequence,
    input  logic [31:0] cpu9_rdata,
    input  logic        cpu9_done,
    input  logic        cpu9_cycles_valid,
    input  logic [31:0] cpu9_debug_pc_raw,
    input  logic [11:0] joystick,

    output logic        target_active,
    output logic        mailbox_completion_seen,
    output logic        cpu_completion_seen,
    output logic        first_retire_seen,
    output logic        later_retire_seen,
    output logic        observer_fault_seen,
    output logic        witness_complete,
    output logic [7:0]  target_request_count,
    output logic [7:0]  mailbox_completion_count,
    output logic [7:0]  cpu_completion_count,
    output logic [7:0]  retirement_event_count,
    output logic [7:0]  abandoned_witness_count,
    output logic [7:0]  witness_retire_count,
    output logic [11:0] request_joystick,
    output logic [31:0] request_pc,
    output logic [31:0] request_fence_sequence,
    output logic [31:0] completion_fence_sequence,
    output logic [31:0] mailbox_response,
    output logic [31:0] cpu_response,
    output logic [31:0] first_retire_pc,
    output logic [31:0] later_retire_pc,
    output logic [31:0] diagnostic_payload,
    output logic        completed_valid,
    output logic [31:0] completed_payload,
    output logic [31:0] completed_first_retire_pc,
    output logic [31:0] completed_later_retire_pc,
    output logic [1:0]  diagnostic_phase,
    output logic [7:0]  diagnostic_marker,
    output logic [31:0] diagnostic_snapshot,
    output logic        diagnostic_snapshot_strobe,
    output logic [31:0] diagnostic_word
);
    nds_r211_keyinput_consumption_observer #(
        .LATER_RETIRE_COUNT(LATER_RETIRE_COUNT)
    ) observer (
        .*
    );

    nds_r211_keyinput_consumption_serializer #(
        .PHASE_DIVIDER_WIDTH(PHASE_DIVIDER_WIDTH)
    ) serializer (
        .clk,
        .reset,
        .witness_complete(completed_valid),
        .live_payload(completed_payload),
        .joystick,
        .diagnostic_phase,
        .diagnostic_marker,
        .diagnostic_snapshot,
        .diagnostic_snapshot_strobe,
        .diagnostic_word
    );
endmodule

`default_nettype wire
