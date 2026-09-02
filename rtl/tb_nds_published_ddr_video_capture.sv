module tb_nds_published_ddr_video_capture;
    localparam integer HA=512,VA=192,HT=640,VT=260;
    localparam [28:0] CONTROL=29'h06000000,SLOT0=29'h06080000,SLOT1=29'h06100000;
    logic clk=0,reset=1,ddram_busy=0,ddram_dout_ready=0,ddram_rd,ddram_we;
    logic ce_pixel,de,hsync,vsync,underrun,tag_error,display_ready;
    logic [7:0] ddram_burstcnt,red,green,blue;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_dout,ddram_din;
    logic [31:0] joystick=0;
    logic signed [15:0] audio_l,audio_r;
    wire [28:0] base_addr=CONTROL,control_addr=CONTROL;
    wire published=1'b1;
    reg [7:0] records [0:3932159];
    logic [511:0] header;
    integer fd,loaded,cycle=0,send_beat=-1,send_count=0;
    integer send_word=0,i,active=0,nonblack=0;

    always #5 clk=~clk;
    nds_ddr_video dut(.*);

    initial begin
        fd=$fopen("/tmp/nds-r215-current.records","rb");
        if(!fd)$fatal(1,"capture open failed");
        loaded=$fread(records,fd);
        $fclose(fd);
        if(loaded!=3932160)$fatal(1,"capture size %0d",loaded);
        header=0;
        header[63:0]=64'h315542504c53444e;
        header[95:64]=1; header[127:96]=64; header[191:128]=2;
        header[223:192]=0; header[255:224]=3932160;
        header[287:256]=40; header[319:288]=98304;
        header[383:320]=64'd7; header[447:384]=2;
        repeat(4)@(posedge clk); @(negedge clk); reset=0;
    end

    function automatic [63:0] captured_word(input integer word_index);
        integer byte_index,j;
        begin
            byte_index=word_index*8;
            captured_word=0;
            for(j=0;j<8;j=j+1)
                captured_word[j*8 +: 8]=records[byte_index+j];
        end
    endfunction

    always @(negedge clk) begin
        cycle=cycle+1;
        ddram_busy=(cycle%17)==5;
        ddram_dout_ready=0;
        if(send_beat>=0&&(cycle%3)!=0) begin
            if(send_count==8) ddram_dout=header[send_beat*64 +: 64];
            else ddram_dout=captured_word(send_word+send_beat);
            ddram_dout_ready=1;
            if(send_beat==send_count-1) send_beat=-1;
            else send_beat=send_beat+1;
        end
        if(ddram_rd&&(ddram_burstcnt!=8||!ddram_busy)) begin
            send_count=ddram_burstcnt;
            if(ddram_burstcnt!=8) begin
                if(ddram_addr>=SLOT1) send_word=ddram_addr-SLOT1;
                else send_word=ddram_addr-SLOT0;
            end
            send_beat=0;
        end
    end

    always @(posedge clk) if(ce_pixel&&de) begin
        active=active+1;
        if(red!=0||green!=0||blue!=0) nonblack=nonblack+1;
        if(active==4096) begin
            if(!display_ready)$fatal(1,"display never became ready");
            if(underrun||tag_error)$fatal(1,"transport flags u=%0d t=%0d",underrun,tag_error);
            if(nonblack<128)$fatal(1,"real capture rendered black: %0d/4096",nonblack);
            $display("PASS: real capture rendered %0d nonblack pixels in first 4096",nonblack);
            $finish;
        end
    end

    initial begin
        repeat(3000000)@(posedge clk);
        $fatal(1,"timeout ready=%0d active=%0d nonblack=%0d owner=%0d cache=%0d",
            display_ready,active,nonblack,dut.ddr_owner,dut.cache.state);
    end
endmodule
