// SPDX-License-Identifier: GPL-3.0-or-later
// Passive debug-only wall-time PC samples. No CPU/bus/IRQ control outputs.
// The existing H3D heartbeat beat publishes the coherent pair, without extra
// DDR transactions. The host must count each sequence once, and report loss.
module nds_arm9_pc_sampler #(
    parameter integer PERIOD = 60000,
    parameter integer JITTER_BITS = 12
) (
    input wire cpu_clk, cpu_reset,
    input wire [31:0] architectural_pc,
    input wire thumb, halted, dma_hold, guest_reset,
    input wire vblank_async,
    input wire ddr_clk, ddr_reset,
    output logic [31:0] pc = 0,
    output logic [31:0] metadata = 0
);
    // One outstanding request. Source holds the multi-bit payload until the
    // destination has acknowledged it by beginning the next request.
    logic request_toggle = 0, ack_toggle = 0;
    (* async_reg = "true" *) logic [1:0] request_sync = 0, ack_sync = 0;
    (* async_reg = "true" *) logic [1:0] vblank_sync = 0;
    logic vblank_last = 0;
    logic [15:0] frame = 0;
    logic [31:0] captured_pc = 0, captured_meta = 0;
    logic [7:0] sequence_number = 0;
    always_ff @(posedge cpu_clk) begin
        if (cpu_reset) begin
            request_sync <= 0; ack_toggle <= 0;
            vblank_sync <= 0; vblank_last <= 0; frame <= 0;
            captured_pc <= 0; captured_meta <= 0; sequence_number <= 0;
        end else begin
            request_sync <= {request_sync[0], request_toggle};
            vblank_sync <= {vblank_sync[0], vblank_async};
            vblank_last <= vblank_sync[1];
            if (guest_reset) frame <= 0;
            else if (vblank_sync[1] && !vblank_last) frame <= frame + 1'b1;
            if (request_sync[1] != ack_toggle) begin
                captured_pc <= architectural_pc;
                captured_meta <= {4'hb, guest_reset, halted, dma_hold, thumb,
                                  frame, sequence_number};
                sequence_number <= sequence_number + 1'b1;
                ack_toggle <= request_sync[1];
            end
        end
    end
    logic pending = 0;
    integer countdown = PERIOD;
    logic [15:0] random_phase = 16'h4e53;
    always_ff @(posedge ddr_clk) begin
        if (ddr_reset) begin
            request_toggle <= 0; ack_sync <= 0; pending <= 0;
            countdown <= PERIOD; random_phase <= 16'h4e53;
            pc <= 0; metadata <= 0;
        end else begin
            ack_sync <= {ack_sync[0], ack_toggle};
            if (pending && ack_sync[1] == request_toggle) begin
                // Payload has been stable throughout the ack synchronizer.
                pc <= captured_pc; metadata <= captured_meta; pending <= 0;
            end else if (!pending) begin
                if (countdown == 0) begin
                    request_toggle <= !request_toggle; pending <= 1;
                    random_phase <= {random_phase[14:0], random_phase[15] ^
                        random_phase[13] ^ random_phase[12] ^ random_phase[10]};
                    countdown <= PERIOD + integer'(random_phase[JITTER_BITS-1:0]);
                end else countdown <= countdown - 1;
            end
        end
    end
endmodule
