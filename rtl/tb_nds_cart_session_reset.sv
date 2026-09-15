// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_cart_session_reset;
    reg clk1x=0,ddr_clk=0;
    always #7 clk1x=~clk1x;
    always #5 ddr_clk=~ddr_clk;
    reg console_reset_1x=1,console_reset_ddr=1,bridge_reset_ddr=1;
    reg h3d_fabric_boot_reset=1;
    reg [1:0] cart_state=3;
    reg cart_download_ddr=0,cart_download_d=0,cart_download_raw=0;
    reg source_request=0,response_ready=0;
    reg [24:0] source_address=0;
    reg [31:0] response_data=0;
    wire request,done,flush_complete;
    wire [24:0] address;
    wire [31:0] data;
    cart_bridge_under_test dut(.*);
    integer requests=0,replies=0;
    always @(negedge ddr_clk) if(request) requests=requests+1;
    always @(negedge clk1x) if(done) replies=replies+1;
    task submit(input [24:0] addr);
        @(negedge clk1x);source_address=addr;source_request=1;
        @(negedge clk1x);source_request=0;
    endtask
    task complete(input [31:0] word_value);
        @(negedge ddr_clk);response_data=word_value;response_ready=1;
        @(negedge ddr_clk);response_ready=0;
    endtask
    task wait_requests(input integer count);
        integer t;
        begin
            t=0;
            while(requests<count && t<100) begin @(negedge ddr_clk);t=t+1;end
            if(requests!=count) $fatal(1,"request missing/duplicated expected=%0d actual=%0d",count,requests);
        end
    endtask
    integer old_requests,old_replies;
    initial begin
        repeat(5) @(negedge clk1x);
        h3d_fabric_boot_reset=0;bridge_reset_ddr=0;
        console_reset_1x=0;console_reset_ddr=0;
        for(integer n=0;n<16;n=n+1) begin
            old_requests=requests;old_replies=replies;
            submit(25'h100+n);wait_requests(old_requests+1);
            // Legacy DDR retains this request while CPU and optionally the
            // shell/session control reset. Delay its completion past release.
            @(negedge ddr_clk);
            console_reset_1x=1;console_reset_ddr=1;bridge_reset_ddr=!n[0];
            repeat(8) @(negedge ddr_clk);
            console_reset_1x=0;console_reset_ddr=0;bridge_reset_ddr=0;
            submit(25'h200+n);
            repeat(20) @(negedge ddr_clk);
            if(requests!=old_requests+1 || address!=25'h100+n)
                $fatal(1,"reset lost ownership of old cartridge read");
            complete(32'hbad00000+n);
            wait_requests(old_requests+2);
            repeat(10) @(negedge clk1x);
            if(replies!=old_replies || address!=25'h200+n)
                $fatal(1,"old response or reset-toggle reached new CPU epoch");
            complete(32'h12340000+n);
            repeat(10) @(negedge clk1x);
            if(replies!=old_replies+1 || data!=32'h12340000+n)
                $fatal(1,"first post-reset cartridge data incorrect");
        end
        // A download must still displace both ch2 cache lines while CPUs are
        // held reset; suppressing CPU traffic must not suppress flush probes.
        console_reset_1x=1;console_reset_ddr=1;
        cart_state=1;cart_download_ddr=1;cart_download_raw=1;
        repeat(6) @(negedge ddr_clk);
        cart_download_d=1;cart_download_ddr=0;cart_download_raw=0;cart_state=2;
        old_requests=requests;
        wait_requests(old_requests+1);
        if(address!=0) $fatal(1,"wrong first flush probe");
        complete(32'd0);wait_requests(old_requests+2);
        if(address!=8) $fatal(1,"wrong second flush probe");
        complete(32'd0);
        if(!flush_complete) $fatal(1,"download flush did not finish in reset");
        $display("PASS: 16 guest/shell resets retain cartridge DDR ownership, discard stale replies, preserve first new reads, and complete ROM cache flush");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
