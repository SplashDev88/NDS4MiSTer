`timescale 1ns/1ps
module tb_nds_rtc_host_bridge;
    reg clk=0,rtc_clk=0;
    always #5 clk=~clk;
    always #17 rtc_clk=~rtc_clk;
    reg [55:0] rtc_datetime=56'h59592304311226;
    reg rtc_date_written=0,io_enable=0,io_strobe=0;
    reg [15:0] io_din=0;
    wire io_override;
    wire [15:0] io_dout;
    nds_rtc_host_bridge dut(.*);
    task word(input [15:0] value,output [15:0] result);
        @(negedge clk);io_din=value;io_strobe=1;
        @(negedge clk);io_strobe=0;result=io_dout;
    endtask
    reg [15:0] value;
    task start;
        @(negedge clk);io_enable=0;
        repeat(2) @(negedge clk);
        if(io_override) $fatal(1,"override leaked outside transaction");
        io_enable=1;word(16'h47,value);
        if(!io_override || value!=16'h5254) $fatal(1,"signature");
    endtask
    task finish;
        @(negedge clk);io_enable=0;
        repeat(2) @(negedge clk);
    endtask
    task request;
        start;word(1,value);finish;
    endtask
    reg [95:0] snapshot;
    task read_snapshot;
        start;word(0,value);
        if(value!=16'h101) $fatal(1,"snapshot not ready: %h",value);
        for(integer i=0;i<6;i=i+1) begin word(0,value);snapshot[i*16+:16]=value;end
        finish;
    endtask
    initial begin
        repeat(4) @(negedge clk);
        start;word(0,value);if(value!=16'h100) $fatal(1,"unrequested data advertised ready");finish;
        io_enable=1;word(16'h45,value);if(io_override) $fatal(1,"claimed firmware command");finish;
        request;repeat(30) @(negedge clk);read_snapshot;
        if(snapshot!={32'd0,8'd0,56'h59592304311226}) $fatal(1,"initial snapshot %h",snapshot);
        // Two edits between host polls must not cancel as a bare toggle would.
        @(negedge rtc_clk);rtc_datetime=56'h00000005010127;rtc_date_written=~rtc_date_written;
        repeat(2) @(negedge rtc_clk);
        rtc_datetime=56'h01000005010127;rtc_date_written=~rtc_date_written;
        repeat(2) @(negedge rtc_clk);
        request;repeat(30) @(negedge clk);
        // Change live data halfway through SPI: all words still one snapshot.
        start;word(0,value);if(value!=16'h101) $fatal;
        word(0,value);snapshot[15:0]=value;
        @(negedge rtc_clk);rtc_datetime=56'h02000005010127;rtc_date_written=~rtc_date_written;
        repeat(10) @(negedge clk);
        for(integer i=1;i<6;i=i+1) begin word(0,value);snapshot[i*16+:16]=value;end
        finish;
        if(snapshot!={32'd2,8'd0,56'h01000005010127}) $fatal(1,"torn snapshot %h",snapshot);
        request;repeat(30) @(negedge clk);read_snapshot;
        if(snapshot!={32'd3,8'd0,56'h02000005010127}) $fatal(1,"lost edit %h",snapshot);
        // A request accepted faster than the destination can acknowledge is
        // ignored while busy, never flips the mailbox twice/loss of request.
        start;word(1,value);finish;
        start;word(1,value);finish;
        repeat(40) @(negedge clk);read_snapshot;
        if(snapshot!={32'd3,8'd0,56'h02000005010127}) $fatal(1,"busy request corrupted data");
        $display("PASS RTC coherent cross-clock snapshots, sequence, routing and busy requests");$finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
