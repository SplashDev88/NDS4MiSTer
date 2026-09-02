module nds_ddr_record_pipeline (
    input logic clk,input logic reset_n,input logic start,
    input logic [28:0] base_addr,input logic [19:0] record_count,
    output logic busy,output logic done,
    output logic [7:0] ddram_burstcnt,output logic [28:0] ddram_addr,
    input logic ddram_busy,input logic [63:0] ddram_dout,input logic ddram_dout_ready,
    output logic ddram_rd,
    output logic out_valid,input logic out_ready,output logic [18:0] out_tag,
    output logic [31:0] out_pixel,output logic [7:0] out_r,out_g,out_b
);
    logic record_valid,record_ready;logic [319:0] record_data;
    nds_ddr_layer_reader reader(
        .clk(clk),.reset_n(reset_n),.start(start),.base_addr(base_addr),
        .record_count(record_count),.busy(busy),.done(done),
        .ddram_burstcnt(ddram_burstcnt),.ddram_addr(ddram_addr),
        .ddram_busy(ddram_busy),.ddram_dout(ddram_dout),
        .ddram_dout_ready(ddram_dout_ready),.ddram_rd(ddram_rd),
        .record_valid(record_valid),.record_ready(record_ready),.record_data(record_data)
    );
    nds_layer_record_stream records(
        .clk(clk),.reset_n(reset_n),.in_valid(record_valid),.in_ready(record_ready),
        .in_record(record_data),.out_valid(out_valid),.out_ready(out_ready),
        .out_tag(out_tag),.out_pixel(out_pixel),.out_r(out_r),.out_g(out_g),.out_b(out_b)
    );
endmodule
