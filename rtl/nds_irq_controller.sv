// Nintendo DS interrupt controller used by the isolated ETW candidates.
//
// The default-off ETW composition gives the FPGA time-master work a small,
// independently testable owner for the two CPUs' IME/IE/IF register banks.
//
// The CPU seam matches the existing local-memory convention:
//   access 00 = byte, 01 = halfword, 10 = word, 11 = invalid
//   narrow write data is right-justified and address[1:0] selects its lane.
// Reads are combinational from the live register state and are likewise
// right-justified.  In particular, IF has no cached/snapshot read interface.
//
// IF event ordering is deliberately source-set-wins.  On one clock edge the
// old IF value is first cleared by CPU W1C and an accepted ordered HPS CLEAR,
// then ORed with local timer events and an accepted ordered HPS SET.  Thus an
// interrupt source which asserts while its bit is being acknowledged or
// externally deasserted remains pending and cannot be lost.  This mirrors
// melonDS' exact SetIRQ/ClearIRQMask operation stream while preserving the DS
// hardware rule for a newly asserted source racing software acknowledgement.
// ARM9 GXFIFO is additionally level-derived: melonDS unconditionally calls
// GPU3D.CheckFIFOIRQ after every ARM9 IF write.  Strict explicit HPS bit-21
// SET/CLEAR records therefore own a persistent condition level, and an ARM9
// IF write reasserts bit 21 whenever the post-event level is true.

`timescale 1ns/1ps
`default_nettype none

module nds_irq_controller #(
    // Existing simulator-only compositions predate explicit SET/CLEAR. They
    // remain SET-only unless they deliberately opt into the exact operation
    // seam. Production ETW candidates explicitly opt into it.
    parameter logic EXPLICIT_HPS_EVENT_OPERATION = 1'b0
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        request,
    input  logic        cpu_is_arm9,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,
    output logic        done,

    // Locally generated events are already in this clock domain.  Each mask
    // is a one-cycle set request; holding or repeating a mask is idempotent.
    input  logic [31:0] timer9_set_mask,
    input  logic [31:0] timer7_set_mask,

    // One ordered HPS event transfer is accepted per clock.  The producer
    // retains VALID/data until READY, so successive accepted cycles preserve
    // stream order without an IF snapshot or event counter.
    input  logic        hps_event_valid,
    output logic        hps_event_ready,
    input  logic        hps_event_cpu_arm9,
    input  logic        hps_event_set,
    // Historical name retained so older simulator compositions need no broad
    // rewrite. In explicit mode this is the exact SET or CLEAR mask.
    input  logic [31:0] hps_event_set_mask,
    output logic        hps_event_accepted,
    output logic        hps_event_protocol_error,

    output logic [31:0] arm9_ime_state,
    output logic [31:0] arm9_ie_state,
    output logic [31:0] arm9_if_state,
    output logic [31:0] arm7_ime_state,
    output logic [31:0] arm7_ie_state,
    output logic [31:0] arm7_if_state,
    output logic        arm9_gxfifo_irq_level,
    output logic [31:0] arm9_pending,
    output logic [31:0] arm7_pending,
    output logic        irq_arm9,
    output logic        irq_arm7,
    output logic        arm7_wake
);
    localparam logic [31:0] REG_IME = 32'h04000208;
    localparam logic [31:0] REG_IE  = 32'h04000210;
    localparam logic [31:0] REG_IF  = 32'h04000214;
    localparam logic [31:0] ARM9_GXFIFO_IRQ_MASK = 32'h00200000;

    logic ime_hit;
    logic ie_hit;
    logic if_hit;
    logic register_hit;
    logic access_legal;
    logic write_fire;
    logic [31:0] selected_register;
    logic [31:0] write_lane_mask;
    logic [31:0] write_lane_data;
    logic [31:0] arm9_if_clear_mask;
    logic [31:0] arm7_if_clear_mask;
    logic hps_event_operation_known;
    logic hps_event_operation_set;
    logic hps_event_malformed;
    logic [31:0] hps_arm9_set_mask;
    logic [31:0] hps_arm7_set_mask;
    logic [31:0] hps_arm9_clear_mask;
    logic [31:0] hps_arm7_clear_mask;
    logic arm9_gxfifo_irq_level_next;
    logic [31:0] arm9_gxfifo_recheck_clear_mask;
    logic [31:0] arm9_gxfifo_reassert_mask;

    assign ime_hit = address[31:2] == REG_IME[31:2];
    assign ie_hit = address[31:2] == REG_IE[31:2];
    assign if_hit = address[31:2] == REG_IF[31:2];
    assign register_hit = ime_hit || ie_hit || if_hit;

    always_comb begin
        access_legal = 1'b0;
        case (access)
            2'b00: access_legal = 1'b1;
            2'b01: access_legal = address[0] == 1'b0;
            2'b10: access_legal = address[1:0] == 2'b00;
            default: access_legal = 1'b0;
        endcase
    end

    assign done = request && register_hit && access_legal &&
                  !hps_event_protocol_error && !hps_event_malformed;
    assign write_fire = done && !read_not_write;

    always_comb begin
        if (cpu_is_arm9) begin
            if (ime_hit)
                selected_register = arm9_ime_state;
            else if (ie_hit)
                selected_register = arm9_ie_state;
            else
                selected_register = arm9_if_state;
        end else begin
            if (ime_hit)
                selected_register = arm7_ime_state;
            else if (ie_hit)
                selected_register = arm7_ie_state;
            else
                selected_register = arm7_if_state;
        end
    end

    always_comb begin
        read_data = 32'h00000000;
        if (done && read_not_write) begin
            case (access)
                2'b00: begin
                    case (address[1:0])
                        2'd0: read_data[7:0] = selected_register[7:0];
                        2'd1: read_data[7:0] = selected_register[15:8];
                        2'd2: read_data[7:0] = selected_register[23:16];
                        default: read_data[7:0] = selected_register[31:24];
                    endcase
                end
                2'b01: begin
                    if (address[1])
                        read_data[15:0] = selected_register[31:16];
                    else
                        read_data[15:0] = selected_register[15:0];
                end
                2'b10: read_data = selected_register;
                default: read_data = 32'h00000000;
            endcase
        end
    end

    always_comb begin
        write_lane_mask = 32'h00000000;
        write_lane_data = 32'h00000000;
        case (access)
            2'b00: begin
                case (address[1:0])
                    2'd0: begin
                        write_lane_mask[7:0] = 8'hff;
                        write_lane_data[7:0] = write_data[7:0];
                    end
                    2'd1: begin
                        write_lane_mask[15:8] = 8'hff;
                        write_lane_data[15:8] = write_data[7:0];
                    end
                    2'd2: begin
                        write_lane_mask[23:16] = 8'hff;
                        write_lane_data[23:16] = write_data[7:0];
                    end
                    default: begin
                        write_lane_mask[31:24] = 8'hff;
                        write_lane_data[31:24] = write_data[7:0];
                    end
                endcase
            end
            2'b01: begin
                if (address[1]) begin
                    write_lane_mask[31:16] = 16'hffff;
                    write_lane_data[31:16] = write_data[15:0];
                end else begin
                    write_lane_mask[15:0] = 16'hffff;
                    write_lane_data[15:0] = write_data[15:0];
                end
            end
            2'b10: begin
                write_lane_mask = 32'hffffffff;
                write_lane_data = write_data;
            end
            default: begin
                write_lane_mask = 32'h00000000;
                write_lane_data = 32'h00000000;
            end
        endcase
    end

    always_comb begin
        arm9_if_clear_mask = 32'h00000000;
        arm7_if_clear_mask = 32'h00000000;
        if (write_fire && if_hit) begin
            if (cpu_is_arm9)
                arm9_if_clear_mask = write_lane_data & write_lane_mask;
            else
                arm7_if_clear_mask = write_lane_data & write_lane_mask;
        end
    end

    // Case equality is intentional in this simulator-first seam: an
    // unconnected/X explicit operation is not guessed to be SET. A zero-mask
    // ordered record is likewise malformed and latches the epoch closed.
    assign hps_event_operation_known =
        !EXPLICIT_HPS_EVENT_OPERATION ||
        (hps_event_set === 1'b0) || (hps_event_set === 1'b1);
    assign hps_event_malformed = EXPLICIT_HPS_EVENT_OPERATION &&
                                 hps_event_valid &&
                                 (!hps_event_operation_known ||
                                  hps_event_set_mask == 0);
    assign hps_event_ready = !reset && !hps_event_protocol_error &&
                             !hps_event_malformed;
    assign hps_event_accepted = hps_event_valid && hps_event_ready;
    assign hps_event_operation_set = EXPLICIT_HPS_EVENT_OPERATION
        ? hps_event_set : 1'b1;
    assign hps_arm9_set_mask =
        (hps_event_accepted && hps_event_cpu_arm9 &&
         hps_event_operation_set)
        ? hps_event_set_mask : 32'h00000000;
    assign hps_arm7_set_mask =
        (hps_event_accepted && !hps_event_cpu_arm9 &&
         hps_event_operation_set)
        ? hps_event_set_mask : 32'h00000000;
    assign hps_arm9_clear_mask =
        (hps_event_accepted && hps_event_cpu_arm9 &&
         !hps_event_operation_set)
        ? hps_event_set_mask : 32'h00000000;
    assign hps_arm7_clear_mask =
        (hps_event_accepted && !hps_event_cpu_arm9 &&
         !hps_event_operation_set)
        ? hps_event_set_mask : 32'h00000000;

    // Only the strict ETW operation stream owns this level. Legacy SET-only
    // simulator paths cannot represent its deassertion and deliberately leave
    // the level inert. The accepted operation is folded into NEXT before the
    // same edge's ARM9 IF write performs its unconditional CheckFIFOIRQ
    // equivalent.
    always_comb begin
        arm9_gxfifo_irq_level_next = arm9_gxfifo_irq_level;
        if (EXPLICIT_HPS_EVENT_OPERATION && hps_event_accepted &&
            hps_event_cpu_arm9 &&
            ((hps_event_set_mask & ARM9_GXFIFO_IRQ_MASK) != 0))
            arm9_gxfifo_irq_level_next = hps_event_operation_set;
    end
    assign arm9_gxfifo_recheck_clear_mask =
        (write_fire && if_hit && cpu_is_arm9)
        ? ARM9_GXFIFO_IRQ_MASK : 32'h00000000;
    assign arm9_gxfifo_reassert_mask =
        ((arm9_gxfifo_recheck_clear_mask != 0) &&
         arm9_gxfifo_irq_level_next)
        ? ARM9_GXFIFO_IRQ_MASK : 32'h00000000;

    assign arm9_pending = arm9_ie_state & arm9_if_state;
    assign arm7_pending = arm7_ie_state & arm7_if_state;
    // IME is a 32-bit I/O register with only bit zero architecturally
    // meaningful.  Upper-lane writes are legal no-ops and read back as zero.
    assign irq_arm9 = arm9_ime_state[0] && (|arm9_pending);
    assign irq_arm7 = arm7_ime_state[0] && (|arm7_pending);
    // ARM7 HALT wakeup observes enabled pending sources even while IME masks
    // delivery of the IRQ exception itself.
    assign arm7_wake = |arm7_pending;

    always_ff @(posedge clk) begin
        if (reset) begin
            arm9_ime_state <= 32'h00000000;
            arm9_ie_state <= 32'h00000000;
            arm9_if_state <= 32'h00000000;
            arm7_ime_state <= 32'h00000000;
            arm7_ie_state <= 32'h00000000;
            arm7_if_state <= 32'h00000000;
            arm9_gxfifo_irq_level <= 1'b0;
            hps_event_protocol_error <= 1'b0;
        end else if (hps_event_protocol_error) begin
            // An explicit-operation protocol fault freezes all architectural
            // state until the enclosing epoch reset. No later local input can
            // make a partially consumed malformed record appear successful.
            hps_event_protocol_error <= 1'b1;
        end else if (hps_event_malformed) begin
            // Reject the complete edge atomically: no MMIO, timer SET, or HPS
            // operation below is allowed to mutate architectural state.
            hps_event_protocol_error <= 1'b1;
        end else begin
            arm9_gxfifo_irq_level <= arm9_gxfifo_irq_level_next;

            if (write_fire && ime_hit && write_lane_mask[0]) begin
                if (cpu_is_arm9)
                    arm9_ime_state <= {31'h00000000, write_lane_data[0]};
                else
                    arm7_ime_state <= {31'h00000000, write_lane_data[0]};
            end

            if (write_fire && ie_hit) begin
                if (cpu_is_arm9)
                    arm9_ie_state <=
                        (arm9_ie_state & ~write_lane_mask) |
                        (write_lane_data & write_lane_mask);
                else
                    arm7_ie_state <=
                        (arm7_ie_state & ~write_lane_mask) |
                        (write_lane_data & write_lane_mask);
            end

            // Exact operation ordering on the accepted edge:
            //   1. CPU W1C and ordered HPS CLEAR remove old flags.
            //      Every ARM9 IF write also clears the old GXFIFO flag before
            //      the unconditional post-write level check.
            //   2. local timer SET, ordered HPS SET, and a true ARM9 GXFIFO
            //      post-operation level check assert flags.
            // W1C and CLEAR commute. Every same-bit SET wins over either
            // clear, matching a hardware source arriving during acknowledge.
            // HPS SET/CLEAR records arrive one at a time, so their producer
            // order is preserved exactly across successive accepted edges.
            arm9_if_state <=
                (arm9_if_state & ~arm9_if_clear_mask &
                 ~hps_arm9_clear_mask &
                 ~arm9_gxfifo_recheck_clear_mask) |
                timer9_set_mask | hps_arm9_set_mask |
                arm9_gxfifo_reassert_mask;
            arm7_if_state <=
                (arm7_if_state & ~arm7_if_clear_mask &
                 ~hps_arm7_clear_mask) |
                timer7_set_mask | hps_arm7_set_mask;
        end
    end
endmodule

`default_nettype wire
