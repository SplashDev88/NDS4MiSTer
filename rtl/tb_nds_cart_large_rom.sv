// SPDX-License-Identifier: GPL-3.0-or-later
// Actual product CDC bridge + retained cartridge DDR cache. No ROM-sized RAM
// allocation is needed: every word carries its byte address and image epoch.
`timescale 1ns/1ps
module tb_nds_cart_large_rom;
    reg clk1x=0,ddr_clk=0;
    always #7 clk1x=~clk1x;
    always #5 ddr_clk=~ddr_clk;
    reg console_reset_1x=1,console_reset_ddr=1,bridge_reset_ddr=1;
    reg h3d_fabric_boot_reset=1;
    reg [1:0] cart_state=3;
    reg cart_download_ddr=0,cart_download_d=0,cart_download_raw=0;
    reg source_request=0;
    reg [15:0] ioctl_index=16'h0003;
    reg expect_large=0,expect_512=0;
    reg [26:0] source_address=0;
    wire response_ready,request,done,flush_complete,altbank;
    wire [31:0] response_data,data;
    wire [25:0] address;
    wire [27:1] ddr_address;
    cart_bridge_under_test bridge(.*);

    wire [7:0] burst;
    wire [28:0] physical_address;
    wire physical_read,physical_write;
    reg [63:0] physical_data=0;
    reg physical_ready=0;
    ddram memory_port(
        .DDRAM_CLK(ddr_clk),.DDRAM_BUSY(1'b0),.DDRAM_BURSTCNT(burst),
        .DDRAM_ADDR(physical_address),.DDRAM_DOUT(physical_data),
        .DDRAM_DOUT_READY(physical_ready),.DDRAM_RD(physical_read),
        .DDRAM_DIN(),.DDRAM_BE(),.DDRAM_WE(physical_write),
        .ch1_addr(27'd0),.ch1_dout(),.ch1_din(16'd0),.ch1_req(1'b0),.ch1_rnw(1'b1),.ch1_ready(),
        .ch2_addr(ddr_address),.ch2_altbank(altbank),.ch2_dout(response_data),.ch2_din(32'd0),
        .ch2_req(request),.ch2_rnw(1'b1),.ch2_ready(response_ready),
        .ch3_addr(27'd0),.ch3_dout(),.ch3_din(64'd0),.ch3_req(1'b0),.ch3_rnw(1'b1),.ch3_be(8'd0),.ch3_ready(),
        .ch4_addr(27'd0),.ch4_dout(),.ch4_din(64'd0),.ch4_req(1'b0),.ch4_rnw(1'b1),.ch4_be(8'd0),.ch4_ready(),
        .ch5_addr(27'd0),.ch5_din(64'd0),.ch5_req(1'b0),.ch5_burst(8'd1),.ch5_next(),.ch5_ready(),
        .ch6_addr(27'd0),.ch6_burst(8'd1),.ch6_req(1'b0),.ch6_dout(),.ch6_valid(),.ch6_ready()
    );
    integer commands=0,beats=0,replies=0,cycles=0;
    integer left=0,delay_count=0,next_delay=0;
    reg [28:0] response_address=0;
    reg [31:0] epoch=0;
    always @(negedge clk1x) if(done) replies=replies+1;
    function automatic [31:0] word_at(input [28:0] byte_address);
        word_at=32'ha5000000 ^ {3'd0,byte_address} ^ epoch;
    endfunction
    always @(posedge ddr_clk) begin
        cycles<=cycles+1;
        physical_ready<=0;
        if(physical_write) $fatal(1,"cartridge path wrote DDR");
        if(physical_read) begin
            if(left!=0) $fatal(1,"overlapping physical read");
            if(physical_address >= (32'h30000000>>3) &&
               (({3'd0,physical_address}<<3)+burst*8) <= 32'h3fc00000)
                response_address <= {1'b0,physical_address[24:0],3'd0};
            else if(expect_512 && physical_address >= (32'h28000000>>3) &&
               (({3'd0,physical_address}<<3)+burst*8) <= 32'h2c000000)
                response_address <= (physical_address >= (32'h2bc00000>>3))
                    ? 29'h0fc00000 + ((physical_address-(32'h2bc00000>>3))<<3)
                    : 29'h10000000 + ((physical_address-(32'h28000000>>3))<<3);
            else $fatal(1,"cartridge read/prefetch escaped owned banks: %h burst=%0d",physical_address,burst);
            left<=burst;
            delay_count<=next_delay;
            commands<=commands+1;
        end else if(delay_count!=0) delay_count<=delay_count-1;
        else if(left!=0) begin
            physical_data<={word_at(response_address+29'd4),word_at(response_address)};
            physical_ready<=1;
            response_address<=response_address+8;
            left<=left-1;
            beats<=beats+1;
        end
    end
    task submit(input [28:0] byte_address);
        @(negedge clk1x);source_address=byte_address[28:2];source_request=1;
        @(negedge clk1x);source_request=0;
    endtask
    task await_word(input [28:0] byte_address);
        integer t;
        reg [31:0] expected;
        begin
            if(expect_512) expected=byte_address>=29'h13c00000 ? 32'hffffffff : word_at({byte_address[28:2],2'b00});
            else expected=expect_large && byte_address[27:0]>=28'hfc00000 ? 32'hffffffff :
                word_at({1'b0,byte_address[27] & expect_large,byte_address[26:2],2'b00});
            t=0;
            while(!done && t<300) begin @(negedge clk1x);t=t+1;end
            if(!done || data!==expected)
                $fatal(1,"word %h got %h expected %h done=%b",byte_address,data,expected,done);
            @(negedge clk1x);
        end
    endtask
    task read_word(input [28:0] byte_address);
        submit(byte_address);await_word(byte_address);
    endtask
    task replace_image(input [15:0] download_index);
        @(negedge ddr_clk);
        console_reset_1x=1;console_reset_ddr=1;
        cart_state=1;cart_download_ddr=1;cart_download_raw=1;
        ioctl_index=download_index;
        repeat(6) @(negedge ddr_clk);
        cart_download_d=1;cart_download_ddr=0;cart_download_raw=0;cart_state=2;
        wait(flush_complete);@(negedge ddr_clk);cart_state=3;
        console_reset_1x=0;console_reset_ddr=0;
        expect_large=download_index[8] && download_index[5:0]==6'h03;
        expect_512=(&download_index[9:8]) && download_index[5:0]==6'h03;
    endtask
    integer before_commands,before_beats,before_cycles,before_replies;
    initial begin
        repeat(5) @(negedge clk1x);
        h3d_fabric_boot_reset=0;bridge_reset_ddr=0;
        console_reset_1x=0;console_reset_ddr=0;
        before_commands=commands;before_beats=beats;before_cycles=cycles;
        for(integer n=0;n<64;n=n+1) read_word(n*4);
        if(commands-before_commands!=8 || beats-before_beats!=32)
            $fatal(1,"small ROM read-ahead command amplification regressed");
        $display("CART_BRIDGE_LOW_BENCH words=64 commands=%0d beats=%0d cycles=%0d",commands-before_commands,beats-before_beats,cycles-before_cycles);
`ifndef LOW_ONLY
        // Default/unmarked mode retains the old alias even for high requests.
        read_word(28'h0008000);read_word(28'h8008000);
        read_word(28'hfc00000);read_word(28'hfffffff);
        for(integer n=0;n<16;n=n+1) read_word(28'h7ffffe0+n*4);
        replace_image(16'h0103);
        // Distinct first words and aligned cache lines on both sides of bit27.
        read_word(28'h0008000);read_word(28'h8008000);read_word(28'h0008000);
        for(integer n=0;n<16;n=n+1) read_word(28'h7ffffe0+n*4);
        before_commands=commands;
        for(integer n=0;n<16;n=n+1) read_word(28'hfbfffe0+n*4);
        if(commands-before_commands!=1) $fatal(1,"252 MiB crossing accessed padding DDR");
        before_commands=commands;
        read_word(28'hfc00000);read_word(28'hfd00000);read_word(28'hfffffff);
        if(commands!=before_commands) $fatal(1,"FF tail accessed graphics DDR");
        read_word(28'hfbffffc); // padding must not corrupt the last retained line

        // Reset while an upper-half DDR transaction owns the channel; a new
        // padding request must wait for its stale reply to drain.
        next_delay=50;before_replies=replies;before_commands=commands;
        submit(28'h8000040);
        wait(commands==before_commands+1);
        @(negedge ddr_clk);console_reset_1x=1;console_reset_ddr=1;
        repeat(8) @(negedge ddr_clk);
        console_reset_1x=0;console_reset_ddr=0;
        submit(28'hfc00000);await_word(28'hfc00000);
        if(replies!=before_replies+1 || commands!=before_commands+1)
            $fatal(1,"reset delivered stale DDR reply or sent padding request");
        next_delay=0;

        // Cancel a synthetic reply at the same reset boundary as a DDR reply.
        before_replies=replies;submit(28'hfffffff);
        wait(bridge.cd_busy);@(negedge ddr_clk);
        console_reset_1x=1;console_reset_ddr=1;
        repeat(8) @(negedge ddr_clk);
        console_reset_1x=0;console_reset_ddr=0;
        repeat(10) @(negedge clk1x);
        if(replies!=before_replies) $fatal(1,"padding reply crossed reset epoch");
        read_word(28'h8000080);

        // Replacement image changes every DDR word. Both actual product
        // flush probes must drain before any new CPU access is released.
        read_word(28'h0000000);
        console_reset_1x=1;console_reset_ddr=1;
        cart_state=1;cart_download_ddr=1;cart_download_raw=1;
        repeat(6) @(negedge ddr_clk);
        epoch=32'h10000000;
        cart_download_d=1;cart_download_ddr=0;cart_download_raw=0;cart_state=2;
        wait(flush_complete);@(negedge ddr_clk);cart_state=3;
        console_reset_1x=0;console_reset_ddr=0;
        read_word(28'h0000000);read_word(28'h8000000);read_word(28'hfc00000);
        // A small replacement clears extended mode; a guest reset preserves
        // that small mode too. Neither old padding nor bit27 may leak through.
        replace_image(16'h0003);
        read_word(28'h0008000);read_word(28'h8008000);
        read_word(28'hfc00000);read_word(28'hfffffff);
        console_reset_1x=1;console_reset_ddr=1;
        repeat(8) @(negedge ddr_clk);
        console_reset_1x=0;console_reset_ddr=0;
        read_word(28'h8008000);read_word(28'hfc00000);
        // 512 mode maps a rotated 64 MiB bank; equal normalized offsets
        // in the original and alternate banks must never hit each other's tag.
        replace_image(16'h0303);
        for(integer n=0;n<3;n=n+1) begin
            read_word(29'h00008000);read_word(29'h10008000);
            read_word(29'h03c00000);read_word(29'h0fc00000);
        end
        for(integer n=0;n<16;n=n+1) read_word(29'h0fbfffe0+n*4);
        for(integer n=0;n<16;n=n+1) read_word(29'h0fffffe0+n*4);
        before_commands=commands;
        for(integer n=0;n<16;n=n+1) read_word(29'h13bfffe0+n*4);
        if(commands-before_commands!=1) $fatal(1,"316 MiB crossing accessed omitted bytes");
        before_commands=commands;
        read_word(29'h13c00000);read_word(29'h18000000);read_word(29'h1fffffff);
        if(commands!=before_commands) $fatal(1,"512 FF tail issued DDR request");
        // Reset while an alternate-bank request owns its refill; the bank
        // register must stay paired with that old request until it drains.
        next_delay=50;before_replies=replies;before_commands=commands;
        submit(29'h10000040);wait(commands==before_commands+1);
        @(negedge ddr_clk);console_reset_1x=1;console_reset_ddr=1;
        repeat(8) @(negedge ddr_clk);
        console_reset_1x=0;console_reset_ddr=0;
        submit(29'h13c00000);await_word(29'h13c00000);
        if(replies!=before_replies+1 || commands!=before_commands+1)
            $fatal(1,"alternate-bank stale reply or padding request escaped reset");
        next_delay=0;read_word(29'h10008000);
        // Replacement during an accepted alternate-bank refill must drain
        // that old owner before the new mode's normal-bank flush can run.
        next_delay=50;before_replies=replies;before_commands=commands;
        submit(29'h10009000);wait(commands==before_commands+1);
        epoch=32'h20000000;replace_image(16'h0103);
        if(replies!=before_replies) $fatal(1,"old alternate-bank reply survived replacement");
        next_delay=0;
        // The flush has also displaced the old alternate-bank cache line.
        read_word(29'h10008000);read_word(29'h0fc00000);
        replace_image(16'h0003);read_word(29'h10008000);read_word(29'h18008000);
        replace_image(16'h0303);read_word(29'h10008000);read_word(29'h0fc00000);
        // A lone new bit without the LR1 bit does not select an extended mode.
        replace_image(16'h0203);read_word(29'h10008000);read_word(29'h18008000);
        // Only FS3 receives extended mode; the old C0 loader remains small.
        replace_image(16'h0103);read_word(28'h8008000);
        replace_image(16'h00c0);read_word(28'h8008000);read_word(28'hfc00000);
`endif
        $display("PASS: actual cartridge bridge/cache ROM boundaries, protected FF padding, and reset/replacement epochs");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
