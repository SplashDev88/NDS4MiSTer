module tb_nds_color_compositor;
    logic [31:0] val1,val2,expected,result; logic [15:0] blend_cnt; logic [4:0] eva,evb,evy; logic window_effect_enable;
    integer fd,count,rc;
    nds_color_compositor dut(.*);
    initial begin
        fd=$fopen("/tmp/nds_color_vectors.txt","r"); if(!fd)$fatal(1,"missing vectors"); count=0;
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%h %h %h %d %d %d %d %h\n",val1,val2,blend_cnt,eva,evb,evy,window_effect_enable,expected);
            if(rc==8) begin #1; if(result!==expected)$fatal(1,"vector %0d got %h expected %h",count,result,expected); count=count+1; end
        end
        $display("NDS color compositor: %0d vectors passed",count); $finish;
    end
endmodule
