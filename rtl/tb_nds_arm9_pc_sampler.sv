`timescale 1ns/1ps
module tb_nds_arm9_pc_sampler;
    reg cpu_clk=0, ddr_clk=0, reset=1;
    always #10 cpu_clk=~cpu_clk;
    always #7 ddr_clk=~ddr_clk;
    reg [31:0] pc=32'h02001008;
    reg thumb=0, halted=0, dma_hold=0, guest_reset=0, vblank=0;
    wire [31:0] out_pc, meta;
    nds_arm9_pc_sampler #(.PERIOD(12), .JITTER_BITS(3)) dut (
        .cpu_clk, .cpu_reset(reset), .architectural_pc(pc), .thumb,
        .halted, .dma_hold, .guest_reset, .vblank_async(vblank),
        .ddr_clk, .ddr_reset(reset), .pc(out_pc), .metadata(meta));
    integer count=0;
    reg [7:0] last_seq=8'hff;
    always @(negedge ddr_clk) if (!reset && meta[31:28]==4'hb && meta[7:0]!=last_seq) begin
        if (count && meta[7:0] != last_seq+8'd1) $fatal(1,"sequence discontinuity");
        if (out_pc != 32'h02001008 && out_pc != 32'h01ff9148) $fatal(1,"torn PC");
        // Inputs below change together on the source falling edge.
        if (out_pc==32'h02001008 && meta[26:24]!=3'b000) $fatal(1,"torn ARM flags");
        if (out_pc==32'h01ff9148 && meta[26:24]!=3'b111) $fatal(1,"torn Thumb flags");
        last_seq=meta[7:0];count=count+1;
    end
    initial begin
        #100; @(negedge cpu_clk);reset=0;
        repeat(3) begin
            #2000; @(negedge cpu_clk);vblank=1;
            #100; @(negedge cpu_clk);vblank=0;
        end
        #1000;if(meta[23:8]!=3) $fatal(1,"frame count");
        @(negedge cpu_clk);pc=32'h01ff9148;thumb=1;halted=1;dma_hold=1;
        #10000;if(count<20) $fatal(1,"insufficient samples");
        @(negedge cpu_clk);guest_reset=1;
        #1000;if(!meta[27] || meta[23:8]!=0) $fatal(1,"guest reset tagging");
        @(negedge cpu_clk);reset=1;
        #200;if(meta!=0 || out_pc!=0) $fatal(1,"reset did not discard snapshot");
        count=0;last_seq=8'hff;
        @(negedge cpu_clk);reset=0;guest_reset=0;
        #1000;if(count==0) $fatal(1,"reset did not recover");
        $display("PASS: coherent asynchronous PC/flags/frame capture, sequence and reset");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
