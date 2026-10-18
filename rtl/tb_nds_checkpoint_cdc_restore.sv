`timescale 1ns/1ps
module tb_nds_checkpoint_cdc_restore;
    parameter integer DDR_HALF = 7;
    parameter bit SPARSE = 0;
    logic source_clk=0,ddr_raw=0,ddr_enabled=1;
    wire ddr_clk=ddr_raw && ddr_enabled;
    always #5 source_clk=~source_clk;
    always #(DDR_HALF) ddr_raw=~ddr_raw;
    logic  reset=1;
    logic  session_flush=0;
    logic  lcd_vblank=0;
    logic  gpu_valid=0;
    wire  gpu_ready;
    logic [27:0] gpu_address=0;
    logic [1:0] gpu_access=2;
    logic [3:0] gpu_byte_enable=15;
    logic [31:0] gpu_data=0;
    logic [63:0] gpu_timestamp=0;
    logic [8:0] gpu_scanline=0;
    logic  arm9_vram_valid=0;
    wire  arm9_vram_ready;
    logic [27:0] arm9_vram_address=0;
    logic [1:0] arm9_vram_access=2;
    logic [3:0] arm9_vram_byte_enable=15;
    logic [31:0] arm9_vram_data=0;
    logic [63:0] arm9_vram_timestamp=0;
    logic [8:0] arm9_vram_scanline=0;
    logic  arm7_vram_valid=0;
    wire  arm7_vram_ready;
    logic [27:0] arm7_vram_address=0;
    logic [1:0] arm7_vram_access=2;
    logic [3:0] arm7_vram_byte_enable=15;
    logic [31:0] arm7_vram_data=0;
    logic [63:0] arm7_vram_timestamp=0;
    logic [8:0] arm7_vram_scanline=0;
    logic  hblank_valid=0;
    wire  hblank_ready;
    logic [8:0] hblank_line=0;
    logic [31:0] hblank_frame=0;
    logic [63:0] hblank_timestamp=0;
    logic  frame_valid=0;
    wire  frame_ready;
    logic [31:0] frame_number=0;
    logic [63:0] frame_timestamp=0;
    wire  source_active;
    wire  ddr_active;
    wire  source_fault;
    wire [3:0] source_fault_reason;
    wire  ddr_fault;
    wire [3:0] ddr_fault_reason;
    wire [8:0] fifo_level;
    wire  fifo_empty;
    wire  fifo_below_half;
    wire  fifo_full;
    wire  gx_geometry_busy;
    logic  gx_stack_ack=0;
    wire [6:0] gx_stack_status;
    wire  record_valid;
    logic  record_ready=1;
    wire [127:0] record;
    wire [31:0] record_frame;
    wire  record_frame_end;
    wire  boundary_valid;
    logic  boundary_ready=1;
    wire [31:0] boundary_frame;
    logic  checkpoint_request=0;
    logic  checkpoint_producers_stopped=0;
    wire  checkpoint_seen;
    wire  checkpoint_stopped;
    logic [8:0] checkpoint_address=0;
    wire [31:0] checkpoint_data;
    wire  checkpoint_valid;
    logic  checkpoint_restore=0;
    logic  checkpoint_write=0;
    logic [31:0] checkpoint_write_data=0;
    wire  checkpoint_restore_ready;
    wire  checkpoint_restore_error;
    wire  checkpoint_ddr_request;
    logic  checkpoint_ddr_ack=0;
    nds_h3d_frame_record_cdc #(.ASYNC_LGDEPTH(2),
        .SPARSE_HBLANK(SPARSE), .SCANLINE_TAGS(1),
        .SWAP_VBLANK_RETIREMENT(1), .EXPERIMENTAL_CHECKPOINT(1)) dut (.*);
    bit restoring,recording=0,check_image=1,ack_enabled=1,force_stale_ack=0,force_ack_low=0;
    integer scenario=0,gap=0,state_file,source_file,ddr_file;
    integer source_observations=0,ddr_observations=0,ack_delay=0;
    integer pre_commands=0,pre_swaps=0,pre_vram=0;
    logic [31:0] image[0:264];
    logic [31:0] rng;
    logic [63:0] stamp=64'h12345678abcdef00;
    wire [31:0] source_observable = {6'd0,source_active,source_fault,
        source_fault_reason,fifo_level,fifo_empty,fifo_below_half,fifo_full,
        gx_geometry_busy,gx_stack_status};
    wire [200:0] ddr_observable = {ddr_active,ddr_fault,ddr_fault_reason,
        record_valid,record_valid?record:128'd0,
        record_valid?record_frame:32'd0,record_frame_end,
        boundary_valid,boundary_valid?boundary_frame:32'd0};
    logic [31:0] source_expected;
    logic [200:0] ddr_expected;
    // The downstream fixture ACKs only an explicit ordered request and keeps
    // its high phase until that request is withdrawn. It models no renderer.
    always @(posedge ddr_clk) begin
        if(reset || session_flush) begin checkpoint_ddr_ack<=0;ack_delay<=0;end
        else if(force_ack_low) checkpoint_ddr_ack<=0;
        else if(force_stale_ack) checkpoint_ddr_ack<=1;
        else if(!checkpoint_ddr_request) begin checkpoint_ddr_ack<=0;ack_delay<=0;end
        else if(ack_enabled) begin
            if(ack_delay<3) ack_delay<=ack_delay+1;
            else checkpoint_ddr_ack<=1;
        end
        if(!reset && !session_flush && record_valid && record_ready) begin
            if(record[7:0]==0) $fatal(1,"CDC checkpoint marker leaked to renderer ABI");
            if(!recording) begin
                if(record[7:0]==1) pre_commands=pre_commands+1;
                if(record[7:0]==9) pre_commands=pre_commands+3;
                if(record_frame_end) pre_swaps=pre_swaps+1;
                if(record[7:0]==3) pre_vram=pre_vram+1;
            end
        end
        #1;
        if(recording) begin
            if(restoring) begin
                if($fscanf(ddr_file,"%h\n",ddr_expected)!=1) $fatal(1,"CDC DDR trace truncated");
                if(ddr_observable !== ddr_expected) $fatal(1,"CDC DDR continuation mismatch scene=%0d obs=%0d got=%h expected=%h",scenario,ddr_observations,ddr_observable,ddr_expected);
            end else $fdisplay(ddr_file,"%h",ddr_observable);
            ddr_observations=ddr_observations+1;
        end
    end
    always @(posedge source_clk) begin
        #1;
        if(recording) begin
            if(restoring) begin
                if($fscanf(source_file,"%h\n",source_expected)!=1) $fatal(1,"CDC source trace truncated");
                if(source_observable !== source_expected) $fatal(1,"CDC source continuation mismatch scene=%0d obs=%0d got=%h expected=%h",scenario,source_observations,source_observable,source_expected);
            end else $fdisplay(source_file,"%h",source_observable);
            source_observations=source_observations+1;
        end
    end
    task automatic ticks(input integer n=1);
        repeat(n) begin @(posedge source_clk);#2;@(negedge source_clk);end
    endtask
    task automatic align;
        while($time%(10*DDR_HALF)!=0) @(negedge source_clk);
    endtask
    task automatic startup;
        integer guard;
        guard=0;
        while(!source_active || !ddr_active) begin
            ticks();guard=guard+1;
            if(guard>100) $fatal(1,"CDC startup failed");
        end
        ticks(4);
    endtask
    task automatic gpu(input logic [27:0] address,input logic [31:0] data,
                       input logic [3:0] lanes=15,input logic [1:0] access=2);
        integer guard;
        gpu_address=address;gpu_data=data;gpu_byte_enable=lanes;gpu_access=access;
        gpu_timestamp=stamp;gpu_scanline=stamp%263;gpu_valid=1;guard=0;#1;
        while(!gpu_ready) begin
            ticks();guard=guard+1;
            if(guard>900) $fatal(1,"CDC GPU write blocked");
        end
        ticks();gpu_valid=0;stamp=stamp+17;
    endtask
    task automatic direct(input logic [7:0] command,input logic [31:0] data=0);
        gpu(28'h400+{18'd0,command,2'b00},data);
    endtask
    task automatic vram(input bit arm7,input logic [31:0] data);
        integer guard;
        guard=0;
        if(arm7) begin
            arm7_vram_address=28'h6001234;arm7_vram_data=data;
            arm7_vram_timestamp=stamp;arm7_vram_scanline=stamp%263;arm7_vram_valid=1;
        end else begin
            arm9_vram_address=28'h6005678;arm9_vram_data=data;
            arm9_vram_timestamp=stamp;arm9_vram_scanline=stamp%263;arm9_vram_valid=1;
        end
        #1;
        while(!(arm7?arm7_vram_ready:arm9_vram_ready))begin
            ticks();guard=guard+1;if(guard>900)$fatal(1,"CDC VRAM write blocked");
        end
        ticks();arm7_vram_valid=0;arm9_vram_valid=0;stamp=stamp+17;
    endtask
    task automatic phase_event(input logic [8:0] line,input logic [31:0] frame);
        integer guard;
        hblank_line=line;hblank_frame=frame;hblank_timestamp=stamp;hblank_valid=1;guard=0;#1;
        while(!hblank_ready) begin ticks();guard=guard+1;if(guard>900)$fatal(1,"CDC phase blocked");end
        ticks();hblank_valid=0;stamp=stamp+17;
    endtask
    task automatic frame_event(input logic [31:0] frame);
        integer guard;
        frame_number=frame;frame_timestamp=stamp;frame_valid=1;guard=0;#1;
        while(!frame_ready) begin ticks();guard=guard+1;if(guard>900)$fatal(1,"CDC frame blocked");end
        ticks();frame_valid=0;stamp=stamp+17;
    endtask
    task automatic pulse;
        lcd_vblank=1;ticks();lcd_vblank=0;ticks();
    endtask
    task automatic acquire;
        integer guard;
        checkpoint_request=1;checkpoint_producers_stopped=1;guard=0;
        while(!checkpoint_stopped) begin
            ticks();guard=guard+1;
            if(guard>1800) $fatal(1,"CDC acquire exceeded bound");
            if(source_fault || ddr_fault) $fatal(1,"CDC unexpected transport fault");
        end
        if(!checkpoint_seen || !checkpoint_ddr_request || !checkpoint_ddr_ack ||
           dut.gx_pack_count!=0 || dut.async_read_valid || record_valid || boundary_valid)
            $fatal(1,"CDC stopped without real drained marker receipt");
        ticks(3);
    endtask
    task automatic release_owner;
        integer guard;
        checkpoint_request=0;guard=0;
        while(checkpoint_seen) begin
            ticks();guard=guard+1;if(guard>1800)$fatal(1,"CDC cancellation failed to drain");
        end
        if(checkpoint_ddr_ack || checkpoint_ddr_request) $fatal(1,"CDC released before ACK cleanup");
        checkpoint_producers_stopped=0;
    endtask
    task automatic load_word(input integer address,input logic [31:0] data);
        checkpoint_address=address;checkpoint_write_data=data;checkpoint_write=1;ticks();
        checkpoint_write=0;ticks(gap+2);
    endtask
    task automatic retry;
        checkpoint_restore=0;reset=1;ticks(5);checkpoint_restore=1;ticks();
        if(checkpoint_restore_error || checkpoint_restore_ready) $fatal(1,"CDC restore retry failed");
    endtask
    task automatic load_all;
        for(integer a=0;a<265;a=a+1) begin
            if(checkpoint_restore_ready) $fatal(1,"CDC partial image qualified");
            load_word(a,image[a]);
            if(checkpoint_restore_error) $fatal(1,"CDC valid image rejected at%0d",a);
            if(gpu_ready || arm9_vram_ready || arm7_vram_ready || hblank_ready || frame_ready ||
               record_valid || boundary_valid || checkpoint_ddr_request)
                $fatal(1,"CDC restore leaked handshake");
        end
        ticks(3);
        if(!checkpoint_restore_ready) $fatal(1,"CDC complete image unavailable");
    endtask
    task automatic read_image;
        for(integer a=0;a<265;a=a+1) begin
            checkpoint_address=a;#1;
            if(!checkpoint_valid) $fatal(1,"CDC image unavailable at%0d",a);
            if(restoring) begin
                if(check_image && checkpoint_data!==image[a]) $fatal(1,"CDC image mismatch at%0d",a);
            end else image[a]=checkpoint_data;
        end
        checkpoint_address=265;#1;
        if(checkpoint_valid || checkpoint_data!==0) $fatal(1,"CDC undefined word visible");
        @(negedge source_clk);
    endtask
    initial begin
        restoring=$test$plusargs("restore");check_image=!$test$plusargs("no-image-check");
        if($value$plusargs("scenario=%d",scenario)) begin end
        if($value$plusargs("gap=%d",gap)) begin end
        ticks(5);
        if(restoring) begin
            state_file=$fopen("cdc.state","r");if(!state_file)$fatal(1,"CDC image missing");
            for(integer a=0;a<265;a=a+1) if($fscanf(state_file,"%h\n",image[a])!=1)$fatal(1,"CDC image truncated");
            if(!$feof(state_file))$fatal(1,"CDC extra image words");$fclose(state_file);
            checkpoint_request=1;checkpoint_producers_stopped=1;checkpoint_restore=1;ticks();
            load_all();read_image();load_word(265,0);
            if(!checkpoint_restore_error || checkpoint_restore_ready)$fatal(1,"CDC extra load accepted");
            for(integer fault=0;fault<10;fault=fault+1) begin
                retry();
                case(fault)
                    0: load_word(1,image[1]);
                    1: begin load_word(0,image[0]);load_word(0,image[0]);end
                    2: load_word(0,0);
                    3: begin load_word(0,image[0]);load_word(1,2);end
                    4: begin
                        for(integer a=0;a<7;a=a+1)load_word(a,image[a]);
                        load_word(7,32'h00100000);
                    end
                    5: begin gpu_valid=1;ticks();gpu_valid=0;ticks();end
                    6: begin lcd_vblank=1;ticks();lcd_vblank=0;ticks();end
                    7: begin checkpoint_producers_stopped=0;ticks();checkpoint_producers_stopped=1;ticks();end
                    8: begin session_flush=1;ticks();session_flush=0;ticks();end
                    9: begin reset=0;ticks(5);load_word(0,image[0]);end
                endcase
                if(!checkpoint_restore_error || checkpoint_restore_ready || checkpoint_valid)
                    $fatal(1,"CDC invalid restore accepted fault=%0d",fault);
                load_word(0,image[0]);if(!checkpoint_restore_error)$fatal(1,"CDC poison recovered");
            end
            retry();load_all();read_image();
            // Release the actual async reset and restore together. The three
            // source reset-pipeline edges must not erase the loaded epoch.
            reset=0;checkpoint_restore=0;startup();acquire();read_image();
            source_file=$fopen("cdc-source.trace","r");ddr_file=$fopen("cdc-ddr.trace","r");
        end else begin
            reset=0;startup();
            // Move the logical epoch far from reset and wrap the tiny CDC FIFO.
            frame_event(32'h81234560);
            for(integer n=0;n<24;n=n+1)gpu(28'h1000,n*91);
            phase_event(0,32'h81234561);
            ticks(8);
            case(scenario)
                0: direct(8'h20,32'habcdef01);
                1: begin direct(8'h20,1);direct(8'h21,2);end
                2: begin end
                3: begin direct(8'h50,1);ticks(6);end
                4: begin direct(8'h50,1);ticks(3);repeat(40)direct(8'h20,77);end
                5: begin gpu(28'h304,0,1,0);direct(8'h50,1);direct(8'h20,42);end
                6: begin direct(8'h50,1);ticks(3);repeat(256)direct(8'h20,19);gpu(28'h400,32'h00111111);end
                7: begin direct(8'h10,2);repeat(37)direct(8'h11);gpu(28'h400,32'h11157034);end
                8: begin
                    gpu(28'h400,32'h00111570);gpu(28'h400,32'h98765432);gpu(28'h400,32'hfedcba98);
                end
                9: begin
                    record_ready=0;direct(8'h20,1);direct(8'h21,2);
                    checkpoint_request=1;checkpoint_producers_stopped=1;ticks(40);
                    if(checkpoint_stopped || checkpoint_valid || checkpoint_ddr_request)
                        $fatal(1,"CDC tail falsely drained under backpressure");
                    record_ready=1;
                end
                10: begin
                    force_stale_ack=1;ticks(5);direct(8'h20,1);
                    checkpoint_request=1;checkpoint_producers_stopped=1;ticks(45);
                    if(checkpoint_stopped || checkpoint_valid || checkpoint_ddr_request)
                        $fatal(1,"CDC stale ACK qualified new capture");
                    force_stale_ack=0;
                end
                11: begin
                    ack_enabled=0;direct(8'h20,1);direct(8'h21,2);
                    checkpoint_request=1;checkpoint_producers_stopped=1;
                    while(!checkpoint_ddr_request)ticks();
                    ticks(15);if(checkpoint_stopped || checkpoint_valid)$fatal(1,"CDC missing ACK qualified capture");
                    checkpoint_request=0;ticks(12);
                    if(!checkpoint_seen)$fatal(1,"CDC cancelled before marker receipt");
                    ack_enabled=1;release_owner();
                    direct(8'h20,32'hbada55);direct(8'h21,32'hface1234);
                end
                12: begin
                    align();ddr_enabled=0;
                    direct(8'h20,1);checkpoint_request=1;checkpoint_producers_stopped=1;ticks(40);
                    if(checkpoint_stopped || checkpoint_valid)$fatal(1,"CDC stopped DDR qualified capture");
                    align();ddr_enabled=1;
                end
                13: begin
                    phase_event(192,32'h81234561);gpu(28'h1000,37);direct(8'h20,42);
                end
                14: begin
                    direct(8'h20,1);direct(8'h21,2);acquire();
                    checkpoint_producers_stopped=0;ticks();checkpoint_producers_stopped=1;
                    ticks(45);
                    if(checkpoint_stopped || checkpoint_valid || !checkpoint_seen)
                        $fatal(1,"CDC owner loss reused same request");
                    release_owner();
                end
                15: begin
                    checkpoint_request=1;checkpoint_producers_stopped=0;ticks(2);
                    repeat(12)begin
                        if(!checkpoint_seen || checkpoint_stopped || checkpoint_valid)
                            $fatal(1,"CDC request receipt lost while waiting for producers");
                        ticks();
                    end
                    checkpoint_producers_stopped=1;
                end
                16: begin
                    record_ready=0;repeat(8)direct(8'h20,42);
                    checkpoint_request=1;checkpoint_producers_stopped=1;ticks(12);
                    if(checkpoint_stopped || checkpoint_valid || checkpoint_ddr_request)
                        $fatal(1,"CDC blocked delivery qualified capture");
                    checkpoint_request=0;ticks(4);
                    if(checkpoint_seen)$fatal(1,"CDC pre-marker cancel stuck");
                    checkpoint_producers_stopped=0;record_ready=1;
                end
                17: begin
                    direct(8'h20,1);acquire();
                    force_stale_ack=1;checkpoint_request=0;ticks(45);
                    if(!checkpoint_seen || checkpoint_stopped || checkpoint_valid)
                        $fatal(1,"CDC owner released before external ACK low");
                    force_stale_ack=0;release_owner();
                end
                18: vram(0,32'habcdef01);
                19: begin vram(0,32'h12345678);vram(1,32'h98765432);end
                20: begin
                    record_ready=0;repeat(8)direct(8'h20,42);
                    if(!SPARSE) record_ready=1;
                    phase_event(192,32'h81234561);
                    checkpoint_request=1;checkpoint_producers_stopped=1;ticks(12);
                    if(SPARSE && (checkpoint_stopped || checkpoint_valid))
                        $fatal(1,"CDC sparse phase discarded at capture");
                    record_ready=1;
                end
                21: begin
                    direct(8'h20,1);acquire();
                    @(negedge ddr_clk);force_ack_low=1;
                    repeat(3)@(negedge ddr_clk);force_ack_low=0;
                    @(negedge source_clk);ticks(45);
                    if(checkpoint_stopped || checkpoint_valid || !checkpoint_seen)
                        $fatal(1,"CDC lost downstream owner qualified old capture");
                    release_owner();
                end
                default: ;
            endcase
            acquire();read_image();
            if(scenario==0 && pre_commands!=1)$fatal(1,"CDC one-command tail missing at capture");
            if(scenario==1 && pre_commands!=2)$fatal(1,"CDC two-command tail missing at capture");
            if(scenario==16 && pre_commands!=8)$fatal(1,"CDC cancel dropped accepted records");
            if(scenario==18 && pre_vram!=1)$fatal(1,"CDC ARM9 VRAM missing at capture");
            if(scenario==19 && pre_vram!=2)$fatal(1,"CDC ARM7 VRAM missing at capture");
            if(scenario==5 && image[1]!=0)$fatal(1,"CDC geometry power setup wrong");
            if(scenario==6 && (!image[8][25] || image[8][24:16]!=256))$fatal(1,"CDC full retirement capture missed");
            state_file=$fopen("cdc.state","w");for(integer a=0;a<265;a=a+1)$fdisplay(state_file,"%h",image[a]);$fclose(state_file);
            source_file=$fopen("cdc-source.trace","w");ddr_file=$fopen("cdc-ddr.trace","w");
        end
        if(!source_file || !ddr_file)$fatal(1,"CDC trace files missing");
        align();gpu_valid=0;gpu_address=0;gpu_data=0;gpu_access=2;gpu_byte_enable=15;
        gpu_timestamp=0;gpu_scanline=0;hblank_valid=0;frame_valid=0;lcd_vblank=0;
        frame_number=0;hblank_frame=0;record_ready=1;boundary_ready=1;
        stamp=64'hf1a2b3c412345678;recording=1;release_owner();ticks(3);
        // Restore geometry power before the next accepted POWCNT1 write. New
        // SWAPs must respect its saved low state in scene5.
        pulse();direct(8'h50,9);ticks(10);pulse();ticks(5);gpu(28'h304,8,1,0);
        repeat(270)begin pulse();ticks(2);end
        for(integer n=0;n<64;n=n+1)begin gpu(28'h400,32'h31412001+n*7);ticks(6);end
        direct(8'h11);direct(8'h10,3);direct(8'h11);gx_stack_ack=1;ticks();gx_stack_ack=0;
        rng=32'h19715137+scenario*7919;
        for(integer n=0;n<180;n=n+1)begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            record_ready=n%5!=0;boundary_ready=n%7!=0;
            // Bounded sink stalls precede writes; source payload remains held.
            ticks(2);record_ready=1;boundary_ready=1;
            case(n%7)
                0: direct(8'h20,rng);
                1: direct(8'h50,rng);
                2: begin pulse();phase_event(0,32'h81234562+n);end
                3: begin gpu(28'h1000,rng);vram(0,rng);vram(1,~rng);end
                4: phase_event(192,32'h81234562+n);
                5: frame_event(32'h81234562+n);
                6: direct(8'h11);
            endcase
        end
        repeat(270)begin pulse();ticks(2);end
        phase_event(0,32'h91234567);frame_event(32'h91234567);ticks(30);
        // A normal session flush must still discard saved state and restore
        // the reset epoch/power configuration, not reuse the release guard.
        session_flush=1;ticks(5);session_flush=0;startup();direct(8'h20,123);phase_event(0,1);ticks(20);
        align();recording=0;
        if(restoring && (!$feof(source_file) || !$feof(ddr_file)))$fatal(1,"CDC trace unread observations");
        $fclose(source_file);$fclose(ddr_file);
        $display("PASS:CDC restore=%0d half=%0d sparse=%0d scene=%0d gap=%0d source=%0d DDR=%0d",restoring,DDR_HALF,SPARSE,scenario,gap,source_observations,ddr_observations);
        $finish;
    end
    initial begin #10000000;$fatal(1,"CDC test timeout");end
endmodule
