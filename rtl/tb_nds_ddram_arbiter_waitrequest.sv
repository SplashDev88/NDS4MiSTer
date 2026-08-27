module tb_nds_ddram_arbiter_waitrequest;
    logic clk=0,reset=1;
    always #5 clk=~clk;
    logic a_rd=0,a_we=0,a_busy,a_ready;
    logic b_rd=0,b_we=0,b_busy,b_ready;
    logic [63:0] a_dout,b_dout;
    logic ddram_rd,ddram_we,ddram_busy=0,ddram_ready=0;
    logic [7:0] ddram_burst,ddram_be;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din,ddram_dout=0;

`ifdef DDRAM_ARBITER_DUT_HELD
    nds_ddram_arbiter_held dut(
`else
    nds_ddram_arbiter dut(
`endif
        .clk,.reset,
        .a_rd,.a_we,.a_burstcnt(8'd1),.a_addr(29'h01234567),
        .a_din(64'h1122334455667788),.a_be(8'hf0),
        .a_busy,.a_dout,.a_dout_ready(a_ready),
        .b_rd,.b_we,.b_burstcnt(8'd1),.b_addr(29'h07654321),
        .b_din(64'h8877665544332211),.b_be(8'h0f),
        .b_busy,.b_dout,.b_dout_ready(b_ready),
        .ddram_rd,.ddram_we,.ddram_burstcnt(ddram_burst),
        .ddram_addr,.ddram_din,.ddram_be,
        .ddram_busy,.ddram_dout,.ddram_dout_ready(ddram_ready));

    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk);
        reset=0;
        // The registered client samples its exposed grant at a clock edge.
        // Model a registered client: it emits its pulse one clock after
        // observing busy low.
        @(posedge clk);
        if(a_busy)$fatal(1,"client A did not receive initial grant");
        a_rd<=1;
        @(negedge clk);
        // External waitrequest changes while the pulse is being presented.
        ddram_busy=1;
        @(posedge clk);
        a_rd<=0;
        repeat(3) begin
            @(posedge clk); #1;
            if(!ddram_rd||ddram_addr!==29'h01234567||
               ddram_burst!==1||ddram_be!==8'hf0)
                $fatal(1,"arbiter did not retain read while waitrequest high rd=%0d addr=%h burst=%0d be=%h sel=%0d pending=%0d",
                    ddram_rd,ddram_addr,ddram_burst,ddram_be,
                    dut.selected_b,dut.command_pending);
        end
        @(negedge clk);
        ddram_busy=0;
        #1;
        if(!ddram_rd||ddram_addr!==29'h01234567)
            $fatal(1,"retained read absent before accepting edge");
        @(posedge clk); #1;
        if(ddram_rd)
            $fatal(1,"retained read remained asserted after acceptance");
        @(negedge clk);
        ddram_dout=64'hdeadbeefcafef00d;
        ddram_ready=1;
        #1;
        if(!a_ready||b_ready||a_dout!==64'hdeadbeefcafef00d)
            $fatal(1,"retained read response ownership mismatch");
        @(posedge clk); #1;
        if(a_ready||b_ready)
            $fatal(1,"read response remained asserted after consumption");

        @(negedge clk);
        ddram_ready=0;
        @(posedge clk);
        if(b_busy)$fatal(1,"client B did not receive post-read grant");
        b_we<=1;
        @(negedge clk);
        ddram_busy=1;
        @(posedge clk);
        b_we<=0;
        repeat(3) begin
            @(posedge clk); #1;
            if(!ddram_we||ddram_addr!==29'h07654321||
               ddram_din!==64'h8877665544332211||ddram_be!==8'h0f)
                $fatal(1,"arbiter did not retain write payload while busy");
        end
        @(negedge clk);
        ddram_busy=0;
        #1;
        if(!ddram_we)$fatal(1,"retained write absent before accepting edge");
        @(posedge clk); #1;
        if(ddram_we)$fatal(1,"retained write remained after acceptance");

        $display("PASS: arbiter retains client command through waitrequest");
        $finish;
    end
endmodule
