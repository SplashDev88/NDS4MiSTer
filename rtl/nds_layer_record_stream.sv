// Five DDR64 beats per pixel. Fields are byte aligned for an ARM producer.
module nds_layer_record_stream (
    input logic clk,input logic reset_n,
    input logic in_valid,output logic in_ready,input logic [319:0] in_record,
    output logic out_valid,input logic out_ready,output logic [18:0] out_tag,
    output logic [31:0] out_pixel,output logic [7:0] out_r,out_g,out_b
);
    nds_video_pixel_stream stream(
        .clk(clk),.reset_n(reset_n),.in_valid(in_valid),.in_ready(in_ready),
        .layer_pixels(in_record[191:0]),.layer_ranks(in_record[215:192]),
        .layer_valid(in_record[221:216]),.blend_cnt(in_record[239:224]),
        .eva(in_record[244:240]),.evb(in_record[252:248]),
        .evy(in_record[260:256]),.window_effect_enable(in_record[264]),
        .in_tag(in_record[290:272]),.out_valid(out_valid),.out_ready(out_ready),
        .out_tag(out_tag),.out_pixel(out_pixel),.out_r(out_r),.out_g(out_g),.out_b(out_b)
    );
endmodule
