// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_h3d_probe_cdc;
    parameter integer CLOCK_CASE=0;
    logic clk=0, reset=1, toggle=0;
    logic [31:0] source=0;
    wire [31:0] sample_data;
    nds_h3d_probe_cdc dut(clk,reset,source,toggle,sample_data);
    always #(3.0 + 0.7*CLOCK_CASE) clk=~clk;
    logic [31:0] old_data=0;
    integer checks=0;
    initial begin
        #27; reset=0;
        for (integer i=0;i<1000;i=i+1) begin
            #(53.7 + (i%7)*0.13);
            old_data=sample_data;
            source=32'h8000ffff ^ (32'h19660d*i);
            toggle=~toggle;
            // Data must not leak through before the synchronized marker.
            #1;
            if (sample_data!==old_data) $fatal(1,"early bundled capture");
            #44;
            if (sample_data!==source) $fatal(1,"lost/torn bundled capture %d",i);
            checks++;
            if (i==347 || i==706) begin
                reset=1; toggle=0; source=0;
                #23;
                if (sample_data!==0) $fatal(1,"reset failed");
                reset=0;
            end
        end
        $display("PASS query probe CDC case=%d snapshots=%d",CLOCK_CASE,checks);
        $finish;
    end
endmodule
