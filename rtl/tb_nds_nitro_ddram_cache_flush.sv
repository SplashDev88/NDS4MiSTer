// SPDX-License-Identifier: GPL-3.0-or-later
// Focused proof for the two-probe cartridge cache displacement used by r355.
// The first post-download read may hit stale ch2 cache state.  A second read
// two 64-bit beats away must perform a physical DDR read and displace it.
`timescale 1ns/1ps

module tb_nds_nitro_ddram_cache_flush;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic        ddram_busy = 1'b0;
    wire  [7:0] ddram_burstcnt;
    wire [28:0] ddram_addr;
    logic [63:0] ddram_dout = '0;
    logic        ddram_dout_ready = 1'b0;
    wire         ddram_rd;
    wire [63:0] ddram_din;
    wire  [7:0] ddram_be;
    wire         ddram_we;

    logic [27:1] ch2_addr = '0;
    wire  [31:0] ch2_dout;
    logic [31:0] ch2_din = '0;
    logic        ch2_req = 1'b0;
    logic        ch2_rnw = 1'b1;
    wire         ch2_ready;

    ddram dut (
        .DDRAM_CLK(clk), .DDRAM_BUSY(ddram_busy),
        .DDRAM_BURSTCNT(ddram_burstcnt), .DDRAM_ADDR(ddram_addr),
        .DDRAM_DOUT(ddram_dout), .DDRAM_DOUT_READY(ddram_dout_ready),
        .DDRAM_RD(ddram_rd), .DDRAM_DIN(ddram_din),
        .DDRAM_BE(ddram_be), .DDRAM_WE(ddram_we),

        .ch1_addr('0), .ch1_dout(), .ch1_din('0), .ch1_req(1'b0),
        .ch1_rnw(1'b1), .ch1_ready(),
        .ch2_addr(ch2_addr), .ch2_dout(ch2_dout), .ch2_din(ch2_din),
        .ch2_req(ch2_req), .ch2_rnw(ch2_rnw), .ch2_ready(ch2_ready),
        .ch3_addr('0), .ch3_dout(), .ch3_din('0), .ch3_req(1'b0),
        .ch3_rnw(1'b1), .ch3_be('0), .ch3_ready(),
        .ch4_addr('0), .ch4_dout(), .ch4_din('0), .ch4_req(1'b0),
        .ch4_rnw(1'b1), .ch4_be('0), .ch4_ready(),
        .ch5_addr('0), .ch5_din('0), .ch5_req(1'b0),
        .ch5_burst(8'd1), .ch5_next(), .ch5_ready(),
        .ch6_addr('0), .ch6_burst(8'd1), .ch6_req(1'b0),
        .ch6_dout(), .ch6_valid(), .ch6_ready()
    );

    logic [63:0] memory [0:15];
    logic        response_active = 1'b0;
    logic  [7:0] response_left = '0;
    logic  [3:0] response_beat = '0;
    integer physical_read_commands = 0;

    // Minimal Avalon-like DDR response model.  Read data starts one cycle
    // after a command and then arrives in consecutive cycles for its burst.
    always_ff @(posedge clk) begin
        ddram_dout_ready <= 1'b0;
        if (ddram_rd) begin
            if (response_active) $fatal(1, "overlapping DDR read command");
            if (ddram_addr[28:25] != 4'b0011)
                $fatal(1, "unexpected DDR base %h", ddram_addr);
            response_active <= 1'b1;
            response_left <= ddram_burstcnt;
            response_beat <= ddram_addr[3:0];
            physical_read_commands <= physical_read_commands + 1;
        end else if (response_active) begin
            ddram_dout <= memory[response_beat];
            ddram_dout_ready <= 1'b1;
            response_beat <= response_beat + 1'b1;
            response_left <= response_left - 1'b1;
            if (response_left == 8'd1) response_active <= 1'b0;
        end
        if (ddram_we) $fatal(1, "flush proof unexpectedly wrote DDR");
    end

    task automatic read_ch2(
        input logic [27:1] address,
        output logic [31:0] value,
        output integer command_delta
    );
        integer before_commands;
        integer timeout;
        begin
            before_commands = physical_read_commands;
            @(negedge clk);
            ch2_addr = address;
            ch2_req = 1'b1;
            @(negedge clk);
            ch2_req = 1'b0;
            timeout = 0;
            while (!ch2_ready && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!ch2_ready) $fatal(1, "ch2 read timeout at %h", address);
            value = ch2_dout;
            // Let a possible second burst beat retire before the next request.
            repeat (4) @(negedge clk);
            command_delta = physical_read_commands - before_commands;
        end
    endtask

    logic [31:0] value;
    integer commands;
    initial begin
        memory[0] = 64'hA1A1A1A1_A0A0A0A0;
        memory[1] = 64'hA3A3A3A3_A2A2A2A2;
        memory[2] = 64'hA5A5A5A5_A4A4A4A4;
        memory[3] = 64'hA7A7A7A7_A6A6A6A6;
        repeat (4) @(negedge clk);

        // Prime ch2's retained tag and data with the old cartridge beat 0.
        read_ch2({27{1'b0}}, value, commands);
        if (value != 32'hA0A0A0A0 || commands != 1)
            $fatal(1, "cache prime failed value=%h commands=%0d", value, commands);

        // Model a direct HPS replacement, which bypasses ddram's cache state.
        memory[0] = 64'hB1B1B1B1_B0B0B0B0;
        memory[1] = 64'hB3B3B3B3_B2B2B2B2;
        memory[2] = 64'hB5B5B5B5_B4B4B4B4;
        memory[3] = 64'hB7B7B7B7_B6B6B6B6;

        // Probe 0 is deliberately the worst case: it legally returns stale
        // cached data and issues no DDR command.
        read_ch2({27{1'b0}}, value, commands);
        if (value != 32'hA0A0A0A0 || commands != 0)
            $fatal(1, "expected stale first probe value=%h commands=%0d", value, commands);

        // The product's second probe is word address 4 -> byte address 16,
        // i.e. beat 2.  It can match neither cached beat 0 nor next beat 1.
        read_ch2({1'b0, 25'd4, 1'b0}, value, commands);
        if (value != 32'hB4B4B4B4 || commands != 1)
            $fatal(1, "second probe did not displace cache value=%h commands=%0d",
                   value, commands);

        // A subsequent real boot read at word 0 must now miss and see the new
        // cartridge rather than the stale beat retained before replacement.
        read_ch2({27{1'b0}}, value, commands);
        if (value != 32'hB0B0B0B0 || commands != 1)
            $fatal(1, "post-flush boot read stale value=%h commands=%0d", value, commands);

        $display("PASS: two-probe Nitro ch2 cache displacement");
        $finish;
    end
endmodule
