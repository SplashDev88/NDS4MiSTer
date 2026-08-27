module tb_nds_ddr_video;
    localparam integer HA=16,VA=4,HT=24,VT=8;localparam [28:0] BASE=29'h06000000;
    logic clk=0,reset=1,ddram_busy,ddram_dout_ready,ddram_rd,ddram_we,ce_pixel,de,hsync,vsync,underrun,tag_error,display_ready;
    logic [7:0] ddram_burstcnt,red,green,blue;logic [28:0] ddram_addr;logic [63:0] ddram_dout,ddram_din;wire [28:0] base_addr=BASE;
    logic [31:0] joystick=0;logic signed [15:0] audio_l,audio_r;
    wire published=0;wire [28:0] control_addr=BASE;
    integer cycle=0,send_beat=-1,send_count=0,send_start=0,number,line,x,frames=0,active=0;logic [319:0] response;
    always #5 clk=~clk;
    nds_ddr_video #(.H_ACTIVE(HA),.H_FRONT(2),.H_SYNC(2),.H_TOTAL(HT),.V_ACTIVE(VA),.V_FRONT(1),.V_SYNC(1),.V_TOTAL(VT)) dut(.*);
    function automatic [319:0] make_record(input integer ln,input integer px);
        logic [31:0] p;logic [18:0] tag;begin
            p={8'h01,2'b0,ln[5:0],2'b0,ln[5:0],2'b0,px[5:0]};tag={ln[8:0],px[9:0]};make_record=0;
            make_record[31:0]=p;make_record[221:216]=1;make_record[290:272]=tag;
        end
    endfunction
    initial begin ddram_busy=0;ddram_dout_ready=0;ddram_dout=0;repeat(4)@(posedge clk);@(negedge clk);reset=0;end
    always @(negedge clk)begin
        cycle=cycle+1;ddram_busy=(cycle%17)==5;ddram_dout_ready=0;
        if(send_beat>=0&&(cycle%3)!=0)begin
            number=(send_start+send_beat)/5;
            response=make_record(number/HA,number%HA);
            ddram_dout=response[(send_beat%5)*64+:64];ddram_dout_ready=1;
            if(send_beat==send_count-1)send_beat=-1;else send_beat=send_beat+1;
        end
        if(ddram_rd)begin
            send_start=ddram_addr-BASE;send_count=ddram_burstcnt;
            send_beat=0;
        end
    end
    always @(posedge clk)if(ce_pixel)begin
        if(de)begin
            active=active+1;
            if(red!=={dut.x[5:0],dut.x[5:4]}||green!=={dut.y[5:0],dut.y[5:4]}||blue!=={dut.y[5:0],dut.y[5:4]})$fatal(1,"rgb x%0d y%0d got=%h,%h,%h tag=%h valid=%b pending=%b owner=%0d cache=%0d line=%0d banks=%b acquired=%b acquire_ready=%b want=%0d seq0=%0d seq1=%0d",dut.x,dut.y,red,green,blue,dut.pixel_tag,dut.pixel_valid,dut.pixel_pending,dut.ddr_owner,dut.cache.state,dut.cache.line_index,dut.bank_free,dut.line_acquired,dut.acquire_ready,dut.acquire_sequence,dut.cache.store.sequence0,dut.cache.store.sequence1);
        end
        if(dut.x==HT-1&&dut.y==VT-1)begin
            frames=frames+1;
            if(frames==2)begin
                if(active!=2*HA*VA)$fatal(1,"active %0d",active);
                if(underrun||tag_error)$fatal(1,"transport errors u=%0d t=%0d",underrun,tag_error);
                $display("NDS DDR video: two frames passed with prefetch, compositor latency, tags, and raster timing");$finish;
            end
        end
    end
    initial begin wait(!reset);repeat(200000)@(posedge clk);$fatal(1,"timeout");end
endmodule
