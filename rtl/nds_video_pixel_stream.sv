module nds_video_pixel_stream (
    input logic clk,input logic reset_n,
    input logic in_valid,output logic in_ready,
    input logic [191:0] layer_pixels,input logic [23:0] layer_ranks,input logic [5:0] layer_valid,
    input logic [15:0] blend_cnt,input logic [4:0] eva,input logic [4:0] evb,input logic [4:0] evy,input logic window_effect_enable,
    input logic [18:0] in_tag,
    output logic out_valid,input logic out_ready,
    output logic [18:0] out_tag,output logic [31:0] out_pixel,
    output logic [7:0] out_r,output logic [7:0] out_g,output logic [7:0] out_b
);
    logic [18:0] tag_stage1,tag_register;

    nds_pixel_pipeline pipeline(
        .clk(clk),.reset_n(reset_n),.in_valid(in_valid),.in_ready(in_ready),
        .layer_pixels(layer_pixels),.layer_ranks(layer_ranks),.layer_valid(layer_valid),
        .blend_cnt(blend_cnt),.eva(eva),.evb(evb),.evy(evy),
        .window_effect_enable(window_effect_enable),.out_valid(out_valid),
        .out_ready(out_ready),.out_pixel(out_pixel)
    );

    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin tag_stage1<=0;tag_register<=0;end
        else begin
            if(!out_valid||out_ready) tag_register<=tag_stage1;
            if(in_valid&&in_ready) tag_stage1<=in_tag;
        end
    end
    assign out_tag=tag_register;

    // Expand melonDS six-bit channels to the full video DAC range by bit
    // replication.  End points remain exact: 0 -> 0 and 63 -> 255.
    assign out_r={out_pixel[5:0],out_pixel[5:4]};
    assign out_g={out_pixel[13:8],out_pixel[13:12]};
    assign out_b={out_pixel[21:16],out_pixel[21:20]};
endmodule
