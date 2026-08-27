module nds_mister_video_test (
    input  logic clk,
    input  logic reset,
    output logic ce_pixel,
    output logic de,
    output logic hsync,
    output logic vsync,
    output logic [7:0] red,
    output logic [7:0] green,
    output logic [7:0] blue
);
    localparam integer H_ACTIVE=512,H_FRONT=16,H_SYNC=48,H_TOTAL=640;
    localparam integer V_ACTIVE=192,V_FRONT=3,V_SYNC=6,V_TOTAL=260;

    logic reset_n;
    logic [3:0] pixel_divider;
    logic [9:0] source_x;
    logic [8:0] source_y;
    logic source_valid,source_ready;
    logic [191:0] layer_pixels;
    logic [23:0] layer_ranks;
    logic [5:0] layer_valid;
    logic [15:0] blend_cnt;
    logic [4:0] eva,evb,evy;
    logic window_effect_enable;
    logic [18:0] source_tag,result_tag;
    logic result_valid;
    logic [31:0] result_pixel;
    logic [7:0] result_r,result_g,result_b;
    logic [5:0] r6,g6,b6;
    logic active_source;

    assign reset_n=!reset;
    always_ff @(posedge clk) begin
        if(reset) pixel_divider<=0;
        else pixel_divider<=pixel_divider==6 ? 0 : pixel_divider+1'b1;
    end
    assign source_valid=pixel_divider==6;

    always_ff @(posedge clk) begin
        if(reset) begin source_x<=0;source_y<=0;end
        else if(source_valid && source_ready) begin
            if(source_x==H_TOTAL-1) begin
                source_x<=0;
                source_y<=source_y==V_TOTAL-1 ? 0 : source_y+1'b1;
            end else source_x<=source_x+1'b1;
        end
    end

    assign active_source=(source_x<H_ACTIVE)&&(source_y<V_ACTIVE);
    assign r6=source_x[5:0];
    assign g6=source_y[5:0];
    assign b6=source_x[8] ? (source_x[5:0]^source_y[5:0]) : source_y[5:0];
    // Candidate zero is a normal BG layer (flag bit zero). Brightness is
    // enabled on alternating 32-line bands to exercise real color arithmetic.
    assign layer_pixels={{160{1'b0}},8'h01,2'b0,b6,2'b0,g6,2'b0,r6};
    assign layer_ranks=0;
    assign layer_valid=active_source ? 6'b000001 : 0;
    assign blend_cnt=16'h0081; // BG0 first target, brightness increase.
    assign eva=5'd8;
    assign evb=5'd8;
    assign evy=5'd4;
    assign window_effect_enable=active_source && source_y[5];
    assign source_tag={source_y,source_x};

    nds_video_pixel_stream pixels(
        .clk(clk),.reset_n(reset_n),.in_valid(source_valid),.in_ready(source_ready),
        .layer_pixels(layer_pixels),.layer_ranks(layer_ranks),.layer_valid(layer_valid),
        .blend_cnt(blend_cnt),.eva(eva),.evb(evb),.evy(evy),
        .window_effect_enable(window_effect_enable),.in_tag(source_tag),
        .out_valid(result_valid),.out_ready(1'b1),.out_tag(result_tag),
        .out_pixel(result_pixel),.out_r(result_r),.out_g(result_g),.out_b(result_b)
    );

    assign ce_pixel=result_valid;
    assign de=result_valid&&(result_tag[18:10]<V_ACTIVE)&&(result_tag[9:0]<H_ACTIVE);
    assign hsync=!((result_tag[9:0]>=H_ACTIVE+H_FRONT)&&(result_tag[9:0]<H_ACTIVE+H_FRONT+H_SYNC));
    assign vsync=!((result_tag[18:10]>=V_ACTIVE+V_FRONT)&&(result_tag[18:10]<V_ACTIVE+V_FRONT+V_SYNC));
    assign red=de ? result_r : 0;
    assign green=de ? result_g : 0;
    assign blue=de ? result_b : 0;
endmodule
