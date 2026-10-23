// SPDX-License-Identifier: GPL-3.0-or-later
// A reply burst must drain before queued cartridge/framebuffer traffic owns
// the legacy port. Return-data validity is independent of command waitrequest.
`timescale 1ns/1ps
module tb_nds_readback_burst_contention;
    reg clk=0;
    always #5 clk=~clk;
    reg [6:1] req=0;
    wire [6:1] ready;
    reg [27:1] address[6:1];
    reg [7:0] reply_burst=16;
    wire [7:0] burst;
    wire [28:0] physical;
    wire rd,wr,v3,v6;
    wire [63:0] q3,q6;
    wire [31:0] q2;
    reg busy=0,valid=0;
    reg [63:0] data=0;
    ddram #(.CART_WIDE_BANK(1),.CH3_READ_BURST(1)) dut(
        .DDRAM_CLK(clk),.DDRAM_BUSY(busy),.DDRAM_DOUT(data),.DDRAM_DOUT_READY(valid),
        .DDRAM_ADDR(physical),.DDRAM_BURSTCNT(burst),.DDRAM_RD(rd),.DDRAM_WE(wr),
        .DDRAM_DIN(),.DDRAM_BE(),
        .ch1_addr(address[1]),.ch1_req(req[1]),.ch1_rnw(1'b1),.ch1_din(16'd0),.ch1_dout(),.ch1_ready(ready[1]),
        .ch2_addr(address[2]),.ch2_altbank(1'b1),.ch2_req(req[2]),.ch2_rnw(1'b1),.ch2_din(32'd0),.ch2_dout(q2),.ch2_ready(ready[2]),
        .ch3_addr(address[3]),.ch3_req(req[3]),.ch3_rnw(1'b1),.ch3_din(64'd0),.ch3_be(8'd0),
        .ch3_burst(reply_burst),.ch3_valid(v3),.ch3_dout(q3),.ch3_ready(ready[3]),
        .ch4_addr(address[4]),.ch4_req(req[4]),.ch4_rnw(1'b1),.ch4_din(64'd0),.ch4_be(8'd0),.ch4_dout(),.ch4_ready(ready[4]),
        .ch5_addr(address[5]),.ch5_req(req[5]),.ch5_burst(8'd1),.ch5_din(64'd0),.ch5_next(),.ch5_ready(ready[5]),
        .ch6_addr(address[6]),.ch6_req(req[6]),.ch6_burst(8'd7),.ch6_dout(q6),.ch6_valid(v6),.ch6_ready(ready[6]));
    integer cycle=0,left=0,commands=0,seen3=0,seen6=0;
    integer completions[6:1];
    reg [31:0] response_address;
    reg [31:0] expected_address[0:255];
    integer expected_burst[0:255];
    integer pushed=0;
    function automatic [63:0] contents(input [31:0] a);
        contents={32'h85acf013^a,32'hb6739e20^a};
    endfunction
    // Deterministic stalls cover both back-to-back and gapped return data,
    // including returning most of a burst while command acceptance is blocked.
    always @(negedge clk) busy=(cycle%7<3);
    always @(posedge clk) begin
        cycle<=cycle+1;valid<=0;
        if((rd||wr) && !busy) begin
            if(left) $fatal(1,"command overlap before burst drained");
            if(commands>=pushed || {physical,3'b0}!==expected_address[commands] || burst!==expected_burst[commands])
                $fatal(1,"wrong owner/address/burst at command %0d",commands);
            commands<=commands+1;
            if(rd) begin left<=burst;response_address<={physical,3'b0};end
        end else if(left && cycle%4!=0) begin
            data<=contents(response_address);valid<=1;
            response_address<=response_address+8;left<=left-1;
        end
        if(v3) begin
            if(q3!==contents(32'h30000000+{address[3],1'b0}+seen3*8)) $fatal(1,"reply beat lost/reordered");
            seen3<=seen3+1;
        end
        if(v6) begin
            if(q6!==contents(32'h30000000+{address[6],1'b0}+seen6*8)) $fatal(1,"framebuffer beat lost/reordered");
            seen6<=seen6+1;
        end
        for(integer c=1;c<=6;c=c+1) if(ready[c]) completions[c]<=completions[c]+1;
        if(ready[3] && seen3!=(reply_burst==0?1:reply_burst)) $fatal(1,"reply completed before all beats");
        if(ready[6] && seen6!=7) $fatal(1,"framebuffer completed before all beats");
        if(ready[2] && q2!==(32'hb6739e20^(32'h20000000+{address[2],1'b0}))) $fatal(1,"cartridge data contaminated");
    end
    task expect_command(input [31:0] a,input integer n);
        begin expected_address[pushed]=a;expected_burst[pushed]=n;pushed=pushed+1;end
    endtask
    initial begin
        for(integer c=1;c<=6;c=c+1) begin address[c]=0;completions[c]=0;end
        for(integer run=0;run<24;run=run+1) begin
            repeat(4) @(negedge clk);
            for(integer c=1;c<=6;c=c+1) address[c]=(28'hf80000+run*512+c*64)>>1;
            reply_burst=run%3==0 ? 0 : run%3==1 ? 1 : 16;
            seen3=0;seen6=0;
            expect_command(32'h30000000+{address[3],1'b0},reply_burst==0?1:reply_burst);
            // These requests arrive while ch3 owns a physical read. The
            // controller's existing priority order must survive that burst.
            expect_command(32'h30000000+{address[1],1'b0},1);
            expect_command(32'h20000000+{address[2],1'b0},4);
            expect_command(32'h30000000+{address[4],1'b0},1);
            expect_command(32'h30000000+{address[6],1'b0},7);
            expect_command(32'h30000000+{address[5],1'b0},1);
            req[3]=1;@(negedge clk);req[3]=0;
            wait(dut.state==6);@(negedge clk);req=6'b111011;
            @(negedge clk);req=0;
            wait(completions[5]==run+1);repeat(3) @(negedge clk);
            for(integer c=1;c<=6;c=c+1) if(completions[c]!=run+1) $fatal(1,"queued request lost or duplicated");
            if(commands!=pushed || left) $fatal(1,"burst tail not drained");
        end
        $display("PASS: 24 reply/cartridge/framebuffer contention rounds, 144 commands, zero/one/16-beat replies, independent DDR stalls");
        $finish;
    end
    initial begin #300000;$fatal(1,"reply contention timeout");end
endmodule
