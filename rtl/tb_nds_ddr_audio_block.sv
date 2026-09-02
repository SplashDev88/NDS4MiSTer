module tb_nds_ddr_audio_block;
    logic clk=0,reset_n=0,start=0,fetch_bank=0,ddram_busy=0;
    logic ddram_dout_ready=0,ddram_rd,activate=0,activate_bank=0;
    logic [28:0] base_addr=29'h12345,ddram_addr;
    logic [10:0] fetch_frames=6,activate_frames=6;
    logic [7:0] ddram_burstcnt;
    logic [63:0] ddram_dout;
    logic busy,done,queue_overflow;logic signed [15:0] audio_l,audio_r;
    integer beat=-1,response_beats=0,response_delay=0;
    integer delay_next_response=0,seen=0,last_l=0,last_r=0;
    always #5 clk=~clk;

    nds_ddr_audio_block #(.AUDIO_DIVIDE(4)) dut(.*);

    function automatic [63:0] sample_word(input integer index,input integer bank);
        sample_word={16'(104+index*2+bank*10),16'(4+index*2+bank*10),
                     16'(103+index*2+bank*10),16'(3+index*2+bank*10)};
    endfunction

    task automatic pulse_start;
        begin
            @(negedge clk);start=1;
            @(negedge clk);start=0;
        end
    endtask

    task automatic pulse_activate;
        begin
            @(negedge clk);activate=1;
            @(negedge clk);activate=0;
        end
    endtask

    always @(negedge clk)begin
        ddram_dout_ready=0;
        if(ddram_rd)begin
            if(ddram_addr!=base_addr||
               ddram_burstcnt!=((fetch_frames+1)>>1))
                $fatal(1,"bad fetch request addr=%h burst=%0d",
                    ddram_addr,ddram_burstcnt);
            // Return beat zero on the command-acceptance edge.  MiSTer's DDR
            // contract permits this and the block must not discard it while
            // transitioning from ISSUE to RECEIVE. The next-response control
            // also exercises the ordinary delayed-beat path.
            beat=0;response_beats=ddram_burstcnt;
            response_delay=delay_next_response;delay_next_response=0;
        end
        if(beat>=0)begin
            if(response_delay>0)response_delay=response_delay-1;
            else begin
                ddram_dout=sample_word(beat,fetch_bank);ddram_dout_ready=1;
                if(beat==response_beats-1)beat=-1;else beat=beat+1;
            end
        end
    end

    always @(negedge clk)begin
        if(reset_n&&seen>0&&seen<11&&audio_l==0&&audio_r==0)
            $fatal(1,"audio gap between queued blocks after sample %0d",seen);
        if(reset_n&&seen<11&&(audio_l!=last_l||audio_r!=last_r))begin
            if(audio_l!==(seen<6?3+seen:13+seen-6)||
               audio_r!==(seen<6?103+seen:113+seen-6))
                $fatal(1,"audio sample %0d got %0d,%0d",seen,audio_l,audio_r);
            last_l=audio_l;last_r=audio_r;
            seen=seen+1;
        end
    end

    initial begin
        repeat(3)@(posedge clk);@(negedge clk);reset_n=1;
        pulse_start();
        // Deliberately activate the first fetched block on an audio tick. A
        // stale end-of-block decision must not clear the new valid state.
        wait(done);do @(negedge clk); while(!dut.audio_tick);
        activate=1;@(negedge clk);activate=0;
        fetch_bank=1;fetch_frames=5;base_addr=29'h22345;
        delay_next_response=1;
        pulse_start();
        wait(done);
        // Also collide the replacement block with the retirement tick after
        // the last sample of block zero.
        do @(negedge clk); while(!(dut.audio_tick&&
                                  dut.audio_index>=dut.play_frames));
        activate_bank=1;activate_frames=5;activate=1;
        @(negedge clk);activate=0;
        wait(seen==11);
        if(queue_overflow)$fatal(1,"unexpected overflow during normal playback");
        // Load a third block after playback ends, then deliberately attempt to
        // activate the same bank again while it is live. This unsafe overwrite
        // must be surfaced instead of silently corrupting queued audio.
        activate_bank=0;activate_frames=2;
        pulse_activate();pulse_activate();wait(queue_overflow);
        // Reset and cover a single-beat acceptance-edge transfer, including
        // its direct completion path.
        @(negedge clk);reset_n=0;repeat(2)@(posedge clk);@(negedge clk);reset_n=1;
        fetch_bank=0;fetch_frames=1;base_addr=29'h32345;
        pulse_start();
        wait(done);@(posedge clk);
        if(busy||dut.bank0[0]!==sample_word(0,0))
            $fatal(1,"single-beat acceptance-edge fetch failed busy=%0d data=%h",
                busy,dut.bank0[0]);
        $display("NDS DDR audio block: same-edge/delayed fetches, continuous stereo blocks, and explicit overflow detection passed");
        $finish;
    end
    initial begin repeat(500)@(posedge clk);
        $fatal(1,"timeout state=%0d beat=%0d receive=%0d burst=%0d remaining=%0d seen=%0d",
            dut.state,beat,dut.receive_index,dut.burst_words,
            dut.words_remaining,seen);
    end
endmodule
