module tb_nds_arm9_repeated_context_full_memory_cosim #(
    parameter integer ITERATIONS = 8,
    parameter integer TIME_FLUSH_CYCLES = 8,
    parameter integer DDR_BUSY_CYCLES = 3,
    parameter integer DDR_READ_LATENCY_CYCLES = 4,
    parameter bit TRACE_CONTEXT = 0
);
    timeunit 1ns;
    timeprecision 1ns;

    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7RAM = 29'h001a0000;
    localparam logic [28:0] ORACLE = 29'h00200000;
    localparam logic [31:0] CONTEXT = 32'h02001000;
    localparam logic [28:0] CONTEXT_SP_DDR = 29'h00100207;

    logic clk = 0;
    logic reset = 1;
    logic descriptor_valid = 1;
    always #5 clk = ~clk;

    logic boot_ready;
    logic global_step_enable;
    logic [7:0] arm9_cycles, arm7_cycles;
    logic arm9_cycles_valid, arm7_cycles_valid;
    logic [31:0] arm9_debug_pc, arm7_debug_pc, arm9_diag_word;
    logic [31:0] arm9_dtcm_region;
    logic arm9_dtcm_enable;
    logic [31:0] ext_addr, ext_wdata, ext_debug_pc, ext_rdata;
    logic ext_rnw, ext_ena, ext_cpu_is_arm9, ext_done;
    logic [1:0] ext_acc;
    logic irq_arm9, irq_arm7, halt_arm9, halt_arm7, cpu_pause;

    logic ddram_read, ddram_write;
    logic [7:0] ddram_burst_count, ddram_byte_enable;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data, ddram_read_data = 0;
    logic ddram_busy, ddram_read_data_ready = 0;
    logic ddram_command_accepted;
    integer ddram_busy_count = 0;
    integer ddram_response_delay = 0;
    integer ddram_response_beats = 0;
    logic [63:0] ddram_response_first = 0;
    logic [63:0] ddram_response_second = 0;

    logic [31:0] main_words [0:1048575];
    logic [31:0] shared_words [0:8191];
    logic [31:0] arm7_words [0:16383];
    logic [63:0] oracle_words [0:4];

    logic irq9_pending = 0;
    integer body_count = 0;
    integer vector_count = 0;
    integer context_sp_count = 0;
    integer return_word0_count = 0;
    integer return_word1_count = 0;
    integer irq_tail_write_count = 0;
    integer irq_tail_pc_read_count = 0;
    integer sp_marker_count = 0;
    integer timing_transactions = 0;
    integer oracle_transactions = 0;
    integer pause_entries = 0;
    integer return_phase = 0;
    integer prologue_phase = 0;
    integer irq_tail_phase = 0;
    logic prior_cpu_pause = 0;

    logic held_pause_request = 0;
    logic [31:0] held_pause_address = 0;
    logic [31:0] held_pause_write_data = 0;
    logic [31:0] held_pause_debug_pc = 0;
    logic held_pause_rnw = 0;
    logic held_pause_cpu = 0;
    logic [1:0] held_pause_access = 0;

    wire [31:0] execute_pc = ext_debug_pc ^ 32'h40000000;
    wire [63:0] current_ddr_read_data = read_ddr(ddram_address);
    // These are simulation-only observations of the reused CPU's explicit
    // execute-bus channel. They distinguish the block-load source from a
    // speculative fetch carrying the same execute-PC tag.
    wire arm9_execute_bus = cpus.cpus.cpu9.executebus;
    wire [31:0] arm9_execute_address = cpus.cpus.cpu9.bus_execute_adr;
    wire [2:0] arm9_block_stage = cpus.cpus.cpu9.block_rw_stage;
    // GHDL flattens regs(0..17) in descending packed-vector order.
    wire [31:0] arm9_r11 = cpus.cpus.cpu9.regs[223:192];
    wire [31:0] arm9_r13 = cpus.cpus.cpu9.regs[159:128];
    wire [31:0] arm9_pipeline_pc = cpus.cpus.cpu9.execute_pc;
    wire [31:0] arm9_previous_pc = cpus.cpus.cpu9.execute_pcprev;
    wire arm9_execute_start = cpus.cpus.cpu9.execute_start;
    wire arm9_calc_done = cpus.cpus.cpu9.calc_done;
    wire arm9_do_step = cpus.cpus.arm9_step_enable;
    assign global_step_enable = !cpu_pause;
    assign ddram_busy = ddram_busy_count != 0;
    assign ddram_command_accepted =
        (ddram_read || ddram_write) && !ddram_busy;

    nds_dual_cpu_cosim_top cpus (
        .clk, .reset, .descriptor_valid, .global_step_enable,
        .arm9_entry(32'h0), .arm7_entry(32'h0),
        .arm9_current_sp(32'h027e3fc0),
        .arm9_irq_sp(32'h027e3fbc),
        .arm9_saved_sp(32'h027e392c),
        .arm7_current_sp(32'h0380fd80),
        .arm7_irq_sp(32'h0380ff80),
        .arm7_saved_sp(32'h0380fd80),
        .initial_cpsr(32'h000000d3), .boot_ready,
        .arm9_cycles, .arm7_cycles,
        .arm9_cycles_valid, .arm7_cycles_valid,
        .arm9_debug_pc, .arm7_debug_pc, .arm9_diag_word,
        .arm9_dtcm_region, .arm9_dtcm_enable,
        .irq_arm9, .irq_arm7,
        .halt_arm9, .halt_arm7,
        .ext_addr, .ext_wdata, .ext_debug_pc,
        .ext_rnw, .ext_ena, .ext_cpu_is_arm9, .ext_acc,
        .ext_rdata, .ext_done
    );

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7RAM),
        .ORACLE_BASE_WORD(ORACLE),
        .ORACLE_POLL_DELAY_CYCLES(2),
        .TIME_FLUSH_CYCLES(TIME_FLUSH_CYCLES),
        .HALT_POLL_CLOCKS(1000000)
    ) memory (
        .clk, .reset, .transport_reset(reset), .request(ext_ena),
        .cpu_is_arm9(ext_cpu_is_arm9),
        .arm9_cycles, .arm9_cycles_valid,
        .arm7_cycles, .arm7_cycles_valid,
        .arm9_debug_pc, .arm7_debug_pc,
        .request_debug_pc(ext_debug_pc),
        .arm9_dtcm_region, .arm9_dtcm_enable,
        .arm9_dtcm_seed_valid(descriptor_valid),
        .arm9_dtcm_irq_vector(32'h00000500),
        .address(ext_addr), .read_not_write(ext_rnw),
        .access(ext_acc), .write_data(ext_wdata),
        .read_data(ext_rdata), .done(ext_done),
        .irq_arm9, .irq_arm7, .halt_arm9, .halt_arm7, .cpu_pause,
        .debug_oracle_request(),
        .debug_mailbox_request(),
        .debug_mailbox_done(),
        .ddram_read, .ddram_write, .ddram_burst_count, .ddram_address,
        .ddram_write_data, .ddram_byte_enable, .ddram_busy,
        .ddram_read_data, .ddram_read_data_ready,
        .ddram_command_accepted
    );

    function automatic logic [31:0] oracle_word(input logic [31:0] address);
        case (address)
            32'hffff0018: oracle_word = 32'hea0001ae;
            32'hffff06d8: oracle_word = 32'he92d500f;
            32'hffff06dc: oracle_word = 32'hee190f11;
            32'hffff06e0: oracle_word = 32'he3c000ff;
            32'hffff06e4: oracle_word = 32'he2800901;
            32'hffff06e8: oracle_word = 32'he1a0e00f;
            32'hffff06ec: oracle_word = 32'he510f004;
            32'hffff06f0: oracle_word = 32'he8bd500f;
            32'hffff06f4: oracle_word = 32'he25ef004;
            default: oracle_word = 32'he1a00000;
        endcase
    endfunction

    function automatic logic [63:0] read_ddr(input logic [28:0] address);
        integer word_index;
        begin
            if (address >= MAIN && address < MAIN + 29'h00080000) begin
                word_index = (address - MAIN) * 2;
                read_ddr = {
                    main_words[word_index + 1],
                    main_words[word_index]
                };
            end else if (address >= SHARED &&
                         address < SHARED + 29'h00001000) begin
                word_index = (address - SHARED) * 2;
                read_ddr = {
                    shared_words[word_index + 1],
                    shared_words[word_index]
                };
            end else if (address >= ARM7RAM &&
                         address < ARM7RAM + 29'h00002000) begin
                word_index = (address - ARM7RAM) * 2;
                read_ddr = {
                    arm7_words[word_index + 1],
                    arm7_words[word_index]
                };
            end else begin
                read_ddr = 64'h0;
            end
        end
    endfunction

    task automatic write_ddr(
        input logic [28:0] address,
        input logic [63:0] data,
        input logic [7:0] byte_enable
    );
        integer word_index;
        integer lane;
        begin
            if (address >= ORACLE && address <= ORACLE + 4) begin
                for (lane = 0; lane < 8; lane++)
                    if (byte_enable[lane])
                        oracle_words[address - ORACLE][lane * 8 +: 8] =
                            data[lane * 8 +: 8];
            end else if (address >= MAIN &&
                         address < MAIN + 29'h00080000) begin
                word_index = (address - MAIN) * 2;
                for (lane = 0; lane < 4; lane++)
                    if (byte_enable[lane])
                        main_words[word_index][lane * 8 +: 8] =
                            data[lane * 8 +: 8];
                for (lane = 4; lane < 8; lane++)
                    if (byte_enable[lane])
                        main_words[word_index + 1][(lane - 4) * 8 +: 8] =
                            data[lane * 8 +: 8];
            end else if (address >= SHARED &&
                         address < SHARED + 29'h00001000) begin
                word_index = (address - SHARED) * 2;
                for (lane = 0; lane < 4; lane++)
                    if (byte_enable[lane])
                        shared_words[word_index][lane * 8 +: 8] =
                            data[lane * 8 +: 8];
                for (lane = 4; lane < 8; lane++)
                    if (byte_enable[lane])
                        shared_words[word_index + 1][(lane - 4) * 8 +: 8] =
                            data[lane * 8 +: 8];
            end else if (address >= ARM7RAM &&
                         address < ARM7RAM + 29'h00002000) begin
                word_index = (address - ARM7RAM) * 2;
                for (lane = 0; lane < 4; lane++)
                    if (byte_enable[lane])
                        arm7_words[word_index][lane * 8 +: 8] =
                            data[lane * 8 +: 8];
                for (lane = 4; lane < 8; lane++)
                    if (byte_enable[lane])
                        arm7_words[word_index + 1][(lane - 4) * 8 +: 8] =
                            data[lane * 8 +: 8];
            end
        end
    endtask

    task automatic put_itcm(
        input logic [31:0] address,
        input logic [31:0] data
    );
        memory.router.arm9_itcm.memory0[address[14:2]] = data[7:0];
        memory.router.arm9_itcm.memory1[address[14:2]] = data[15:8];
        memory.router.arm9_itcm.memory2[address[14:2]] = data[23:16];
        memory.router.arm9_itcm.memory3[address[14:2]] = data[31:24];
    endtask

    task automatic put_dtcm(
        input logic [31:0] address,
        input logic [31:0] data
    );
        memory.router.arm9_dtcm.memory0[address[13:2]] = data[7:0];
        memory.router.arm9_dtcm.memory1[address[13:2]] = data[15:8];
        memory.router.arm9_dtcm.memory2[address[13:2]] = data[23:16];
        memory.router.arm9_dtcm.memory3[address[13:2]] = data[31:24];
    endtask

    task automatic put_main(
        input logic [31:0] address,
        input logic [31:0] data
    );
        main_words[address[21:2]] = data;
    endtask

    always @(posedge clk) begin
        ddram_read_data_ready <= 0;

        if (ddram_busy_count != 0)
            ddram_busy_count <= ddram_busy_count - 1;

        if (ddram_response_beats != 0) begin
            if (ddram_response_delay != 0) begin
                ddram_response_delay <= ddram_response_delay - 1;
            end else begin
                ddram_read_data_ready <= 1;
                ddram_read_data <= ddram_response_beats == 2
                    ? ddram_response_first : ddram_response_second;
                ddram_response_beats <= ddram_response_beats - 1;
            end
        end

        if ((ddram_read || ddram_write) && !ddram_busy) begin
            ddram_busy_count <= DDR_BUSY_CYCLES;
            if (ddram_write) begin
                write_ddr(ddram_address, ddram_write_data,
                          ddram_byte_enable);
            end else begin
                if (ddram_response_beats != 0)
                    $fatal(1,
                        "overlapping DDR read addr=%h pending_beats=%0d",
                        ddram_address, ddram_response_beats);
                ddram_response_delay <= DDR_READ_LATENCY_CYCLES;
                if (ddram_address == ORACLE + 3 &&
                    ddram_burst_count == 2) begin
                    ddram_response_first <= {
                        oracle_words[0][63:32],
                        oracle_word(oracle_words[1][31:0])
                    };
                    ddram_response_second <= {
                        60'h0, 3'b000, irq9_pending
                    };
                    ddram_response_beats <= 2;
                    if (oracle_words[1][31:0] == 32'hffffffff)
                        timing_transactions <= timing_transactions + 1;
                    else
                        oracle_transactions <= oracle_transactions + 1;
                end else begin
                    // A single-beat response reaches the common delivery
                    // path with response_beats==1, which selects the final
                    // response slot. Keep burst beat zero and the standalone
                    // local read in their unambiguous slots.
                    ddram_response_first <= 0;
                    ddram_response_second <=
                        read_ddr(ddram_address);
                    ddram_response_beats <= 1;
                    if (ddram_address == CONTEXT_SP_DDR &&
                        memory.router.main_ram.latched_offset == 3'd0) begin
                        context_sp_count <= context_sp_count + 1;
                        if (current_ddr_read_data[31:0] !=
                            32'h027e3914)
                            $fatal(1,
                                "context R13 source corrupt addr=%h data=%h",
                                ddram_address, read_ddr(ddram_address));
                    end
                end
            end
        end

        if (cpu_pause && !prior_cpu_pause)
            pause_entries <= pause_entries + 1;
        if (TRACE_CONTEXT && cpu_pause && !prior_cpu_pause)
            $display(
                "PAUSE t=%0t live=%h prev=%h r11=%h r13=%h start=%0d done=%0d execbus=%0d block=%0d ext=%h",
                $time, arm9_pipeline_pc, arm9_previous_pc,
                arm9_r11, arm9_r13, arm9_execute_start, arm9_calc_done,
                arm9_execute_bus, arm9_block_stage, ext_addr
            );
        if (TRACE_CONTEXT && arm9_cycles_valid &&
            arm9_previous_pc >= 32'h01ffd22c &&
            arm9_previous_pc <= 32'h01ffd280)
            $display(
                "RETIRE t=%0t pc=%h live=%h r11=%h r13=%h pause=%0d step=%0d start=%0d done=%0d",
                $time, arm9_previous_pc, arm9_pipeline_pc,
                arm9_r11, arm9_r13, cpu_pause, arm9_do_step,
                arm9_execute_start, arm9_calc_done
            );
        prior_cpu_pause <= cpu_pause;
        if (cpu_pause && global_step_enable)
            $fatal(1, "global_step_enable remained high during cpu_pause");

        // A paused live bus request must remain stable until its completion.
        // This covers both an oracle pause and a timing flush that temporarily
        // owns DDR while a successor request is already queued.
        if (cpu_pause && ext_ena && !ext_done) begin
            if (!held_pause_request) begin
                held_pause_request <= 1;
                held_pause_address <= ext_addr;
                held_pause_write_data <= ext_wdata;
                held_pause_debug_pc <= ext_debug_pc;
                held_pause_rnw <= ext_rnw;
                held_pause_cpu <= ext_cpu_is_arm9;
                held_pause_access <= ext_acc;
            end else if (ext_addr != held_pause_address ||
                         ext_wdata != held_pause_write_data ||
                         ext_debug_pc != held_pause_debug_pc ||
                         ext_rnw != held_pause_rnw ||
                         ext_cpu_is_arm9 != held_pause_cpu ||
                         ext_acc != held_pause_access) begin
                $fatal(1,
                    "paused request changed pc=%h->%h addr=%h->%h",
                    held_pause_debug_pc, ext_debug_pc,
                    held_pause_address, ext_addr);
            end
        end else begin
            held_pause_request <= 0;
        end

        if (ext_ena && ext_done && ext_cpu_is_arm9) begin
            if (ext_rnw && ext_addr == 32'h01ffd238)
                body_count <= body_count + 1;
            if (ext_rnw && ext_addr == 32'hffff0018)
                vector_count <= vector_count + 1;

            if (execute_pc == 32'h01ffd22c && !ext_rnw) begin
                if (prologue_phase[0] == 0) begin
                    if (ext_addr != 32'h027e3924 ||
                        ext_wdata != 32'h00000000)
                        $fatal(1,
                            "prologue R11 push diverged phase=%0d addr=%h data=%h",
                            prologue_phase, ext_addr, ext_wdata);
                end else begin
                    if (ext_addr != 32'h027e3928 ||
                        ext_wdata != 32'h00000200)
                        $fatal(1,
                            "prologue LR push diverged phase=%0d addr=%h data=%h",
                            prologue_phase, ext_addr, ext_wdata);
                end
                prologue_phase <= prologue_phase + 1;
            end

            if (execute_pc == 32'h00000530 && !ext_rnw) begin
                if (ext_addr != 32'h027e3f64 +
                                4 * (irq_tail_phase % 6))
                    $fatal(1,
                        "IRQ tail STMDA order diverged phase=%0d addr=%h expected=%h",
                        irq_tail_phase, ext_addr,
                        32'h027e3f64 + 4 * (irq_tail_phase % 6));
                irq_tail_phase <= irq_tail_phase + 1;
                irq_tail_write_count <= irq_tail_write_count + 1;
            end
            if (execute_pc == 32'h00000534 && ext_rnw &&
                ext_addr >= 32'h027e3f00 &&
                ext_addr < 32'h027e4000) begin
                if (ext_addr != 32'h027e3f60 ||
                    ext_rdata != 32'h00000560)
                    $fatal(1,
                        "IRQ tail PC pop diverged addr=%h data=%h",
                        ext_addr, ext_rdata);
                irq_tail_pc_read_count <= irq_tail_pc_read_count + 1;
            end

            // Instruction prefetches carry the same execute-PC tag. The
            // block-load data source is in the 0x02+ data aperture; an r181
            // style runaway source (for example 0xa0053004) is therefore
            // still diagnosed rather than filtered out.
            if (execute_pc == 32'h01ffd280 && ext_rnw &&
                arm9_execute_bus &&
                arm9_execute_address == ext_addr) begin
                if (return_phase[0] == 0) begin
                    if (ext_addr != 32'h027e3924 ||
                        ext_rdata != 32'h00000000)
                        $fatal(1,
                            "first return source diverged phase=%0d addr=%h data=%h r11=%h r13=%h block=%0d",
                            return_phase, ext_addr, ext_rdata,
                            arm9_r11, arm9_r13, arm9_block_stage);
                    return_word0_count <= return_word0_count + 1;
                end else begin
                    if (ext_addr != 32'h027e3928 ||
                        ext_rdata != 32'h00000200)
                        $fatal(1,
                            "R15 return source diverged phase=%0d addr=%h data=%h r11=%h r13=%h block=%0d",
                            return_phase, ext_addr, ext_rdata,
                            arm9_r11, arm9_r13, arm9_block_stage);
                    return_word1_count <= return_word1_count + 1;
                end
                return_phase <= return_phase + 1;
            end

            if (!ext_rnw && ext_addr == 32'h04000300) begin
                sp_marker_count <= sp_marker_count + 1;
                if (ext_wdata != 32'h027e392c)
                    $fatal(1, "post-return System SP corrupt: %h",
                           ext_wdata);
            end
        end
    end

    initial begin : preload
        #1ns;

        put_itcm(32'h00000000, 32'he59f0024);
        put_itcm(32'h00000004, 32'hee090f11);
        put_itcm(32'h00000008, 32'he321f0d2);
        put_itcm(32'h0000000c, 32'he59fd01c);
        put_itcm(32'h00000010, 32'he321f0df);
        put_itcm(32'h00000014, 32'he59fd018);
        put_itcm(32'h00000018, 32'he321f01f);
        put_itcm(32'h0000001c, 32'he59fe014);
        put_itcm(32'h00000020, 32'he59ff014);
        put_itcm(32'h00000024, 32'he1a00000);
        put_itcm(32'h00000028, 32'he1a00000);
        put_itcm(32'h0000002c, 32'h027e000a);
        put_itcm(32'h00000030, 32'h027e3fbc);
        put_itcm(32'h00000034, 32'h027e392c);
        put_itcm(32'h00000038, 32'h00000200);
        put_itcm(32'h0000003c, 32'h01ffd22c);

        put_itcm(32'h00000200, 32'he1a0000d);
        put_itcm(32'h00000204, 32'he59f2018);
        put_itcm(32'h00000208, 32'he5820000);
        put_itcm(32'h0000020c, 32'he59fe008);
        put_itcm(32'h00000210, 32'he59ff008);
        put_itcm(32'h0000021c, 32'h00000200);
        put_itcm(32'h00000220, 32'h01ffd22c);
        put_itcm(32'h00000224, 32'h04000300);

        put_itcm(32'h01ffd22c, 32'he92d4800);
        put_itcm(32'h01ffd230, 32'he24dd010);
        put_itcm(32'h01ffd234, 32'he1a0b00d);
        for (int address = 'h1ffd238; address <= 'h1ffd278;
             address += 4)
            put_itcm(address, 32'he1a00000);
        // Issue one harmless oracle read immediately after the observed body
        // point. The test raises the mailbox IRQ flag when the 0x01ffd238
        // fetch completes, so every flush cadence delivers the interrupt
        // while this exact SDK frame is live rather than after its epilogue.
        put_itcm(32'h01ffd238, 32'he59f0044);
        put_itcm(32'h01ffd23c, 32'he5900000);
        put_itcm(32'h01ffd27c, 32'he28bd010);
        put_itcm(32'h01ffd280, 32'he8bd8800);
        put_itcm(32'h01ffd284, 32'h04000304);

        put_itcm(32'h00000500, 32'he59f1054);
        put_itcm(32'h00000504, 32'he24dd02c);
        put_itcm(32'h00000508, 32'he3a030d3);
        put_itcm(32'h0000050c, 32'he121f003);
        put_itcm(32'h00000510, 32'he591d044);
        put_itcm(32'h00000514, 32'he3a030d2);
        put_itcm(32'h00000518, 32'he121f003);
        put_itcm(32'h0000051c, 32'he5b12000);
        put_itcm(32'h00000520, 32'he169f002);
        put_itcm(32'h00000524, 32'he591e040);
        put_itcm(32'h00000528, 32'he9f17fff);
        put_itcm(32'h0000052c, 32'he1a00000);
        put_itcm(32'h00000530, 32'he82d500f);
        put_itcm(32'h00000534, 32'he8bd8000);
        put_itcm(32'h0000055c, CONTEXT);
        put_itcm(32'h00000560, 32'he28dd040);
        put_itcm(32'h00000564, 32'he59fe008);
        put_itcm(32'h00000568, 32'he12fff1e);
        put_itcm(32'h00000574, 32'hffff06f0);

        put_dtcm(32'h027e3f60, 32'h00000560);
        put_dtcm(32'h027e3ffc, 32'h00000500);
        put_dtcm(32'h027e3930, 32'hdeaddead);

        put_main(CONTEXT + 32'h00, 32'h2000001f);
        put_main(CONTEXT + 32'h04, 32'h11110000);
        put_main(CONTEXT + 32'h08, 32'h11110001);
        put_main(CONTEXT + 32'h0c, 32'h11110002);
        put_main(CONTEXT + 32'h10, 32'h11110003);
        put_main(CONTEXT + 32'h14, 32'h11110004);
        put_main(CONTEXT + 32'h18, 32'h11110005);
        put_main(CONTEXT + 32'h1c, 32'h11110006);
        put_main(CONTEXT + 32'h20, 32'h11110007);
        put_main(CONTEXT + 32'h24, 32'h11110008);
        put_main(CONTEXT + 32'h28, 32'h11110009);
        put_main(CONTEXT + 32'h2c, 32'h1111000a);
        put_main(CONTEXT + 32'h30, 32'h027e3914);
        put_main(CONTEXT + 32'h34, 32'h1111000c);
        put_main(CONTEXT + 32'h38, 32'h027e3914);
        put_main(CONTEXT + 32'h3c, 32'h00000200);
        put_main(CONTEXT + 32'h40, 32'h01ff8224);
        put_main(CONTEXT + 32'h44, 32'h027e0830);

        memory.router.arm7_bios.words[0] = 32'heafffffe;
    end

    initial begin : exercise
        integer iteration;
        integer vector_baseline;
        integer tail_baseline;
        integer return_baseline;

        repeat (4) @(posedge clk);
        reset = 0;
        wait (boot_ready);

        for (iteration = 1; iteration <= ITERATIONS; iteration++) begin
            fork
                begin
                    wait (body_count >= iteration);
                end
                begin
                    #5ms;
                    $fatal(1,
                        "body timeout iteration=%0d pc=%h addr=%h pause=%0d",
                        iteration, execute_pc, ext_addr, cpu_pause);
                end
            join_any
            disable fork;

            vector_baseline = vector_count;
            tail_baseline = irq_tail_pc_read_count;
            return_baseline = return_word1_count;
            irq9_pending = 1;

            fork
                begin
                    wait (vector_count > vector_baseline);
                end
                begin
                    #5ms;
                    $fatal(1,
                        "IRQ delivery timeout iteration=%0d pc=%h timing=%0d oracle=%0d",
                        iteration, execute_pc,
                        timing_transactions, oracle_transactions);
                end
            join_any
            disable fork;
            if (return_word1_count != return_baseline)
                $fatal(1,
                    "mailbox IRQ arrived after System epilogue iteration=%0d baseline=%0d now=%0d",
                    iteration, return_baseline, return_word1_count);
            irq9_pending = 0;

            fork
                begin
                    wait (irq_tail_pc_read_count > tail_baseline);
                    wait (return_word1_count > return_baseline);
                    wait (!irq_arm9);
                end
                begin
                    #5ms;
                    $fatal(1,
                        "context return timeout iteration=%0d pc=%h addr=%h irq=%0d tail=%0d return=%0d",
                        iteration, execute_pc, ext_addr, irq_arm9,
                        irq_tail_pc_read_count, return_word1_count);
                end
            join_any
            disable fork;
        end

        if (prologue_phase < 2 * ITERATIONS ||
            return_word0_count < ITERATIONS ||
            return_word1_count < ITERATIONS)
            $fatal(1,
                "insufficient System stack traffic push=%0d return=%0d/%0d",
                prologue_phase, return_word0_count, return_word1_count);
        if (context_sp_count < ITERATIONS)
            $fatal(1, "context R13 DDR reads=%0d expected>=%0d",
                   context_sp_count, ITERATIONS);
        if (irq_tail_write_count != 6 * irq_tail_pc_read_count ||
            irq_tail_pc_read_count < ITERATIONS)
            $fatal(1, "IRQ tail writes=%0d PC reads=%0d",
                   irq_tail_write_count, irq_tail_pc_read_count);
        if (sp_marker_count == 0)
            $fatal(1, "post-return SP marker was never published");
        if (pause_entries == 0 || oracle_transactions == 0)
            $fatal(1, "production pause/mailbox seam was not exercised");

        $display(
            "PASS: full memory/mailbox pause seam preserves repeated ARM9 SDK context (iterations=%0d flush=%0d busy=%0d latency=%0d pauses=%0d timing=%0d oracle=%0d)",
            ITERATIONS, TIME_FLUSH_CYCLES, DDR_BUSY_CYCLES,
            DDR_READ_LATENCY_CYCLES, pause_entries,
            timing_transactions, oracle_transactions
        );
        $finish;
    end
endmodule
