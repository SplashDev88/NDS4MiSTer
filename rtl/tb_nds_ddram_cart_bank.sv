// SPDX-License-Identifier: GPL-3.0-or-later
// Cartridge bank ownership must survive command stalls/refill and must never
// leak into any of the five other legacy DDR clients, especially ch6.
`timescale 1ns/1ps
module tb_nds_ddram_cart_bank;
    reg clk=0;
    always #5 clk=~clk;
    reg [6:1] req=0;
    wire [6:1] ready;
    reg [27:1] addr[6:1];
    reg altbank=0;
    reg busy=0;
    wire [28:0] physical;
    wire read_en,write_en;
    wire [7:0] burst;
    wire [31:0] cart_data;
    reg [63:0] read_data=0;
    reg read_valid=0;
    ddram dut(
        .DDRAM_CLK(clk),.DDRAM_BUSY(busy),.DDRAM_BURSTCNT(burst),
        .DDRAM_ADDR(physical),.DDRAM_DOUT(read_data),
        .DDRAM_DOUT_READY(read_valid),.DDRAM_RD(read_en),
        .DDRAM_DIN(),.DDRAM_BE(),.DDRAM_WE(write_en),
        .ch1_addr(addr[1]),.ch1_req(req[1]),.ch1_rnw(1'b1),
        .ch1_din(16'd0),.ch1_dout(),.ch1_ready(ready[1]),
        .ch2_addr(addr[2]),.ch2_altbank(altbank),.ch2_req(req[2]),
        .ch2_rnw(1'b1),.ch2_din(32'd0),.ch2_dout(cart_data),.ch2_ready(ready[2]),
        .ch3_addr(addr[3]),.ch3_req(req[3]),.ch3_rnw(1'b1),.ch3_be(8'hff),
        .ch3_din(64'd0),.ch3_dout(),.ch3_ready(ready[3]),
        .ch4_addr(addr[4]),.ch4_req(req[4]),.ch4_rnw(1'b1),.ch4_be(8'hff),
        .ch4_din(64'd0),.ch4_dout(),.ch4_ready(ready[4]),
        .ch5_addr(addr[5]),.ch5_req(req[5]),.ch5_burst(8'd1),
        .ch5_din(64'd0),.ch5_next(),.ch5_ready(ready[5]),
        .ch6_addr(addr[6]),.ch6_req(req[6]),.ch6_burst(8'd4),
        .ch6_dout(),.ch6_valid(),.ch6_ready(ready[6])
    );
    reg [31:0] expected_physical[0:127];
    integer pushed=0,accepted=0,left=0,gap=0;
    reg [31:0] response_address;
    reg refill_bank;
    function automatic [31:0] word_at(input [31:0] byte_address);
        word_at=32'hb639e8a5 ^ byte_address;
    endfunction
    always @(posedge clk) begin
        read_valid<=0;
        if((read_en||write_en) && !busy) begin
            if(accepted==pushed || {physical,3'b0} !== expected_physical[accepted])
                $fatal(1,"DDR bank leak command%0d physical=%h expected=%h",accepted,{physical,3'b0},expected_physical[accepted]);
            accepted<=accepted+1;
            if(read_en) begin
                if(left) $fatal(1,"overlapping read commands");
                response_address<={physical,3'b0};left<=burst;gap<=3;
                refill_bank<=dut.ram_altbank;
            end
        end else if(gap) gap<=gap-1;
        else if(left) begin
            read_data<={word_at(response_address+4),word_at(response_address)};
            read_valid<=1;response_address<=response_address+8;left<=left-1;gap<=1;
        end
        if(left && dut.state==5 && dut.ram_altbank!==refill_bank)
            $fatal(1,"cartridge bank changed during read-ahead fill");
    end
    always @(negedge clk) begin
        if(busy && read_en && {physical,3'b0} !== expected_physical[accepted])
            $fatal(1,"physical bank/address changed while command stalled");
    end
    task cart(input bit bank,input [27:0] byte_address,input bit miss,input bit stall);
        reg [31:0] mapped;
        begin
            mapped=bank ? 32'h28000000+{6'd0,byte_address[25:0]} : 32'h30000000+byte_address;
            if(miss) begin expected_physical[pushed]=mapped&32'hffffffe0;pushed=pushed+1;end
            @(negedge clk);addr[2]=byte_address[27:1];altbank=bank;req[2]=1;
            @(negedge clk);req[2]=0;
            if(stall) begin
                // Grant has latched the request, but acceptance is stalled.
                wait(read_en);busy=1;altbank=~bank;
                repeat(4) @(negedge clk);
                busy=0;
            end
            wait(ready[2]);@(negedge clk);
            if(cart_data!==word_at(mapped&32'hfffffffc))
                $fatal(1,"bank-tag alias bank=%b byte=%h data=%h expected=%h",bank,byte_address,cart_data,word_at(mapped&32'hfffffffc));
            // The requested beat can complete before the refill drains.
            altbank=~bank;
            wait(dut.state==0);repeat(2) @(negedge clk);
        end
    endtask
    task other_channel(input integer channel);
        begin
            expected_physical[pushed]=32'h3fd80000+channel*32;
            pushed=pushed+1;
            @(negedge clk);addr[channel]=(28'hfd80000+channel*32)>>1;req[channel]=1;
            @(negedge clk);req[channel]=0;
            wait(ready[channel]);@(negedge clk);
            wait(dut.state==0);repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        for(integer c=1;c<=6;c=c+1) addr[c]=0;
        repeat(4) @(negedge clk);
        // Every offset within a line, both banks, and both word halves.
        for(integer c=0;c<3;c=c+1) begin
            cart(1,28'h8000+c*32,1,c==0);
            for(integer w=1;w<8;w=w+1) cart(1,28'h8000+c*32+w*4,0,0);
            cart(0,28'h8000+c*32,1,0);
            for(integer w=1;w<8;w=w+1) cart(0,28'h8000+c*32+w*4,0,0);
        end
        // Re-arm the alternate bank before EVERY other client's grant.
        // ch6 deliberately runs first while the old shared ch register is2.
        cart(1,28'h9000,1,0);other_channel(6);
        cart(1,28'ha000,1,0);other_channel(3);
        cart(1,28'hb000,1,0);other_channel(5);
        cart(1,28'hc000,1,0);other_channel(1);
        cart(1,28'hd000,1,0);other_channel(4);
        cart(0,28'hd000,1,0);
        if(accepted!=pushed || left) $fatal(1,"unconsumed DDR expectations");
        $display("PASS: cartridge bank tags, all line offsets, stalls/refill ownership, and ch1/ch3/ch4/ch5/ch6 physical isolation (%0d commands)",accepted);
        $finish;
    end
    initial begin #200000;$fatal(1,"bank/interleave timeout");end
endmodule
