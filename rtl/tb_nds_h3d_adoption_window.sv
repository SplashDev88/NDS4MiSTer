`timescale 1ns/1ps
module tb_nds_h3d_adoption_window;
    logic clk=0;
    always #5 clk=~clk;
    logic reset=1, lcd_phase=0, merge_start=0, merge_end=0;
    logic [8:0] lcd_line=0;
    logic [7:0] merge_y=0;
    wire switch_allowed;
    nds_h3d_adoption_window dut (.*);
    integer checks=0;
    task automatic check(input logic expected);
        begin
            #1;
            if (switch_allowed !== expected)
                $fatal(1,"window mismatch line=%0d merge=%0d got=%b expected=%b",lcd_line,merge_y,switch_allowed,expected);
            checks=checks+1;
        end
    endtask
    task automatic phase(input integer y);
        begin
            @(negedge clk);lcd_phase=1;lcd_line=y;
            // Cutoff/visible event must close in this cycle, before a flop.
            if (y<192 || y>=240) check(0);
            @(negedge clk);lcd_phase=0;
        end
    endtask
    task automatic tail;
        begin
            @(negedge clk);merge_y=191;merge_end=1;
            @(negedge clk);merge_end=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); reset=0;
        // No completed visible tail, including boot directly into blanking.
        for(integer y=192;y<263;y=y+1) begin phase(y);check(0);end
        for(integer frame=0;frame<4;frame=frame+1) begin
            for(integer y=0;y<192;y=y+1) begin phase(y);check(0);end
            tail();check(0);
            for(integer y=192;y<240;y=y+1) begin phase(y);check(1);end
            for(integer y=240;y<263;y=y+1) begin phase(y);check(0);end
        end
        // Source blanking alone does not permit a switch during a late merge.
        phase(0);phase(191);
        @(negedge clk);merge_y=191;merge_start=1;
        @(negedge clk);merge_start=0;
        phase(192);repeat(20) begin @(negedge clk);check(0);end
        tail();check(1);
        // Immediate merge start wins even if blank state was already open.
        @(negedge clk);merge_y=0;merge_start=1;check(0);
        @(negedge clk);merge_start=0;check(0);
        @(negedge clk);merge_end=1;
        @(negedge clk);merge_end=0;check(0);
        // Stale line191 end at wrap may not arm a later blank interval.
        @(negedge clk);lcd_phase=1;lcd_line=0;merge_y=191;merge_end=1;check(0);
        @(negedge clk);lcd_phase=0;merge_end=0;
        phase(192);check(0);
        tail();check(1);
        @(negedge clk);reset=1;check(0);
        @(negedge clk);reset=0;check(0);
        phase(193);check(0);
        $display("PASS: raw LCD adoption window %0d checks; cutoff, wrap, late merges and reset protected",checks);
        $finish;
    end
endmodule
