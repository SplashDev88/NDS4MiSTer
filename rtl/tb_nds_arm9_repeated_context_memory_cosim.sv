module tb_nds_arm9_repeated_context_memory_cosim;
    timeunit 1ns;
    timeprecision 1ns;

    parameter int ITERATIONS = 8;
    parameter int ORACLE_DELAY_CYCLES = 0;
    parameter int DDR_READ_DELAY_CYCLES = 0;

    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7RAM = 29'h001a0000;
    localparam logic [31:0] CONTEXT = 32'h02001000;
    localparam logic [28:0] CONTEXT_SP_DDR = 29'h00100207;

    logic clk = 0;
    logic reset = 1;
    logic descriptor_valid = 1;
    logic irq_arm9 = 0;
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
    logic oracle_wait_release = 0;
    int oracle_wait = 0;
    logic [31:0] oracle_latched_address = 0;
    logic [31:0] oracle_rdata = 0;

    logic ddram_read, ddram_write;
    logic [7:0] ddram_burst_count, ddram_byte_enable;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data, ddram_read_data = 0;
    logic ddram_busy = 0, ddram_read_data_ready = 0;
    logic ddram_read_pending = 0;
    int ddram_read_wait = 0;
    logic [28:0] ddram_latched_address = 0;

    logic [31:0] main_words [0:1048575];

    int body_count = 0;
    int vector_count = 0;
    int context_sp_count = 0;
    int return_word0_count = 0;
    int return_word1_count = 0;
    int irq_tail_write_count = 0;
    int irq_tail_pc_read_count = 0;
    int sp_marker_count = 0;
    logic context_sp_ddr_pending = 0;
    logic bad_context_sp = 0;
    logic bad_return = 0;
    logic bad_irq_tail = 0;
    logic bad_final_sp = 0;

    wire [31:0] execute_pc = ext_debug_pc ^ 32'h40000000;

    nds_dual_cpu_cosim_top cpus (
        .clk, .reset, .descriptor_valid, .global_step_enable(1'b1),
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
        .irq_arm9, .irq_arm7(1'b0),
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

    task automatic put_main(
        input logic [31:0] address,
        input logic [31:0] data
    );
        main_words[address[21:2]] = data;
    endtask

    always @(posedge clk) begin
        oracle_done <= 0;
        if (oracle_wait_release) begin
            if (!oracle_request)
                oracle_wait_release <= 0;
        end else if (!oracle_pending && oracle_request) begin
            oracle_pending <= 1;
            oracle_wait <= ORACLE_DELAY_CYCLES;
            oracle_latched_address <= oracle_address;
            oracle_rdata <= oracle_word(oracle_address);
        end else if (oracle_pending && oracle_wait != 0) begin
            oracle_wait <= oracle_wait - 1;
        end else if (oracle_pending) begin
            oracle_pending <= 0;
            oracle_wait_release <= 1;
            oracle_done <= 1;
        end

        ddram_read_data_ready <= 0;
        if (!ddram_read_pending && ddram_read) begin
            ddram_read_pending <= 1;
            ddram_read_wait <= DDR_READ_DELAY_CYCLES;
            ddram_latched_address <= ddram_address;
        end else if (ddram_read_pending && ddram_read_wait != 0) begin
            ddram_read_wait <= ddram_read_wait - 1;
        end else if (ddram_read_pending) begin
            ddram_read_pending <= 0;
            ddram_read_data <= read_main(ddram_latched_address);
            ddram_read_data_ready <= 1;
        end

        if (ext_ena && ext_done && ext_cpu_is_arm9) begin
            if (ext_rnw && ext_addr == 32'h01ffd238)
                body_count <= body_count + 1;
            if (ext_rnw && ext_addr == 32'hffff0018)
                vector_count <= vector_count + 1;

            if (execute_pc == 32'h00000530 && !ext_rnw) begin
                if (ext_addr >= 32'h027e3f64 &&
                    ext_addr <= 32'h027e3f78 &&
                    ext_addr[1:0] == 0)
                    irq_tail_write_count <= irq_tail_write_count + 1;
                else
                    bad_irq_tail <= 1;
            end
            if (execute_pc == 32'h00000534 && ext_rnw &&
                ext_addr >= 32'h027e3f00 && ext_addr < 32'h027e4000) begin
                if (ext_addr == 32'h027e3f60 &&
                    ext_rdata == 32'h00000560)
                    irq_tail_pc_read_count <= irq_tail_pc_read_count + 1;
                else
                    bad_irq_tail <= 1;
            end

            if (ext_rnw && ext_addr == 32'h027e3924) begin
                return_word0_count <= return_word0_count + 1;
                if (execute_pc != 32'h01ffd280 ||
                    ext_rdata != 32'h00000000)
                    bad_return <= 1;
            end
            if (ext_rnw && ext_addr == 32'h027e3928) begin
                return_word1_count <= return_word1_count + 1;
                if (execute_pc != 32'h01ffd280 ||
                    ext_rdata != 32'h00000200)
                    bad_return <= 1;
            end
            if (!ext_rnw && ext_addr == 32'h04000300) begin
                sp_marker_count <= sp_marker_count + 1;
                if (ext_wdata != 32'h027e392c)
                    bad_final_sp <= 1;
            end
        end

        // ext_addr can already carry a completion-edge successor request
        // while ext_done completes the prior transfer. Observe the accepted
        // production DDR request instead; offset zero selects the exact R13
        // context word at 0x02001038 rather than the adjacent R14 word.
        if (ddram_read && !ddram_busy &&
            ddram_address == CONTEXT_SP_DDR &&
            router.main_ram.latched_offset == 3'd0) begin
            context_sp_count <= context_sp_count + 1;
            context_sp_ddr_pending <= 1;
        end
        if (ddram_read_data_ready && context_sp_ddr_pending) begin
            context_sp_ddr_pending <= 0;
            if (ddram_read_data[31:0] != 32'h027e3914)
                bad_context_sp <= 1;
        end
    end

    initial begin : preload
        #1ns;

        // Relocate/enable DTCM, seed IRQ/System stacks, then enter the exact
        // native System-mode function frame.
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
        put_itcm(32'h01ffd27c, 32'he28bd010);
        put_itcm(32'h01ffd280, 32'he8bd8800);

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

        // Keep ARM7 continuously requesting its local BIOS loop so the
        // production dual-CPU owner handoff is exercised.
        router.arm7_bios.words[0] = 32'heafffffe;
    end

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        wait (boot_ready);

        for (int iteration = 1; iteration <= ITERATIONS; iteration++) begin
            fork
                begin
                    wait (body_count >= iteration);
                end
                begin
                    #2ms;
                    $fatal(1, "body timeout iteration=%0d pc=%h addr=%h",
                           iteration, execute_pc, ext_addr);
                end
            join_any
            disable fork;
            irq_arm9 = 1;
            fork
                begin
                    wait (vector_count >= iteration);
                end
                begin
                    #2ms;
                    $fatal(1, "IRQ timeout iteration=%0d pc=%h addr=%h",
                           iteration, execute_pc, ext_addr);
                end
            join_any
            disable fork;
            irq_arm9 = 0;
            fork
                begin
                    wait (sp_marker_count >= iteration);
                end
                begin
                    #2ms;
                    $fatal(1, "return timeout iteration=%0d pc=%h addr=%h",
                           iteration, execute_pc, ext_addr);
                end
            join_any
            disable fork;
        end

        if (context_sp_count < ITERATIONS ||
            context_sp_ddr_pending || bad_context_sp)
            $fatal(1, "context SP reads=%0d expected>=%0d pending=%0d bad=%0d",
                   context_sp_count, ITERATIONS,
                   context_sp_ddr_pending, bad_context_sp);
        if (return_word0_count != ITERATIONS ||
            return_word1_count != ITERATIONS || bad_return)
            $fatal(1, "return reads=%0d/%0d bad=%0d",
                   return_word0_count, return_word1_count, bad_return);
        if (irq_tail_write_count != 6 * ITERATIONS ||
            irq_tail_pc_read_count != ITERATIONS || bad_irq_tail)
            $fatal(1, "IRQ tail writes=%0d reads=%0d bad=%0d",
                   irq_tail_write_count, irq_tail_pc_read_count,
                   bad_irq_tail);
        if (sp_marker_count != ITERATIONS || bad_final_sp)
            $fatal(1, "SP markers=%0d bad=%0d",
                   sp_marker_count, bad_final_sp);

        $display(
            "PASS: production router/DTCM preserves repeated ARM9 context SP for %0d iterations (oracle=%0d DDR=%0d)",
            ITERATIONS, ORACLE_DELAY_CYCLES, DDR_READ_DELAY_CYCLES
        );
        $finish;
    end
endmodule
