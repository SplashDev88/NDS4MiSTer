module nds_layer_selector #(
    parameter integer LAYERS = 6
) (
    input  logic [LAYERS*32-1:0] layer_pixels,
    input  logic [LAYERS*4-1:0]  layer_ranks,
    input  logic [LAYERS-1:0]    layer_valid,
    output logic [31:0] top_pixel,
    output logic [31:0] second_pixel
);
    integer i;
    logic [3:0] top_rank, second_rank;
    always_comb begin
        top_pixel=0; second_pixel=0; top_rank=4'hf; second_rank=4'hf;
        for(i=LAYERS-1;i>=0;i=i-1) begin
            if(layer_valid[i]) begin
                if(layer_ranks[i*4 +: 4] <= top_rank) begin
                    second_pixel=top_pixel; second_rank=top_rank;
                    top_pixel=layer_pixels[i*32 +: 32]; top_rank=layer_ranks[i*4 +: 4];
                end else if(layer_ranks[i*4 +: 4] <= second_rank) begin
                    second_pixel=layer_pixels[i*32 +: 32]; second_rank=layer_ranks[i*4 +: 4];
                end
            end
        end
    end
endmodule
