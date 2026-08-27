module tb_nds_cpu_memory_gx_shadow_equivalence;
    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7 = 29'h001a0000;
    localparam logic [28:0] ORACLE = 29'h00200000;
    localparam logic [28:0] POSTED = 29'h00300000;
    localparam integer MAX_EXPECTED = 64;

    logic clk = 0;
    logic reset = 1;
    logic request = 0;
    logic cpu_is_arm9 = 1;
    logic [7:0] arm9_cycles = 0;
    logic arm9_cycles_valid = 0;
    logic [7:0] arm7_cycles = 0;
    logic arm7_cycles_valid = 0;
    logic [31:0] arm9_debug_pc = 32'h02001000;
    logic [31:0] arm7_debug_pc = 32'h037f8000;
    wire [31:0] request_debug_pc =
        cpu_is_arm9 ? arm9_debug_pc : arm7_debug_pc;
    logic [31:0] arm9_dtcm_region = 32'h0300000a;
    logic arm9_dtcm_enable = 1;
    logic arm9_dtcm_seed_valid = 1;
    logic [31:0] arm9_dtcm_irq_vector = 32'h01ffd5ec;
    logic [31:0] address = 0;
    logic read_not_write = 1;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = 0;

    logic [31:0] base_read_data;
    logic base_done;
    logic base_irq9, base_irq7, base_halt9, base_halt7;
    logic base_pause;
    logic base_debug_oracle, base_debug_mailbox, base_debug_done;
    logic [3:0] base_debug_state;
    logic [1:0] base_debug_tick;
    logic base_ddr_read, base_ddr_write;
    logic [7:0] base_ddr_burst, base_ddr_be;
    logic [28:0] base_ddr_address;
    logic [63:0] base_ddr_write_data;

    logic [31:0] shadow_read_data;
    logic shadow_done;
    logic shadow_irq9, shadow_irq7, shadow_halt9, shadow_halt7;
    logic shadow_pause;
    logic shadow_debug_oracle, shadow_debug_mailbox, shadow_debug_done;
    logic [3:0] shadow_debug_state;
    logic [1:0] shadow_debug_tick;
    logic shadow_ddr_read, shadow_ddr_write;
    logic [7:0] shadow_ddr_burst, shadow_ddr_be;
    logic [28:0] shadow_ddr_address;
    logic [63:0] shadow_ddr_write_data;

    logic ddr_busy = 0;
    logic ddr_ready = 0;
    logic [63:0] ddr_read_data = 0;
    wire base_ddr_accepted =
        (base_ddr_read || base_ddr_write) && !ddr_busy;
    wire shadow_ddr_accepted =
        (shadow_ddr_read || shadow_ddr_write) && !ddr_busy;

    logic [31:0] mailbox_sequence = 0;
    logic [31:0] response_data = 32'h00000000;
    logic [31:0] response_flags = 32'h0000000f;
    logic second_response_word = 0;
    integer mailbox_words = 0;
    integer mailbox_requests = 0;
    integer equivalence_cycles = 0;

    logic [7:0] expected_command [0:MAX_EXPECTED-1];
    logic [31:0] expected_parameter [0:MAX_EXPECTED-1];
    integer expected_write = 0;
    integer expected_read = 0;

    always #5 clk = ~clk;

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7),
        .ORACLE_BASE_WORD(ORACLE),
        .POSTED_RING_BASE_WORD(POSTED),
        .ORACLE_POLL_DELAY_CYCLES(1),
        .TIME_FLUSH_CYCLES(32'h7fffffff),
        .HALT_POLL_CLOCKS(32'h7fffffff),
        .GX_COMMAND_SHADOW_ENABLE(0)
    ) baseline (
        .clk, .reset, .transport_reset(reset), .request, .cpu_is_arm9,
        .arm9_cycles, .arm9_cycles_valid,
        .arm7_cycles, .arm7_cycles_valid,
        .arm9_debug_pc, .arm7_debug_pc, .request_debug_pc,
        .arm9_dtcm_region, .arm9_dtcm_enable,
        .arm9_dtcm_seed_valid, .arm9_dtcm_irq_vector,
        .address, .read_not_write, .access, .write_data,
        .read_data(base_read_data), .done(base_done),
        .irq_arm9(base_irq9), .irq_arm7(base_irq7),
        .halt_arm9(base_halt9), .halt_arm7(base_halt7),
        .cpu_pause(base_pause),
        .debug_oracle_request(base_debug_oracle),
        .debug_mailbox_request(base_debug_mailbox),
        .debug_mailbox_done(base_debug_done),
        .debug_mailbox_state(base_debug_state),
        .debug_tick_state(base_debug_tick),
        .ddram_read(base_ddr_read),
        .ddram_write(base_ddr_write),
        .ddram_burst_count(base_ddr_burst),
        .ddram_address(base_ddr_address),
        .ddram_write_data(base_ddr_write_data),
        .ddram_byte_enable(base_ddr_be),
        .ddram_busy(ddr_busy),
        .ddram_command_accepted(base_ddr_accepted),
        .ddram_read_data(ddr_read_data),
        .ddram_read_data_ready(ddr_ready)
    );

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7),
        .ORACLE_BASE_WORD(ORACLE),
        .POSTED_RING_BASE_WORD(POSTED),
        .ORACLE_POLL_DELAY_CYCLES(1),
        .TIME_FLUSH_CYCLES(32'h7fffffff),
        .HALT_POLL_CLOCKS(32'h7fffffff),
        .GX_COMMAND_SHADOW_ENABLE(1),
        .GX_COMMAND_SHADOW_QUEUE_DEPTH(8)
    ) shadow (
        .clk, .reset, .transport_reset(reset), .request, .cpu_is_arm9,
        .arm9_cycles, .arm9_cycles_valid,
        .arm7_cycles, .arm7_cycles_valid,
        .arm9_debug_pc, .arm7_debug_pc, .request_debug_pc,
        .arm9_dtcm_region, .arm9_dtcm_enable,
        .arm9_dtcm_seed_valid, .arm9_dtcm_irq_vector,
        .address, .read_not_write, .access, .write_data,
        .read_data(shadow_read_data), .done(shadow_done),
        .irq_arm9(shadow_irq9), .irq_arm7(shadow_irq7),
        .halt_arm9(shadow_halt9), .halt_arm7(shadow_halt7),
        .cpu_pause(shadow_pause),
        .debug_oracle_request(shadow_debug_oracle),
        .debug_mailbox_request(shadow_debug_mailbox),
        .debug_mailbox_done(shadow_debug_done),
        .debug_mailbox_state(shadow_debug_state),
        .debug_tick_state(shadow_debug_tick),
        .ddram_read(shadow_ddr_read),
        .ddram_write(shadow_ddr_write),
        .ddram_burst_count(shadow_ddr_burst),
        .ddram_address(shadow_ddr_address),
        .ddram_write_data(shadow_ddr_write_data),
        .ddram_byte_enable(shadow_ddr_be),
        .ddram_busy(ddr_busy),
        .ddram_command_accepted(shadow_ddr_accepted),
        .ddram_read_data(ddr_read_data),
        .ddram_read_data_ready(ddr_ready)
    );

    task automatic expect_geometry(
        input logic [7:0] wanted_command,
        input logic [31:0] wanted_parameter
    );
        begin
            expected_command[expected_write] = wanted_command;
            expected_parameter[expected_write] = wanted_parameter;
            expected_write = expected_write + 1;
        end
    endtask

    task automatic issue_write(
        input logic selected_cpu,
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] bus_data
    );
        integer waited;
        begin
            @(negedge clk);
            cpu_is_arm9 = selected_cpu;
            address = bus_address;
            access = bus_access;
            write_data = bus_data;
            read_not_write = 0;
            request = 1;
            waited = 0;
            while (!base_done) begin
                @(posedge clk);
                waited = waited + 1;
                if (waited > 500)
                    $fatal(1, "write completion timeout at %h", bus_address);
            end
            if (!shadow_done)
                $fatal(1, "shadow instance completion lagged baseline");
            @(negedge clk);
            request = 0;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic issue_read(
        input logic selected_cpu,
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] wanted_data
    );
        integer waited;
        begin
            response_data = wanted_data;
            @(negedge clk);
            cpu_is_arm9 = selected_cpu;
            address = bus_address;
            access = bus_access;
            read_not_write = 1;
            request = 1;
            waited = 0;
            while (!base_done) begin
                @(posedge clk);
                waited = waited + 1;
                if (waited > 500)
                    $fatal(1, "read completion timeout at %h", bus_address);
            end
            #1;
            if (base_read_data !== wanted_data ||
                shadow_read_data !== wanted_data)
                $fatal(1, "read result mismatch base=%h shadow=%h wanted=%h",
                       base_read_data, shadow_read_data, wanted_data);
            @(negedge clk);
            request = 0;
            repeat (2) @(posedge clk);
        end
    endtask

    // One common DDR responder is valid only while every routed command is
    // identical. The cycle-by-cycle checker below turns any divergence into
    // an immediate failure before this model can hide it.
    always_ff @(posedge clk) begin
        ddr_ready <= 0;
        if (!reset && base_ddr_write) begin
            mailbox_words <= mailbox_words + 1;
            if (base_ddr_address == ORACLE) begin
                mailbox_sequence <= base_ddr_write_data[63:32];
                mailbox_requests <= mailbox_requests + 1;
            end
        end
        if (!reset && base_ddr_read) begin
            if (base_ddr_address != ORACLE + 3)
                $fatal(1, "unexpected DDR read address %h",
                       base_ddr_address);
            ddr_read_data <= {mailbox_sequence, response_data};
            ddr_ready <= 1;
            second_response_word <= 1;
        end else if (second_response_word) begin
            ddr_read_data <= {32'd0, response_flags};
            ddr_ready <= 1;
            second_response_word <= 0;
        end
    end

    // Architectural results and the complete DDR mailbox request are
    // required to be case-equal on every stable half-cycle.
    always @(negedge clk) begin
        if (!reset) begin
            equivalence_cycles = equivalence_cycles + 1;
            if (base_read_data !== shadow_read_data ||
                base_done !== shadow_done ||
                base_irq9 !== shadow_irq9 ||
                base_irq7 !== shadow_irq7 ||
                base_halt9 !== shadow_halt9 ||
                base_halt7 !== shadow_halt7 ||
                base_pause !== shadow_pause)
                $fatal(1,
                    "architectural shadow divergence cycle=%0d read=%h/%h done=%b/%b irq=%b%b/%b%b halt=%b%b/%b%b pause=%b/%b",
                    equivalence_cycles,
                    base_read_data, shadow_read_data,
                    base_done, shadow_done,
                    base_irq9, base_irq7,
                    shadow_irq9, shadow_irq7,
                    base_halt9, base_halt7,
                    shadow_halt9, shadow_halt7,
                    base_pause, shadow_pause);
            if (base_debug_oracle !== shadow_debug_oracle ||
                base_debug_mailbox !== shadow_debug_mailbox ||
                base_debug_done !== shadow_debug_done ||
                base_debug_state !== shadow_debug_state ||
                base_debug_tick !== shadow_debug_tick)
                $fatal(1, "debug/mailbox state shadow divergence");
            if (base_ddr_read !== shadow_ddr_read ||
                base_ddr_write !== shadow_ddr_write ||
                base_ddr_burst !== shadow_ddr_burst ||
                base_ddr_address !== shadow_ddr_address ||
                base_ddr_write_data !== shadow_ddr_write_data ||
                base_ddr_be !== shadow_ddr_be)
                $fatal(1,
                    "DDR mailbox routing divergence rd=%b/%b wr=%b/%b burst=%h/%h addr=%h/%h data=%h/%h be=%h/%h",
                    base_ddr_read, shadow_ddr_read,
                    base_ddr_write, shadow_ddr_write,
                    base_ddr_burst, shadow_ddr_burst,
                    base_ddr_address, shadow_ddr_address,
                    base_ddr_write_data, shadow_ddr_write_data,
                    base_ddr_be, shadow_ddr_be);
            if (baseline.gx_shadow_command_valid)
                $fatal(1, "default-off instance emitted a shadow command");
            if (shadow.oracle_start && !shadow.oracle_rnw &&
                !shadow.gx_shadow_write_ready)
                $fatal(1,
                    "passive shadow was not ready at oracle admission");
            if (shadow.gx_shadow_command_valid) begin
                if (expected_read >= expected_write)
                    $fatal(1, "unexpected shadow command %02x %08x",
                           shadow.gx_shadow_command_id,
                           shadow.gx_shadow_command_parameter);
                if (shadow.gx_shadow_command_id !==
                        expected_command[expected_read] ||
                    shadow.gx_shadow_command_parameter !==
                        expected_parameter[expected_read])
                    $fatal(1,
                        "normalized shadow mismatch at %0d got %02x/%08x expected %02x/%08x",
                        expected_read,
                        shadow.gx_shadow_command_id,
                        shadow.gx_shadow_command_parameter,
                        expected_command[expected_read],
                        expected_parameter[expected_read]);
                expected_read = expected_read + 1;
            end
        end
    end

    initial begin : timeout_guard
        repeat (10000) @(posedge clk);
        $fatal(1, "GX shadow equivalence timeout");
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Packed command word: 10(1), 12(1), 23(2), zero padding.
        expect_geometry(8'h10, 32'h10101010);
        expect_geometry(8'h12, 32'h12121212);
        expect_geometry(8'h23, 32'h23232301);
        expect_geometry(8'h23, 32'h23232302);
        issue_write(1, 32'h04000400, 2'b10, 32'h00231210);
        issue_write(1, 32'h04000400, 2'b10, 32'h10101010);
        issue_write(1, 32'h04000404, 2'b10, 32'h12121212);
        issue_write(1, 32'h04000408, 2'b10, 32'h23232301);
        issue_write(1, 32'h0400040c, 2'b10, 32'h23232302);

        // Direct ingress does not disturb packed parser state.
        issue_write(1, 32'h04000400, 2'b10, 32'h00000010);
        expect_geometry(8'h20, 32'h20202020);
        issue_write(1, 32'h04000480, 2'b10, 32'h20202020);
        expect_geometry(8'h10, 32'h10000010);
        issue_write(1, 32'h04000400, 2'b10, 32'h10000010);

        // Exact zero-parameter behavior: three named commands reuse their
        // command word; an all-zero packet emits exactly one NOP.
        expect_geometry(8'h11, 32'h00411511);
        expect_geometry(8'h15, 32'h00411511);
        expect_geometry(8'h41, 32'h00411511);
        issue_write(1, 32'h04000400, 2'b10, 32'h00411511);
        expect_geometry(8'h00, 32'h00000000);
        issue_write(1, 32'h04000400, 2'b10, 32'h00000000);

        // ARM7, wrong-width GX traffic, and unrelated I/O remain mailbox
        // owned but must never enter the ARM9 geometry shadow.
        issue_write(0, 32'h04000440, 2'b10, 32'h77777777);
        issue_write(1, 32'h04000440, 2'b01, 32'h88888888);
        issue_write(1, 32'h04000208, 2'b01, 32'h00000001);

        // Read data, IRQ/HALT, and pause are also checked through completion.
        issue_read(1, 32'h04000600, 2'b10, 32'h86002000);
        issue_read(0, 32'h04000130, 2'b01, 32'h000003ff);

        repeat (12) @(posedge clk);
        if (expected_read != expected_write)
            $fatal(1, "missing shadow commands got=%0d expected=%0d",
                   expected_read, expected_write);
        if (shadow.gx_shadow_queue_level != 0 ||
            shadow.gx_shadow_packed_active ||
            !shadow.gx_shadow_protocol_error)
            $fatal(1,
                "shadow state mismatch level=%0d packed=%b error=%b",
                shadow.gx_shadow_queue_level,
                shadow.gx_shadow_packed_active,
                shadow.gx_shadow_protocol_error);
        if (mailbox_requests != 15 || mailbox_words != mailbox_requests * 4)
            $fatal(1,
                "unexpected mailbox routing count requests=%0d words=%0d",
                mailbox_requests, mailbox_words);

        $display(
            "PASS: default-off and passive GX-shadow memory systems are cycle/byte-identical");
        $display(
            "equivalence_cycles=%0d mailbox_requests=%0d mailbox_words=%0d normalized_commands=%0d",
            equivalence_cycles, mailbox_requests, mailbox_words,
            expected_read);
        $finish;
    end
endmodule
