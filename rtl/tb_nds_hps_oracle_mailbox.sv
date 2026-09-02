module tb_nds_hps_oracle_mailbox;
    localparam [28:0] BASE=29'h00300000;
    logic clk=0,reset=1,request=0,cpu_is_arm9=1,rnw=1;always #5 clk=~clk;
    logic [31:0] elapsed_cycles=32'h12345678;
    logic [31:0] fence_sequence=32'h89abcdef;
    logic [31:0] address=0,wdata=0,rdata;logic [1:0] access=2'b10;logic done;
    logic [31:0] completed_fence_sequence;
    logic [3:0] debug_state;
    logic irq_arm9,irq_arm7,halt_arm9,halt_arm7;
    logic rd,we,busy=0,ready=0;logic [7:0] burst,be;logic [28:0] daddr;
    logic [63:0] din,dout=0,mem[0:4];integer writes=0,polls=0,remaining=0;
    logic saw_poll_burst=0;
    nds_hps_oracle_mailbox #(.BASE_WORD(BASE),.POLL_DELAY_CYCLES(2)) dut(.*,
        .read_not_write(rnw),.write_data(wdata),.read_data(rdata),
        .ddram_read(rd),.ddram_write(we),.ddram_burst_count(burst),
        .ddram_address(daddr),.ddram_write_data(din),.ddram_byte_enable(be),
        .ddram_busy(busy),.ddram_read_data(dout),.ddram_read_data_ready(ready));

    always @(posedge clk) begin
        ready <= 0;
        if(we)begin
            if(daddr<BASE||daddr>BASE+4)$fatal(1,"mailbox write address");
            mem[daddr-BASE] <= din; writes <= writes+1;
            if(daddr==BASE && writes!=3)$fatal(1,"header was not published last");
        end
        if(rd)begin
            if(burst!=2)$fatal(1,"response/IRQ poll must be a two-word burst");
            saw_poll_burst<=1;
            polls <= polls+1; ready <= 1;
            remaining <= 1;
            if(polls==0)dout <= {32'hffffeeee,32'h11111111};
            else dout <= {mem[0][63:32],32'h89abcdef};
        end else if(remaining!=0)begin
            ready<=1;remaining<=0;dout<=64'h0000000000000009;
        end
    end

    initial begin
        repeat(3)@(posedge clk);reset=0;
        @(negedge clk);address=32'h04000208;wdata=32'h12345678;
        access=2'b01;rnw=0;cpu_is_arm9=1;request=1;
        wait(done);#1;
        if(debug_state!==4'd10)
            $fatal(1,"mailbox debug state did not expose WAIT_RELEASE");
        if(rdata!==32'h89abcdef||polls!=2||!irq_arm9||irq_arm7||
            halt_arm9||!halt_arm7)
            $fatal(1,"response/generation/IRQ/halt check");
        if(completed_fence_sequence!==fence_sequence)
            $fatal(1,"completed fence identity %h",completed_fence_sequence);
        if(mem[1]!==64'h1234567804000208)$fatal(1,"transaction payload");
        if(mem[2]!==64'h123456780000000a)$fatal(1,"control/cycles payload %h",mem[2]);
        if(mem[4]!==64'h89abcdef00000000)$fatal(1,"fence payload %h",mem[4]);
        if(mem[0]!==64'h000000014f53444e)$fatal(1,"header payload %h",mem[0]);
        if(!saw_poll_burst||be!==8'hff)$fatal(1,"DDRAM transfer shape");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        $display("PASS: HPS oracle mailbox publishes cycles atomically and rejects stale responses");
        $finish;
    end
endmodule
