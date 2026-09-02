module tb_nds_cpu_ddram;
`ifndef CPU_DDRAM_DUT
`define CPU_DDRAM_DUT nds_cpu_ddram
`endif
    logic clk=0,reset=1,request=0,rnw;always #5 clk=~clk;
    logic [31:0] address,wdata,rdata;logic [1:0] access;logic done;
    logic rd,we,busy=0,ready=0;logic [7:0] burst,be;logic [28:0] daddr;
    logic [63:0] din,dout=0;
    `CPU_DDRAM_DUT #(.BASE_WORD(29'h01200000)) dut(.*,
        .read_not_write(rnw),.write_data(wdata),.read_data(rdata),
        .ddram_read(rd),.ddram_write(we),.ddram_burst_count(burst),
        .ddram_address(daddr),.ddram_write_data(din),.ddram_byte_enable(be),
        .ddram_busy(busy),.ddram_read_data(dout),.ddram_read_data_ready(ready));

    task start(input [31:0] a,input bit is_read,input [1:0] size,input [31:0] value);
        @(negedge clk);address=a;rnw=is_read;access=size;wdata=value;request=1;
    endtask
    task release_request;@(negedge clk);request=0;@(posedge clk);endtask

    initial begin
        rnw=0;address=0;access=0;wdata=0;
        repeat(3)@(posedge clk);reset=0;

        start(32'h20,0,2'b10,32'h11223344);busy=1;
        repeat(2)begin
            @(posedge clk);
            if(done)$fatal(1,"write completed while DDR busy");
        end
        @(negedge clk);busy=0;wait(we);
        if(daddr!==29'h01200004||burst!==1||be!==8'h0f||din!==64'h0000000011223344)$fatal(1,"word write");
        wait(done);release_request();

        start(32'h2e,0,2'b01,32'h0000a1b2);wait(we);
        if(daddr!==29'h01200005||be!==8'hc0||din!==64'ha1b2000000000000)$fatal(1,"half write");
        wait(done);release_request();

        start(32'h37,0,2'b00,32'h0000005a);wait(we);
        if(daddr!==29'h01200006||be!==8'h80||din!==64'h5a00000000000000)$fatal(1,"byte write");
        wait(done);release_request();

        start(32'h44,1,2'b10,0);wait(rd);
        if(daddr!==29'h01200008||be!==8'hf0)$fatal(1,"word read request");
        @(posedge clk);
        @(negedge clk);dout=64'hdeadbeef89abcdef;ready=1;
        @(posedge clk);#1;if(!done||rdata!==32'hdeadbeef)$fatal(1,"word read data %h",rdata);
        @(negedge clk);ready=0;request=0;@(posedge clk);

        start(32'h4a,1,2'b01,0);wait(rd);
        @(posedge clk);
        @(negedge clk);dout=64'h0011223344556677;ready=1;
        @(posedge clk);#1;if(!done||rdata[15:0]!==16'h4455)$fatal(1,"half read data %h",rdata);
        @(negedge clk);ready=0;request=0;@(posedge clk);

        $display("PASS: CPU bus accesses local MiSTer DDR with correct lanes");
        $finish;
    end
endmodule
