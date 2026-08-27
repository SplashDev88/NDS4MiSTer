// Simulator-first, fail-closed shadow for the ARM7 firmware-SPI BUSY poll.
//
// This block does not emulate SPI completion, clear BUSY, or raise IRQ_SPI.
// It may answer only the strictly pre-deadline halfword read of SPICNT.  The
// first read at or beyond the deadline is deliberately left to the HPS model,
// which remains authoritative for completion, device state, and interrupts.
//
// Feed completed_write_* only after the matching external ARM7 write has been
// accepted/completed.  arm7_cycle_delta must contain only real accumulated
// ARM7 CPU cycles; reads and wall-clock time must never drive that input.
// Narrow completed-write data is right-justified.

`timescale 1ns/1ps
`default_nettype none

module nds_arm7_firmware_spi_busy_shadow (
    input  logic        clk,
    input  logic        reset,

    input  logic        completed_write_valid,
    input  logic        completed_write_cpu_arm9,
    // 00=byte, 01=halfword, 10=word, 11=invalid.
    input  logic [1:0]  completed_write_access,
    input  logic [31:0] completed_write_address,
    input  logic [31:0] completed_write_data,

    input  logic        arm7_cycle_delta_valid,
    input  logic [31:0] arm7_cycle_delta,

    input  logic        read_request_valid,
    input  logic        read_request_cpu_arm9,
    // 00=byte, 01=halfword, 10=word, 11=invalid.
    input  logic [1:0]  read_request_access,
    input  logic [31:0] read_request_address,
    output logic        local_read_hit,
    output logic [31:0] local_read_data,

    // Observation-only outputs for directed simulation and a possible later
    // integration review.  shadow_valid means the cached control is exact;
    // a local hit additionally requires remaining_cycles != 0.
    output logic        shadow_valid,
    output logic [15:0] cached_spicnt,
    output logic [9:0]  remaining_cycles,
    // Sticky because this standalone prototype has no authoritative HPS
    // idle/completion resynchronization input.  Only reset clears it.
    output logic        authority_lost
);
    localparam logic [31:0] SPICNT_ADDRESS  = 32'h0400_01c0;
    localparam logic [31:0] SPIDATA_ADDRESS = 32'h0400_01c2;
    localparam logic [15:0] SPICNT_WRITABLE = 16'hcf03;

    logic        shadow_valid_next;
    logic [15:0] cached_spicnt_next;
    logic [9:0]  remaining_cycles_next;
    logic        authority_lost_next;
    logic        read_predeadline_after_credit;

    // X detection is a simulation-only safety net.  In synthesized hardware
    // every input bit is two-state, so these helpers deliberately collapse to
    // constants instead of asking Quartus to interpret four-state operators.
    function automatic logic vector_known_32(input logic [31:0] value);
`ifdef SYNTHESIS
        vector_known_32 = 1'b1;
`else
        vector_known_32 = (^value !== 1'bx);
`endif
    endfunction

    function automatic logic vector_known_16(input logic [15:0] value);
`ifdef SYNTHESIS
        vector_known_16 = 1'b1;
`else
        vector_known_16 = (^value !== 1'bx);
`endif
    endfunction

    function automatic logic vector_known_8(input logic [7:0] value);
`ifdef SYNTHESIS
        vector_known_8 = 1'b1;
`else
        vector_known_8 = (^value !== 1'bx);
`endif
    endfunction

    function automatic logic [9:0] transfer_cycles(
        input logic [1:0] baud_rate
    );
        case (baud_rate)
            2'b00: transfer_cycles = 10'd64;
            2'b01: transfer_cycles = 10'd128;
            2'b10: transfer_cycles = 10'd256;
            2'b11: transfer_cycles = 10'd512;
            default: transfer_cycles = 10'd0;
        endcase
    endfunction

    // Cycle credit is applied before a completed bus write on the same edge:
    // the credit belongs to execution preceding that completed request.  This
    // also permits a new SPIDATA write on the exact edge an older transfer
    // reaches its HPS-owned deadline without charging old cycles to the new
    // transfer.
    always_comb begin
        shadow_valid_next = shadow_valid;
        cached_spicnt_next = cached_spicnt;
        remaining_cycles_next = remaining_cycles;
        authority_lost_next = authority_lost;

        if (arm7_cycle_delta_valid) begin
                if (shadow_valid_next && remaining_cycles_next != 0) begin
                    if (!vector_known_32(arm7_cycle_delta)) begin
                        shadow_valid_next = 1'b0;
                        cached_spicnt_next = 16'd0;
                        remaining_cycles_next = 10'd0;
                        authority_lost_next = 1'b1;
                    end else if (arm7_cycle_delta >=
                                 {22'd0, remaining_cycles_next}) begin
                        // Do not synthesize completion.  Retain the exact
                        // configuration only so a later completed SPIDATA
                        // write can begin another pre-deadline interval.
                        remaining_cycles_next = 10'd0;
                    end else begin
                        remaining_cycles_next = remaining_cycles_next -
                            arm7_cycle_delta[9:0];
                    end
                end
        end
`ifndef SYNTHESIS
        else if (arm7_cycle_delta_valid !== 1'b0) begin
            // An unknown cycle-valid may conceal elapsed transfer time.
            if (shadow_valid_next && remaining_cycles_next != 0) begin
                shadow_valid_next = 1'b0;
                cached_spicnt_next = 16'd0;
                remaining_cycles_next = 10'd0;
                authority_lost_next = 1'b1;
            end
        end
`endif

        if (completed_write_valid) begin
                if (authority_lost_next) begin
                    // No accepted write proves that an earlier ambiguous or
                    // interrupted transfer has completed.  Stay fail-closed
                    // until reset (or a future explicit HPS resync input).
                    shadow_valid_next = 1'b0;
                    cached_spicnt_next = 16'd0;
                    remaining_cycles_next = 10'd0;
                end else if (!vector_known_32(completed_write_address)) begin
                    // The write may alias SPICNT/SPIDATA.
                    shadow_valid_next = 1'b0;
                    cached_spicnt_next = 16'd0;
                    remaining_cycles_next = 10'd0;
                    authority_lost_next = 1'b1;
                end else if (completed_write_address >= SPICNT_ADDRESS &&
                             completed_write_address <=
                                 (SPIDATA_ADDRESS + 32'd1)) begin
`ifndef SYNTHESIS
                    if (completed_write_cpu_arm9 !== 1'b0 &&
                        completed_write_cpu_arm9 !== 1'b1) begin
                        // The write may be from ARM7.
                        shadow_valid_next = 1'b0;
                        cached_spicnt_next = 16'd0;
                        remaining_cycles_next = 10'd0;
                        authority_lost_next = 1'b1;
                    end else
`endif
                    if (completed_write_cpu_arm9) begin
                        // Firmware SPI belongs only to ARM7.  An ARM9 access
                        // cannot alter this ARM7-local shadow.
                    end else begin
                            if (completed_write_address == SPICNT_ADDRESS &&
                                completed_write_access == 2'b01 &&
                                vector_known_16(
                                    completed_write_data[15:0])) begin
                                if (remaining_cycles_next != 0) begin
                                    // melonDS permits SPICNT changes during a
                                    // transfer.  Rather than predict their
                                    // completion/IRQ consequences, fail closed.
                                    shadow_valid_next = 1'b0;
                                    cached_spicnt_next = 16'd0;
                                    remaining_cycles_next = 10'd0;
                                    authority_lost_next = 1'b1;
                                end else if (
                                    completed_write_data[15] == 1'b1 &&
                                    completed_write_data[14] == 1'b0) begin
                                    shadow_valid_next = 1'b1;
                                    cached_spicnt_next =
                                        completed_write_data[15:0] &
                                        SPICNT_WRITABLE;
                                    remaining_cycles_next = 10'd0;
                                end else if (
                                    completed_write_data[15] == 1'b0 &&
                                    completed_write_data[14] == 1'b0) begin
                                    // A completed idle disable is an exact,
                                    // HPS-observed session boundary.  Drop the
                                    // inactive cache without poisoning a later
                                    // completed safe enable/reseed.
                                    shadow_valid_next = 1'b0;
                                    cached_spicnt_next = 16'd0;
                                    remaining_cycles_next = 10'd0;
                                end else begin
                                    // IRQ-enabled modes stay HPS authoritative
                                    // until reset; their completion interrupt
                                    // cannot be predicted by this shadow.
                                    shadow_valid_next = 1'b0;
                                    cached_spicnt_next = 16'd0;
                                    remaining_cycles_next = 10'd0;
                                    authority_lost_next = 1'b1;
                                end
                            end else if (
                                completed_write_address == SPIDATA_ADDRESS &&
                                (completed_write_access == 2'b00 ||
                                 completed_write_access == 2'b01) &&
                                ((completed_write_access == 2'b00 &&
                                  vector_known_8(
                                      completed_write_data[7:0])) ||
                                 (completed_write_access == 2'b01 &&
                                  vector_known_16(
                                      completed_write_data[15:0])))) begin
                                if (shadow_valid_next &&
                                    remaining_cycles_next == 0 &&
                                    cached_spicnt_next[15] == 1'b1 &&
                                    cached_spicnt_next[14] == 1'b0) begin
                                    remaining_cycles_next = transfer_cycles(
                                        cached_spicnt_next[1:0]);
                                end
                                // A known SPIDATA write while BUSY is ignored,
                                // matching the HPS model's WriteData behavior.
                            end else begin
                                // Byte/word/misaligned control writes, word or
                                // misaligned data writes, and unknown payloads
                                // are not safe to mirror.
                                shadow_valid_next = 1'b0;
                                cached_spicnt_next = 16'd0;
                                remaining_cycles_next = 10'd0;
                                authority_lost_next = 1'b1;
                            end
                    end
                end
                // Known writes outside the firmware-SPI register pair cannot
                // affect this shadow and are ignored.
        end
`ifndef SYNTHESIS
        else if (completed_write_valid !== 1'b0) begin
            // An unknown completed-write valid may conceal a relevant control
            // transition or transfer start.
            if (shadow_valid_next) begin
                shadow_valid_next = 1'b0;
                cached_spicnt_next = 16'd0;
                remaining_cycles_next = 10'd0;
            end
            authority_lost_next = 1'b1;
        end
`endif
    end

    // A cycle delta is authoritative for execution preceding the current bus
    // request.  Therefore local-hit eligibility must use the post-credit
    // remaining time combinationally, not wait for the registering edge.  An
    // exact deadline or overshoot is always forwarded to HPS.
    always_comb begin
        read_predeadline_after_credit = 1'b0;
        if (remaining_cycles != 0) begin
`ifndef SYNTHESIS
            if (arm7_cycle_delta_valid !== 1'b0 &&
                arm7_cycle_delta_valid !== 1'b1) begin
                read_predeadline_after_credit = 1'b0;
            end else
`endif
            if (!arm7_cycle_delta_valid) begin
                read_predeadline_after_credit = 1'b1;
            end else if (vector_known_32(arm7_cycle_delta) &&
                         arm7_cycle_delta < {22'd0, remaining_cycles}) begin
                read_predeadline_after_credit = 1'b1;
            end
        end
    end

    always_comb begin
        local_read_hit = 1'b0;
        local_read_data = 32'd0;

        if (!reset && read_request_valid && !read_request_cpu_arm9 &&
            read_request_access == 2'b01 &&
            vector_known_32(read_request_address) &&
            read_request_address == SPICNT_ADDRESS &&
            shadow_valid && !authority_lost && !cached_spicnt[14] &&
            read_predeadline_after_credit) begin
            local_read_hit = 1'b1;
            local_read_data = {16'd0, cached_spicnt | 16'h0080};
        end
    end

    always_ff @(posedge clk) begin
        // Unknown reset is fail-closed only in four-state simulation.  The
        // synthesized branch is an ordinary deterministic active-high reset.
`ifndef SYNTHESIS
        if (reset !== 1'b0 && reset !== 1'b1) begin
            shadow_valid <= 1'b0;
            cached_spicnt <= 16'd0;
            remaining_cycles <= 10'd0;
            authority_lost <= 1'b0;
        end else
`endif
        if (reset) begin
            shadow_valid <= 1'b0;
            cached_spicnt <= 16'd0;
            remaining_cycles <= 10'd0;
            authority_lost <= 1'b0;
        end else begin
            shadow_valid <= shadow_valid_next;
            cached_spicnt <= cached_spicnt_next;
            remaining_cycles <= remaining_cycles_next;
            authority_lost <= authority_lost_next;
        end
    end
endmodule

`default_nettype wire
