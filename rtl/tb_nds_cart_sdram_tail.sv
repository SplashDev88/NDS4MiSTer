// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_cart_sdram_tail;
    reg clk=0,mem_clk=0,reset=1;
    always #5 clk=~clk;
    always #3.7 mem_clk=~mem_clk;
    reg cart_download=0,full_download=0,ioctl_wr=0,read_req=0;
    reg [26:0] ioctl_addr=0;
    reg [15:0] ioctl_data=0;
    reg [25:0] read_addr=0;
    wire ioctl_wait,loaded,fault,read_ready,ram_req,ram_rnw;
    wire [31:0] read_data;
    wire [26:1] ram_addr;
    wire [15:0] ram_data;
    reg ram_ready=0;
    reg [63:0] ram_result=0;
    nds_cart_sdram_tail #(.TAIL_BYTES(256)) dut(.*);
    reg [15:0] memory[0:127];
    integer delay_left=0,commands=0,reads=0,writes=0,extra_delay=0;
    reg saved_read;
    reg [6:0] saved_addr;
    reg [15:0] saved_data;
    always @(posedge mem_clk) begin
        ram_ready<=0;
        if (ram_req) begin
            if(delay_left)$fatal(1,"overlapping SDRAM command");
            if(ram_addr<26'h800000 || ram_addr>=26'h800080)$fatal(1,"escaped SDRAM tail");
            saved_addr<=ram_addr-26'h800000;saved_data<=ram_data;saved_read<=ram_rnw;
            delay_left<=4+extra_delay;commands<=commands+1;
        end else if(delay_left>1) delay_left<=delay_left-1;
        else if(delay_left==1) begin
            delay_left<=0;ram_ready<=1;
            if(saved_read) begin
                if(saved_addr[1:0])$fatal(1,"unaligned SDRAM line");
                ram_result<={memory[saved_addr+3],memory[saved_addr+2],memory[saved_addr+1],memory[saved_addr]};
                reads<=reads+1;
            end else begin memory[saved_addr]<=saved_data;writes<=writes+1;end
        end
    end
    task begin_image;
        @(negedge clk);cart_download=1;full_download=1;
        repeat(3)@(negedge clk);
        if(loaded)$fatal(1,"download released early");
    endtask
    task write_half(input integer at,input [15:0] value);
        wait(!ioctl_wait);@(negedge clk);ioctl_addr=at;ioctl_data=value;ioctl_wr=1;
        @(negedge clk);ioctl_wr=0;
        wait(!ioctl_wait);@(negedge clk);
    endtask
    task end_image;
        @(negedge clk);cart_download=0;full_download=0;
        repeat(5)@(negedge clk);
    endtask
    task read_word(input integer at,input [31:0] expected);
        @(negedge clk);read_addr=at;read_req=1;
        @(negedge clk);read_req=0;
        wait(read_ready);#1;
        if(read_data!==expected)$fatal(1,"tail %h got %h expected %h",at,read_data,expected);
        @(negedge clk);
    endtask
    integer i,old_reads;
    initial begin
        repeat(4)@(negedge clk);reset=0;
        repeat(3)@(negedge clk);
        if(!loaded)$fatal(1,"normal cartridge blocked");
        begin_image();write_half(0,16'h1234);end_image();
        if(loaded)$fatal(1,"partial upload admitted");
        begin_image();write_half(2,16'habcd);end_image();
        if(loaded || !fault)$fatal(1,"out-of-order upload admitted");
        begin_image();
        for(i=0;i<128;i=i+1)write_half(i*2,16'h8100+i);
        end_image();if(!loaded || fault)$fatal(1,"complete upload rejected");
        old_reads=reads;
        for(i=0;i<64;i=i+1)read_word(i*4,{16'(16'h8101+i*2),16'(16'h8100+i*2)});
        if(reads-old_reads!=32)$fatal(1,"line cache did not serve adjacent word");
        read_word(256,32'hffffffff);
        if(reads-old_reads!=32)$fatal(1,"out-of-range read touched SDRAM");
        // Replacement invalidates the old line and overwrites every byte.
        begin_image();
        extra_delay=17;
        for(i=0;i<128;i=i+1)write_half(i*2,16'h4200+i);
        end_image();if(!loaded || fault)$fatal(1,"delayed upload rejected");
        for(i=0;i<64;i=i+1)read_word(i*4,{16'(16'h4201+i*2),16'(16'h4200+i*2)});
        begin_image();write_half(1,0);end_image();
        if(!fault || loaded)$fatal(1,"odd write admitted");
        @(negedge clk);cart_download=1;
        repeat(4)@(negedge clk);cart_download=0;
        repeat(4)@(negedge clk);if(!loaded || fault)$fatal(1,"normal replacement remained blocked");
        $display("PASS: tail CDC upload/readback, complete-image gate, cache, replacement, invalid offsets and delayed replies");
        $finish;
    end
    initial begin #10000000;$fatal(1,"tail watchdog");end
endmodule
