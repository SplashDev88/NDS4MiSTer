module tb;
    logic clk=0,reset_n=0,start=0,ddram_busy=0,ddram_dout_ready=0;always #5 clk=~clk;
    logic [63:0] ddram_dout;logic busy,done,valid,compact,ddram_rd;logic [28:0] frame_addr,ddram_addr;
    logic [63:0] frame_sequence;logic [10:0] audio_frames;
    logic [7:0] ddram_burstcnt;logic [511:0] header;
    nds_frame_publication_reader dut(.*,.control_addr(29'h06000000));
    task run(input logic expected);
        @(negedge clk);start=1;@(negedge clk);start=0;wait(ddram_rd);
        for(integer i=0;i<8;i++)begin @(negedge clk);ddram_dout=header[i*64 +:64];ddram_dout_ready=1;@(negedge clk);ddram_dout_ready=0;end
        wait(done);#1;if(valid!==expected)$fatal(1,"valid %0d expected %0d",valid,expected);
    endtask
    initial begin
        header=0;header[63:0]=64'h315542504c53444e;header[95:64]=1;header[127:96]=64;
        header[191:128]=2;header[223:192]=1;header[255:224]=3932160;
        header[287:256]=40;header[319:288]=98304;header[383:320]=64'h12345678;header[447:384]=2;
        repeat(2)@(negedge clk);reset_n=1;run(1);if(frame_addr!=29'h06100000||frame_sequence!=64'h12345678)$fatal(1,"published fields");
        header[95:64]=2;header[255:224]=196608;header[287:256]=2;run(1);if(!compact)$fatal(1,"compact ABI");
        header[95:64]=1;header[255:224]=3932160;header[287:256]=40;
        header[191:128]=3;header[447:384]=3;run(0);
        header[191:128]=4;run(0);
        header[447:384]=4;header[223:192]=2;run(0);
        $display("NDS publication reader: stable slots accepted; odd, torn, and out-of-range headers rejected");$finish;
    end
endmodule
