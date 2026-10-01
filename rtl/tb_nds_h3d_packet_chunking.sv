// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise real-size continuation boundaries with DDR stalls and ring wrap.
module tb_nds_h3d_packet_chunking;
    parameter integer CHUNK = 1024;
    localparam integer TOTAL = 10001;
    logic clk=0; always #5 clk=~clk;
    logic reset=1,session_flush=0;
    logic [31:0] session=7;
    logic record_valid=0,record_ready,record_frame_end=0;
    logic [127:0] record;
    logic [31:0] record_frame=1;
    logic boundary_valid=0,boundary_ready;
    logic [31:0] boundary_frame=1;
    logic active,full,packet_done,fault;
    logic [31:0] producer_sequence,acknowledged_sequence;
    logic [4:0] fault_reason;
    logic ddram_read,ddram_write;
    logic [7:0] ddram_burst_count,ddram_byte_enable;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data,ddram_read_data;
    integer cycles=0;
    wire ddram_busy=cycles%11==3 || cycles%7==4;
    wire ddram_command_accepted=(ddram_read||ddram_write)&&!ddram_busy;
    logic ddram_read_data_ready=0,read_pending=0;
    logic [63:0] pending_data;
    logic [63:0] mem[0:32767];
    integer burst_index=0,burst_base=0,burst_length=0;
    integer seen=0,packets=0,early_prefixes=0,queries=0;
    integer base,len,flags;
    logic [127:0] got;
    function automatic logic is_query(input integer i);
        return i==2300 || i==3324 || i==6000 || i==8200;
    endfunction
    function automatic logic [127:0] expected(input integer i);
        if (is_query(i)) return {64'd0,32'(i+1),32'd10};
        return {32'd0,32'(i),32'd0,32'h00002001};
    endfunction
    nds_h3d_frame_packet_writer #(.CONTROL_BASE_WORD(0),.SLOT_BASE_WORD(64),.MAX_RECORDS(CHUNK)) dut(.*);
    always @(posedge clk) begin
        cycles<=cycles+1;
        ddram_read_data_ready<=0;
        if(read_pending) begin
            ddram_read_data<=pending_data;ddram_read_data_ready<=1;read_pending<=0;
        end
        if(ddram_read && ddram_command_accepted) begin
            if(read_pending) $fatal(1,"overlapping reads");
            pending_data<=mem[ddram_address];read_pending<=1;
        end
        if(ddram_write && ddram_command_accepted) begin
            if(ddram_byte_enable!=8'hff) $fatal(1,"partial DDR write");
            if(burst_index==0) begin burst_base=ddram_address;burst_length=ddram_burst_count;end
            else if(ddram_address!=burst_base || ddram_burst_count!=burst_length) $fatal(1,"burst metadata changed");
            mem[burst_base+burst_index]=ddram_write_data;
            burst_index=burst_index+1;
            if(burst_index==burst_length) burst_index=0;
        end
        if(!reset && fault) $fatal(1,"writer fault %d",fault_reason);
        if(packet_done) begin
            packets=packets+1;base=64+((packets-1)%4)*8192;
            len=mem[base+4][63:32];flags=mem[base+3][63:32];
            if(mem[2]!=packets || mem[base+7]!=packets || mem[base+2]!=packets) $fatal(1,"commit order/sequence");
            if(mem[base]!=64'h0040000131423348 || mem[base+1]!=7 || mem[base+5]!=(packets-1)%4 || mem[base+6]!=0) $fatal(1,"header changed");
            if(len<1 || len>CHUNK || mem[base+4][31:0]!=len*16 || mem[base+3][31:0]!=1) $fatal(1,"length/frame changed");
            if(seen+len<TOTAL && flags!=1) $fatal(1,"early frame end");
            if(seen+len==TOTAL && flags!=2) $fatal(1,"missing terminal frame");
            if(seen+len> TOTAL) $fatal(1,"extra records");
            for(integer j=0;j<len;j=j+1) begin
                got={mem[base+8+j*2+1],mem[base+8+j*2]};
                if(got!==expected(seen+j)) $fatal(1,"record mismatch %d",seen+j);
                if(is_query(seen+j)) begin
                    if(j!=len-1 || flags!=1) $fatal(1,"query not immediate final continuation");
                    queries=queries+1;
                end
            end
            if(seen+len<=2300) early_prefixes=early_prefixes+1;
            seen=seen+len;mem[3]=packets;
        end
    end
    initial begin
        for(integer i=0;i<32768;i=i+1) mem[i]=0;
        mem[1]=7;
        repeat(5) @(negedge clk);reset=0;
        for(integer i=0;i<TOTAL;i=i+1) begin
            @(negedge clk);record=expected(i);record_frame_end=(i==TOTAL-1);record_valid=1;
            do @(posedge clk);while(!record_ready);
            @(negedge clk);record_valid=0;
        end
        wait(seen==TOTAL);repeat(12) @(negedge clk);
        if(queries!=4 || packets<5 || (CHUNK<=1024 && early_prefixes<2)) $fatal(1,"missing early work or fences");
        $display("PACKET_CHUNK_PASS chunk=%0d records=%0d packets=%0d fences=%0d early_prefixes=%0d stalled_ddr=1 ring_wrap=1",CHUNK,seen,packets,queries,early_prefixes);$finish;
    end
    initial begin #3000000;$fatal(1,"timeout");end
endmodule
