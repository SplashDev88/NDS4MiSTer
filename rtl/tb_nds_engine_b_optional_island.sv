`timescale 1ns/1ps
// Elaborate the actual island with unused peripherals left unbound.
// These are its output-ownership gates, not a duplicate behavioral model.
module tb_nds_engine_b_optional_island;
  nds_nitro_console_island dut();
  initial begin
    force dut.bridge_reset_ddr = 1'b0;
    force dut.h3d_control_release = 1'b1;
    force dut.h3d_engine_b_applied = 1'b0;
    #1;
    if(dut.h3d_external_video_enable !== 1'b1) $fatal(1,"A-only display disabled");
    force dut.h3d_engine_b_applied = 1'b1;
    #1;
    if(dut.h3d_external_video_enable !== 1'b1) $fatal(1,"paired display disabled");
    force dut.h3d_control_release = 1'b0;
    #1;
    if(dut.h3d_external_video_enable !== 1'b0) $fatal(1,"unreleased display enabled");
    force dut.h3d_control_release = 1'b1;
    force dut.bridge_reset_ddr = 1'b1;
    #1;
    if(dut.h3d_external_video_enable !== 1'b0) $fatal(1,"reset display enabled");
    $display("PASS: actual island matched output gate, B Off/On and reset/release"); $finish;
  end
endmodule
