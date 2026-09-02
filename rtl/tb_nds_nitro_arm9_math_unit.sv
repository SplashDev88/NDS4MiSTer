// SPDX-License-Identifier: GPL-3.0-or-later
// Product-mode proof for the compact serial DIV/SQRT unit.  Unlike the legacy
// radix-4 test, this permits BUSY to extend until the serial result is ready.
`timescale 1ns/1ps

module tb_nds_nitro_arm9_math_unit;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic reset = 1'b1;
    logic [7:0] cycle_advance = 8'd1;
    logic cycle_advance_valid = 1'b1;
    logic request = 1'b0;
    logic [31:0] address = '0;
    logic read_not_write = 1'b1;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = '0;
    wire selected;
    wire [31:0] read_data;
    wire done, div_busy, sqrt_busy;

    nds_nitro_arm9_math_unit #(.COMBINATIONAL_READ(1'b1)) dut (.*);

    task automatic write32(input logic [31:0] a, input logic [31:0] d);
        begin
            @(negedge clk);
            address = a;
            write_data = d;
            access = 2'b10;
            read_not_write = 1'b0;
            request = 1'b1;
            // One clk1x IO level spans two clk2x samples in production.
            repeat (2) @(negedge clk);
            request = 1'b0;
            // Allow the adapter's level guard to return inactive.
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic write16(input logic [31:0] a, input logic [15:0] d);
        begin
            @(negedge clk);
            address = a;
            write_data = {16'd0, d};
            access = 2'b01;
            read_not_write = 1'b0;
            request = 1'b1;
            repeat (2) @(negedge clk);
            request = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic read32(input logic [31:0] a, output logic [31:0] d);
        begin
            @(negedge clk);
            address = a;
            access = 2'b10;
            read_not_write = 1'b1;
            request = 1'b1;
            #1;
            if (!selected) $fatal(1, "math read not selected at %h", a);
            d = read_data;
            repeat (2) @(negedge clk);
            request = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic wait_div(input integer min_clocks, input integer max_clocks);
        integer n;
        begin
            n = 0;
            while (div_busy && n < max_clocks) begin
                @(posedge clk);
                #1;
                n = n + 1;
            end
            if (div_busy || n < min_clocks)
                $fatal(1, "divide BUSY clocks=%0d expected %0d..%0d",
                       n, min_clocks, max_clocks);
        end
    endtask

    task automatic wait_sqrt(input integer min_clocks, input integer max_clocks);
        integer n;
        begin
            n = 0;
            while (sqrt_busy && n < max_clocks) begin
                @(posedge clk);
                #1;
                n = n + 1;
            end
            if (sqrt_busy || n < min_clocks)
                $fatal(1, "sqrt BUSY clocks=%0d expected %0d..%0d",
                       n, min_clocks, max_clocks);
        end
    endtask

    logic [31:0] value;
    initial begin
        repeat (4) @(negedge clk);
        reset = 1'b0;

        // Mode 0: 100 / 7 = 14 remainder 2.  The result registers must retain
        // their prior values for the entire extended serial BUSY interval.
        write32(32'h04000290, 32'd100);
        write32(32'h04000294, 32'd0);
        write32(32'h04000298, 32'd7);
        write32(32'h0400029c, 32'd0);
        write16(32'h04000280, 16'd0);
        if (!div_busy) $fatal(1, "mode0 BUSY never asserted");
        read32(32'h040002a0, value);
        if (value != 32'd0) $fatal(1, "result changed while BUSY: %h", value);
        wait_div(1, 40);
        read32(32'h040002a0, value);
        if (value != 32'd14) $fatal(1, "mode0 quotient %h", value);
        read32(32'h040002a8, value);
        if (value != 32'd2) $fatal(1, "mode0 remainder %h", value);

        // Mode 2: 0x1_00000000 / 3 = 0x55555555 remainder 1.
        write32(32'h04000290, 32'd0);
        write32(32'h04000294, 32'd1);
        write32(32'h04000298, 32'd3);
        write32(32'h0400029c, 32'd0);
        write16(32'h04000280, 16'd2);
        wait_div(1, 72);
        read32(32'h040002a0, value);
        if (value != 32'h55555555) $fatal(1, "mode2 quotient %h", value);
        read32(32'h040002a4, value);
        if (value != 32'd0) $fatal(1, "mode2 quotient high %h", value);
        read32(32'h040002a8, value);
        if (value != 32'd1) $fatal(1, "mode2 remainder %h", value);

        // Nitro DMA's fast IO lane can transition directly from a read unit to
        // a write unit while ena remains high.  The address/RNW edge, not a low
        // gap, separates the transactions.  The write must still restart DIV.
        @(negedge clk);
        address = 32'h04000290;
        access = 2'b10;
        read_not_write = 1'b1;
        request = 1'b1;
        repeat (2) @(negedge clk);
        address = 32'h04000298;
        write_data = 32'd9;
        read_not_write = 1'b0;
        repeat (2) @(negedge clk);
        if (dut.div_iterations != 7'd1)
            $fatal(1, "one DMA write restarted %0d times (iterations=%0d)",
                   2 - dut.div_iterations, dut.div_iterations);
        request = 1'b0;
        if (!div_busy || dut.div_denominator[31:0] != 32'd9)
            $fatal(1, "continuous-ena DMA write was lost busy=%b denominator=%h",
                   div_busy, dut.div_denominator[31:0]);
        wait_div(1, 72);

        // A repeated fixed-destination write is still distinct: every DMA
        // unit has an intervening RD phase, even when that read is non-math.
        @(negedge clk);
        address = 32'h04000130;
        access = 2'b10;
        read_not_write = 1'b1;
        request = 1'b1;
        repeat (2) @(negedge clk);
        address = 32'h04000298;
        write_data = 32'd11;
        read_not_write = 1'b0;
        repeat (2) @(negedge clk);
        if (dut.div_iterations != 7'd1)
            $fatal(1, "repeated fixed-destination DMA write duplicated/lost");
        request = 1'b0;
        if (!div_busy || dut.div_denominator[31:0] != 32'd11)
            $fatal(1, "repeated fixed-destination DMA write not accepted");
        wait_div(1, 72);

        // Upper-half halfword controls are holes, not aliases of DIVCNT.
        address = 32'h04000282;
        access = 2'b01;
        read_not_write = 1'b0;
        request = 1'b1;
        #1;
        if (selected) $fatal(1, "upper DIVCNT halfword was incorrectly selected");
        request = 1'b0;

        // Both 32- and 64-bit square root modes.
        write32(32'h040002b8, 32'd144);
        write32(32'h040002bc, 32'd0);
        write16(32'h040002b0, 16'd0);
        wait_sqrt(1, 24);
        read32(32'h040002b4, value);
        if (value != 32'd12) $fatal(1, "sqrt32 result %h", value);

        write32(32'h040002b8, 32'd0);
        write32(32'h040002bc, 32'd1);
        write16(32'h040002b0, 16'd1);
        wait_sqrt(1, 40);
        read32(32'h040002b4, value);
        if (value != 32'h00010000) $fatal(1, "sqrt64 result %h", value);

        $display("PASS: compact Nitro DIV/SQRT results, extended BUSY, and lane holes");
        $finish;
    end
endmodule
