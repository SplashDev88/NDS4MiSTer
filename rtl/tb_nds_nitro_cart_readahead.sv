// SPDX-License-Identifier: GPL-3.0-or-later
// Measures cartridge-channel DDR command amplification while checking every
// returned word.  The product optimization must reduce commands without ever
// serving a word from a different line or cartridge epoch.
`timescale 1ns/1ps

module tb_nds_nitro_cart_readahead;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic ddram_busy = 1'b0;
    wire [7:0] ddram_burstcnt;
    wire [28:0] ddram_addr;
    logic [63:0] ddram_dout = '0;
    logic ddram_dout_ready = 1'b0;
    wire ddram_rd;
    wire [63:0] ddram_din;
    wire [7:0] ddram_be;
    wire ddram_we;

    logic [27:1] ch2_addr = '0;
    wire [31:0] ch2_dout;
    logic ch2_req = 1'b0;
    wire ch2_ready;

    ddram dut (
        .DDRAM_CLK(clk), .DDRAM_BUSY(ddram_busy),
        .DDRAM_BURSTCNT(ddram_burstcnt), .DDRAM_ADDR(ddram_addr),
        .DDRAM_DOUT(ddram_dout), .DDRAM_DOUT_READY(ddram_dout_ready),
        .DDRAM_RD(ddram_rd), .DDRAM_DIN(ddram_din),
        .DDRAM_BE(ddram_be), .DDRAM_WE(ddram_we),
        .ch1_addr('0), .ch1_dout(), .ch1_din('0), .ch1_req(1'b0),
        .ch1_rnw(1'b1), .ch1_ready(),
        .ch2_addr(ch2_addr), .ch2_dout(ch2_dout), .ch2_din('0),
        .ch2_req(ch2_req), .ch2_rnw(1'b1), .ch2_ready(ch2_ready),
        .ch3_addr('0), .ch3_dout(), .ch3_din('0), .ch3_req(1'b0),
        .ch3_rnw(1'b1), .ch3_be('0), .ch3_ready(),
        .ch4_addr('0), .ch4_dout(), .ch4_din('0), .ch4_req(1'b0),
        .ch4_rnw(1'b1), .ch4_be('0), .ch4_ready(),
        .ch5_addr('0), .ch5_din('0), .ch5_req(1'b0),
        .ch5_burst(8'd1), .ch5_next(), .ch5_ready(),
        .ch6_addr('0), .ch6_burst(8'd1), .ch6_req(1'b0),
        .ch6_dout(), .ch6_valid(), .ch6_ready()
    );

    logic [63:0] memory [0:255];
    logic response_active = 1'b0;
    integer response_left = 0;
    integer response_beat = 0;
    integer physical_commands = 0;
    integer physical_beats = 0;
    integer elapsed_cycles = 0;

    always_ff @(posedge clk) begin
        elapsed_cycles <= elapsed_cycles + 1;
        ddram_dout_ready <= 1'b0;
        if (ddram_rd) begin
            if (response_active) $fatal(1, "overlapping DDR read command");
            response_active <= 1'b1;
            response_left <= ddram_burstcnt;
            response_beat <= ddram_addr[7:0];
            physical_commands <= physical_commands + 1;
        end else if (response_active) begin
            ddram_dout <= memory[response_beat];
            ddram_dout_ready <= 1'b1;
            response_beat <= response_beat + 1;
            response_left <= response_left - 1;
            physical_beats <= physical_beats + 1;
            if (response_left == 1) response_active <= 1'b0;
        end
        if (ddram_we) $fatal(1, "cartridge benchmark wrote DDR");
    end

    task automatic read_word(input integer word_address);
        integer timeout;
        logic [31:0] expected;
        begin
            expected = 32'h51000000 + word_address;
            @(negedge clk);
            ch2_addr = word_address << 1;
            ch2_req = 1'b1;
            @(negedge clk);
            ch2_req = 1'b0;
            timeout = 0;
            while (!ch2_ready && timeout < 200) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!ch2_ready)
                $fatal(1, "word %0d timed out", word_address);
            if (ch2_dout !== expected)
                $fatal(1, "word %0d returned %h expected %h",
                       word_address, ch2_dout, expected);
        end
    endtask

    integer index;
    integer commands_before;
    integer beats_before;
    integer cycles_before;
    integer sequential_commands;
    integer sequential_beats;
    integer sequential_cycles;
    initial begin
        for (index = 0; index < 256; index = index + 1) begin
            memory[index][31:0] = 32'h51000000 + index * 2;
            memory[index][63:32] = 32'h51000001 + index * 2;
        end
        repeat (4) @(negedge clk);

        commands_before = physical_commands;
        beats_before = physical_beats;
        cycles_before = elapsed_cycles;
        for (index = 0; index < 64; index = index + 1)
            read_word(index);
        sequential_commands = physical_commands - commands_before;
        sequential_beats = physical_beats - beats_before;
        sequential_cycles = elapsed_cycles - cycles_before;
        if (sequential_commands != 8 || sequential_beats != 32)
            $fatal(1,
                "read-ahead amplification regressed commands=%0d beats=%0d",
                sequential_commands, sequential_beats);

        // Cross line boundaries in both directions and revisit both halves of
        // beats. These accesses catch stale tags and wrong half-word selects.
        read_word(95);
        read_word(64);
        read_word(71);
        read_word(68);
        read_word(127);
        read_word(1);

        $display(
            "CART_READAHEAD_BENCH words=64 commands=%0d beats=%0d cycles=%0d",
            sequential_commands, sequential_beats, sequential_cycles);
        $display("PASS: bounded cartridge read-ahead data and ordering");
        $finish;
    end
endmodule
