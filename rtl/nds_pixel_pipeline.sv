module nds_pixel_pipeline (
    input logic clk,input logic reset_n,
    input logic in_valid,output logic in_ready,
    input logic [191:0] layer_pixels,input logic [23:0] layer_ranks,input logic [5:0] layer_valid,
    input logic [15:0] blend_cnt,input logic [4:0] eva,input logic [4:0] evb,input logic [4:0] evy,input logic window_effect_enable,
    output logic out_valid,input logic out_ready,output logic [31:0] out_pixel
);
    logic [31:0] top_pixel,second_pixel,composited_pixel;
    logic stage1_valid,stage1_ready;
    logic [31:0] stage1_top,stage1_second;
    logic [15:0] stage1_blend_cnt;
    logic [4:0] stage1_eva,stage1_evb,stage1_evy;
    logic stage1_window_effect_enable;
    nds_layer_selector selector(.layer_pixels(layer_pixels),.layer_ranks(layer_ranks),.layer_valid(layer_valid),.top_pixel(top_pixel),.second_pixel(second_pixel));
    nds_color_compositor compositor(.val1(stage1_top),.val2(stage1_second),.blend_cnt(stage1_blend_cnt),.eva(stage1_eva),.evb(stage1_evb),.evy(stage1_evy),.window_effect_enable(stage1_window_effect_enable),.result(composited_pixel));
    assign stage1_ready=!stage1_valid;
    assign in_ready=stage1_ready;
    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            stage1_valid<=0;out_valid<=0;out_pixel<=0;
            stage1_top<=0;stage1_second<=0;stage1_blend_cnt<=0;
            stage1_eva<=0;stage1_evb<=0;stage1_evy<=0;stage1_window_effect_enable<=0;
        end else begin
            if(!out_valid||out_ready) begin
                out_valid<=stage1_valid;
                if(stage1_valid) out_pixel<=composited_pixel;
                if(stage1_valid) stage1_valid<=0;
            end
            if(stage1_ready) begin
                stage1_valid<=in_valid;
                if(in_valid) begin
                    stage1_top<=top_pixel;stage1_second<=second_pixel;
                    stage1_blend_cnt<=blend_cnt;stage1_eva<=eva;stage1_evb<=evb;stage1_evy<=evy;
                    stage1_window_effect_enable<=window_effect_enable;
                end
            end
        end
    end
endmodule
