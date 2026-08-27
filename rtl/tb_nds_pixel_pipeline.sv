module tb_nds_pixel_pipeline;
    logic clk=0,reset_n=0,in_valid,in_ready,out_valid,out_ready,window_effect_enable; logic [191:0] layer_pixels; logic [23:0] layer_ranks; logic [5:0] layer_valid; logic [15:0] blend_cnt; logic [4:0] eva,evb,evy; logic [31:0] out_pixel,expected; integer fd,rc,count,stall;
    always #5 clk=~clk;
    nds_pixel_pipeline dut(.*);
    initial begin
        in_valid=0;out_ready=0;layer_pixels=0;layer_ranks=0;layer_valid=0;blend_cnt=0;eva=0;evb=0;evy=0;window_effect_enable=0;
        repeat(3)@(posedge clk);@(negedge clk);reset_n=1;fd=$fopen("/tmp/nds_pipeline_vectors.txt","r");if(!fd)$fatal(1,"missing vectors");count=0;
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%h %h %h %h %d %d %d %d %h\n",layer_pixels,layer_ranks,layer_valid,blend_cnt,eva,evb,evy,window_effect_enable,expected);
            if(rc==9) begin
                // Change handshake controls only on falling edges and sample the
                // registered interface just after rising edges.  This keeps the
                // testbench out of the DUT's active-edge scheduling region.
                while(out_valid)@(negedge clk);
                @(negedge clk);in_valid=1;out_ready=0;
                @(posedge clk);#1;if(out_valid)$fatal(1,"vector %0d returned too early",count);
                @(posedge clk);#1;
                if(!out_valid||out_pixel!==expected)$fatal(1,"accepted vector %0d got %h expected %h",count,out_pixel,expected);
                @(negedge clk);in_valid=0;
                stall=count%5;repeat(stall)begin @(posedge clk);#1;if(!out_valid||out_pixel!==expected)$fatal(1,"stalled vector %0d",count);end
                if(!out_valid||out_pixel!==expected)$fatal(1,"vector %0d got %h expected %h",count,out_pixel,expected);
                @(negedge clk);out_ready=1;
                @(posedge clk);#1;if(out_valid)$fatal(1,"vector %0d was not consumed",count);
                @(negedge clk);out_ready=0;count=count+1;
            end
        end
        $display("NDS pixel pipeline: %0d vectors passed with stalls",count);$finish;
    end
endmodule
