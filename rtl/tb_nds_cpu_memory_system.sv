module tb_nds_cpu_memory_system;
    // Default-off lightweight transport seam. Keep it explicitly present so
    // wildcard wiring cannot silently stop compiling when the production
    // module's transport contract evolves.
    logic [18:0] lw_reg_raddr = 0;
    logic [31:0] lw_reg_rdata;
    logic [18:0] lw_reg_waddr = 0;
    logic [31:0] lw_reg_wdata = 0;
    logic [3:0] lw_reg_be = 0;
    logic lw_reg_write = 0;
    logic lw_request_pending_irq;
    localparam [28:0] MAIN=29'h00100000, SHARED=29'h00180000;
    localparam [28:0] ARM7=29'h001a0000, ORACLE=29'h00200000;
    localparam [28:0] POSTED_RING=29'h00300000;
    logic clk=0,reset=1,request=0,cpu_is_arm9=1,rnw=1;always #5 clk=~clk;
    logic [7:0] arm9_cycles=0,arm7_cycles=0;
    logic arm9_cycles_valid=0,arm7_cycles_valid=0;
    logic [31:0] arm9_debug_pc=32'h02001234;
    logic [31:0] arm7_debug_pc=32'h037f8120;
    wire [31:0] request_debug_pc =
        cpu_is_arm9 ? arm9_debug_pc : arm7_debug_pc;
    logic [31:0] arm9_dtcm_region=32'h0300000a;
    logic arm9_dtcm_enable=1;
    logic arm9_dtcm_seed_valid=1;
    logic [31:0] arm9_dtcm_irq_vector=32'h01ffd5ec;
    logic [31:0] address=0,wdata=0,rdata;logic [1:0] access=2'b10;logic done;
    logic irq_arm9,irq_arm7,halt_arm9,halt_arm7;
    logic cpu_pause;
    logic debug_oracle_request,debug_mailbox_request,debug_mailbox_done;
    logic [3:0] debug_mailbox_state;
    logic [1:0] debug_tick_state;
    logic rd,we,busy=0,ready=0,ddram_command_accepted;
    logic [7:0] burst,be;logic [28:0] daddr;
    logic [63:0] din,dout=0,mailbox[0:4],posted_ring[0:31];
    integer polls=0,remaining=0,posted_ring_writes=0;
    integer timing9_writes=0,timing7_writes=0,start_timing9,start_timing7;
    integer io_transactions=0;
    logic [31:0] response_flags=32'h00000006;
    logic [31:0] response_data=32'hfeedc0de;
    assign ddram_command_accepted = (rd || we) && !busy;
    nds_cpu_memory_system #(.MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),.ARM7_WRAM_BASE_WORD(ARM7),
        .ORACLE_BASE_WORD(ORACLE),
        .POSTED_RING_BASE_WORD(POSTED_RING),
        .ORACLE_POLL_DELAY_CYCLES(1),.TIME_FLUSH_CYCLES(32),
        .ARM9_BAD_WRITE_PC_TELEMETRY(1),
        .ARM7_INVALID_WRITE_PC_TELEMETRY(1),
        .ARM9_MATH_RUNAWAY_PC_TELEMETRY(1),
        .ARM9_MATH_RUNAWAY_THRESHOLD(4),
        .ARM9_POLL_ADDRESS_TELEMETRY(1),
        .ARM9_DTCM_HANDLER_TELEMETRY(1),
        .HALT_POLL_CLOCKS(64),.HALT_ADVANCE_CYCLES(1024),
        // Intentionally omit transport_reset here. This default-off DDR
        // regression proves archived tops with the legacy port list still
        // reset their mailbox/ring from reset rather than a floating input.
        .POSTED_IRQ_REFRESH_WRITES(2)) dut(.transport_reset(),.*,
        .read_not_write(rnw),.write_data(wdata),
        .read_data(rdata),.ddram_read(rd),.ddram_write(we),.ddram_burst_count(burst),
        .ddram_address(daddr),.ddram_write_data(din),.ddram_byte_enable(be),
        .ddram_busy(busy),.ddram_read_data(dout),.ddram_read_data_ready(ready));

    task automatic put_dtcm_word(
        input integer word_index, input logic [31:0] value
    );
        begin
            dut.router.arm9_dtcm.memory0[word_index]=value[7:0];
            dut.router.arm9_dtcm.memory1[word_index]=value[15:8];
            dut.router.arm9_dtcm.memory2[word_index]=value[23:16];
            dut.router.arm9_dtcm.memory3[word_index]=value[31:24];
        end
    endtask

    always @(posedge clk) begin
        ready<=0;
        if(we && daddr>=ORACLE && daddr<=ORACLE+4)begin
            mailbox[daddr-ORACLE]<=din;
            if(daddr==ORACLE+1 && din[31:0]!==32'hffffffff)
                io_transactions<=io_transactions+1;
            if(daddr==ORACLE+2 && mailbox[1][31:0]===32'hffffffff)begin
                if(din[3])timing9_writes<=timing9_writes+1;
                else timing7_writes<=timing7_writes+1;
            end
        end else if(we && daddr>=POSTED_RING &&
                    daddr<POSTED_RING+32)begin
            posted_ring[daddr-POSTED_RING]<=din;
            posted_ring_writes<=posted_ring_writes+1;
        end
        if(rd)begin
            ready<=1;
            if(daddr==POSTED_RING+1)begin
                dout<=posted_ring[1];
            end else if(daddr==ORACLE+3)begin
                polls<=polls+1;remaining<=1;
                dout<={mailbox[0][63:32],response_data};
            end else dout<=64'h0123456789abcdef;
        end else if(remaining!=0)begin
            ready<=1;remaining<=0;dout<={32'h0,response_flags};
        end
    end

    initial begin
        integer index;
        for(index=0;index<32;index=index+1)
            posted_ring[index]=0;
        repeat(3)@(posedge clk);reset=0;

        // Exercise NSMB's exact filesystem stack slot through the complete
        // production memory-system wrapper, including its registered local
        // completion handoff. CPU and bus regressions separately prove the
        // exact instruction payload; this proves the remaining local seam.
        arm9_dtcm_region=32'h027e000a;
        put_dtcm_word(14'h0de3,32'haabb6114);
        @(negedge clk);address=32'h027e378c;rnw=1;access=2'b01;
        cpu_is_arm9=1;request=1;wait(done);#1;
        if(rdata!==32'h00006114||debug_oracle_request||rd||we)
            $fatal(1,"filesystem DTCM initial halfword %h",rdata);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h027e378c;wdata=32'h00006107;
        rnw=0;access=2'b01;request=1;wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);rnw=1;access=2'b00;request=1;wait(done);#1;
        if(rdata!==32'h00000007||debug_oracle_request||rd||we)
            $fatal(1,"filesystem DTCM completion/readback %h",rdata);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        arm9_dtcm_region=32'h0300000a;

        // Cycle reports accumulate across local RAM traffic.
        @(negedge clk);arm7_cycles=7;arm7_cycles_valid=1;
        @(posedge clk);@(negedge clk);arm7_cycles_valid=0;
        // Local mirrored main RAM read.
        @(negedge clk);address=32'h02c00000;rnw=1;access=2'b10;
        request=1;wait(rd);
        if(daddr!==MAIN)$fatal(1,"main mirror did not select local DDR");
        wait(done);#1;if(rdata!==32'h89abcdef)$fatal(1,"main response");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);arm7_cycles=9;arm7_cycles_valid=1;
        @(posedge clk);@(negedge clk);arm7_cycles_valid=0;

        // The measured hot VRAM page is write-only in the current game menu.
        // Its exact ARM9 halfword shape must commit to the HPS-visible ring
        // without publishing an oracle request. The next ordinary mailbox
        // request must fence that sequence so HPS cannot reorder it.
        @(negedge clk);arm9_cycles=11;arm9_cycles_valid=1;
        @(posedge clk);@(negedge clk);arm9_cycles_valid=0;
        @(negedge clk);address=32'h0600c000;wdata=32'h00001234;rnw=0;
        access=2'b01;cpu_is_arm9=1;request=1;
        wait(done);#1;
        if(debug_oracle_request || cpu_pause || posted_ring_writes!=3)
            $fatal(1,"VRAM halfword was not posted locally oracle=%b pause=%b writes=%0d",
                debug_oracle_request,cpu_pause,posted_ring_writes);
        if(posted_ring[8]!==64'h000012340600c000 ||
           posted_ring[9]!==64'h0000000a0000000b ||
           posted_ring[10]!==64'h0000000000000001)
            $fatal(1,"posted VRAM entry mismatch %h %h %h",
                posted_ring[8],posted_ring[9],posted_ring[10]);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // A second posted write reaches the deliberately short test cadence.
        // It must generate a fenced zero-cycle mailbox refresh so pending
        // VBlank/HALT state cannot remain stale during a long VRAM stream.
        @(negedge clk);address=32'h0600c002;wdata=32'h00005678;request=1;
        wait(done);
        @(negedge clk);request=0;
        wait(cpu_pause);
        wait(polls==1);
        wait(!cpu_pause);
        repeat(3)@(posedge clk);
        if(posted_ring_writes!=6 ||
           posted_ring[11]!==64'h000056780600c002 ||
           posted_ring[12]!==64'h0000000a00000000 ||
           posted_ring[13]!==64'h0000000000000002)
            $fatal(1,"second posted VRAM entry mismatch");
        if(mailbox[1][31:0]!==32'hffffffff ||
           mailbox[2][63:32]!==0 ||
           mailbox[4]!==64'h0000000200000000)
            $fatal(1,"posted IRQ refresh was not zero-cycle/fenced polls=%0d count=%0d %h %h %h",
                polls,dut.posted_since_irq_refresh,
                mailbox[1],mailbox[2],mailbox[4]);
        if(dut.mailbox_completed_fence!==32'd2 ||
           dut.posted_write_ring.consumer_sequence!==32'd2)
            $fatal(1,"completed mailbox fence did not acknowledge ring %h %h",
                dut.mailbox_completed_fence,
                dut.posted_write_ring.consumer_sequence);
        @(negedge clk);polls=0;

        // Unresolved I/O transaction completes through the DDR mailbox.
        @(negedge clk);address=32'h04000184;wdata=32'h76543210;rnw=0;
        access=2'b10;cpu_is_arm9=0;request=1;
        wait(cpu_pause);
        if(!cpu_pause)$fatal(1,"oracle request did not pause both CPUs");
        wait(done);#1;
        if(!cpu_pause)$fatal(1,"oracle pause released before request");
        if(rdata!==32'hfeedc0de||polls!=1||irq_arm9||!irq_arm7||
            !halt_arm9||halt_arm7)
            $fatal(1,"oracle completion/IRQ/halt");
        if(mailbox[1]!==64'h7654321004000184)$fatal(1,"oracle transaction");
        if(mailbox[2]!==64'h0000001000000004)
            $fatal(1,"ARM7 oracle cycles/control %h",mailbox[2]);
        if(mailbox[4]!==64'h0000000200000000)
            $fatal(1,"oracle did not fence posted VRAM sequence %h",
                mailbox[4]);
        if(mailbox[0]!==64'h000000024f53444e)$fatal(1,"oracle header");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        if(cpu_pause)$fatal(1,"oracle pause did not release");

        // The transmitted ARM7 accumulator must clear exactly once; a second
        // request without new cycle reports carries zero rather than replaying.
        @(negedge clk);address=32'h04000130;rnw=1;request=1;
        wait(done);#1;
        if(mailbox[1][63:32]!==arm7_debug_pc)
            $fatal(1,"ARM7 read PC telemetry missing %h",mailbox[1]);
        if(mailbox[2][63:32]!==0)
            $fatal(1,"ARM7 elapsed cycles replayed %h",mailbox[2]);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // WRAMCNT changes complete through the oracle, then immediately
        // redirect subsequent CPU accesses to the matching shared DDR bank.
        @(negedge clk);address=32'h04000247;wdata=1;rnw=0;access=2'b00;
        cpu_is_arm9=1;request=1;wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        if(dut.wramcnt!==1)$fatal(1,"WRAMCNT write was not mirrored");
        @(negedge clk);address=32'h03005234;rnw=1;access=2'b10;request=1;
        wait(rd);
        if(daddr!==SHARED+29'h00000a46)
            $fatal(1,"WRAMCNT shared bank route %h",daddr);
        wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // With no CPU I/O request, accumulated local execution must still
        // flush through a timing-only mailbox transaction so scheduled
        // peripherals and IRQ outputs cannot stall indefinitely.
        @(negedge clk);arm9_cycles=40;arm9_cycles_valid=1;
        @(posedge clk);@(negedge clk);arm9_cycles_valid=0;
        wait(cpu_pause);
        wait(mailbox[1][31:0]===32'hffffffff);
        wait(polls==4);repeat(5)@(posedge clk);
        if(cpu_pause)$fatal(1,"timing-flush pause did not release");
        if(mailbox[1][63:32]!==arm9_debug_pc ||
            mailbox[2][63:32]!==32||mailbox[2][3]!==1)
            $fatal(1,"ARM9 timing flush telemetry %h %h",
                mailbox[1],mailbox[2]);
        if(!irq_arm7)$fatal(1,"timing flush did not refresh IRQ outputs");

        // Back-to-back local requests may keep the shared request line high.
        // A completed local transaction must still form a safe timing-flush
        // boundary once the execution bucket is full.
        @(negedge clk);address=32'h02000040;rnw=1;access=2'b10;
        cpu_is_arm9=1;request=1;arm9_cycles=40;arm9_cycles_valid=1;
        @(posedge clk);@(negedge clk);arm9_cycles_valid=0;
        wait(done);#1;
        @(posedge clk);
        @(negedge clk);request=0;
        wait(polls==5);repeat(5)@(posedge clk);
        if(mailbox[1][31:0]!==32'hffffffff ||
            mailbox[1][63:32]!==arm9_debug_pc ||
            mailbox[2][63:32] !== 32)
            $fatal(1,"active local timing flush payload %h %h",
                mailbox[1],mailbox[2]);

        // Zero-cycle activity still suppresses the autonomous idle heartbeat.
        // Otherwise it double-counts time and can flood the HPS responder.
        repeat(80) begin
            @(negedge clk); arm9_cycles=0; arm9_cycles_valid=1;
            @(posedge clk); @(negedge clk); arm9_cycles_valid=0;
        end
        repeat(32) @(posedge clk);
        if(polls!=5)
            $fatal(1,"active CPU execution triggered idle heartbeat");

        // A halted external CPU cannot contribute more retired cycles. The
        // FPGA must still advance its scheduler until an IRQ can wake it.
        wait(polls==6);repeat(5)@(posedge clk);
        if(mailbox[1][31:0]!==32'hffffffff ||
            mailbox[1][63:32]!==arm9_debug_pc ||
            mailbox[2][63:32]!==1024 || mailbox[2][3]!==1)
            $fatal(1,"halt wake heartbeat payload %h %h",
                mailbox[1],mailbox[2]);

        // The backend may clear its software-visible HALT flags before either
        // hardware CPU can produce another request. Global DS time must still
        // move, so an idle heartbeat is required even with both flags clear.
        response_flags=0;
        wait(polls==7);repeat(5)@(posedge clk);
        if(halt_arm9||halt_arm7)$fatal(1,"HALT flags did not clear");
        wait(polls==8);repeat(5)@(posedge clk);
        if(mailbox[1][31:0]!==32'hffffffff ||
            mailbox[1][63:32]!==arm7_debug_pc ||
            mailbox[2][63:32]!==1024)
            $fatal(1,"flag-clear idle heartbeat payload %h %h",
                mailbox[1],mailbox[2]);

        // Diagnostic mode substitutes the issuing PC only for the exact
        // corrupt ARM9 write address; all ordinary writes above remain intact.
        @(negedge clk);address=32'h0400009f;wdata=32'he59f2048;rnw=0;
        access=2'b10;cpu_is_arm9=1;request=1;wait(done);#1;
        if(mailbox[1]!=={arm9_debug_pc,32'h0400009f})
            $fatal(1,"bad-write PC telemetry missing %h",mailbox[1]);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // Normal math-register programming remains byte-for-byte unchanged.
        // An unrelated completed I/O transaction resets a partial run. Only
        // after four consecutive math writes does the diagnostic latch the PC
        // that began the run and tag subsequent already-corrupt writes.
        repeat(2) begin
            @(negedge clk);address=32'h04000280;wdata=32'h11223344;rnw=0;
            access=2'b10;cpu_is_arm9=1;request=1;wait(done);#1;
            if(mailbox[1]!==64'h1122334404000280)
                $fatal(1,"short math write was modified %h",mailbox[1]);
            @(negedge clk);request=0;repeat(2)@(posedge clk);
        end
        @(negedge clk);address=32'h04000184;wdata=32'h55667788;
        request=1;wait(done);#1;
        if(mailbox[1]!==64'h5566778804000184)
            $fatal(1,"run reset write was modified %h",mailbox[1]);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        repeat(4) begin
            @(negedge clk);address=32'h04000290;wdata=32'he59f1048;
            request=1;wait(done);#1;
            if(mailbox[1]!==64'he59f104804000290)
                $fatal(1,"pre-threshold math write modified %h",mailbox[1]);
            @(negedge clk);request=0;repeat(2)@(posedge clk);
        end
        if(!dut.arm9_math_runaway_seen ||
           dut.arm9_math_run_first_pc!==arm9_debug_pc)
            $fatal(1,"math runaway did not latch first PC count=%0d pc=%h",
                dut.arm9_math_write_count,dut.arm9_math_run_first_pc);
        @(negedge clk);arm9_debug_pc=32'h02005678;
        address=32'h04000294;wdata=32'he590c000;request=1;wait(done);#1;
        if(mailbox[1]!==64'h0200123404000294)
            $fatal(1,"math runaway first-PC tag missing %h",mailbox[1]);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        arm9_debug_pc=32'h02001234;

        // FPGA-local ARM7 RAM and BIOS transactions cannot reach this oracle.
        // Preserve ordinary 0x04xxxxxx I/O writes (proved above), but tag the
        // first impossible external write with its exact issuing PC.
        @(negedge clk);address=32'hfffffe60;wdata=32'h00000000;rnw=0;
        access=2'b10;cpu_is_arm9=0;request=1;wait(done);#1;
        if(mailbox[1]!=={arm7_debug_pc,32'hfffffe60})
            $fatal(1,"ARM7 invalid-write PC telemetry missing %h",
                mailbox[1]);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // Direct-boot DTCM startup temporarily overwrites the IRQ-vector word.
        // Do not expose a pending ARM9 interrupt until software restores the
        // descriptor's expected handler.
        response_flags=1;
        @(negedge clk);address=32'h04000184;rnw=1;access=2'b10;
        cpu_is_arm9=1;request=1;wait(done);#1;
        if(!irq_arm9)$fatal(1,"seeded ARM9 IRQ vector blocked");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h03003ffc;wdata=32'he1888a00;rnw=0;
        access=2'b10;request=1;wait(done);#1;
        if(irq_arm9)$fatal(1,"premature ARM9 IRQ was not guarded");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h03003ffc;wdata=arm9_dtcm_irq_vector;
        request=1;wait(done);#1;
        if(!irq_arm9)$fatal(1,"ARM9 IRQ did not resume after vector install");
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // Once the vulnerable startup copy has been followed by a verified
        // restore, a game may legitimately install a different dispatcher.
        // The boot-time safety guard must remain open for that runtime vector.
        @(negedge clk);address=32'h03003ffc;wdata=32'h02064160;rnw=0;
        access=2'b10;request=1;wait(done);#1;
        if(!irq_arm9)
            $fatal(1,"runtime ARM9 IRQ vector was incorrectly blocked");
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // Model the stale underlying BRAM word observed on hardware after the
        // startup copy. BIOS-visible vector readback must follow the last
        // completed CPU write tracked by the memory system.
        put_dtcm_word(4095,32'he1888a00);
        @(negedge clk);address=32'h03003ffc;rnw=1;access=2'b10;request=1;
        wait(done);#1;
        if(rdata!==32'h02064160)
            $fatal(1,"stale DTCM BRAM escaped vector shadow %h",rdata);
        // The real ARM9 advances the address bus on the completion edge. The
        // vector must remain visible through that handoff rather than
        // immediately exposing the router's stale registered BRAM word.
        address=32'he1888a00;#1;
        if(rdata!==32'h02064160)
            $fatal(1,"completion-edge address change escaped vector shadow %h",
                rdata);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // DTCM+0x3c0 contains the SDK IRQ handler-table pointer used after
        // FIFO command 0x6B. Shadow writes with architectural byte lanes and
        // export the otherwise HPS-invisible word on tagged timing telemetry.
        @(negedge clk);address=32'h030003c0;wdata=32'h02001000;rnw=0;
        access=2'b10;cpu_is_arm9=1;request=1;wait(done);#1;
        if(!dut.arm9_dtcm_handler_write_seen ||
           dut.arm9_dtcm_handler_shadow!==32'h02001000)
            $fatal(1,"DTCM handler pointer shadow missing %h",
                dut.arm9_dtcm_handler_shadow);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        force dut.tick_cpu=1'b1;
        force dut.arm9_dtcm_handler_telemetry_phase=1'b1;
        #1;
        if(dut.timing_debug_pc!==32'h62001000)
            $fatal(1,"DTCM handler telemetry missing %h",
                dut.timing_debug_pc);
        release dut.arm9_dtcm_handler_telemetry_phase;
        release dut.tick_cpu;

        // Timing samples land anywhere within this tight polling loop. Export
        // both the live DTCM vector and a tagged guard-state word so hardware
        // can distinguish guard suppression from CPU-side IRQ rejection.
        arm9_debug_pc=32'h0207cca4;
        address=32'h020980a4;
        force dut.tick_cpu=1'b1;
        force dut.arm9_dtcm_handler_telemetry_phase=1'b0;
        #1;
        if(dut.timing_debug_pc[31:8]!==24'ha90000 ||
           dut.timing_debug_pc[4:0]!==5'b01111)
            $fatal(1,"IRQ guard telemetry missed loop PC %h",
                dut.timing_debug_pc);
        arm9_debug_pc=32'h0207ccac;
        #1;
        if(dut.timing_debug_pc!==32'h02064160)
            $fatal(1,"live IRQ vector telemetry missing %h",
                dut.timing_debug_pc);
        release dut.arm9_dtcm_handler_telemetry_phase;
        release dut.tick_cpu;

        // Sustained execution from both local CPUs can fill both timing
        // buckets faster than HPS consumes them. Each CPU must still receive
        // service; fixed ARM9 priority freezes the backend at ARM7's old
        // timestamp and prevents DMA/IRQ/video/audio events from completing.
        start_timing9=timing9_writes;
        start_timing7=timing7_writes;
        @(negedge clk);
        request=0;
        arm9_cycles=8;
        arm7_cycles=8;
        arm9_cycles_valid=1;
        arm7_cycles_valid=1;
        repeat(600)@(posedge clk);
        @(negedge clk);
        arm9_cycles_valid=0;
        arm7_cycles_valid=0;
        if(timing9_writes-start_timing9<2 ||
           timing7_writes-start_timing7<2)
            $fatal(1,"dual-CPU timing flush starvation ARM9=%0d ARM7=%0d",
                timing9_writes-start_timing9,
                timing7_writes-start_timing7);

        // IME/IE reads are side-effect free and CPU-owned. The first read must
        // obtain authoritative HPS state; a repeated read may complete from
        // the per-CPU shadow without another mailbox poll. Writes must still
        // reach HPS and update the shadow only after that completion.
        @(negedge clk);
        request=0;
        arm9_cycles_valid=0;
        arm7_cycles_valid=0;
        response_flags=0;
        repeat(5)@(posedge clk);
        // Keep the independent idle-heartbeat timer from adding unrelated
        // mailbox polls while this block counts only CPU register traffic.
        force dut.halt_poll_count=0;
        start_timing9=io_transactions;
        response_data=32'h00000001;
        @(negedge clk);address=32'h04000208;rnw=1;access=2'b01;
        cpu_is_arm9=0;request=1;wait(done);#1;
        if(rdata!==1 || io_transactions!=start_timing9+1)
            $fatal(1,"authoritative ARM7 IME read failed data=%h io=%0d",
                rdata,io_transactions-start_timing9);
        start_timing9=io_transactions;
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);request=1;wait(done);#1;
        if(rdata!==1 || io_transactions!=start_timing9)
            $fatal(1,"ARM7 IME cache miss data=%h io=%0d",
                rdata,io_transactions-start_timing9);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        @(negedge clk);rnw=0;wdata=0;request=1;wait(done);
        if(io_transactions!=start_timing9+1)
            $fatal(1,"ARM7 IME write bypassed HPS io=%0d",
                io_transactions-start_timing9);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);rnw=1;request=1;wait(done);#1;
        if(rdata!==0 || io_transactions!=start_timing9+1)
            $fatal(1,"ARM7 IME write did not update cache");
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        response_data=32'h89abcdef;
        @(negedge clk);address=32'h04000210;rnw=1;access=2'b10;
        request=1;wait(done);#1;
        if(rdata!==32'h89abcdef || io_transactions!=start_timing9+2)
            $fatal(1,"authoritative ARM7 IE read failed");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h04000212;access=2'b01;request=1;
        wait(done);#1;
        if(rdata!==16'h89ab || io_transactions!=start_timing9+2)
            $fatal(1,"ARM7 IE halfword cache failed data=%h",rdata);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // ARM9 owns a distinct IME/IE register bank. ARM7's populated cache
        // must never satisfy an ARM9 read.
        response_data=32'h13579bdf;
        @(negedge clk);address=32'h04000210;access=2'b10;
        cpu_is_arm9=1;request=1;wait(done);#1;
        if(rdata!==32'h13579bdf || io_transactions!=start_timing9+3)
            $fatal(1,"ARM9 IE cache was not independent");
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // IF can change asynchronously from DMA/video/audio events and must
        // never use this optimization.
        response_data=32'h00000080;
        @(negedge clk);address=32'h04000214;request=1;wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        response_data=32'h00000100;
        @(negedge clk);request=1;wait(done);#1;
        if(rdata!==32'h00000100 || io_transactions!=start_timing9+5)
            $fatal(1,"IF was incorrectly cached data=%h io=%0d",
                rdata,io_transactions-start_timing9);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // melonDS models only the ARM7 16-bit WiFi BBBUSY read at 0x0480815e
        // as a constant zero. Prove the exact access is local and that neither
        // another width nor ARM9 can accidentally take this fast path.
        @(negedge clk);address=32'h0480815e;access=2'b01;
        cpu_is_arm9=0;rnw=1;request=1;wait(done);#1;
        if(rdata!==0 || io_transactions!=start_timing9+5)
            $fatal(1,"ARM7 WiFi BBBUSY constant read failed data=%h io=%0d",
                rdata,io_transactions-start_timing9);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        response_data=32'h000000a5;
        @(negedge clk);access=2'b00;request=1;wait(done);#1;
        if(rdata!==32'h000000a5 || io_transactions!=start_timing9+6)
            $fatal(1,"non-halfword WiFi access was incorrectly local");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        response_data=32'h00005a5a;
        @(negedge clk);access=2'b01;cpu_is_arm9=1;request=1;wait(done);#1;
        if(rdata!==32'h00005a5a || io_transactions!=start_timing9+7)
            $fatal(1,"ARM9 WiFi access was incorrectly local");
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // The complete baseband data port is local and coherent. Firmware
        // stages a byte through BBWrite, commits it by writing BBCnt with
        // command 5, then selects command 6 and reads it back through BBRead.
        // This sequence must consume no HPS mailbox transactions.
        cpu_is_arm9=0;
        response_data=32'hdeadbeef;
        @(negedge clk);address=32'h0480815a;rnw=0;access=2'b01;
        wdata=32'h000000a5;request=1;wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h04808158;wdata=32'h00005022;
        request=1;wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);wdata=32'h00006022;request=1;wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h0480815c;rnw=1;request=1;wait(done);#1;
        if(rdata!==32'h000000a5 || io_transactions!=start_timing9+7)
            $fatal(1,"WiFi BB write/readback mismatch data=%h io=%0d",
                rdata,io_transactions-start_timing9);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // Fixed baseband IDs ignore writes exactly as melonDS does.
        @(negedge clk);address=32'h0480815a;rnw=0;wdata=0;request=1;
        wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h04808158;wdata=32'h00005000;request=1;
        wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);wdata=32'h00006000;request=1;wait(done);
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h0480815c;rnw=1;request=1;wait(done);#1;
        if(rdata!==32'h0000006d)
            $fatal(1,"WiFi fixed BB register was overwritten data=%h",rdata);
        @(negedge clk);request=0;repeat(2)@(posedge clk);

        // Writes to BBRead and non-halfword port accesses are not part of the
        // local device and must remain HPS-owned.
        @(negedge clk);address=32'h0480815c;rnw=0;wdata=32'h55;
        request=1;wait(done);
        if(io_transactions!=start_timing9+8)
            $fatal(1,"WiFi BBRead write incorrectly completed locally");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        @(negedge clk);address=32'h04808158;rnw=1;access=2'b10;
        request=1;wait(done);
        if(io_transactions!=start_timing9+9)
            $fatal(1,"WiFi BB word access incorrectly completed locally");
        @(negedge clk);request=0;repeat(2)@(posedge clk);
        release dut.halt_poll_count;

        $display("PASS: CPU memory system keeps RAM local, completes I/O, and advances global time through all idle states");
        $finish;
    end
endmodule
