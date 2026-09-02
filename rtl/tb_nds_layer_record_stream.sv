module tb_nds_layer_record_stream;
    logic clk=0,reset_n=0,in_valid,in_ready,out_valid,out_ready;
    logic [319:0] in_record;logic [18:0] out_tag,expected_tag;
    logic [31:0] out_pixel,expected;logic [7:0] out_r,out_g,out_b,expected_r,expected_g,expected_b;
    integer fd,rc,count,stall;
    always #5 clk=~clk;
    nds_layer_record_stream dut(.*);
    initial begin
        in_valid=0;out_ready=0;in_record=0;repeat(3)@(posedge clk);@(negedge clk);reset_n=1;
        fd=$fopen("/tmp/nds_layer_record_vectors.txt","r");if(!fd)$fatal(1,"missing vectors");count=0;
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%h %h %h %h %h %h\n",in_record,expected_tag,expected,expected_r,expected_g,expected_b);
            if(rc==6)begin
                while(out_valid)@(negedge clk);@(negedge clk);in_valid=1;
                @(posedge clk);#1;if(out_valid)$fatal(1,"record %0d returned too early",count);
                @(posedge clk);#1;
                if(!out_valid||out_tag!==expected_tag||out_pixel!==expected||out_r!==expected_r||out_g!==expected_g||out_b!==expected_b)$fatal(1,"record %0d",count);
                @(negedge clk);in_valid=0;stall=count%9;
                repeat(stall)begin @(posedge clk);#1;if(!out_valid||out_tag!==expected_tag||out_pixel!==expected)$fatal(1,"stalled record %0d",count);end
                @(negedge clk);out_ready=1;@(posedge clk);#1;if(out_valid)$fatal(1,"consume %0d",count);
                @(negedge clk);out_ready=0;count=count+1;
            end
        end
        $display("NDS DDR layer records: %0d vectors passed with stalls",count);$finish;
    end
endmodule
