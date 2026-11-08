// SPDX-License-Identifier: GPL-3.0-only
module nds_fpga3d_mix_test(input logic [5:0] source,dest,input logic [7:0] weight,input logic [2:0] shift,output logic [5:0] result_value);
 nds_fpga3d_pixels dut(.clk(1'b0),.reset(1'b1),.ce(1'b0));
 assign result_value=dut.mix6(source,dest,weight,int'(shift));
endmodule
