`timescale 1ns/1ps
`default_nettype none

module tb_nds_sound_output_start_guard;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic reset = 1'b1;
    logic engine_cycles_valid = 1'b0;
    logic signed [15:0] raw_audio_left = 16'sd0;
    logic signed [15:0] raw_audio_right = 16'sd0;
    logic output_started;
    logic output_known;

    nds_sound_output_start_guard dut (.*);

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic require(
        input logic condition,
        input string message
    );
        begin
            if (condition !== 1'b1)
                $fatal(1, "%s", message);
        end
    endtask

    initial begin
        tick();
        require(output_started === 1'b0,
            "output started during reset");
        require(output_known === 1'b1,
            "known silence was rejected");

        reset = 1'b0;
        repeat (3) tick();
        require(output_started === 1'b0,
            "known controls/silence started output without engine time");

        engine_cycles_valid = 1'b1;
        tick();
        engine_cycles_valid = 1'b0;
        require(output_started === 1'b0,
            "output started on the same edge as the first cycle beat");

        raw_audio_left = 16'sd123;
        raw_audio_right = -16'sd456;
        tick();
        require(output_started === 1'b1,
            "known output did not start after an accepted cycle beat");

`ifndef VERILATOR
        raw_audio_left = 16'shxxxx;
        #1;
        require(output_known === 1'b0,
            "unknown raw output was accepted");
`endif

        reset = 1'b1;
        tick();
        require(output_started === 1'b0,
            "reset did not clear output-start history");

        $display(
            "PASS: FPGA sound waits for a first known post-cycle engine output");
        $finish;
    end
endmodule

`default_nettype wire
