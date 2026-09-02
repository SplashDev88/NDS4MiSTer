module tb_nds_dual_cpu_memory_cosim #(
    parameter integer TIME_FLUSH_CYCLES = 8192,
    parameter bit TRACE_RETURN = 0
);
    timeunit 1ns;
    timeprecision 1ns;

    localparam logic [28:0] MAIN   = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7RAM= 29'h001a0000;
    localparam logic [28:0] ORACLE = 29'h00200000;

    logic clk=0, reset=1, descriptor_valid=1;
    always #5 clk=~clk;

    logic boot_ready, global_step_enable;
    logic [7:0] arm9_cycles,arm7_cycles;
    logic arm9_cycles_valid,arm7_cycles_valid;
    logic [31:0] arm9_debug_pc,arm7_debug_pc,arm9_dtcm_region;
    logic arm9_dtcm_enable;
    logic irq_arm9,irq_arm7,halt_arm9,halt_arm7,cpu_pause;
    logic [31:0] ext_addr,ext_wdata,ext_debug_pc,ext_rdata;
    logic ext_rnw,ext_ena,ext_cpu_is_arm9,ext_done;
    logic [1:0] ext_acc;

    // Bus-level lockstep trace. Emits the same JSONL contract that
    // melonDS produces under NDS4MISTER_ARM_TRACE with BUS_ONLY, so
    // tools/compare_arm_traces.py can stop at the first divergent
    // port-visible event. gba_cpu does not expose its register file, so the
    // external bus is the finest granularity available without modifying
    // Peip's core -- and it is the right granularity here, since a CPU
    // divergence that never reaches the bus cannot corrupt GX.
    integer bus_trace_fd = 0;
    integer bus_trace_seq = 0;
    integer bus_trace_limit = 200000;
    string  bus_trace_path;
    initial begin
        if ($value$plusargs("bustrace=%s", bus_trace_path)) begin
            bus_trace_fd = $fopen(bus_trace_path, "w");
            if (bus_trace_fd == 0)
                $display("WARN could not open bus trace %s", bus_trace_path);
        end
    end
    // One event per accepted transaction: sample on the completion edge so a
    // stalled or retried request is logged exactly once.
    logic ext_ena_d;
    always_ff @(posedge clk) begin
        ext_ena_d <= ext_ena;
        if (bus_trace_fd != 0 && ext_ena && ext_done &&
            bus_trace_seq < bus_trace_limit) begin
            // %s right-justifies a SV string literal into a padded field,
            // which emitted "kind":" read" and would make every read compare
            // unequal. Select a pre-built exact format instead.
            if (ext_rnw)
              $fwrite(bus_trace_fd,
                "{\"event\":\"bus\",\"cpu\":\"%s\",\"seq\":%0d,\"kind\":\"read\",\"addr\":\"%08h\",\"size\":%0d,\"value\":\"%08h\",\"pc\":\"%08h\"}\n",
                ext_cpu_is_arm9 ? "arm9" : "arm7", bus_trace_seq, ext_addr,
                (ext_acc == 2'd0) ? 1 : ((ext_acc == 2'd1) ? 2 : 4),
                ext_rdata, ext_debug_pc);
            else
              $fwrite(bus_trace_fd,
                "{\"event\":\"bus\",\"cpu\":\"%s\",\"seq\":%0d,\"kind\":\"write\",\"addr\":\"%08h\",\"size\":%0d,\"value\":\"%08h\",\"pc\":\"%08h\"}\n",
                ext_cpu_is_arm9 ? "arm9" : "arm7", bus_trace_seq, ext_addr,
                (ext_acc == 2'd0) ? 1 : ((ext_acc == 2'd1) ? 2 : 4),
                ext_wdata, ext_debug_pc);
            if (0) $fwrite(bus_trace_fd, "%0d%08h",
                bus_trace_seq,
                ext_addr,
                ext_debug_pc);
            bus_trace_seq++;
        end
    end


    logic ddram_read,ddram_write,ddram_busy=0,ddram_read_data_ready=0;
    logic ddram_command_accepted;
    logic [7:0] ddram_burst_count,ddram_byte_enable;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data,ddram_read_data=0;
    assign ddram_command_accepted =
        (ddram_read || ddram_write) && !ddram_busy;

    logic [31:0] main_words[0:1048575];
    // Optional real memory image. Without this the cosim only holds a
    // two-instruction shim, so lockstep diverges at event 1 with the FPGA
    // reading zeros while melonDS runs real game code. Dump the post
    // direct-boot image from melonDS (DirectBootImage.main_ram) as one 32-bit
    // hex word per line and pass +mainimage=<path>.
    string main_image_path;
    // +naturalboot enters the real ARM9/ARM7 entry points and suppresses the
    // synthetic seam stubs, so both cores follow the same control flow melonDS
    // takes. Without it the shim deliberately jumps into a curated SDK
    // sequence, which makes lockstep compare two different programs.
    bit natural_boot = 0;
    logic [31:0] natural_arm9_entry = 32'h02000800;
    logic [31:0] natural_arm7_entry = 32'h02380000;
    initial begin
        natural_boot = $test$plusargs("naturalboot");
        void'($value$plusargs("arm9entry=%h", natural_arm9_entry));
        void'($value$plusargs("arm7entry=%h", natural_arm7_entry));
        if ($value$plusargs("mainimage=%s", main_image_path)) begin
            $readmemh(main_image_path, main_words);
            $display("LOCKSTEP loaded main RAM image %s", main_image_path);
        end
    end
    logic [31:0] shared_words[0:8191];
    logic [31:0] arm7_words[0:16383];
    logic [63:0] oracle_words[0:4];
    logic second_mailbox_beat=0;
    logic ddram_read_seen=0;
    logic irq9_pending=0;
    logic arm7_sent_6b=0,arm9_read_6b=0,arm9_sent_ab=0;
    logic saw_first_arm9_ime_write=0;
    logic [31:0] first_arm9_io_address=0,first_arm9_io_data=0;
    logic first_arm9_io_seen=0;
    logic saw_irq_vector=0,saw_bios_epilogue=0,saw_outer_fifo=0;
    integer fifo_status_reads=0,gpu_reads=0,gpu_writes=0;
    integer oracle_transactions=0,timing_transactions=0;
    integer arm9_cycle_reports=0,arm7_cycle_reports=0;
    integer arm9_return_trace_count=0;
    longint unsigned arm9_cycle_sum=0,arm7_cycle_sum=0;

    assign global_step_enable=!cpu_pause;

    nds_dual_cpu_cosim_top cpus(
        .clk,.reset,.descriptor_valid,.global_step_enable,
        // Begin with the exact first two NSMB ARM9 instructions observed on
        // hardware.  The second instruction is the first external I/O access
        // and must survive the VHDL arbiter/SystemVerilog mailbox seam before
        // continuing into the established mixed-language replay.
        .arm9_entry(32'h02000800),.arm7_entry(32'h037f8000),
        .arm9_current_sp(32'h027e392c),.arm9_irq_sp(32'h027e3f78),
        .arm9_saved_sp(32'h027e392c),.arm7_current_sp(32'h0380fd80),
        .arm7_irq_sp(32'h0380ff80),.arm7_saved_sp(32'h0380fd80),
        .initial_cpsr(32'h0000001f),.boot_ready,
        .arm9_cycles,.arm7_cycles,.arm9_cycles_valid,.arm7_cycles_valid,
        .arm9_debug_pc,.arm7_debug_pc,.arm9_dtcm_region,.arm9_dtcm_enable,
        .irq_arm9,.irq_arm7,.halt_arm9,.halt_arm7,
        .ext_addr,.ext_wdata,.ext_debug_pc,.ext_rnw,.ext_ena,
        .ext_cpu_is_arm9,.ext_acc,.ext_rdata,.ext_done);

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN),.SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7RAM),.ORACLE_BASE_WORD(ORACLE),
        .ORACLE_POLL_DELAY_CYCLES(2),
        .TIME_FLUSH_CYCLES(TIME_FLUSH_CYCLES),
        .HALT_POLL_CLOCKS(1000000)
    ) memory(
        .clk,.reset,.transport_reset(reset),
        .request(ext_ena),.cpu_is_arm9(ext_cpu_is_arm9),
        .arm9_cycles,.arm9_cycles_valid,.arm7_cycles,.arm7_cycles_valid,
        .arm9_debug_pc,.arm7_debug_pc,.request_debug_pc(ext_debug_pc),
        .arm9_dtcm_region,.arm9_dtcm_enable,
        .arm9_dtcm_seed_valid(descriptor_valid),
        .arm9_dtcm_irq_vector(32'h01ffa7ec),
        .address(ext_addr),.read_not_write(ext_rnw),.access(ext_acc),
        .write_data(ext_wdata),.read_data(ext_rdata),.done(ext_done),
        .irq_arm9,.irq_arm7,.halt_arm9,.halt_arm7,.cpu_pause,
        .ddram_read,.ddram_write,.ddram_burst_count,.ddram_address,
        .ddram_write_data,.ddram_byte_enable,.ddram_busy,
        .ddram_read_data,.ddram_read_data_ready,
        .ddram_command_accepted);

    function automatic logic [31:0] bios_word(input logic [31:0] a);
        case(a)
            32'hffff0018: bios_word=32'hea0001ae;
            32'hffff06d8: bios_word=32'he92d500f;
            32'hffff06dc: bios_word=32'hee190f11;
            32'hffff06e0: bios_word=32'he3c000ff;
            32'hffff06e4: bios_word=32'he2800901;
            32'hffff06e8: bios_word=32'he1a0e00f;
            32'hffff06ec: bios_word=32'he510f004;
            32'hffff06f0: bios_word=32'he8bd500f;
            32'hffff06f4: bios_word=32'he25ef004;
            default: bios_word=32'he1a00000;
        endcase
    endfunction

    function automatic logic is_gpu(input logic [31:0] a);
        return a==32'h04000290||a==32'h04000294||
               a==32'h04000298||a==32'h0400029c||
               a==32'h04000280||a==32'h040002b8||
               a==32'h040002bc||a==32'h040002b0;
    endfunction

    function automatic logic [63:0] read_ddr(input logic [28:0] a);
        integer n;
        begin
            if(a>=MAIN && a<MAIN+29'h00080000) begin
                n=(a-MAIN)*2;
                read_ddr={main_words[n+1],main_words[n]};
            end else if(a>=SHARED && a<SHARED+29'h00001000) begin
                n=(a-SHARED)*2;
                read_ddr={shared_words[n+1],shared_words[n]};
            end else if(a>=ARM7RAM && a<ARM7RAM+29'h00002000) begin
                n=(a-ARM7RAM)*2;
                read_ddr={arm7_words[n+1],arm7_words[n]};
            end else begin
                read_ddr=64'h0;
            end
        end
    endfunction

    task automatic write_ddr(input logic [28:0] a,input logic [63:0] d,
                             input logic [7:0] be);
        integer n,b;
        begin
            if(a>=MAIN && a<MAIN+29'h00080000) begin
                n=(a-MAIN)*2;
                for(b=0;b<4;b++)
                    if(be[b]) main_words[n][b*8 +: 8]=d[b*8 +: 8];
                for(b=4;b<8;b++)
                    if(be[b]) main_words[n+1][(b-4)*8 +: 8]=d[b*8 +: 8];
            end else if(a>=SHARED && a<SHARED+29'h00001000) begin
                n=(a-SHARED)*2;
                for(b=0;b<4;b++)
                    if(be[b]) shared_words[n][b*8 +: 8]=d[b*8 +: 8];
                for(b=4;b<8;b++)
                    if(be[b]) shared_words[n+1][(b-4)*8 +: 8]=d[b*8 +: 8];
            end else if(a>=ARM7RAM && a<ARM7RAM+29'h00002000) begin
                n=(a-ARM7RAM)*2;
                for(b=0;b<4;b++)
                    if(be[b]) arm7_words[n][b*8 +: 8]=d[b*8 +: 8];
                for(b=4;b<8;b++)
                    if(be[b]) arm7_words[n+1][(b-4)*8 +: 8]=d[b*8 +: 8];
            end
        end
    endtask

    task automatic put_main(input logic [31:0] a,input logic [31:0] d);
        main_words[a[21:2]]=d;
    endtask
    task automatic put_arm7(input logic [31:0] a,input logic [31:0] d);
        arm7_words[a[15:2]]=d;
    endtask
    task automatic put_shared(input logic [31:0] a,input logic [31:0] d);
        shared_words[a[14:2]]=d;
    endtask
    task automatic put_itcm(input logic [31:0] a,input logic [31:0] d);
        memory.router.arm9_itcm.memory0[a[14:2]]=d[7:0];
        memory.router.arm9_itcm.memory1[a[14:2]]=d[15:8];
        memory.router.arm9_itcm.memory2[a[14:2]]=d[23:16];
        memory.router.arm9_itcm.memory3[a[14:2]]=d[31:24];
    endtask
    task automatic put_dtcm(input logic [31:0] a,input logic [31:0] d);
        memory.router.arm9_dtcm.memory0[a[13:2]]=d[7:0];
        memory.router.arm9_dtcm.memory1[a[13:2]]=d[15:8];
        memory.router.arm9_dtcm.memory2[a[13:2]]=d[23:16];
        memory.router.arm9_dtcm.memory3[a[13:2]]=d[31:24];
    endtask
    function automatic logic [31:0] get_dtcm(input logic [31:0] a);
        get_dtcm={
            memory.router.arm9_dtcm.memory3[a[13:2]],
            memory.router.arm9_dtcm.memory2[a[13:2]],
            memory.router.arm9_dtcm.memory1[a[13:2]],
            memory.router.arm9_dtcm.memory0[a[13:2]]
        };
    endfunction

    task automatic service_oracle;
        logic [31:0] a,w,response,flags;
        logic rnw,cpu9;
        begin
            a=oracle_words[1][31:0];
            w=oracle_words[1][63:32];
            rnw=oracle_words[2][0];
            cpu9=oracle_words[2][3];
            response=0;
            flags={31'b0,irq9_pending};
            if(a==32'hffffffff) begin
                timing_transactions++;
            end else begin
                oracle_transactions++;
                if(cpu9 && !rnw && !first_arm9_io_seen) begin
                    first_arm9_io_seen=1;
                    first_arm9_io_address=a;
                    first_arm9_io_data=w;
                end
                if(cpu9 && !rnw && a==32'h04000208 &&
                   w==32'h04000000) begin
                    saw_first_arm9_ime_write=1;
                end else if(!cpu9 && !rnw && a==32'h04000188 &&
                   w==32'h0000006b) begin
                    arm7_sent_6b=1;
                    irq9_pending=1;
                    flags=32'h1;
                end else if(cpu9 && rnw && a==32'h04000184) begin
                    response=fifo_status_reads<2 ? 32'h00008401 :
                                                   32'h00008501;
                    fifo_status_reads++;
                end else if(cpu9 && rnw && a==32'h04100000) begin
                    response=32'h0000006b;
                    arm9_read_6b=1;
                    irq9_pending=0;
                    flags=0;
                end else if(cpu9 && !rnw && a==32'h04000188 &&
                            w==32'h000000ab) begin
                    arm9_sent_ab=1;
                end else if(cpu9 && a==32'h0400101c && rnw) begin
                    response={31'b0,saw_bios_epilogue};
                end else if(cpu9 && is_gpu(a)) begin
                    if(rnw) gpu_reads++; else gpu_writes++;
                end else if(cpu9 && a[31:16]==16'hffff && rnw) begin
                    response=bios_word(a);
                    if(a==32'hffff0018) saw_irq_vector=1;
                    if(a==32'hffff06f0) saw_bios_epilogue=1;
                end
                if(cpu9 && rnw && a>=32'h020689fc &&
                   a<=32'h02068aa4) saw_outer_fifo=1;
            end
            ddram_read_data<={oracle_words[0][63:32],response};
            oracle_words[3]={oracle_words[0][63:32],response};
            oracle_words[4]={32'h0,flags};
        end
    endtask

    always @(posedge clk) begin
        if(arm9_cycles_valid) begin
            arm9_cycle_reports++;
            arm9_cycle_sum+=arm9_cycles;
        end
        if(arm7_cycles_valid) begin
            arm7_cycle_reports++;
            arm7_cycle_sum+=arm7_cycles;
        end
        if(TRACE_RETURN && arm9_read_6b && ext_ena && ext_done &&
           ext_cpu_is_arm9 &&
           arm9_return_trace_count<600) begin
            $display("RETTRACE %0d pc=%h %s addr=%h acc=%0d w=%h r=%h",
                arm9_return_trace_count,ext_debug_pc,
                ext_rnw ? "R" : "W",ext_addr,ext_acc,
                ext_wdata,ext_rdata);
            arm9_return_trace_count++;
        end
        if(ext_ena && ext_done && ext_cpu_is_arm9 &&
           ext_rnw && ext_addr>=32'h020689fc &&
           ext_addr<=32'h02068aa4)
            saw_outer_fifo=1;
        ddram_read_data_ready<=0;
        if(!ddram_read) ddram_read_seen<=0;
        if(ddram_write) begin
            if(ddram_address>=ORACLE && ddram_address<=ORACLE+2)
                oracle_words[ddram_address-ORACLE]=ddram_write_data;
            else
                write_ddr(ddram_address,ddram_write_data,ddram_byte_enable);
        end
        if(second_mailbox_beat) begin
            ddram_read_data_ready<=1;
            ddram_read_data<=oracle_words[4];
            second_mailbox_beat<=0;
        end else if(ddram_read && !ddram_read_seen) begin
            ddram_read_seen<=1;
            ddram_read_data_ready<=1;
            if(ddram_address==ORACLE+3) begin
                service_oracle();
                second_mailbox_beat<=1;
            end else begin
                ddram_read_data<=read_ddr(ddram_address);
            end
        end
    end

    initial begin : preload
        integer i;
        // Let the synthesised ROM/RAM initial blocks settle before replacing
        // their reset vectors with a direct-boot shim for this cosimulation.
        #1ns;
        for(i=0;i<128;i++) main_words[(32'h003e3800>>2)+i]=32'ha5a5a5a5;

        // GHDL-to-Verilator cannot preserve the resolved savestate record
        // used by the normal boot sequencer. Enter both real CPU pipelines
        // through architectural reset code instead: establish IRQ/system
        // stacks, relocate ARM9 DTCM, then jump to the exact replay entries.
        put_itcm(32'h00000000,32'he59f001c);
        put_itcm(32'h00000004,32'hee090f11);
        put_itcm(32'h00000008,32'he321f0d2);
        put_itcm(32'h0000000c,32'he59fd014);
        put_itcm(32'h00000010,32'he321f0df);
        put_itcm(32'h00000014,32'he59fd010);
        put_itcm(32'h00000018,32'he321f01f);
        put_itcm(32'h0000001c,32'he59ff00c);
        put_itcm(32'h00000020,32'he1a00000);
        put_itcm(32'h00000024,32'h027e000a);
        put_itcm(32'h00000028,32'h027e3f78);
        put_itcm(32'h0000002c,32'h027e392c);
        // Enter the exact SDK odd-address halfword copy first. It returns to
        // the existing NSMB reset-prefix replay, so all older production-seam
        // coverage remains intact.
        // Jump target for the ITCM prologue's ldr pc. The seam replay enters
        // the curated SDK copy; natural boot enters the game's real entry.
        put_itcm(32'h00000030, natural_boot ? natural_arm9_entry : 32'h02067000);

        memory.router.arm7_bios.words[0]=32'he321f0d2;
        memory.router.arm7_bios.words[1]=32'he59fd010;
        memory.router.arm7_bios.words[2]=32'he321f0df;
        memory.router.arm7_bios.words[3]=32'he59fd00c;
        memory.router.arm7_bios.words[4]=32'he321f01f;
        memory.router.arm7_bios.words[5]=32'he59ff008;
        memory.router.arm7_bios.words[6]=32'he1a00000;
        memory.router.arm7_bios.words[7]=32'h0380ff80;
        memory.router.arm7_bios.words[8]=32'h0380fd80;
        memory.router.arm7_bios.words[9]=
            natural_boot ? natural_arm7_entry : 32'h037f8000;

        put_shared(32'h037f8000,32'he3a0001f);
        put_shared(32'h037f8004,32'he129f000);
        put_shared(32'h037f8008,32'he3a04080);
        put_shared(32'h037f800c,32'he2544001);
        put_shared(32'h037f8010,32'h1afffffd);
        put_shared(32'h037f8014,32'he59f0008);
        put_shared(32'h037f8018,32'he3a0106b);
        put_shared(32'h037f801c,32'he5801000);
        put_shared(32'h037f8020,32'heafffffe);
        put_shared(32'h037f8024,32'h04000188);

        // These stubs overwrite real program text, so they must not run when
        // a real image is loaded for lockstep.
        if (!natural_boot) begin
        put_main(32'h0207cc60,32'he3a04044);
        put_main(32'h0207cc64,32'he3a05055);
        put_main(32'h0207cc68,32'he3a06066);
        put_main(32'h0207cc6c,32'he3a07077);
        put_main(32'h0207cc70,32'he3a08088);
        put_main(32'h0207cc74,32'he3a09099);
        put_main(32'h0207cc78,32'he3a0a0aa);
        put_main(32'h0207cc7c,32'hea000007);
        put_main(32'h0207cca0,32'he59fc048);
        put_main(32'h0207cca4,32'he58c4000);
        put_main(32'h0207cca8,32'he58c5004);
        put_main(32'h0207ccac,32'he58c6008);
        put_main(32'h0207ccb0,32'he58c700c);
        put_main(32'h0207ccb4,32'he58c8010);
        put_main(32'h0207ccb8,32'he58c9014);
        put_main(32'h0207ccbc,32'he58ca018);
        put_main(32'h0207ccc0,32'he59c001c);
        put_main(32'h0207ccc4,32'he3500000);
        put_main(32'h0207ccc8,32'h0afffff4);
        put_main(32'h0207cccc,32'he3a0000b);
        put_main(32'h0207ccd0,32'he3a01002);
        put_main(32'h0207ccd4,32'he3a02001);
        put_main(32'h0207ccd8,32'he24dd028);
        put_main(32'h0207ccdc,32'hebffaf46);
        put_main(32'h0207cce0,32'he28dd028);
        put_main(32'h0207cce4,32'heafffffe);
        put_main(32'h0207ccf0,32'h04001000);

        // Native NSMB reset prefix:
        //   02000800 e3a0c301  mov r12,#0x04000000
        //   02000804 e58cc208  str r12,[r12,#0x208]
        // Continue into the longer production-seam replay after proving the
        // first I/O write rather than replacing that existing coverage.
        put_main(32'h02000800,32'he3a0c301);
        put_main(32'h02000804,32'he58cc208);
        put_main(32'h02000808,32'hea01f114);

        // Native SDK copy that produces "BUILDTIME" in relocated ARM9 DTCM.
        // This runs the same sequence as tb_nds_arm9_dtcm_buildtime_copy
        // through the complete GHDL CPU, shared dual-CPU bus, SystemVerilog
        // memory system, and production nds_cpu_tcm implementation.
        put_main(32'h02067000,32'he59f0010);
        put_main(32'h02067004,32'he59f1010);
        put_main(32'h02067008,32'he3a02009);
        put_main(32'h0206700c,32'he59fe00c);
        put_main(32'h02067010,32'hea00001b);
        put_main(32'h02067018,32'h02096a89);
        put_main(32'h0206701c,32'h027e37d8);
        put_main(32'h02067020,32'h020697b0);
        put_main(32'h02067084,32'he3520000);
        put_main(32'h02067088,32'h012fff1e);
        put_main(32'h0206708c,32'he3110001);
        put_main(32'h02067090,32'h0a00000b);
        put_main(32'h020670c4,32'he021c000);
        put_main(32'h020670c8,32'he31c0001);
        put_main(32'h020670cc,32'h0a000011);
        put_main(32'h020670d0,32'he3c00001);
        put_main(32'h020670d4,32'he0d0c0b2);
        put_main(32'h020670d8,32'he1a0342c);
        put_main(32'h020670dc,32'he2522002);
        put_main(32'h020670e0,32'h3a000005);
        put_main(32'h020670e4,32'he0d0c0b2);
        put_main(32'h020670e8,32'he183c40c);
        put_main(32'h020670ec,32'he0c1c0b2);
        put_main(32'h020670f0,32'he1a0382c);
        put_main(32'h020670f4,32'he2522002);
        put_main(32'h020670f8,32'h2afffff9);
        put_main(32'h020670fc,32'he3120001);
        put_main(32'h02067100,32'h012fff1e);
        put_main(32'h02067104,32'he1d1c0b0);
        put_main(32'h02067108,32'he20cccff);
        put_main(32'h0206710c,32'he18cc003);
        put_main(32'h02067110,32'he1c1c0b0);
        put_main(32'h02067114,32'he12fff1e);
        put_main(32'h020697b0,32'heafe5c12);
        put_main(32'h02096a88,32'h49554209);
        put_main(32'h02096a8c,32'h4954444c);
        put_main(32'h02096a90,32'h0000454d);

        put_main(32'h020689fc,32'he92d4000);
        put_main(32'h02068a00,32'he24dd004);
        put_main(32'h02068a04,32'he59d3000);
        put_main(32'h02068a08,32'he200001f);
        put_main(32'h02068a0c,32'he3c3301f);
        put_main(32'h02068a10,32'he183c000);
        put_main(32'h02068a14,32'he3cc3020);
        put_main(32'h02068a18,32'he2020001);
        put_main(32'h02068a1c,32'he1833280);
        put_main(32'h02068a20,32'he58dc000);
        put_main(32'h02068a24,32'he203203f);
        put_main(32'h02068a28,32'he3c1033f);
        put_main(32'h02068a2c,32'he1820300);
        put_main(32'h02068a30,32'he58d3000);
        put_main(32'h02068a34,32'he59f206c);
        put_main(32'h02068a38,32'he58d0000);
        put_main(32'h02068a3c,32'he1d200b0);
        put_main(32'h02068a40,32'he2100901);
        put_main(32'h02068a44,32'h11d210b0);
        put_main(32'h02068a48,32'h128dd004);
        put_main(32'h02068a4c,32'h13e00000);
        put_main(32'h02068a50,32'h13811903);
        put_main(32'h02068a54,32'h11c210b0);
        put_main(32'h02068a58,32'h18bd4000);
        put_main(32'h02068a5c,32'h112fff1e);
        put_main(32'h02068a60,32'hebfe46d7);
        put_main(32'h02068a64,32'he59f103c);
        put_main(32'h02068a68,32'he1d110b0);
        put_main(32'h02068a6c,32'he2111002);
        put_main(32'h02068a70,32'h0a000004);
        put_main(32'h02068a74,32'hebfe4711);
        put_main(32'h02068a78,32'he28dd004);
        put_main(32'h02068a7c,32'he3e00001);
        put_main(32'h02068a80,32'he8bd4000);
        put_main(32'h02068a84,32'he12fff1e);
        put_main(32'h02068a88,32'he59d2000);
        put_main(32'h02068a8c,32'he59f1018);
        put_main(32'h02068a90,32'he5812000);
        put_main(32'h02068a94,32'hebfe4709);
        put_main(32'h02068a98,32'he3a00000);
        put_main(32'h02068a9c,32'he28dd004);
        put_main(32'h02068aa0,32'he8bd4000);
        put_main(32'h02068aa4,32'he12fff1e);
        put_main(32'h02068aa8,32'h04000184);
        put_main(32'h02068aac,32'h04000188);

        put_main(32'h02001000,32'he59f0058);
        put_main(32'h02001004,32'he5901000);
        put_main(32'h02001008,32'he5901004);
        put_main(32'h0200100c,32'he5901008);
        put_main(32'h02001010,32'he590100c);
        put_main(32'h02001014,32'he2402010);
        put_main(32'h02001018,32'he5921000);
        put_main(32'h0200101c,32'he5901028);
        put_main(32'h02001020,32'he590102c);
        put_main(32'h02001024,32'he5901020);
        put_main(32'h02001028,32'he3a01000);
        put_main(32'h0200102c,32'he5801000);
        put_main(32'h02001030,32'he5801004);
        put_main(32'h02001034,32'he5801008);
        put_main(32'h02001038,32'he580100c);
        put_main(32'h0200103c,32'he5821000);
        put_main(32'h02001040,32'he5801028);
        put_main(32'h02001044,32'he580102c);
        put_main(32'h02001048,32'he5801020);
        put_main(32'h0200104c,32'he12fff1e);
        put_main(32'h02001060,32'h04000290);
        put_dtcm(32'h027e03c0,32'h02001000);
        end // !natural_boot -- synthetic main-RAM program text ends here

        put_itcm(32'h01ffa7ec,32'he92d47f0);
        put_itcm(32'h01ffa7f0,32'he24dd008);
        put_itcm(32'h01ffa7f4,32'he59fa108);
        put_itcm(32'h01ffa7f8,32'he59f5108);
        put_itcm(32'h01ffa7fc,32'he59f4108);
        put_itcm(32'h01ffa800,32'he3a07641);
        put_itcm(32'h01ffa804,32'he3a06000);
        put_itcm(32'h01ffa808,32'he3e08003);
        put_itcm(32'h01ffa80c,32'he3e09002);
        put_itcm(32'h01ffa810,32'he1da00b0);
        put_itcm(32'h01ffa814,32'he2100901);
        put_itcm(32'h01ffa818,32'h11da00b0);
        put_itcm(32'h01ffa81c,32'h11a01009);
        put_itcm(32'h01ffa820,32'h13800903);
        put_itcm(32'h01ffa824,32'h11ca00b0);
        put_itcm(32'h01ffa828,32'h1a00000a);
        put_itcm(32'h01ffa82c,32'hebffff64);
        put_itcm(32'h01ffa830,32'he1da10b0);
        put_itcm(32'h01ffa834,32'he2111c01);
        put_itcm(32'h01ffa838,32'h0a000002);
        put_itcm(32'h01ffa83c,32'hebffff9f);
        put_itcm(32'h01ffa840,32'he1a01008);
        put_itcm(32'h01ffa844,32'hea000003);
        put_itcm(32'h01ffa848,32'he5971000);
        put_itcm(32'h01ffa84c,32'he58d1000);
        put_itcm(32'h01ffa850,32'hebffff9a);
        put_itcm(32'h01ffa854,32'he1a01006);
        put_itcm(32'h01ffa858,32'he1510008);
        put_itcm(32'h01ffa85c,32'h028dd008);
        put_itcm(32'h01ffa860,32'h08bd47f0);
        put_itcm(32'h01ffa864,32'h012fff1e);
        put_itcm(32'h01ffa868,32'he3e00002);
        put_itcm(32'h01ffa86c,32'he1510000);
        put_itcm(32'h01ffa870,32'h0affffe6);
        put_itcm(32'h01ffa874,32'he59d1000);
        put_itcm(32'h01ffa878,32'he1a00d81);
        put_itcm(32'h01ffa87c,32'he1b00da0);
        put_itcm(32'h01ffa880,32'h0affffe2);
        put_itcm(32'h01ffa884,32'he7953100);
        put_itcm(32'h01ffa888,32'he3530000);
        put_itcm(32'h01ffa88c,32'h0a000004);
        put_itcm(32'h01ffa890,32'he1a02d01);
        put_itcm(32'h01ffa894,32'he1a01321);
        put_itcm(32'h01ffa898,32'he1a02fa2);
        put_itcm(32'h01ffa89c,32'he12fff33);
        put_itcm(32'h01ffa8a0,32'heaffffda);
        put_itcm(32'h01ffa5c4,32'he10f0000);
        put_itcm(32'h01ffa5c8,32'he3801080);
        put_itcm(32'h01ffa5cc,32'he121f001);
        put_itcm(32'h01ffa5d0,32'he2000080);
        put_itcm(32'h01ffa5d4,32'he12fff1e);
        put_itcm(32'h01ffa6c0,32'he10f1000);
        put_itcm(32'h01ffa6c4,32'he3c12080);
        put_itcm(32'h01ffa6c8,32'he1822000);
        put_itcm(32'h01ffa6cc,32'he121f002);
        put_itcm(32'h01ffa6d0,32'he2010080);
        put_itcm(32'h01ffa6d4,32'he12fff1e);
        put_itcm(32'h01ffa904,32'h04000184);
        put_itcm(32'h01ffa908,32'h027e0394);
        put_itcm(32'h01ffa90c,32'h04000188);
    end

    initial begin
        repeat(4) @(posedge clk);
        reset=0;
        descriptor_valid=1;
        fork
            begin wait(arm9_sent_ab); end
            begin
                #1ms;
                $display("TIMEOUT mixed replay boot=%0d 6Bsend=%0d 6Bread=%0d irq=%0d gpu=%0d/%0d bios=%0d outer=%0d AB=%0d oracle=%0d timing=%0d pc9=%h pc7=%h cyc9=%0d/%0d last=%0d/%0d cyc7=%0d/%0d",
                    boot_ready,
                    arm7_sent_6b,arm9_read_6b,saw_irq_vector,
                    gpu_reads,gpu_writes,saw_bios_epilogue,
                    saw_outer_fifo,arm9_sent_ab,oracle_transactions,
                    timing_transactions,arm9_debug_pc,arm7_debug_pc,
                    arm9_cycle_sum,arm9_cycle_reports,
                    arm9_cycles,arm9_cycles_valid,
                    arm7_cycle_sum,arm7_cycle_reports);
                $fatal(1,"mixed CPU/memory replay timed out");
            end
        join_any
        disable fork;
        $display("mixed replay 6Bsend=%0d 6Bread=%0d irq=%0d gpu=%0d/%0d bios=%0d outer=%0d AB=%0d oracle=%0d timing=%0d pc9=%h",
            arm7_sent_6b,arm9_read_6b,saw_irq_vector,gpu_reads,gpu_writes,
            saw_bios_epilogue,saw_outer_fifo,arm9_sent_ab,
            oracle_transactions,timing_transactions,arm9_debug_pc);
        if(!saw_first_arm9_ime_write)
            $fatal(1,
                "first NSMB ARM9 IME write mismatch: first ARM9 write %h=%h",
                first_arm9_io_address,first_arm9_io_data);
        if(!arm7_sent_6b||!arm9_read_6b||!saw_irq_vector)
            $fatal(1,"mixed replay did not reach command IRQ");
        if(gpu_reads!=8||gpu_writes!=8||!saw_bios_epilogue)
            $fatal(1,"mixed replay handler/GPU/BIOS mismatch");
        if(!saw_outer_fifo||!arm9_sent_ab)
            $fatal(1,"mixed replay failed post-BIOS 0xAB continuation");
        if(get_dtcm(32'h027e37d8)!==32'h4c495542 ||
           get_dtcm(32'h027e37dc)!==32'h4d495444 ||
           (get_dtcm(32'h027e37e0) & 32'h0000ffff)!==32'h00000045)
            $fatal(1,
                "production BUILDTIME DTCM copy corrupt: %h %h %h",
                get_dtcm(32'h027e37d8),
                get_dtcm(32'h027e37dc),
                get_dtcm(32'h027e37e0));
        $display("PASS: GHDL-to-Verilator dual CPUs cross the production memory/mailbox seam");
        $finish;
    end
endmodule
