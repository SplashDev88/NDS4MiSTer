module tb_nds_published_ddr_video;
    // Leave one scaled pixel of transport margin. With the deliberately
    // throttled two-of-three-cycle DDR responder, HT=24 makes the last line's
    // publish edge coincide exactly with x=0 and tests no usable elasticity.
    localparam integer HA=16,VA=4,HT=25,VT=8;
    localparam [28:0] CONTROL=29'h06000000,SLOT0=29'h06080000,SLOT1=29'h06100000;
    logic clk=0,reset=1,ddram_busy=0,ddram_dout_ready=0,ddram_rd,ddram_we,ce_pixel,de,hsync,vsync,underrun,tag_error,display_ready;
    logic [7:0] ddram_burstcnt,red,green,blue;logic [28:0] ddram_addr;logic [63:0] ddram_dout,ddram_din;
    logic [31:0] joystick=0;logic signed [15:0] audio_l,audio_r;
    wire [28:0] base_addr=CONTROL,control_addr=CONTROL;wire published=1;
    integer cycle=0,send_beat=-1,send_count=0,send_start=0,number,line,px,slot,header_reads=0,frames=0,active=0,expected_red;
    integer input_writes=0,audio_seen=0,last_audio_l=0,last_audio_r=0;
    logic [511:0] response;
    always #5 clk=~clk;
    nds_ddr_video #(.H_ACTIVE(HA),.H_FRONT(2),.H_SYNC(2),.H_TOTAL(HT),
        .V_ACTIVE(VA),.V_FRONT(1),.V_SYNC(1),.V_TOTAL(VT),.AUDIO_DIVIDE(8),
        .VIDEO_DEBUG_INPUT_TELEMETRY(1)) dut(.*);
    function automatic [319:0] make_record(input integer ln,input integer xpos,input integer which);
        logic [31:0] p;logic [18:0] tag;integer color;begin
            color=xpos+which*16;p={8'h01,2'b0,ln[5:0],2'b0,ln[5:0],2'b0,color[5:0]};tag={ln[8:0],xpos[9:0]};make_record=0;
            make_record[31:0]=p;make_record[221:216]=1;make_record[290:272]=tag;
        end
    endfunction
    task automatic make_header(input integer request);
        logic [63:0] generation,check;logic [31:0] selected;begin
            selected=request>=3;generation=request==1?1:request>=3?4:2;
            check=request==3?2:generation;response=0;
            response[63:0]=64'h315542504c53444e;response[95:64]=1;response[127:96]=64;
            response[191:128]=generation;response[223:192]=selected;response[255:224]=3932160;
            response[287:256]=40;response[319:288]=98304;
            // A core normally attaches to a publisher that has already
            // produced many frames.  Starting at sequence zero hid an
            // initial line-acquire deadlock in the hardware path.
            response[383:320]=selected+7;response[447:384]=check;
            response[479:448]=6;
        end endtask
    function automatic [63:0] make_audio(input integer index,input integer which);
        make_audio={16'(104+index*2+which*10),16'(4+index*2+which*10),
                    16'(103+index*2+which*10),16'(3+index*2+which*10)};
    endfunction
    initial begin repeat(4)@(posedge clk);@(negedge clk);reset=0;end
    always @(negedge clk)begin
        cycle=cycle+1;ddram_busy=(cycle%17)==5;ddram_dout_ready=0;
        // Deliver only beats from a previously accepted command. Scheduling a
        // response below the new command on this same edge makes beat zero
        // appear before the DUT can enter its RECEIVE state.
        if(send_beat>=0&&(cycle%3)!=0)begin
            if(send_count==3)ddram_dout=make_audio(send_beat,slot);
            else if(send_count==8)
                ddram_dout=response[send_beat*64+:64];
            else begin
                number=(send_start+send_beat)/5;
                line=number/HA;px=number%HA;
                response=make_record(line,px,slot);
                ddram_dout=response[(send_beat%5)*64+:64];
            end
            ddram_dout_ready=1;
            if(send_beat==send_count-1)send_beat=-1;else send_beat=send_beat+1;
        end
        // Header reads hold rd through waitrequest, whereas the layer/audio
        // readers pulse rd only after they have already sampled busy low.
        if(ddram_rd&&(ddram_burstcnt!=8||!ddram_busy))begin
            if(ddram_burstcnt==8)begin header_reads=header_reads+1;make_header(header_reads);send_count=8;end
            else if(ddram_burstcnt==3)begin
                slot=ddram_addr>=SLOT1;response=make_audio(0,slot);send_count=3;
            end
            else begin
                slot=ddram_addr>=SLOT1;
                send_start=ddram_addr-(slot?SLOT1:SLOT0);
                send_count=ddram_burstcnt;
            end
            send_beat=0;
            if(dut.ddr_owner==2&&ddram_addr<SLOT0)
                $fatal(1,"frame fetch used control/header address %h before first valid publication",
                    ddram_addr);
        end
        if(ddram_we)begin
            if(ddram_addr!=CONTROL+8||ddram_din[63:32]!=32'h4a53444e||
               ddram_din[31:28]!=4'hd||ddram_din[11:0]!=joystick[11:0])
                $fatal(1,"bad joystick publication");
            input_writes=input_writes+1;
        end
    end
    always @(negedge clk)if((audio_l!=last_audio_l||audio_r!=last_audio_r)&&
                            (audio_l!=0||audio_r!=0))begin
        audio_seen=audio_seen+1;last_audio_l=audio_l;last_audio_r=audio_r;
    end
    always @(posedge clk)if(ce_pixel)begin
        if(de)begin
            active=active+1;
            // Header 1 is invalid at startup and must be retried. Header 2
            // publishes slot 0. Header 3 is invalid mid-update, so r241 must
            // redisplay slot 0. Header 4 then publishes slot 1.
            expected_red=dut.x+(frames>=2?16:0);
            if(red!=={expected_red[5:0],expected_red[5:4]}||
               green!=={dut.y[5:0],dut.y[5:4]}||blue!=={dut.y[5:0],dut.y[5:4]})
                $fatal(1,"rgb frame%0d x%0d y%0d got %h acquired=%0d banks=%b cache_line=%0d cache_state=%0d underrun=%0d tag=%0d",
                    frames,dut.x,dut.y,red,dut.line_acquired,dut.bank_free,
                    dut.cache.line_index,dut.cache.state,underrun,tag_error);
        end
        if(dut.x==HT-1&&dut.y==VT-1)begin
            frames=frames+1;
            if(frames==3)begin
                if(active!=3*HA*VA||header_reads<4||audio_seen<6||input_writes<1)
                    $fatal(1,"coverage active=%0d headers=%0d audio=%0d input=%0d",
                        active,header_reads,audio_seen,input_writes);
                if(underrun||tag_error)$fatal(1,"transport errors u=%0d t=%0d",underrun,tag_error);
                $display("NDS published DDR video: startup retry, previous-frame fallback, atomic slot switch, FPGA audio, and input publication passed");$finish;
            end
        end
    end
    initial begin
        wait(!reset);repeat(300000)@(posedge clk);
        $fatal(1,"timeout owner=%0d headers=%0d frames=%0d send=%0d/%0d pubstate=%0d cachestate=%0d audio_seen=%0d",
            dut.ddr_owner,header_reads,frames,send_beat,send_count,
            dut.publication.state,dut.cache.state,audio_seen);
    end
endmodule
