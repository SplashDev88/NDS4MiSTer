// SPDX-License-Identifier: GPL-3.0-or-later
// Directed CDC/reset/overflow proof for the r355 pixel-boundary FIFO.
`timescale 1ns/1ps

module tb_nds_nitro_async_fifo;
    localparam integer WIDTH = 16;
    localparam integer LGDEPTH = 3;
    localparam integer DEPTH = 1 << LGDEPTH;

    logic write_clk = 1'b0;
    logic read_clk = 1'b0;
    always #7 write_clk = ~write_clk;
    always #11 read_clk = ~read_clk;

    logic write_reset = 1'b1;
    logic write_enable = 1'b0;
    logic [WIDTH-1:0] write_data = '0;
    wire write_full;
    wire write_overflow;
    logic read_reset = 1'b1;
    logic read_enable = 1'b0;
    wire [WIDTH-1:0] read_data;
    wire read_valid;
    wire read_empty;

    nds_nitro_async_fifo #(.WIDTH(WIDTH), .LGDEPTH(LGDEPTH)) dut (.*);

    task automatic push(input logic [WIDTH-1:0] value);
        integer timeout;
        begin
            timeout = 0;
            @(negedge write_clk);
            while (write_full && timeout < 100) begin
                @(negedge write_clk);
                timeout = timeout + 1;
            end
            if (write_full) $fatal(1, "FIFO remained full before push");
            write_data = value;
            write_enable = 1'b1;
            @(negedge write_clk);
            write_enable = 1'b0;
        end
    endtask

    task automatic pop_expect(input logic [WIDTH-1:0] expected);
        integer timeout;
        begin
            timeout = 0;
            @(negedge read_clk);
            while (read_empty && timeout < 100) begin
                @(negedge read_clk);
                timeout = timeout + 1;
            end
            if (read_empty) $fatal(1, "FIFO remained empty before pop");
            read_enable = 1'b1;
            @(negedge read_clk);
            read_enable = 1'b0;
            if (!read_valid || read_data !== expected)
                $fatal(1, "FIFO pop got valid=%b data=%h expected=%h",
                       read_valid, read_data, expected);
        end
    endtask

    integer i;
    initial begin
        repeat (4) @(negedge write_clk);
        write_reset = 1'b0;
        repeat (3) @(negedge read_clk);
        read_reset = 1'b0;
        repeat (4) @(negedge read_clk);
        if (!read_empty || write_full || write_overflow)
            $fatal(1, "bad state after reset empty=%b full=%b overflow=%b",
                   read_empty, write_full, write_overflow);

        // Ordered crossing with unrelated clocks.
        for (i = 0; i < 6; i = i + 1) push(16'h1100 + i);
        for (i = 0; i < 6; i = i + 1) pop_expect(16'h1100 + i);
        repeat (4) @(negedge read_clk);
        if (!read_empty) $fatal(1, "FIFO did not return empty");

        // Fill all physical slots, then prove the next write fails closed and
        // leaves a sticky diagnostic without corrupting queued order.
        for (i = 0; i < DEPTH; i = i + 1) push(16'h2200 + i);
        repeat (4) @(negedge write_clk);
        if (!write_full) $fatal(1, "FIFO did not assert full at depth");
        write_data = 16'hDEAD;
        write_enable = 1'b1;
        @(negedge write_clk);
        write_enable = 1'b0;
        if (!write_overflow) $fatal(1, "overflow diagnostic did not stick");
        for (i = 0; i < DEPTH; i = i + 1) pop_expect(16'h2200 + i);

        // A cartridge epoch asserts both domain resets.  It must clear stale
        // pointers, pending data visibility, full, valid, and overflow.
        write_reset = 1'b1;
        read_reset = 1'b1;
        repeat (3) @(negedge write_clk);
        repeat (3) @(negedge read_clk);
        write_reset = 1'b0;
        read_reset = 1'b0;
        repeat (4) @(negedge write_clk);
        repeat (4) @(negedge read_clk);
        if (!read_empty || write_full || write_overflow || read_valid)
            $fatal(1, "epoch reset left state empty=%b full=%b ovf=%b valid=%b",
                   read_empty, write_full, write_overflow, read_valid);

        push(16'hCAFE);
        pop_expect(16'hCAFE);
        $display("PASS: Nitro async FIFO CDC order, overflow, and epoch reset");
        $finish;
    end
endmodule
