`timescale 1ns/1ps

module tb_nds_arm9_math_unit;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [7:0] cycle_advance = 8'd0;
    logic cycle_advance_valid = 1'b0;
    logic request = 1'b0;
    logic [31:0] address = 32'd0;
    logic read_not_write = 1'b1;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = 32'd0;
    logic selected;
    logic [31:0] read_data;
    logic done;
    logic div_busy;
    logic sqrt_busy;

    always #5 clk <= ~clk;

    nds_arm9_math_unit dut (.*);

    task automatic bus_write(
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] value
    );
        begin
            @(negedge clk);
            address = bus_address;
            access = bus_access;
            write_data = value;
            read_not_write = 1'b0;
            request = 1'b1;
            wait (done);
            @(negedge clk);
            request = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic bus_read(
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        output logic [31:0] value
    );
        begin
            @(negedge clk);
            address = bus_address;
            access = bus_access;
            write_data = 32'd0;
            read_not_write = 1'b1;
            request = 1'b1;
            wait (done);
            #1;
            value = read_data;
            @(negedge clk);
            request = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic bus_read_with_credit(
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [7:0] credit,
        output logic [31:0] value
    );
        begin
            @(negedge clk);
            address = bus_address;
            access = bus_access;
            write_data = 32'd0;
            read_not_write = 1'b1;
            request = 1'b1;
            cycle_advance = credit;
            cycle_advance_valid = 1'b1;
            @(posedge clk);
            #1;
            cycle_advance = 8'd0;
            cycle_advance_valid = 1'b0;
            wait (done);
            #1;
            value = read_data;
            @(negedge clk);
            request = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic bus_write_with_credit(
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] value,
        input logic [7:0] credit
    );
        begin
            @(negedge clk);
            address = bus_address;
            access = bus_access;
            write_data = value;
            read_not_write = 1'b0;
            request = 1'b1;
            cycle_advance = credit;
            cycle_advance_valid = 1'b1;
            @(posedge clk);
            #1;
            cycle_advance = 8'd0;
            cycle_advance_valid = 1'b0;
            wait (done);
            @(negedge clk);
            request = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic arm9_cycles(input integer count);
        begin
            if (count < 0 || count > 255)
                $fatal(1, "invalid atomic ARM9 credit %0d", count);
            @(negedge clk);
            cycle_advance = count[7:0];
            cycle_advance_valid = 1'b1;
            @(posedge clk);
            #1;
            cycle_advance = 8'd0;
            cycle_advance_valid = 1'b0;
        end
    endtask

    task automatic calculation_clocks(input integer count);
        begin
            repeat (count) @(posedge clk);
            #1;
        end
    endtask

    task automatic expect_read(
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] expected,
        input string label
    );
        logic [31:0] actual;
        begin
            bus_read(bus_address, bus_access, actual);
            if (actual !== expected)
                $fatal(1, "%s: got %08h expected %08h",
                    label, actual, expected);
        end
    endtask

    task automatic expect_div_result(
        input logic [63:0] quotient,
        input logic [63:0] remainder,
        input string label
    );
        logic [31:0] actual;
        begin
            bus_read(32'h040002a0, 2'b10, actual);
            if (actual !== quotient[31:0])
                $fatal(1, "%s quotient low %08h", label, actual);
            bus_read(32'h040002a4, 2'b10, actual);
            if (actual !== quotient[63:32])
                $fatal(1, "%s quotient high %08h", label, actual);
            bus_read(32'h040002a8, 2'b10, actual);
            if (actual !== remainder[31:0])
                $fatal(1, "%s remainder low %08h", label, actual);
            bus_read(32'h040002ac, 2'b10, actual);
            if (actual !== remainder[63:32])
                $fatal(1, "%s remainder high %08h", label, actual);
        end
    endtask

    task automatic finish_div(input integer latency, input string label);
        begin
            if (!div_busy)
                $fatal(1, "%s BUSY did not assert", label);
            calculation_clocks(40);
            arm9_cycles(latency - 1);
            if (!div_busy)
                $fatal(1, "%s BUSY cleared early", label);
            arm9_cycles(1);
            if (div_busy)
                $fatal(1, "%s BUSY did not clear at cycle %0d",
                    label, latency);
        end
    endtask

    task automatic finish_sqrt(input string label);
        begin
            if (!sqrt_busy)
                $fatal(1, "%s BUSY did not assert", label);
            calculation_clocks(16);
            arm9_cycles(12);
            if (!sqrt_busy)
                $fatal(1, "%s BUSY cleared early", label);
            arm9_cycles(1);
            if (sqrt_busy)
                $fatal(1, "%s BUSY did not clear at cycle 13", label);
        end
    endtask

    // No artificial calculation wait: this is the densest realistic
    // production cadence, one retired ARM9 cycle credit per clk_sys tick.
    // The iterative result must already be ready before BUSY's deadline.
    task automatic finish_div_no_prewait(
        input integer latency,
        input string label
    );
        integer index;
        begin
            if (!div_busy)
                $fatal(1, "%s BUSY did not assert", label);
            for (index = 1; index < latency; index = index + 1)
                arm9_cycles(1);
            if (!div_busy)
                $fatal(1, "%s BUSY cleared before credit boundary", label);
            if (!dut.div_calculation_done)
                $fatal(1, "%s calculation missed production cadence", label);
            arm9_cycles(1);
            if (div_busy)
                $fatal(1, "%s BUSY missed exact no-prewait boundary", label);
        end
    endtask

    task automatic finish_sqrt_no_prewait(input string label);
        integer index;
        begin
            if (!sqrt_busy)
                $fatal(1, "%s BUSY did not assert", label);
            for (index = 1; index < 13; index = index + 1)
                arm9_cycles(1);
            if (!sqrt_busy)
                $fatal(1, "%s BUSY cleared before credit boundary", label);
            if (!dut.sqrt_calculation_done)
                $fatal(1, "%s calculation missed production cadence", label);
            arm9_cycles(1);
            if (sqrt_busy)
                $fatal(1, "%s BUSY missed exact no-prewait boundary", label);
        end
    endtask

    logic [31:0] value;
    initial begin
        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
        #1;

        // Undefined holes must not steal a parent-bus transaction.
        address = 32'h04000284;
        access = 2'b10;
        #1;
        if (selected)
            $fatal(1, "undefined DIV/SQRT hole selected");

        // Word writes are little-endian through byte/halfword/word reads.
        bus_write(32'h04000290, 2'b10, 32'h11223344);
        expect_read(32'h04000290, 2'b10, 32'h11223344,
            "word readback");
        expect_read(32'h04000291, 2'b00, 32'h00000033,
            "byte lane readback");
        expect_read(32'h04000292, 2'b01, 32'h00001122,
            "halfword lane readback");

        // melonDS ignores byte and halfword operand writes. They must neither
        // alter the operand nor restart the already-running divider.
        arm9_cycles(5);
        bus_write(32'h04000290, 2'b00, 32'h000000aa);
        bus_write(32'h04000292, 2'b01, 32'h0000bbbb);
        expect_read(32'h04000290, 2'b10, 32'h11223344,
            "ignored narrow operand writes");
        calculation_clocks(20);
        arm9_cycles(12);
        if (!div_busy)
            $fatal(1, "ignored narrow write disturbed original latency");
        arm9_cycles(1);
        if (div_busy)
            $fatal(1, "original divider did not finish after 18 cycles");

        // Signed 32/32: -7 / 3 = -2 remainder -1.
        bus_write(32'h04000290, 2'b10, 32'hfffffff9);
        bus_write(32'h04000294, 2'b10, 32'hdeadbeef);
        bus_write(32'h04000298, 2'b10, 32'h00000003);
        bus_write(32'h0400029c, 2'b10, 32'd0);
        bus_write(32'h04000280, 2'b01, 32'd0);
        expect_read(32'h04000281, 2'b00, 32'h00000080,
            "DIVCNT busy byte lane");
        finish_div_no_prewait(18, "mode0 signed divide");
        expect_div_result(64'hfffffffffffffffe,
            64'hffffffffffffffff, "mode0 signed divide");

        // A write during BUSY cancels and gives the replacement operation a
        // fresh full latency.
        bus_write(32'h04000290, 2'b10, 32'd100);
        bus_write(32'h04000298, 2'b10, 32'd5);
        bus_write(32'h04000280, 2'b01, 32'd0);
        arm9_cycles(10);
        bus_write(32'h04000298, 2'b10, 32'd4);
        calculation_clocks(40);
        arm9_cycles(17);
        if (!div_busy)
            $fatal(1, "operand restart did not restore full DIV latency");
        arm9_cycles(1);
        if (div_busy)
            $fatal(1, "restarted DIV did not complete");
        expect_div_result(64'd25, 64'd0, "operand restart result");

        // The production seam can deliver all elapsed cycles in one credit.
        // A credit presented with a read is consumed before that MMIO read,
        // so the read observes completion exactly at the 17+1 boundary.
        bus_write(32'h04000290, 2'b10, 32'd81);
        bus_write(32'h04000298, 2'b10, 32'd9);
        bus_write(32'h04000280, 2'b01, 32'd0);
        calculation_clocks(20);
        arm9_cycles(17);
        bus_read_with_credit(32'h04000280, 2'b01, 8'd1, value);
        if (value !== 32'd0 || div_busy)
            $fatal(1, "same-edge final credit was not visible to DIVCNT read");
        expect_div_result(64'd9, 64'd0,
            "same-edge credit-before-read result");

        // A write on the final-credit edge first completes the old operation,
        // then restarts from the fresh operand without charging that old
        // credit to the replacement operation.
        bus_write(32'h04000290, 2'b10, 32'd100);
        bus_write(32'h04000298, 2'b10, 32'd5);
        bus_write(32'h04000280, 2'b01, 32'd0);
        calculation_clocks(20);
        arm9_cycles(17);
        bus_write_with_credit(32'h04000298, 2'b10, 32'd4, 8'd1);
        if (!div_busy)
            $fatal(1, "same-edge replacement write did not restart DIV");
        expect_div_result(64'd20, 64'd0,
            "old result committed before replacement write");
        calculation_clocks(20);
        arm9_cycles(17);
        if (!div_busy)
            $fatal(1, "old credit leaked into replacement DIV deadline");
        arm9_cycles(1);
        if (div_busy)
            $fatal(1, "replacement DIV did not finish at fresh 18 credits");
        expect_div_result(64'd25, 64'd0,
            "same-edge replacement result");

        // Start a DIV0 operation with stale DIV0=0, then complete it on the
        // same edge that a nonzero denominator restarts the divider. HPS
        // advances first, so the replacement BUSY interval must retain the
        // just-completed DIV0=1 rather than the opposite pre-edge status.
        bus_write(32'h04000290, 2'b10, 32'd7);
        bus_write(32'h04000294, 2'b10, 32'd0);
        bus_write(32'h04000298, 2'b10, 32'd0);
        bus_write(32'h0400029c, 2'b10, 32'd0);
        bus_write(32'h04000280, 2'b01, 32'd0);
        calculation_clocks(20);
        arm9_cycles(17);
        bus_write_with_credit(32'h04000298, 2'b10, 32'd4, 8'd1);
        expect_read(32'h04000280, 2'b01, 32'h0000c000,
            "completed DIV0 carried into replacement BUSY interval");
        expect_div_result(64'h00000000ffffffff, 64'd7,
            "same-edge DIV0 old result");
        calculation_clocks(20);
        arm9_cycles(18);
        if (div_busy)
            $fatal(1, "DIV0 replacement missed fresh deadline");
        expect_div_result(64'd1, 64'd3,
            "same-edge DIV0 replacement result");

        // Credits larger than the remaining delay saturate atomically.
        bus_write(32'h04000290, 2'b10, 32'd77);
        bus_write(32'h04000298, 2'b10, 32'd7);
        bus_write(32'h04000280, 2'b01, 32'd0);
        calculation_clocks(20);
        arm9_cycles(255);
        if (div_busy)
            $fatal(1, "oversized DIV credit did not saturate deadline");
        expect_div_result(64'd11, 64'd0, "oversized DIV credit result");

        // Mode 1 is signed 64/32 and takes 34 cycles.
        bus_write(32'h04000290, 2'b10, 32'h00000000);
        bus_write(32'h04000294, 2'b10, 32'h00000001);
        bus_write(32'h04000298, 2'b10, 32'h00000002);
        bus_write(32'h0400029c, 2'b10, 32'hcafebabe);
        bus_write(32'h04000280, 2'b10, 32'd1);
        finish_div(34, "mode1 64/32 divide");
        expect_div_result(64'h0000000080000000, 64'd0,
            "mode1 64/32 divide");

        // Mode 2 is signed 64/64 and mode 3 aliases signed 64/32.
        bus_write(32'h04000290, 2'b10, 32'hfffffff7);
        bus_write(32'h04000294, 2'b10, 32'hffffffff);
        bus_write(32'h04000298, 2'b10, 32'h00000004);
        bus_write(32'h0400029c, 2'b10, 32'd0);
        bus_write(32'h04000280, 2'b01, 32'd2);
        finish_div_no_prewait(34, "mode2 64/64 divide");
        expect_div_result(64'hfffffffffffffffe,
            64'hffffffffffffffff, "mode2 64/64 divide");

        bus_write(32'h04000290, 2'b10, 32'd21);
        bus_write(32'h04000294, 2'b10, 32'd0);
        bus_write(32'h04000298, 2'b10, 32'd4);
        bus_write(32'h0400029c, 2'b10, 32'hffffffff);
        bus_write(32'h04000280, 2'b01, 32'd3);
        finish_div(34, "mode3 alias divide");
        expect_div_result(64'd5, 64'd1, "mode3 alias divide");

        // Nonzero modes use ordinary signed-64 +/-1 on divide by zero.
        bus_write(32'h04000290, 2'b10, 32'hfffffff9);
        bus_write(32'h04000294, 2'b10, 32'hffffffff);
        bus_write(32'h04000298, 2'b10, 32'd0);
        bus_write(32'h0400029c, 2'b10, 32'd0);
        bus_write(32'h04000280, 2'b01, 32'd1);
        finish_div(34, "mode1 negative divide by zero");
        expect_div_result(64'd1, 64'hfffffffffffffff9,
            "mode1 negative divide by zero");

        // Divide by zero result and DIV0 flag, for each numerator sign.
        bus_write(32'h04000290, 2'b10, 32'd7);
        bus_write(32'h04000294, 2'b10, 32'd0);
        bus_write(32'h04000298, 2'b10, 32'd0);
        bus_write(32'h0400029c, 2'b10, 32'd0);
        bus_write(32'h04000280, 2'b01, 32'd0);
        finish_div(18, "positive divide by zero");
        expect_div_result(64'h00000000ffffffff, 64'd7,
            "positive divide by zero");
        expect_read(32'h04000280, 2'b01, 32'h00004000,
            "DIV0 flag");

        bus_write(32'h04000290, 2'b10, 32'hfffffff9);
        bus_write(32'h04000280, 2'b01, 32'd0);
        finish_div(18, "negative divide by zero");
        expect_div_result(64'hffffffff00000001,
            64'hfffffffffffffff9,
            "negative divide by zero");

        // melonDS computes the DIV0 status from the full 64-bit denominator,
        // even in a 32-bit-denominator mode.
        bus_write(32'h04000290, 2'b10, 32'd7);
        bus_write(32'h0400029c, 2'b10, 32'd1);
        bus_write(32'h04000280, 2'b01, 32'd0);
        finish_div(18, "mode0 high denominator flag quirk");
        expect_div_result(64'h00000000ffffffff, 64'd7,
            "mode0 effective zero denominator");
        expect_read(32'h04000280, 2'b01, 32'd0,
            "full-denominator DIV0 flag quirk");

        // Signed overflow is deterministic and produces a zero remainder.
        bus_write(32'h04000290, 2'b10, 32'h80000000);
        bus_write(32'h04000298, 2'b10, 32'hffffffff);
        bus_write(32'h04000280, 2'b01, 32'd0);
        finish_div(18, "mode0 overflow");
        expect_div_result(64'h0000000080000000, 64'd0,
            "mode0 overflow");

        bus_write(32'h04000290, 2'b10, 32'd0);
        bus_write(32'h04000294, 2'b10, 32'h80000000);
        bus_write(32'h04000298, 2'b10, 32'hffffffff);
        bus_write(32'h0400029c, 2'b10, 32'hffffffff);
        bus_write(32'h04000280, 2'b01, 32'd2);
        finish_div(34, "mode2 overflow");
        expect_div_result(64'h8000000000000000, 64'd0,
            "mode2 overflow");

        // Writes to read-only result registers are swallowed but do not
        // modify or restart the divider.
        bus_write(32'h040002a0, 2'b10, 32'h12345678);
        if (div_busy)
            $fatal(1, "result write restarted divider");
        expect_div_result(64'h8000000000000000, 64'd0,
            "read-only divide result");

        // 32-bit and 64-bit integer square roots both complete at cycle 13.
        bus_write(32'h040002b8, 2'b10, 32'd144);
        bus_write(32'h040002bc, 2'b10, 32'hfeedface);
        bus_write(32'h040002b0, 2'b01, 32'd0);
        expect_read(32'h040002b1, 2'b00, 32'h00000080,
            "SQRTCNT busy byte lane");
        finish_sqrt_no_prewait("sqrt32");
        expect_read(32'h040002b4, 2'b10, 32'd12, "sqrt32 result");

        bus_write(32'h040002b8, 2'b10, 32'd0);
        bus_write(32'h040002bc, 2'b10, 32'd1);
        bus_write(32'h040002b0, 2'b10, 32'd1);
        finish_sqrt_no_prewait("sqrt64");
        expect_read(32'h040002b4, 2'b10, 32'h00010000,
            "sqrt64 result");

        bus_write(32'h040002b8, 2'b10, 32'd625);
        bus_write(32'h040002b0, 2'b01, 32'd0);
        calculation_clocks(16);
        arm9_cycles(255);
        if (sqrt_busy)
            $fatal(1, "oversized SQRT credit did not saturate deadline");
        expect_read(32'h040002b4, 2'b10, 32'd25,
            "oversized SQRT credit result");

        // SQRT operand writes also restart, while narrow writes are ignored.
        bus_write(32'h040002b8, 2'b10, 32'd81);
        bus_write(32'h040002b0, 2'b01, 32'd0);
        arm9_cycles(7);
        bus_write(32'h040002b8, 2'b00, 32'h00000010);
        calculation_clocks(10);
        arm9_cycles(5);
        if (!sqrt_busy)
            $fatal(1, "ignored byte write disturbed SQRT latency");
        arm9_cycles(1);
        if (sqrt_busy)
            $fatal(1, "SQRT did not finish after ignored byte write");
        expect_read(32'h040002b4, 2'b10, 32'd9,
            "ignored narrow SQRT write");

        bus_write(32'h040002b8, 2'b10, 32'd100);
        arm9_cycles(6);
        bus_write(32'h040002b8, 2'b10, 32'd121);
        calculation_clocks(16);
        arm9_cycles(12);
        if (!sqrt_busy)
            $fatal(1, "SQRT operand restart did not restore latency");
        arm9_cycles(1);
        if (sqrt_busy)
            $fatal(1, "restarted SQRT did not finish");
        expect_read(32'h040002b4, 2'b10, 32'd11,
            "restarted SQRT result");

        $display("PASS: ARM9 DIV/SQRT MMIO semantics, arithmetic, restart, and BUSY timing");
        $finish;
    end
endmodule
