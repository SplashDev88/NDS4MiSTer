module tb_nds_ddram_arbiter;
    logic clk=0,reset=1;always #5 clk=~clk;
    logic a_rd=0,a_we=0,b_rd=0,b_we=0;
    logic [7:0] a_burstcnt=1,b_burstcnt=3;
    logic [28:0] a_addr=29'h11,b_addr=29'h22,daddr;
    logic [63:0] a_din=64'ha,b_din=64'hb,din,dout=0,a_dout,b_dout;
    logic [7:0] a_be=8'h0f,b_be=8'hf0,be,burst;
    logic a_busy,b_busy,a_ready,b_ready,rd,we,busy=0,ready=0;
    integer beat=0,a_returns=0,b_returns=0,a_writes=0;
    logic sync_a_pending=0,sync_b_pending=0;

    nds_ddram_arbiter dut(
        .clk,.reset,.a_rd,.a_we,.a_burstcnt,.a_addr,.a_din,.a_be,
        .a_busy,.a_dout,.a_dout_ready(a_ready),
        .b_rd,.b_we,.b_burstcnt,.b_addr,.b_din,.b_be,
        .b_busy,.b_dout,.b_dout_ready(b_ready),
        .ddram_rd(rd),.ddram_we(we),.ddram_burstcnt(burst),
        .ddram_addr(daddr),.ddram_din(din),.ddram_be(be),
        .ddram_busy(busy),.ddram_dout(dout),.ddram_dout_ready(ready));

    always @(posedge clk) begin
        // Model the real DDR clients: they register a one-cycle command pulse
        // only after sampling their busy input low at a clock edge.
        a_we <= 0;
        if(sync_a_pending && !a_busy) begin
            a_we <= 1;
            sync_a_pending <= 0;
        end
        b_rd <= 0;
        if(sync_b_pending && !b_busy) begin
            b_rd <= 1;
            sync_b_pending <= 0;
        end
        ready<=0;
        if(rd)begin
            if(daddr!==29'h22||burst!==3)$fatal(1,"B burst not selected");
            beat<=3;
        end else if(beat>0)begin
            dout<=64'hb000+beat;ready<=1;beat<=beat-1;
        end
        if(a_ready)a_returns<=a_returns+1;
        if(b_ready)b_returns<=b_returns+1;
        if(we)begin
            if(daddr!==29'h11||din!==64'ha||be!==8'h0f)
                $fatal(1,"A write routing");
            a_writes<=a_writes+1;
        end
        if(a_ready&&b_ready)$fatal(1,"response delivered to both clients");
    end

    initial begin
        fork begin
            repeat(500) @(posedge clk);
            $fatal(1, "timeout sel_b=%0d dwell=%0d pending=%0d a_busy=%0d b_busy=%0d a_we=%0d b_rd=%0d a_writes=%0d b_returns=%0d",
                   dut.selected_b, dut.grant_dwell, dut.read_pending,
                   a_busy, b_busy, a_we, b_rd, a_writes, b_returns);
        end join_none
        repeat(3)@(posedge clk);reset=0;
        // B asks through the same registered busy/command handshake used by
        // the real compact-frame client. It must retain all return beats.
        @(negedge clk);sync_b_pending=1;
        wait(b_returns==3);repeat(2)@(posedge clk);
        if(a_returns!=0)$fatal(1,"B response leaked to A");

        // Simultaneous registered requests: round-robin service must accept
        // both without losing either client's one-cycle pulse.
        @(negedge clk);sync_a_pending=1;sync_b_pending=1;
        wait(a_writes==1);
        wait(b_returns==6);repeat(2)@(posedge clk);
        if(a_writes!=1)$fatal(1,"A was starved");

        // Repeat A alone to cover a grant reached after multiple idle turns.
        @(negedge clk);sync_a_pending=1;
        wait(a_writes==2);repeat(2)@(posedge clk);
        $display("PASS: DDR arbiter preserves burst ownership and fairness");
        $finish;
    end
endmodule
