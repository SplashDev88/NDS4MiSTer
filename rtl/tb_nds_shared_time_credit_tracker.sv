module tb_nds_shared_time_credit_tracker;
    logic clk = 0;
    logic reset = 1;
    logic credit_valid = 0;
    logic credit_arm9 = 0;
    logic [31:0] credit_cycles = 0;
    logic [63:0] arm9_timestamp;
    logic [63:0] arm7_timestamp;
    logic [63:0] shared_timestamp;
    logic shared_timestamp_changed;
    logic overflow;
    integer change_count = 0;

    logic overflow_credit_valid = 0;
    logic overflow_credit_arm9 = 0;
    logic [31:0] overflow_credit_cycles = 0;
    logic [63:0] overflow_arm9_timestamp;
    logic [63:0] overflow_arm7_timestamp;
    logic [63:0] overflow_shared_timestamp;
    logic overflow_shared_timestamp_changed;
    logic overflow_sticky;

    always #5 clk = ~clk;

    nds_shared_time_credit_tracker dut (.*);
    nds_shared_time_credit_tracker #(
        .RESET_TIMESTAMP(64'hfffffffffffffff0)
    ) overflow_dut (
        .clk,
        .reset,
        .credit_valid(overflow_credit_valid),
        .credit_arm9(overflow_credit_arm9),
        .credit_cycles(overflow_credit_cycles),
        .arm9_timestamp(overflow_arm9_timestamp),
        .arm7_timestamp(overflow_arm7_timestamp),
        .shared_timestamp(overflow_shared_timestamp),
        .shared_timestamp_changed(overflow_shared_timestamp_changed),
        .overflow(overflow_sticky)
    );

    always @(posedge clk) begin
        if (!reset && shared_timestamp_changed)
            change_count <= change_count + 1;
    end

    task automatic credit(
        input logic arm9,
        input logic [31:0] cycles,
        input logic [63:0] expected9,
        input logic [63:0] expected7,
        input logic [63:0] expected_shared,
        input logic expected_changed
    );
        begin
            @(negedge clk);
            credit_arm9 = arm9;
            credit_cycles = cycles;
            credit_valid = 1;
            @(posedge clk);
            #1;
            if (arm9_timestamp !== expected9 ||
                arm7_timestamp !== expected7 ||
                shared_timestamp !== expected_shared ||
                shared_timestamp_changed !== expected_changed) begin
                $fatal(1,
                    "credit mismatch cpu=%0d cycles=%0d got=%0d/%0d/%0d changed=%0d expected=%0d/%0d/%0d changed=%0d",
                    arm9, cycles, arm9_timestamp, arm7_timestamp,
                    shared_timestamp, shared_timestamp_changed,
                    expected9, expected7, expected_shared, expected_changed);
            end
            @(negedge clk);
            credit_valid = 0;
            credit_cycles = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Exact sequence asserted by ExternalTimingTest.cpp:
        // floor(ARM9, ARM7) = 0, 0, 11, 37, 51.
        credit(1, 37, 37, 0, 0, 0);
        credit(0, 11, 37, 11, 11, 1);
        credit(0, 40, 37, 51, 37, 1);
        credit(1, 14, 51, 51, 51, 1);

        // A zero-cycle IRQ refresh is a no-op.
        credit(1, 0, 51, 51, 51, 0);

        // A running CPU cannot drag shared peripherals past the other CPU.
        credit(1, 32768, 32819, 51, 51, 0);
        // A synthetic halt credit for ARM7 catches shared time up exactly.
        credit(0, 32768, 32819, 32819, 32819, 1);

        // Let the monitor account for the final registered change pulse.
        @(posedge clk);
        #1;
        if (overflow)
            $fatal(1, "ordinary shared-time credits overflowed");
        if (change_count != 4)
            $fatal(1, "unexpected shared timestamp change count %0d",
                change_count);

        // Overflow is epoch-fatal: reject the overflowing credit and every
        // later credit rather than silently resuming from lost elapsed time.
        @(negedge clk);
        overflow_credit_valid = 1;
        overflow_credit_arm9 = 1;
        overflow_credit_cycles = 32;
        @(posedge clk);
        #1;
        if (!overflow_sticky ||
            overflow_arm9_timestamp !== 64'hfffffffffffffff0 ||
            overflow_arm7_timestamp !== 64'hfffffffffffffff0 ||
            overflow_shared_timestamp !== 64'hfffffffffffffff0)
            $fatal(1, "timestamp overflow did not fail closed");
        @(negedge clk);
        overflow_credit_arm9 = 0;
        overflow_credit_cycles = 1;
        @(posedge clk);
        #1;
        if (!overflow_sticky ||
            overflow_arm9_timestamp !== 64'hfffffffffffffff0 ||
            overflow_arm7_timestamp !== 64'hfffffffffffffff0 ||
            overflow_shared_timestamp !== 64'hfffffffffffffff0 ||
            overflow_shared_timestamp_changed)
            $fatal(1, "timestamp tracker resumed after sticky overflow");
        @(negedge clk);
        overflow_credit_valid = 0;

        $display(
            "PASS: credited ARM9/ARM7 cycles reproduce the canonical min(timestamp9,timestamp7) DS scheduler clock");
        $display(
            "INFO: arm9=%0d arm7=%0d shared=%0d changes=%0d",
            arm9_timestamp, arm7_timestamp, shared_timestamp, change_count);
        $finish;
    end
endmodule
