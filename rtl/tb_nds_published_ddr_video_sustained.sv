// Sustained multi-frame publication stress for nds_ddr_video.
//
// tb_nds_published_ddr_video_capture proves one frame can start and render,
// but it stops after 4096 active pixels -- eight lines, less than a twentieth
// of a frame -- with a static header, ~6% DDR occupancy, and audioFrames=0 so
// the DDR_AUDIO path never runs. The hardware symptom is that SOME frames come
// out black over many frames, which that test cannot observe by construction.
//
// This bench renders whole frames back to back while a publisher republishes
// underneath the raster: alternating slots, advancing sequence, and a seqlock
// window where the generation is odd (copy in progress) for a realistic
// fraction of each publication period. DDR is held busy far more aggressively
// to stand in for the CPU, posted-write and sound clients. Every frame's
// non-black pixel count is recorded, so a frame that renders black is caught
// and reported with the state that produced it.
module tb_nds_published_ddr_video_sustained;
    localparam integer HA=512,VA=192,HT=640,VT=260,PDIV=6;
    localparam integer FRAME_PIXELS=HA*VA;
    localparam integer FRAME_CLOCKS=HT*VT*PDIV;
    localparam integer FRAMES_TO_RENDER=8;
    // Publication period and in-progress window. The real system publishes
    // about every 6.6 frame times with the header odd for ~5.6% of that. The
    // period is compressed here so several publications land inside a
    // tractable simulation while keeping the odd-window proportion, which
    // makes the seqlock stress harder rather than easier.
    localparam integer PUB_PERIOD=1500000;
    localparam integer PUB_ODD_WINDOW=90000;

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
    integer send_word=0,i;
    integer active=0,nonblack=0,frame_index=0,black_frames=0;
    integer pub_generation=2,pub_sequence=7,pub_slot=0,pub_count=0;
    integer lfsr=32'h1234_5678;

    always #5 clk=~clk;
    nds_ddr_video dut(.*);

    task automatic write_header;
        begin
            header=0;
            header[63:0]=64'h315542504c53444e;
            header[95:64]=1;            // abi
            header[127:96]=64;          // sizeof(LayerPublication)
            header[191:128]=pub_generation;
            header[223:192]=pub_slot;
            header[255:224]=3932160;    // frame bytes
            header[287:256]=40;         // sizeof(LayerRecord)
            header[319:288]=98304;      // records
            header[383:320]=pub_sequence;
            header[447:384]=pub_generation;
            // Exercise the DDR_AUDIO fetch every publication. Zero here is
            // what let the audio path go untested for so long.
            header[479:448]=800;
        end
    endtask

    initial begin
        fd=$fopen("/tmp/nds-r215-current.records","rb");
        if(!fd)$fatal(1,"capture open failed");
        loaded=$fread(records,fd);
        $fclose(fd);
        if(loaded!=3932160)$fatal(1,"capture size %0d",loaded);
        write_header;
        repeat(4)@(posedge clk); @(negedge clk); reset=0;
    end

    // Publisher: seqlock exactly as publishLayerNow() does it -- bump to an
    // odd generation and switch the slot BEFORE the copy, then even after.
    initial begin
        forever begin
            repeat(PUB_PERIOD)@(posedge clk);
            pub_generation=pub_generation+1;   // odd: copy in progress
            pub_slot=pub_slot^1;
            pub_sequence=pub_sequence+1;
            write_header;
            repeat(PUB_ODD_WINDOW)@(posedge clk);
            pub_generation=pub_generation+1;   // even: valid
            write_header;
            pub_count=pub_count+1;
        end
    end

    function automatic [63:0] captured_word(input integer word_index);
        integer byte_index,j,wrapped;
        begin
            wrapped=word_index%491520;
            if(wrapped<0) wrapped=wrapped+491520;
            byte_index=wrapped*8;
            captured_word=0;
            for(j=0;j<8;j=j+1)
                captured_word[j*8 +: 8]=records[byte_index+j];
        end
    endfunction

    // DDR model with aggressive, irregular occupancy standing in for the other
    // three arbiter clients.
    always @(negedge clk) begin
        cycle=cycle+1;
        lfsr=(lfsr>>1)^(-(lfsr&32'd1)&32'hD000_0001);
        ddram_busy=(lfsr[3:0]<4'd6);   // ~40% occupied
        ddram_dout_ready=0;
        if(send_beat>=0&&(lfsr[5:4]!=2'b00)) begin
            if(send_count==8) ddram_dout=header[send_beat*64 +: 64];
            else ddram_dout=captured_word(send_word+send_beat);
            ddram_dout_ready=1;
            if(send_beat==send_count-1) send_beat=-1;
            else send_beat=send_beat+1;
        end
        if(ddram_rd&&!ddram_busy) begin
            send_count=ddram_burstcnt;
            if(ddram_burstcnt!=8) begin
                if(ddram_addr>=SLOT1) send_word=ddram_addr-SLOT1;
                else send_word=ddram_addr-SLOT0;
            end
            send_beat=0;
        end
    end

    // Per-frame non-black accounting.
    always @(posedge clk) if(ce_pixel&&de) begin
        active=active+1;
        if(red!=0||green!=0||blue!=0) nonblack=nonblack+1;
        if(active==FRAME_PIXELS) begin
            frame_index=frame_index+1;
            $display("frame %0d: nonblack %0d/%0d  underrun=%0d tag_error=%0d owner=%0d cache=%0d pubs=%0d",
                frame_index,nonblack,FRAME_PIXELS,underrun,tag_error,
                dut.ddr_owner,dut.cache.state,pub_count);
            if(nonblack*100<FRAME_PIXELS) begin
                black_frames=black_frames+1;
                $display("  ^^ FRAME %0d IS EFFECTIVELY BLACK", frame_index);
            end
            active=0; nonblack=0;
            if(frame_index==FRAMES_TO_RENDER) begin
                if(black_frames!=0)
                    $display("REPRODUCED: %0d of %0d frames rendered black",
                        black_frames,FRAMES_TO_RENDER);
                else
                    $display("PASS: all %0d frames rendered picture under sustained republication",
                        FRAMES_TO_RENDER);
                $finish;
            end
        end
    end

    initial begin
        repeat(FRAME_CLOCKS*(FRAMES_TO_RENDER+3))@(posedge clk);
        $fatal(1,"timeout ready=%0d frame=%0d active=%0d owner=%0d cache=%0d pubs=%0d",
            display_ready,frame_index,active,dut.ddr_owner,dut.cache.state,pub_count);
    end
endmodule
