module tb_nds_arm9_stack_return_memory_cosim;
    timeunit 1ns;
    timeprecision 1ns;

    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7RAM = 29'h001a0000;
    localparam logic [31:0] EXPECTED_PC = 32'h0204d4c8;
    localparam logic [31:0] RETURN_PC = 32'h01ffd280;
    localparam logic [31:0] STALE_WRITE_DATA = 32'he5823004;

    logic clk = 0;
    logic reset = 1;
    logic descriptor_valid = 1;
    always #5 clk = ~clk;

    logic boot_ready;
    logic [7:0] arm9_cycles, arm7_cycles;
    logic arm9_cycles_valid, arm7_cycles_valid;
    logic [31:0] arm9_debug_pc, arm7_debug_pc, arm9_diag_word;
    logic [31:0] arm9_dtcm_region;
    logic arm9_dtcm_enable;
    logic [31:0] ext_addr, ext_wdata, ext_debug_pc, ext_rdata;
    logic ext_rnw, ext_ena, ext_cpu_is_arm9, ext_done;
    logic [1:0] ext_acc;

    logic oracle_request, oracle_rnw, oracle_done = 0;
    logic [1:0] oracle_acc;
    logic [31:0] oracle_address, oracle_wdata;
    logic oracle_pending = 0;
    logic [31:0] oracle_rdata = 0;

    logic ddram_read, ddram_write;
    logic [7:0] ddram_burst_count, ddram_byte_enable;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data, ddram_read_data = 0;
    logic ddram_busy = 0, ddram_read_data_ready = 0;
    logic ddram_read_seen = 0;

    logic [31:0] main_words [0:1048575];
    logic saw_stale_write = 0;
    logic saw_stack_word0 = 0;
    logic saw_stack_word1 = 0;
    logic saw_target_fetch = 0;
    logic saw_stale_target_fetch = 0;
    logic saw_live_telemetry = 0;
    logic [31:0] stack_word0_data = 0;
    logic [31:0] stack_word1_data = 0;

    nds_dual_cpu_cosim_top cpus (
        .clk, .reset, .descriptor_valid, .global_step_enable(1'b1),
        .arm9_entry(32'h0), .arm7_entry(32'h0),
        .arm9_current_sp(32'h027e3924),
        .arm9_irq_sp(32'h027e3f78),
        .arm9_saved_sp(32'h027e3924),
        .arm7_current_sp(32'h0380fd80),
        .arm7_irq_sp(32'h0380ff80),
        .arm7_saved_sp(32'h0380fd80),
        .initial_cpsr(32'h0000001f), .boot_ready,
        .arm9_cycles, .arm7_cycles,
        .arm9_cycles_valid, .arm7_cycles_valid,
        .arm9_debug_pc, .arm7_debug_pc, .arm9_diag_word,
        .arm9_dtcm_region, .arm9_dtcm_enable,
        .irq_arm9(1'b0), .irq_arm7(1'b0),
        .halt_arm9(1'b0), .halt_arm7(1'b0),
        .ext_addr, .ext_wdata, .ext_debug_pc,
        .ext_rnw, .ext_ena, .ext_cpu_is_arm9, .ext_acc,
        .ext_rdata, .ext_done
    );

    nds_cpu_memory_router #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7RAM)
    ) router (
        .clk, .reset, .request(ext_ena), .cpu_is_arm9(ext_cpu_is_arm9),
        .wramcnt(2'd0), .arm9_dtcm_region, .arm9_dtcm_enable,
        .arm9_dtcm_seed_valid(1'b0), .arm9_dtcm_irq_vector(32'd0),
        .address(ext_addr), .read_not_write(ext_rnw), .access(ext_acc),
        .write_data(ext_wdata), .read_data(ext_rdata), .done(ext_done),
        .oracle_request, .oracle_address,
        .oracle_read_not_write(oracle_rnw), .oracle_access(oracle_acc),
        .oracle_write_data(oracle_wdata), .oracle_read_data(oracle_rdata),
        .oracle_done,
        .ddram_read, .ddram_write, .ddram_burst_count, .ddram_address,
        .ddram_write_data, .ddram_byte_enable, .ddram_busy,
        .ddram_read_data, .ddram_read_data_ready
    );

    function automatic logic [63:0] read_main(input logic [28:0] address);
        integer word_index;
        begin
            word_index = (address - MAIN) * 2;
            read_main = {
                main_words[word_index + 1],
                main_words[word_index]
            };
        end
    endfunction

    task automatic put_itcm(
        input logic [31:0] address,
        input logic [31:0] data
    );
        router.arm9_itcm.memory0[address[14:2]] = data[7:0];
        router.arm9_itcm.memory1[address[14:2]] = data[15:8];
        router.arm9_itcm.memory2[address[14:2]] = data[23:16];
        router.arm9_itcm.memory3[address[14:2]] = data[31:24];
    endtask

    task automatic put_dtcm(
        input logic [31:0] address,
        input logic [31:0] data
    );
        router.arm9_dtcm.memory0[address[13:2]] = data[7:0];
        router.arm9_dtcm.memory1[address[13:2]] = data[15:8];
        router.arm9_dtcm.memory2[address[13:2]] = data[23:16];
        router.arm9_dtcm.memory3[address[13:2]] = data[31:24];
    endtask

    always @(posedge clk) begin
        oracle_done <= 0;
        if (oracle_pending) begin
            oracle_pending <= 0;
            oracle_done <= 1;
        end else if (oracle_request) begin
            oracle_pending <= 1;
            if (!oracle_rnw &&
                oracle_address == 32'h0400029c &&
                oracle_wdata == STALE_WRITE_DATA)
                saw_stale_write <= 1;
        end

        ddram_read_data_ready <= 0;
        if (!ddram_read)
            ddram_read_seen <= 0;
        if (ddram_read && !ddram_read_seen) begin
            ddram_read_seen <= 1;
            ddram_read_data_ready <= 1;
            ddram_read_data <= read_main(ddram_address);
        end

        if (ext_ena && ext_done && ext_cpu_is_arm9 && ext_rnw) begin
            if (ext_addr == 32'h027e3924) begin
                saw_stack_word0 <= 1;
                stack_word0_data <= ext_rdata;
                if ((ext_debug_pc ^ 32'h40000000) != 32'h01ffd280)
                    $fatal(1, "saved-R11 read execute PC %h",
                           ext_debug_pc ^ 32'h40000000);
            end else if (ext_addr == 32'h027e3928) begin
                saw_stack_word1 <= 1;
                stack_word1_data <= ext_rdata;
                if ((ext_debug_pc ^ 32'h40000000) != 32'h01ffd280)
                    $fatal(1, "saved-PC read execute PC %h",
                           ext_debug_pc ^ 32'h40000000);
            end
        end
        if (ext_ena && ext_cpu_is_arm9 && ext_rnw &&
            ext_addr == EXPECTED_PC) begin
            saw_target_fetch <= 1;
            // r182 leaves the independent diagnostic seam live until the
            // exact privileged context/ADD/System-POP path reaches a bad
            // final R15 source. This simple healthy POP is deliberately not
            // qualified, so the seam must still report its execute PC.
            if (arm9_diag_word != RETURN_PC)
                $fatal(1, "healthy block-return telemetry froze %h",
                       arm9_diag_word);
            // The new target is being fetched while the return instruction
            // is still the architectural execute-stage PC seen by the HPS
            // model. It must remain live, not become the A-tag diagnostic.
            if ((ext_debug_pc ^ 32'h40000000) != RETURN_PC)
                $fatal(1, "functional execute-PC seam was contaminated %h",
                       ext_debug_pc ^ 32'h40000000);
            saw_live_telemetry <= 1;
        end
        if (ext_ena && ext_cpu_is_arm9 && ext_rnw &&
            ext_addr == STALE_WRITE_DATA) begin
            saw_stale_target_fetch <= 1;
            if (arm9_diag_word != RETURN_PC)
                $fatal(
                    1,
                    "unqualified second block-return telemetry froze %h",
                    arm9_diag_word
                );
            if ((ext_debug_pc ^ 32'h40000000) != RETURN_PC)
                $fatal(1, "functional execute-PC seam was contaminated %h",
                       ext_debug_pc ^ 32'h40000000);
        end
    end

    initial begin : preload
        #1ns;

        // Architectural-reset shim: relocate DTCM, establish IRQ/System
        // stacks, then enter the exact failing ITCM return sequence.
        put_itcm(32'h00000000, 32'he59f001c);
        put_itcm(32'h00000004, 32'hee090f11);
        put_itcm(32'h00000008, 32'he321f0d2);
        put_itcm(32'h0000000c, 32'he59fd014);
        put_itcm(32'h00000010, 32'he321f0df);
        put_itcm(32'h00000014, 32'he59fd010);
        put_itcm(32'h00000018, 32'he321f01f);
        put_itcm(32'h0000001c, 32'he59ff00c);
        put_itcm(32'h00000020, 32'he1a00000);
        put_itcm(32'h00000024, 32'h027e000a);
        put_itcm(32'h00000028, 32'h027e3f78);
        put_itcm(32'h0000002c, 32'h027e3924);
        put_itcm(32'h00000030, 32'h01ffd260);

        // Make the previous completed bus write carry the exact corrupt value
        // seen in hardware, then branch to the native LDM return instruction.
        put_itcm(32'h01ffd260, 32'he59f2010);
        put_itcm(32'h01ffd264, 32'he59f3010);
        put_itcm(32'h01ffd268, 32'he5823004);
        put_itcm(32'h01ffd26c, 32'hea000003);
        put_itcm(32'h01ffd270, 32'he1a00000);
        put_itcm(32'h01ffd274, 32'he1a00000);
        put_itcm(32'h01ffd278, 32'h04000298);
        put_itcm(32'h01ffd27c, STALE_WRITE_DATA);
        put_itcm(32'h01ffd280, 32'he8bd8800);

        put_dtcm(32'h027e3924, 32'h00000000);
        put_dtcm(32'h027e3928, EXPECTED_PC);
        // The first return is healthy and writes SP back from 0x027e3924 to
        // 0x027e392c. Its target stores the known stale BIOS opcode at the
        // second invocation's saved-PC word 0x027e3930, then invokes the same
        // BIOS return again. Neither invocation includes r182's privileged
        // context/ADD preamble, so telemetry must remain live through both.
        main_words[EXPECTED_PC[21:2] + 0] = 32'he59f0004;
        main_words[EXPECTED_PC[21:2] + 1] = 32'he58d0004;
        main_words[EXPECTED_PC[21:2] + 2] = 32'he59ff000;
        main_words[EXPECTED_PC[21:2] + 3] = STALE_WRITE_DATA;
        main_words[EXPECTED_PC[21:2] + 4] = 32'h01ffd280;

        // Leave ARM7 in a harmless architectural-reset loop.
        router.arm7_bios.words[0] = 32'heafffffe;
    end

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        fork
            begin
                wait (saw_stale_target_fetch);
            end
            begin
                #200us;
                $fatal(
                    1,
                    "stack return timeout write=%0d reads=%0d/%0d target=%0d pc9=%h addr=%h rdata=%h",
                    saw_stale_write, saw_stack_word0, saw_stack_word1,
                    saw_stale_target_fetch, arm9_debug_pc ^ 32'h40000000,
                    ext_addr, ext_rdata
                );
            end
        join_any
        disable fork;

        if (!saw_stale_write)
            $fatal(1, "preceding stale-data write was not completed");
        if (!saw_stack_word0 || stack_word0_data !== 32'h00000000)
            $fatal(1, "saved R11 read mismatch %h", stack_word0_data);
        if (!saw_stack_word1 || stack_word1_data !== EXPECTED_PC)
            $fatal(1, "saved PC read mismatch %h", stack_word1_data);
        if (!saw_live_telemetry)
            $fatal(1, "live r182 diagnostic seam was not observed");
        if (!saw_stale_target_fetch)
            $fatal(1, "second block-return target was not observed");
        $display(
            "PASS: r182 telemetry remains live across healthy/unqualified block returns at 0x%08h",
            RETURN_PC
        );
        $finish;
    end
endmodule
