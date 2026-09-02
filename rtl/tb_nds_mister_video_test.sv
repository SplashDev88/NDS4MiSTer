module tb_nds_mister_video_test;
    logic clk=0,reset=1,ce_pixel,de,hsync,vsync;logic [7:0] red,green,blue;
    integer pixels=0,active=0,hs_low=0,vs_low=0,frames=0;
    always #5 clk=~clk;
    nds_mister_video_test dut(.*);
    initial begin repeat(4)@(posedge clk);@(negedge clk);reset=0;end
    always @(posedge clk) if(ce_pixel)begin
        pixels<=pixels+1;if(de)active<=active+1;if(!hsync)hs_low<=hs_low+1;if(!vsync)vs_low<=vs_low+1;
        if(dut.result_tag=={9'd259,10'd639})begin
            if(frames==1)begin
                if(pixels+1!=640*260)$fatal(1,"frame pixels %0d",pixels+1);
                if(active!=512*192)$fatal(1,"active pixels %0d",active);
                if(hs_low!=48*260)$fatal(1,"hsync pixels %0d",hs_low);
                if(vs_low!=6*640)$fatal(1,"vsync pixels %0d",vs_low);
                $display("NDS MiSTer raster: exact frame timing and active area passed");$finish;
            end
            frames<=frames+1;pixels<=0;active<=0;hs_low<=0;vs_low<=0;
        end
    end
endmodule
