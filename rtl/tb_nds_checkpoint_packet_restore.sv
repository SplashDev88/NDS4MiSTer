`timescale 1ns/1ps
module tb_nds_checkpoint_packet_restore;
    parameter bit RETIRE = 1;
    logic clk=0,reset=1,lcd_vblank=0,geometry_enabled=1;
    logic write_valid=0,write_is_dma=0,record_ready=1,stack_ack=0;
    logic [31:0] write_address=0,write_data=0,write_frame=32'h81421324;
    logic [1:0] write_access=2;
    logic [63:0] write_timestamp=64'h12345678abcdef01;
    logic checkpoint_request=0,checkpoint_producers_stopped=0;
    logic checkpoint_restore=0,checkpoint_write=0;
    logic [8:0] checkpoint_address=0;
    logic [31:0] checkpoint_data,checkpoint_write_data=0;
    logic checkpoint_valid,checkpoint_stopped,checkpoint_restore_ready,checkpoint_restore_error;
    bit restoring,recording=0,check_image=1;
    integer scenario=0,gap=0,state_file,trace_file,result,observations=0;
    logic [31:0] image[0:262];
    logic [31:0] rng;
    logic [315:0] expected;
    always #5 clk=~clk;
    // A bounded owner intentionally freezes local geometry retirement. The
    // pinned implementation is clocked identically outside that explicit hold.
    wire reference_clk = clk && !dut.checkpoint_hold && !checkpoint_restore;
    wire write_ready, ref_write_ready;
    wire record_valid, ref_record_valid;
    wire [127:0] record, ref_record;
    wire [31:0] record_frame, ref_record_frame;
    wire [63:0] record_timestamp, ref_record_timestamp;
    wire record_frame_end, ref_record_frame_end;
    wire swap_enqueued, ref_swap_enqueued;
    wire swap_pending, ref_swap_pending;
    wire [63:0] oldest_swap_timestamp, ref_oldest_swap_timestamp;
    wire [8:0] fifo_level, ref_fifo_level;
    wire fifo_empty, ref_fifo_empty;
    wire fifo_below_half, ref_fifo_below_half;
    wire fifo_full, ref_fifo_full;
    wire geometry_busy, ref_geometry_busy;
    wire packed_active, ref_packed_active;
    wire normalization_pending, ref_normalization_pending;
    wire protocol_error, ref_protocol_error;
    wire [4:0] pos_stack_level, ref_pos_stack_level;
    wire proj_stack_level, ref_proj_stack_level;
    wire stack_error, ref_stack_error;
    nds_gx_fifo_packet_frontend #(.SWAP_VBLANK_RETIREMENT(RETIRE), .EXPERIMENTAL_CHECKPOINT(1)) dut (.*);
    nds_gx_fifo_packet_frontend_reference #(.SWAP_VBLANK_RETIREMENT(RETIRE)) baseline (
        .clk(reference_clk),
        .reset(reset),
        .lcd_vblank(lcd_vblank),
        .geometry_enabled(geometry_enabled),
        .write_valid(write_valid),
        .write_is_dma(write_is_dma),
        .write_address(write_address),
        .write_access(write_access),
        .write_data(write_data),
        .write_frame(write_frame),
        .write_timestamp(write_timestamp),
        .record_ready(record_ready),
        .stack_ack(stack_ack),
        .write_ready(ref_write_ready),
        .record_valid(ref_record_valid),
        .record(ref_record),
        .record_frame(ref_record_frame),
        .record_timestamp(ref_record_timestamp),
        .record_frame_end(ref_record_frame_end),
        .swap_enqueued(ref_swap_enqueued),
        .swap_pending(ref_swap_pending),
        .oldest_swap_timestamp(ref_oldest_swap_timestamp),
        .fifo_level(ref_fifo_level),
        .fifo_empty(ref_fifo_empty),
        .fifo_below_half(ref_fifo_below_half),
        .fifo_full(ref_fifo_full),
        .geometry_busy(ref_geometry_busy),
        .packed_active(ref_packed_active),
        .normalization_pending(ref_normalization_pending),
        .protocol_error(ref_protocol_error),
        .pos_stack_level(ref_pos_stack_level),
        .proj_stack_level(ref_proj_stack_level),
        .stack_error(ref_stack_error)
    );
    wire [315:0] observable = {write_ready, record_valid, record, record_frame, record_timestamp, record_frame_end, swap_enqueued, swap_pending, oldest_swap_timestamp, fifo_level, fifo_empty, fifo_below_half, fifo_full, geometry_busy, packed_active, normalization_pending, protocol_error, pos_stack_level, proj_stack_level, stack_error};
    wire [315:0] reference_observable = {ref_write_ready, ref_record_valid, ref_record, ref_record_frame, ref_record_timestamp, ref_record_frame_end, ref_swap_enqueued, ref_swap_pending, ref_oldest_swap_timestamp, ref_fifo_level, ref_fifo_empty, ref_fifo_below_half, ref_fifo_full, ref_geometry_busy, ref_packed_active, ref_normalization_pending, ref_protocol_error, ref_pos_stack_level, ref_proj_stack_level, ref_stack_error};

    task automatic observe;
        if(recording) begin
            if(restoring) begin
                if($fscanf(trace_file,"%h\n",expected)!=1) $fatal(1,"packet trace truncated");
                if(observable !== expected) $fatal(1,"packet continuation mismatch scene=%0d obs=%0d got=%h expected=%h",scenario,observations,observable,expected);
            end else begin
                if(observable !== reference_observable) $fatal(1,"packet pinned reference mismatch scene=%0d obs=%0d got=%h ref=%h",scenario,observations,observable,reference_observable);
                $fdisplay(trace_file,"%h",observable);
            end
            observations=observations+1;
        end
    endtask
    task automatic ticks(input integer n=1);
        repeat(n) begin #1;observe();@(posedge clk);#1;observe();@(negedge clk);end
    endtask
    task automatic send(input logic [31:0] address,input logic [31:0] data);
        integer guard;
        write_address=address;write_data=data;write_valid=1;guard=0;
        #1;
        while(!write_ready) begin
            ticks();guard=guard+1;
            if(guard>700) $fatal(1,"packet write blocked beyond bound");
        end
        ticks();write_valid=0;write_timestamp=write_timestamp+17;
    endtask
    task automatic direct(input logic [7:0] command,input logic [31:0] data=0);
        send(32'h04000400+{22'd0,command,2'b00},data);
    endtask
    task automatic vblank;
        lcd_vblank=1;ticks();lcd_vblank=0;ticks();
    endtask
    task automatic load_word(input integer address,input logic [31:0] data);
        checkpoint_address=address;checkpoint_write_data=data;checkpoint_write=1;ticks();
        checkpoint_write=0;ticks(gap+1);
    endtask
    task automatic retry;
        checkpoint_restore=0;ticks();checkpoint_restore=1;ticks();
        if(checkpoint_restore_error || checkpoint_restore_ready) $fatal(1,"packet retry failed");
    endtask
    task automatic load_all;
        for(integer a=0;a<263;a=a+1) begin
            if(checkpoint_restore_ready) $fatal(1,"packet partial image ready");
            load_word(a,image[a]);
            if(checkpoint_restore_error) $fatal(1,"packet valid image rejected at%0d",a);
            if(write_ready || record_valid || record_frame_end || swap_enqueued)
                $fatal(1,"packet restore emitted source/record handshake");
        end
        if(!checkpoint_restore_ready) $fatal(1,"packet full image not ready");
    endtask
    task automatic read_image;
        for(integer a=0;a<263;a=a+1) begin
            checkpoint_address=a;#1;
            if(!checkpoint_valid) $fatal(1,"packet image unavailable");
            if(restoring) begin
                if(check_image && checkpoint_data!==image[a]) $fatal(1,"packet image mismatch at%0d",a);
            end else image[a]=checkpoint_data;
        end
        checkpoint_address=263;#1;
        if(checkpoint_valid || checkpoint_data!==0) $fatal(1,"packet exposed undefined word");
        @(negedge clk);
    endtask
    task automatic acquire;
        integer guard;
        checkpoint_request=1;checkpoint_producers_stopped=1;guard=0;
        while(!checkpoint_stopped) begin
            ticks();guard=guard+1;
            if(guard>600) $fatal(1,"packet capture blocked waiting for future VBlank");
        end
        if(record_valid || swap_pending || write_ready) $fatal(1,"packet capture not drained");
        ticks(3);
    endtask
    initial begin
        restoring=$test$plusargs("restore");check_image=!$test$plusargs("no-image-check");
        if($value$plusargs("scenario=%d",scenario)) begin end
        if($value$plusargs("gap=%d",gap)) begin end
        ticks(4);
        if(restoring) begin
            state_file=$fopen("packet.state","r");if(!state_file) $fatal(1,"packet image missing");
            if($fscanf(state_file,"%b\n",geometry_enabled)!=1) $fatal(1,"packet external power context missing");
            for(integer a=0;a<263;a=a+1) if($fscanf(state_file,"%h\n",image[a])!=1) $fatal(1,"packet image truncated");
            if(!$feof(state_file)) $fatal(1,"packet extra image data");$fclose(state_file);
            checkpoint_request=1;checkpoint_producers_stopped=1;checkpoint_restore=1;ticks();
            load_all();read_image();
            load_word(263,0);
            if(!checkpoint_restore_error || checkpoint_restore_ready) $fatal(1,"packet extra word accepted");
            for(integer fault=0;fault<12;fault=fault+1) begin
                retry();
                case(fault)
                    0: load_word(1,image[1]);
                    1: begin load_word(0,image[0]);load_word(0,image[0]);end
                    2,3,4: begin
                        for(integer a=0;a<5;a=a+1) load_word(a,image[a]);
                        if(fault==2) load_word(5,image[5]|32'h00100000);
                        if(fault==3) load_word(5,(image[5]&32'hfffffff8)|5);
                        if(fault==4) load_word(5,(image[5]&32'hfffffe07)|(33<<3));
                    end
                    5,6: begin
                        for(integer a=0;a<6;a=a+1) load_word(a,image[a]);
                        if(fault==5) load_word(6,image[6]^32'h00000100);
                        if(fault==6) load_word(6,(image[6]&32'hfe000000)|32'h01010001);
                    end
                    7: begin
                        for(integer a=0;a<7;a=a+1) load_word(a,image[a]);
                        load_word(7,2);
                    end
                    8: begin write_valid=1;ticks();write_valid=0;ticks();end
                    9: begin lcd_vblank=1;ticks();lcd_vblank=0;ticks();end
                    10: begin stack_ack=1;ticks();stack_ack=0;ticks();end
                    11: begin checkpoint_producers_stopped=0;ticks();checkpoint_producers_stopped=1;ticks();end
                endcase
                if(!checkpoint_restore_error || checkpoint_restore_ready || checkpoint_valid) $fatal(1,"packet invalid restore accepted fault=%0d",fault);
                load_word(0,image[0]);
                if(!checkpoint_restore_error || checkpoint_restore_ready) $fatal(1,"packet poisoned image recovered");
            end
            // A reset-free load attempt must poison without qualifying.
            retry();reset=0;load_word(0,image[0]);
            if(!checkpoint_restore_error || checkpoint_restore_ready) $fatal(1,"packet live restore accepted");
            checkpoint_restore=0;reset=1;ticks();checkpoint_restore=1;ticks();
            load_all();read_image();
            checkpoint_restore=0;reset=0;
            // Maintain the owner hold for a settled readout before release.
            ticks(3);
            if(!checkpoint_stopped) $fatal(1,"packet restore lost owner hold");
            trace_file=$fopen("packet.trace","r");
        end else begin
            reset=0;ticks(2);
            // Establish ring history and wrap both independent queues.
            for(integer n=0;n<300;n=n+1) direct(8'h20,n*71);
            ticks(5);
            case(scenario)
                1: send(32'h04000400,32'h11157034);
                2: begin
                    send(32'h04000400,32'h00111516);
                    for(integer n=0;n<7;n=n+1) send(32'h04000400,n*531+7);
                end
                3: send(32'h04000400,32'h00111111);
                4: begin
                    direct(8'h10,2);repeat(37) direct(8'h11);direct(8'h12,63);
                    direct(8'h10,3);direct(8'h11);direct(8'h10,1);
                end
                5: begin direct(8'h50,3);ticks(8);end
                6,8,9: begin
                    direct(8'h50,1);ticks(3);
                    for(integer n=0;n<(scenario==9?210:40);n=n+1)
                        direct(n%7==3?8'h50:8'h20,n);
                    if(scenario==8) geometry_enabled=0;
                    if(scenario==9) send(32'h04000400,32'h11157034);
                end
                7: begin
                    direct(8'h50,0);ticks(3);
                    for(integer n=0;n<256;n=n+1) direct(n%5==0?8'h50:8'h20,n);
                    // Initial packed word is accepted even at full retirement.
                    send(32'h04000400,32'h00111111);
                end
                10: begin geometry_enabled=0;direct(8'h50,1);direct(8'h11);send(32'h04000400,32'h11157034);end
                11: begin
                    direct(8'h10,2);repeat(34) direct(8'h11);
                    direct(8'h10,0);direct(8'h11);direct(8'h10,3);direct(8'h11);
                end
                12: begin
                    send(32'h04000400,32'h00111570);
                    send(32'h04000400,32'h98fedcba);send(32'h04000400,32'h12345678);
                end
                13,14: begin
                    record_ready=0;
                    for(integer n=0;n<200;n=n+1) direct(n%9==0?8'h50:8'h20,n*911);
                    checkpoint_request=1;checkpoint_producers_stopped=1;ticks(12);
                    if(checkpoint_stopped || checkpoint_valid) $fatal(1,"packet undelivered queue claimed stopped");
                    // Withheld sink never produces false success. Cancellation
                    // leaves accepted records intact, then retry after delivery.
                    if(scenario==14) begin
                        checkpoint_request=0;checkpoint_producers_stopped=0;ticks(3);
                    end
                    record_ready=1;
                end
                15: send(32'h04000400,0);
                default: ;
            endcase
            // Do not wait away an autonomous zero-param phase here.
            acquire();read_image();
            if(RETIRE && scenario==5 && (!image[6][25] || image[6][24:16]!=0))
                $fatal(1,"packet empty transport lost pending SWAP");
            if(RETIRE && scenario==7 && (image[6][24:16]!=256 || !image[6][25]))
                $fatal(1,"packet full retirement setup missed");
            state_file=$fopen("packet.state","w");$fdisplay(state_file,"%b",geometry_enabled);
            for(integer a=0;a<263;a=a+1) $fdisplay(state_file,"%h",image[a]);$fclose(state_file);
            trace_file=$fopen("packet.trace","w");
        end
        if(!trace_file) $fatal(1,"packet trace unavailable");
        checkpoint_request=0;checkpoint_producers_stopped=0;
        // Use identical post-snapshot external stimuli; geometry_enabled above
        // is fixture context, not proof of the wrapper's power-state restore.
        write_valid=0;write_is_dma=0;write_access=2;write_address=0;write_data=0;
        write_timestamp=64'hdeadf00d76543210;write_frame=32'hf1237890;
        record_ready=1;lcd_vblank=0;stack_ack=0;recording=1;ticks(3);
        // Power-off must retain old waits until power and a future native pulse.
        geometry_enabled=0;ticks(7);vblank();geometry_enabled=1;ticks(3);
        // Drain every retained SWAP without assuming one per delivered frame.
        repeat(270) begin vblank();ticks(2);end
        // Finish partial packed streams and exercise zero-param expansion with
        // its original trigger/frame/timestamp after the last parameter.
        for(integer n=0;n<64;n=n+1) begin
            send(32'h04000400,32'h30201001+n*31);ticks(5);
        end
        // Matrix mode, hidden texture pointer, visible projection/position and
        // error latches must influence future normalized commands identically.
        direct(8'h11);direct(8'h12,63);direct(8'h10,3);direct(8'h11);
        direct(8'h10,0);direct(8'h11);stack_ack=1;ticks();stack_ack=0;
        direct(8'h10,2);direct(8'h11);direct(8'h12,2);
        rng=32'h17625749+scenario*7919;
        for(integer n=0;n<1200;n=n+1) begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            record_ready=rng[0] || rng[1];lcd_vblank=n%5==0;
            geometry_enabled=!(n>=400 && n<440);
            write_valid=1;write_address=32'h04000480;write_access=2;write_is_dma=rng[5];
            write_data=rng;write_timestamp=64'hf00dcafe10000000+n;write_frame=32'h12340123+n;
            if(n%41==0) write_address=32'h04000540;
            ticks();
        end
        write_valid=0;record_ready=1;geometry_enabled=1;
        repeat(270) begin vblank();ticks(2);end
        reset=1;ticks(3);reset=0;ticks(3);direct(8'h10,2);direct(8'h11);ticks(5);
        if(restoring && !$feof(trace_file)) $fatal(1,"packet trace has unread observations");
        $fclose(trace_file);
        $display("PASS:packet restore=%0d retire=%0d scene=%0d gap=%0d observations=%0d",restoring,RETIRE,scenario,gap,observations);
        $finish;
    end
    initial begin #5000000;$fatal(1,"packet test timeout");end
endmodule
