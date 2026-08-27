module tb_nds_video_pixel_stream;
    logic clk=0,reset_n=0,in_valid,in_ready,out_valid,out_ready,window_effect_enable;
    logic [191:0] layer_pixels;logic [23:0] layer_ranks;logic [5:0] layer_valid;
    logic [15:0] blend_cnt;logic [4:0] eva,evb,evy;logic [18:0] in_tag,out_tag;
    logic [31:0] out_pixel,expected;logic [7:0] out_r,out_g,out_b,expected_r,expected_g,expected_b;
    integer fd,rc,count,stall;
    always #5 clk=~clk;
    nds_video_pixel_stream dut(.*);
    initial begin
        in_valid=0;out_ready=0;layer_pixels=0;layer_ranks=0;layer_valid=0;blend_cnt=0;eva=0;evb=0;evy=0;window_effect_enable=0;in_tag=0;
        repeat(3)@(posedge clk);@(negedge clk);reset_n=1;
        fd=$fopen("/tmp/nds_video_vectors.txt","r");if(!fd)$fatal(1,"missing vectors");count=0;
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%h %h %h %h %d %d %d %d %h %h %h %h %h\n",layer_pixels,layer_ranks,layer_valid,blend_cnt,eva,evb,evy,window_effect_enable,in_tag,expected,expected_r,expected_g,expected_b);
            if(rc==13)begin
                while(out_valid)@(negedge clk);@(negedge clk);in_valid=1;
                @(posedge clk);#1;if(out_valid)$fatal(1,"vector %0d returned too early",count);
                @(posedge clk);#1;
                if(!out_valid||out_tag!==in_tag||out_pixel!==expected||out_r!==expected_r||out_g!==expected_g||out_b!==expected_b)$fatal(1,"accepted vector %0d",count);
                @(negedge clk);in_valid=0;stall=count%7;
                repeat(stall)begin @(posedge clk);#1;if(!out_valid||out_tag!==in_tag||out_pixel!==expected)$fatal(1,"stalled vector %0d",count);end
                @(negedge clk);out_ready=1;@(posedge clk);#1;if(out_valid)$fatal(1,"consume vector %0d",count);
                @(negedge clk);out_ready=0;count=count+1;
            end
        end
        $display("NDS video pixel stream: %0d vectors passed with tags and stalls",count);$finish;
    end
endmodule
