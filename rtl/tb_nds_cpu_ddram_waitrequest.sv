module tb_nds_cpu_ddram_waitrequest;
    logic clk=0,reset=1,request=0,rnw=1;
    always #5 clk=~clk;
    logic [31:0] cpu_address=32'h00004800;
    logic [1:0] access=2'b10;
    logic [31:0] write_data=0;
    logic [31:0] read_data;
    logic done,rd,we,busy=0,ready=0;
    logic [7:0] burst,be;
    logic [28:0] address;
    logic [63:0] din,dout=0;

    nds_cpu_ddram_held dut(
        .clk,.reset,.request,.address(cpu_address),
        .read_not_write(rnw),.access,.write_data,
        .read_data,.done,.ddram_read(rd),.ddram_write(we),
        .ddram_burst_count(burst),.ddram_address(address),
        .ddram_write_data(din),.ddram_byte_enable(be),
        .ddram_busy(busy),.ddram_read_data(dout),
        .ddram_read_data_ready(ready));

    initial begin
        repeat(3) @(posedge clk);
        reset=0;
        @(negedge clk);
        request=1;

        // The client observes busy low while preparing the registered command.
        wait(rd);
        // Avalon waitrequest may be asserted while that command is presented.
        // A conforming master must retain RD and its address until an edge on
        // which busy is low actually accepts the transaction.
        busy=1;
        repeat(3) begin
            @(posedge clk); #1;
            if(!rd)
                $fatal(1,"CPU DDR read was dropped while waitrequest was high");
        end
        @(negedge clk);
        busy=0;
        #1;
        if(!rd)
            $fatal(1,"CPU DDR read was not present before the accepting edge");
        @(posedge clk); #1;
        if(rd)
            $fatal(1,"CPU DDR read remained asserted after acceptance");

        @(negedge clk);
        dout=64'h11223344e3a00301;
        ready=1;
        @(posedge clk); #1;
        if(!done||read_data!==32'he3a00301)
            $fatal(1,"accepted held read did not complete");

        @(negedge clk);
        ready=0;
        request=0;
        @(posedge clk);
        @(negedge clk);
        cpu_address=32'h00004806;
        access=2'b01;
        write_data=32'h0000a1b2;
        rnw=0;
        request=1;
        wait(we);
        busy=1;
        repeat(3) begin
            @(posedge clk); #1;
            if(!we||done)
                $fatal(1,"CPU DDR write was not retained while busy");
        end
        @(negedge clk);
        busy=0;
        #1;
        if(!we||address!==29'h05820900||be!==8'hc0||
           din!==64'ha1b2000000000000)
            $fatal(1,"held write payload changed before acceptance");
        @(posedge clk); #1;
        if(we||!done)
            $fatal(1,"held write did not complete on accepting edge");

        $display("PASS: CPU DDR command survives external waitrequest");
        $finish;
    end
endmodule
