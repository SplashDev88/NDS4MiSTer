module tb_nds_dual_line_store;
    logic clk=0,reset_n=0,write_valid,write_ready,write_bank,publish,publish_bank,acquire,acquire_bank,acquire_ready,read_enable,read_bank,read_valid,release_valid,release_bank;
    logic [1:0] bank_free;logic [8:0] write_addr,read_addr;logic [31:0] publish_sequence,acquire_sequence;logic [319:0] write_data,read_data;
    integer line,i;logic [319:0] expected;
    always #5 clk=~clk;
    nds_dual_line_store dut(.*);
    function automatic [319:0] pattern(input integer seq,input integer x);
        integer k;begin for(k=0;k<10;k=k+1)pattern[k*32+:32]=(seq*32'h10204081)^x^(k*32'h11111111);end
    endfunction
    task fill(input integer seq);
        begin
            write_bank=seq[0];
            for(i=0;i<512;i=i+1)begin @(negedge clk);if(!write_ready)$fatal(1,"bank not free");write_valid=1;write_addr=i;write_data=pattern(seq,i);end
            @(negedge clk);write_valid=0;publish=1;publish_bank=seq[0];publish_sequence=seq;
            @(negedge clk);publish=0;
        end
    endtask
    initial begin
        write_valid=0;publish=0;acquire=0;read_enable=0;release_valid=0;write_bank=0;write_addr=0;write_data=0;publish_bank=0;publish_sequence=0;acquire_bank=0;acquire_sequence=0;read_bank=0;read_addr=0;release_bank=0;
        repeat(3)@(posedge clk);@(negedge clk);reset_n=1;fill(0);
        for(line=0;line<200;line=line+1)begin
            @(negedge clk);acquire=1;acquire_bank=line[0];acquire_sequence=line;#1;if(!acquire_ready)$fatal(1,"acquire line %0d",line);
            @(negedge clk);acquire=0;
            // Read the current line. The next producer line is written into the
            // other bank during the same 512-cycle window.
            for(i=0;i<512;i=i+1)begin
                read_enable=1;read_bank=line[0];read_addr=i;
                if(line<199)begin write_valid=1;write_bank=~line[0];write_addr=i;write_data=pattern(line+1,i);if(!write_ready)$fatal(1,"overlap bank busy");end
                @(posedge clk);#1;
                if(!read_valid||read_data!==pattern(line,i))$fatal(1,"line %0d pixel %0d",line,i);
                @(negedge clk);
            end
            read_enable=0;write_valid=0;
            release_valid=1;release_bank=line[0];
            if(line<199)begin publish=1;publish_bank=~line[0];publish_sequence=line+1;end
            @(negedge clk);release_valid=0;publish=0;
        end
        if(bank_free!=2'b11)$fatal(1,"banks not released");
        $display("NDS dual line store: 200 lines passed with concurrent fill/read and sequence ownership");$finish;
    end
endmodule
