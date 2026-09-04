`timescale 1ns/1ps

module tb_nds_audio_headroom;
    logic signed [15:0] input_left;
    logic signed [15:0] input_right;
    logic signed [15:0] output_left;
    logic signed [15:0] output_right;

    nds_audio_headroom #(.SHIFT(1)) dut (
        .input_left,
        .input_right,
        .output_left,
        .output_right
    );

    task automatic check(
        input logic signed [15:0] left_value,
        input logic signed [15:0] right_value,
        input logic signed [15:0] expected_left,
        input logic signed [15:0] expected_right
    );
        begin
            input_left = left_value;
            input_right = right_value;
            #1;
            if (output_left !== expected_left ||
                output_right !== expected_right)
                $fatal(1,
                    "headroom mismatch in=%0d/%0d out=%0d/%0d expected=%0d/%0d",
                    left_value, right_value, output_left, output_right,
                    expected_left, expected_right);
        end
    endtask

    initial begin
        check(16'sd0,       16'sd0,       16'sd0,       16'sd0);
        check(16'sd32767,  -16'sd32768,   16'sd16383,  -16'sd16384);
        check(16'sd2,      -16'sd2,       16'sd1,      -16'sd1);
        check(16'sd1,      -16'sd1,       16'sd0,      -16'sd1);
        check(16'sh5555,    16'shaaaa,    16'sh2aaa,    16'shd555);
        $display("PASS: NDS output headroom preserves signed stereo and adds exactly 6.02 dB headroom");
        $finish;
    end
endmodule
