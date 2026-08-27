module tb;
    localparam WORDS=256,BURST=16;logic clk=0,reset_n=0,start=0,ddram_busy=0,ddram_dout_ready=0;
    logic [63:0] ddram_dout,write_data;logic busy,done,ddram_rd,write_enable;
    logic [7:0] ddram_burstcnt;logic [28:0] ddram_addr;logic [14:0] write_addr;integer sent=0,received=0;
    always #5 clk=~clk;
    nds_compact_frame_fetch #(.FRAME_WORDS(WORDS),.BURST_WORDS(BURST)) dut(.*,.base_addr(29'h1234));
    initial begin repeat(2)@(negedge clk);reset_n=1;@(negedge clk);start=1;@(negedge clk);start=0;end
    always @(negedge clk)begin
        ddram_busy=($time%70)==0;ddram_dout_ready=0;
        if(sent&&($time%30)!=0)begin ddram_dout=received;ddram_dout_ready=1;sent=sent-1;received=received+1;end
        // A newly accepted Avalon command cannot also retroactively produce
        // its first response beat on this same testbench edge.
        if(ddram_rd&&!ddram_busy)begin if(ddram_burstcnt!=BURST)$fatal(1,"burst");sent=BURST;end
    end
    // The DUT registers write_enable/address/data together on the positive
    // edge. Sample them on the following negative edge so the check observes
    // one coherent transaction rather than racing nonblocking assignments.
    always @(negedge clk)if(write_enable)begin
        if(write_addr!==write_data[14:0])$fatal(1,"word %0d data %0d",write_addr,write_data);
        if(write_addr==WORDS-1)begin wait(done);if(received!=WORDS)$fatal(1,"received");
            $display("NDS compact fetch: %0d words passed with burst backpressure",WORDS);$finish;end
    end
    initial begin repeat(10000)@(posedge clk);$fatal(1,"timeout");end
endmodule
