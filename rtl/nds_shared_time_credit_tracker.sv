// Reconstructs the canonical Nintendo DS shared scheduler timestamp from the
// per-CPU cycle credits actually published to the HPS model.
//
// melonDS advances shared LCD/audio/DMA time to:
//   min(normalized ARM9 timestamp, ARM7 timestamp)
// so raw retirement streams must not be summed or selected independently.
// Feed this block normalized credits only at the point the HPS scheduler has
// consumed them in causal order, including synthetic halt ticks. The current
// RTL does not expose that literal seam yet: posted ring-space admission is
// earlier than commit/consumption, and mailbox launch is earlier than response.
// Do not connect allocation-time pulses and call the result HPS-exact.
// Its absolute timestamp cannot lose elapsed time if a downstream consumer
// samples it less frequently than credits arrive.
//
// This is a simulator-first observation seam. It is not connected to the
// production top or Quartus project.
module nds_shared_time_credit_tracker #(
    parameter logic [63:0] RESET_TIMESTAMP = 64'd0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        credit_valid,
    input  logic        credit_arm9,
    input  logic [31:0] credit_cycles,
    output logic [63:0] arm9_timestamp,
    output logic [63:0] arm7_timestamp,
    output logic [63:0] shared_timestamp,
    output logic        shared_timestamp_changed,
    output logic        overflow
);
    logic [64:0] next_arm9;
    logic [64:0] next_arm7;
    logic [64:0] next_shared;
    logic [64:0] arm9_incremented;
    logic [64:0] arm7_incremented;
    logic [64:0] shared_if_arm9;
    logic [64:0] shared_if_arm7;

    always_comb begin
        // Evaluate both possible lane updates in parallel, then select the
        // already-complete result. This is algebraically identical to muxing
        // a lane before the 65-bit add/min chain, but removes credit_valid,
        // the fault-derived valid gate, and credit_arm9 from the front of the
        // long arithmetic cone. The sequential credit_valid guard below is
        // unchanged, so latency and externally visible behavior are exact.
        arm9_incremented = {1'b0, arm9_timestamp} +
            {33'd0, credit_cycles};
        arm7_incremented = {1'b0, arm7_timestamp} +
            {33'd0, credit_cycles};
        shared_if_arm9 = arm9_incremented < {1'b0, arm7_timestamp}
            ? arm9_incremented : {1'b0, arm7_timestamp};
        shared_if_arm7 = {1'b0, arm9_timestamp} < arm7_incremented
            ? {1'b0, arm9_timestamp} : arm7_incremented;
        next_arm9 = credit_arm9
            ? arm9_incremented : {1'b0, arm9_timestamp};
        next_arm7 = credit_arm9
            ? {1'b0, arm7_timestamp} : arm7_incremented;
        next_shared = credit_arm9 ? shared_if_arm9 : shared_if_arm7;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            arm9_timestamp <= RESET_TIMESTAMP;
            arm7_timestamp <= RESET_TIMESTAMP;
            shared_timestamp <= RESET_TIMESTAMP;
            shared_timestamp_changed <= 1'b0;
            overflow <= 1'b0;
        end else begin
            shared_timestamp_changed <= 1'b0;
            if (credit_valid) begin
                if (overflow) begin
                    // Epoch-fatal: never resume from a timestamp whose exact
                    // elapsed time was lost.
                end else if (next_arm9[64] || next_arm7[64]) begin
                    // A wrapped absolute timestamp would violate monotonicity.
                    // Fail closed and retain the last complete state.
                    overflow <= 1'b1;
                end else begin
                    arm9_timestamp <= next_arm9[63:0];
                    arm7_timestamp <= next_arm7[63:0];
                    if (next_shared[63:0] != shared_timestamp) begin
                        shared_timestamp <= next_shared[63:0];
                        shared_timestamp_changed <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
