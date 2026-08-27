module tb_nds_ddr_layer_reader;
    localparam [28:0] BASE=29'h06000000;localparam integer RECORDS=2000;
    logic clk=0,reset_n=0,start,busy,done,ddram_busy,ddram_dout_ready,ddram_rd,record_valid,record_ready;
    logic [7:0] ddram_burstcnt;logic [28:0] ddram_addr;logic [63:0] ddram_dout,mem[0:RECORDS*5-1];logic [319:0] expected[0:RECORDS-1],record_data;
    wire [28:0] base_addr=BASE;wire [19:0] record_count=RECORDS;
    integer send_index=-1,send_beat=0,send_count=0,received=0,cycle=0;
    always #5 clk=~clk;
    nds_ddr_layer_reader dut(.*);
    initial begin
        $readmemh("/tmp/nds_ddr_beats.txt",mem);$readmemh("/tmp/nds_ddr_records.txt",expected);
        start=0;ddram_busy=0;ddram_dout_ready=0;ddram_dout=0;record_ready=0;
        repeat(3)@(posedge clk);@(negedge clk);reset_n=1;start=1;@(negedge clk);start=0;
    end
    always @(negedge clk)begin
        cycle=cycle+1;ddram_busy=(cycle%11)==3;ddram_dout_ready=0;record_ready=(cycle%7)!=2;
        // Never return beat zero on the same half-cycle that discovers a new
        // command; the reader enters RECEIVE on the following active edge.
        if(send_index>=0&&(cycle%4)!=1)begin
            ddram_dout=mem[send_index+send_beat];ddram_dout_ready=1;send_beat=send_beat+1;
            if(send_beat==send_count)send_index=-1;
        end
        if(ddram_rd)begin
            if(ddram_burstcnt==0||ddram_burstcnt>80||ddram_burstcnt%5!=0)
                $fatal(1,"burst count %0d",ddram_burstcnt);
            send_index=ddram_addr-BASE;send_beat=0;
            send_count=ddram_burstcnt;
        end
    end
    always @(posedge clk)begin
        if(record_valid&&record_ready)begin
            if(record_data!==expected[received])$fatal(1,"record %0d",received);received=received+1;
        end
        #1;
        if(done)begin
            if(received!=RECORDS)$fatal(1,"received %0d",received);
            if(ddram_addr!=BASE+RECORDS*5)$fatal(1,"final address");
            $display("NDS DDR reader: %0d records passed in bounded multi-record bursts with wait states and stalls",received);$finish;
        end
    end
    initial begin wait(reset_n);repeat(100000)@(posedge clk);$fatal(1,"timeout");end
endmodule
