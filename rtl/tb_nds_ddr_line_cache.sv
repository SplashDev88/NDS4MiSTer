module tb_nds_ddr_line_cache;
    localparam integer LINES=20;localparam [28:0] BASE=29'h06000000;localparam [31:0] SEQ=32'h12340000;
    logic clk=0,reset_n=0,start,busy,frame_fetched,ddram_busy,ddram_dout_ready,ddram_rd;
    logic acquire,acquire_bank,acquire_ready,read_enable,read_bank,read_valid,release_valid,release_bank;
    logic [1:0] bank_free;logic [7:0] ddram_burstcnt;logic [28:0] ddram_addr;logic [63:0] ddram_dout;logic [31:0] acquire_sequence;
    logic [8:0] read_addr;logic [319:0] read_data;wire [28:0] base_addr=BASE;wire [31:0] sequence_base=SEQ;
    integer cycle=0,send_beat=-1,send_count=0,send_start=0,record_number,line,x,k;logic [319:0] response_record;logic saw_frame_fetched=0;
    always #5 clk=~clk;
    nds_ddr_line_cache #(.FRAME_LINES(LINES)) dut(.*);
    function automatic [319:0] pattern(input integer ln,input integer px);
        integer j;begin for(j=0;j<10;j=j+1)pattern[j*32+:32]=(ln*32'h10204081)^px^(j*32'h11111111);end
    endfunction
    initial begin
        start=0;ddram_busy=0;ddram_dout_ready=0;ddram_dout=0;acquire=0;acquire_bank=0;acquire_sequence=0;read_enable=0;read_bank=0;read_addr=0;release_valid=0;release_bank=0;
        repeat(3)@(posedge clk);@(negedge clk);reset_n=1;start=1;@(negedge clk);start=0;
        for(line=0;line<LINES;line=line+1)begin
            acquire=1;acquire_bank=line[0];acquire_sequence=SEQ+line;
            while(!acquire_ready)@(negedge clk);
            @(negedge clk);acquire=0;
            for(x=0;x<512;x=x+1)begin
                repeat(8)@(negedge clk);
                read_enable=1;read_bank=line[0];read_addr=x;
                @(posedge clk);#1;if(!read_valid||read_data!==pattern(line,x))$fatal(1,"line %0d pixel %0d",line,x);
                @(negedge clk);read_enable=0;
            end
            release_valid=1;release_bank=line[0];@(negedge clk);release_valid=0;
        end
        wait(!busy);if(!saw_frame_fetched)$fatal(1,"frame completion");
        $display("NDS DDR line cache: %0d lines passed with concurrent prefetch, paced scanout, and ownership",LINES);$finish;
    end
    always @(posedge clk)if(frame_fetched)saw_frame_fetched<=1;
    always @(negedge clk)begin
        cycle=cycle+1;ddram_busy=(cycle%13)==4;ddram_dout_ready=0;
        if(send_beat>=0&&(cycle%3)!=1)begin
            record_number=(send_start+send_beat)/5;
            response_record=pattern(record_number/512,record_number%512);
            ddram_dout=response_record[(send_beat%5)*64+:64];
            ddram_dout_ready=1;
            if(send_beat==send_count-1)send_beat=-1;
            else send_beat=send_beat+1;
        end
        if(ddram_rd)begin
            if(ddram_burstcnt==0||ddram_burstcnt>160||ddram_burstcnt%5!=0)
                $fatal(1,"burst %0d",ddram_burstcnt);
            send_start=ddram_addr-BASE;send_count=ddram_burstcnt;
            send_beat=0;
        end
    end
    initial begin wait(reset_n);repeat(2000000)@(posedge clk);$fatal(1,"timeout");end
endmodule
