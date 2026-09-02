module tb_nds_cpu_memory_gx_posted;
    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7 = 29'h001a0000;
    localparam logic [28:0] ORACLE = 29'h00200000;
    localparam logic [28:0] POSTED = 29'h00300000;
    localparam integer HEADER_WORDS64 = 8;

    logic clk = 0;
    logic reset = 1;
    logic request = 0;
    logic cpu_is_arm9 = 1;
    logic [7:0] arm9_cycles = 0;
    logic arm9_cycles_valid = 0;
    logic [7:0] arm7_cycles = 0;
    logic arm7_cycles_valid = 0;
    logic [31:0] address = 0;
    logic read_not_write = 0;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = 0;
    logic [31:0] read_data;
    logic done;
    logic irq_arm9, irq_arm7, halt_arm9, halt_arm7, cpu_pause;
    logic debug_oracle_request;
    logic debug_mailbox_request;
    logic debug_mailbox_done;
    logic [3:0] debug_mailbox_state;
    logic [1:0] debug_tick_state;
    logic ddram_read, ddram_write;
    logic [7:0] ddram_burst_count, ddram_byte_enable;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic ddram_busy = 0;
    logic ddram_command_accepted;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;

    logic [63:0] mailbox_memory [0:4];
    logic [63:0] posted_memory [0:63];
    logic response_second_word = 0;
    integer posted_ddr_writes = 0;
    integer mailbox_requests = 0;

    always #5 clk = ~clk;
    assign ddram_command_accepted =
        (ddram_read || ddram_write) && !ddram_busy;

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7),
        .ORACLE_BASE_WORD(ORACLE),
        .POSTED_RING_BASE_WORD(POSTED),
        .ORACLE_POLL_DELAY_CYCLES(1),
        .TIME_FLUSH_CYCLES(32'h7fffffff),
        .HALT_POLL_CLOCKS(32'h7fffffff),
        .POSTED_IRQ_REFRESH_WRITES(4),
        .GX_POSTED_ENABLE(1)
    ) dut (
        .clk, .reset, .transport_reset(reset), .request, .cpu_is_arm9,
        .arm9_cycles, .arm9_cycles_valid,
        .arm7_cycles, .arm7_cycles_valid,
        .arm9_debug_pc(32'h02001000),
        .arm7_debug_pc(32'h037f8000),
        .request_debug_pc(cpu_is_arm9
            ? 32'h02001000 : 32'h037f8000),
        .arm9_dtcm_region(32'h0300000a),
        .arm9_dtcm_enable(1'b1),
        .arm9_dtcm_seed_valid(1'b1),
        .arm9_dtcm_irq_vector(32'h01ffd5ec),
        .address, .read_not_write, .access, .write_data,
        .read_data, .done,
        .irq_arm9, .irq_arm7, .halt_arm9, .halt_arm7, .cpu_pause,
        .debug_oracle_request,
        .debug_mailbox_request,
        .debug_mailbox_done,
        .debug_mailbox_state,
        .debug_tick_state,
        .ddram_read, .ddram_write, .ddram_burst_count,
        .ddram_address, .ddram_write_data, .ddram_byte_enable,
        .ddram_busy, .ddram_command_accepted,
        .ddram_read_data, .ddram_read_data_ready
    );

    always_ff @(posedge clk) begin
        ddram_read_data_ready <= 0;
        if (ddram_write) begin
            if (ddram_address >= POSTED &&
                ddram_address < POSTED + 64) begin
                posted_memory[ddram_address - POSTED] <= ddram_write_data;
                posted_ddr_writes <= posted_ddr_writes + 1;
            end else if (ddram_address >= ORACLE &&
                         ddram_address <= ORACLE + 4) begin
                mailbox_memory[ddram_address - ORACLE] <= ddram_write_data;
                if (ddram_address == ORACLE)
                    mailbox_requests <= mailbox_requests + 1;
            end else begin
                $fatal(1, "unexpected DDR write address %h", ddram_address);
            end
        end
        if (ddram_read) begin
            if (ddram_address == ORACLE + 3) begin
                ddram_read_data <=
                    {mailbox_memory[0][63:32], 32'hfeedc0de};
                ddram_read_data_ready <= 1;
                response_second_word <= 1;
            end else if (ddram_address == POSTED + 1) begin
                ddram_read_data <= posted_memory[1];
                ddram_read_data_ready <= 1;
            end else begin
                $fatal(1, "unexpected DDR read address %h", ddram_address);
            end
        end else if (response_second_word) begin
            ddram_read_data <= 64'h0000000000000000;
            ddram_read_data_ready <= 1;
            response_second_word <= 0;
        end
    end

    task automatic add_arm9_cycles(input logic [7:0] cycles);
        begin
            @(negedge clk);
            arm9_cycles = cycles;
            arm9_cycles_valid = 1;
            @(posedge clk);
            @(negedge clk);
            arm9_cycles_valid = 0;
            arm9_cycles = 0;
        end
    endtask

    task automatic issue_transaction(
        input logic selected_cpu,
        input logic is_read,
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] bus_data,
        input logic expect_posted
    );
        integer writes_before;
        integer mailboxes_before;
        integer waited;
        logic saw_oracle;
        begin
            writes_before = posted_ddr_writes;
            mailboxes_before = mailbox_requests;
            saw_oracle = 0;
            @(negedge clk);
            cpu_is_arm9 = selected_cpu;
            read_not_write = is_read;
            address = bus_address;
            access = bus_access;
            write_data = bus_data;
            request = 1;
            waited = 0;
            while (!done) begin
                @(posedge clk);
                #1;
                if (debug_oracle_request)
                    saw_oracle = 1;
                waited = waited + 1;
                if (waited > 500)
                    $fatal(1, "transaction timeout at %h", bus_address);
            end
            #1;
            if (expect_posted) begin
                if (saw_oracle || posted_ddr_writes != writes_before + 3 ||
                    mailbox_requests != mailboxes_before)
                    $fatal(1,
                        "expected posted write addr=%h oracle=%b ring=%0d/%0d mailbox=%0d/%0d",
                        bus_address, saw_oracle,
                        posted_ddr_writes, writes_before,
                        mailbox_requests, mailboxes_before);
            end else begin
                if (!saw_oracle || posted_ddr_writes != writes_before ||
                    mailbox_requests != mailboxes_before + 1)
                    $fatal(1,
                        "expected mailbox addr=%h oracle=%b ring=%0d/%0d mailbox=%0d/%0d",
                        bus_address, saw_oracle,
                        posted_ddr_writes, writes_before,
                        mailbox_requests, mailboxes_before);
            end
            @(negedge clk);
            request = 0;
            wait (!done);
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic verify_posted_entry(
        input integer slot,
        input logic [31:0] expected_sequence,
        input logic [31:0] expected_address,
        input logic [31:0] expected_data,
        input logic [31:0] expected_cycles,
        input logic [3:0] expected_control
    );
        integer base;
        begin
            base = HEADER_WORDS64 + slot * 3;
            if (posted_memory[base] !==
                    {expected_data, expected_address} ||
                posted_memory[base + 1] !==
                    {28'h0, expected_control, expected_cycles} ||
                posted_memory[base + 2] !==
                    {32'h0, expected_sequence})
                $fatal(1,
                    "posted entry %0d mismatch %h %h %h",
                    slot, posted_memory[base],
                    posted_memory[base + 1],
                    posted_memory[base + 2]);
        end
    endtask

    initial begin : timeout_guard
        repeat (5000) @(posedge clk);
        $fatal(1,
            "timeout sequence=%0d ring_writes=%0d mailbox_requests=%0d",
            dut.posted_producer_sequence,
            posted_ddr_writes, mailbox_requests);
    end

    initial begin
        integer index;
        integer mailboxes_before_refresh;
        integer writes_before_exhaustion;
        integer mailboxes_before_exhaustion;
        logic [31:0] cycles_before_exhaustion;
        for (index = 0; index < 5; index = index + 1)
            mailbox_memory[index] = 0;
        for (index = 0; index < 64; index = index + 1)
            posted_memory[index] = 0;
        repeat (3) @(posedge clk);
        reset = 0;

        // One legacy VRAM write followed by both inclusive GX endpoints must
        // share one sequence and preserve each write's execution timestamp.
        add_arm9_cycles(8'd11);
        issue_transaction(
            1, 0, 32'h0600c000, 2'b01, 32'h00001234, 1);
        add_arm9_cycles(8'd13);
        issue_transaction(
            1, 0, 32'h04000400, 2'b10, 32'h11112222, 1);
        add_arm9_cycles(8'd17);
        issue_transaction(
            1, 0, 32'h040005c8, 2'b10, 32'h33334444, 1);
        if (dut.posted_producer_sequence != 3)
            $fatal(1, "mixed VRAM/GX sequence did not reach three");
        verify_posted_entry(
            0, 1, 32'h0600c000, 32'h00001234, 11, 4'ha);
        verify_posted_entry(
            1, 2, 32'h04000400, 32'h11112222, 13, 4'hc);
        verify_posted_entry(
            2, 3, 32'h040005c8, 32'h33334444, 17, 4'hc);

        // The first following mailbox request is the common ordering fence.
        issue_transaction(
            0, 0, 32'h04000184, 2'b10, 32'h76543210, 0);
        if (mailbox_memory[1] !== 64'h7654321004000184 ||
            mailbox_memory[4][63:32] !== 32'd3 ||
            dut.mailbox_completed_fence !== 32'd3 ||
            dut.posted_write_ring.consumer_sequence !== 32'd3)
            $fatal(1,
                "mailbox overtook mixed posted sequence %h %h %h %h",
                mailbox_memory[1], mailbox_memory[4],
                dut.mailbox_completed_fence,
                dut.posted_write_ring.consumer_sequence);

        // Every scope edge stays authoritative: immediate neighbors, narrow
        // and unaligned accesses, ARM7 writes, and reads all use the mailbox.
        issue_transaction(
            1, 0, 32'h040003fc, 2'b10, 32'h00000001, 0);
        issue_transaction(
            1, 0, 32'h040005cc, 2'b10, 32'h00000002, 0);
        issue_transaction(
            1, 0, 32'h04000400, 2'b01, 32'h00000003, 0);
        issue_transaction(
            1, 0, 32'h04000402, 2'b10, 32'h00000004, 0);
        issue_transaction(
            0, 0, 32'h04000400, 2'b10, 32'h00000005, 0);
        issue_transaction(
            1, 1, 32'h04000400, 2'b10, 32'h00000000, 0);
        if (dut.posted_producer_sequence != 3 ||
            posted_ddr_writes != 9)
            $fatal(1, "rejected GX traffic escaped into posted ring");

        // Four more valid GX words exercise the existing posted-write IRQ
        // refresh cadence. The refresh itself must carry zero cycles and fence
        // the common sequence through seven before acknowledging ring space.
        mailboxes_before_refresh = mailbox_requests;
        issue_transaction(
            1, 0, 32'h04000440, 2'b10, 32'h44440001, 1);
        issue_transaction(
            1, 0, 32'h04000444, 2'b10, 32'h44440002, 1);
        issue_transaction(
            1, 0, 32'h04000448, 2'b10, 32'h44440003, 1);
        issue_transaction(
            1, 0, 32'h0400044c, 2'b10, 32'h44440004, 1);
        wait (mailbox_requests == mailboxes_before_refresh + 1);
        wait (!cpu_pause);
        repeat (3) @(posedge clk);
        if (mailbox_memory[1][31:0] !== 32'hffffffff ||
            mailbox_memory[2][63:32] !== 32'd0 ||
            mailbox_memory[4][63:32] !== 32'd7 ||
            dut.posted_producer_sequence !== 32'd7 ||
            dut.mailbox_completed_fence !== 32'd7 ||
            dut.posted_write_ring.consumer_sequence !== 32'd7)
            $fatal(1,
                "GX IRQ refresh lost timing/fence order %h %h %h seq=%0d ack=%0d/%0d",
                mailbox_memory[1], mailbox_memory[2], mailbox_memory[4],
                dut.posted_producer_sequence,
                dut.mailbox_completed_fence,
                dut.posted_write_ring.consumer_sequence);

        // A current-ABI sequence wrap must hang this one CPU transaction
        // fail-closed. In particular, admission must not reset its accumulated
        // execution cycles and no commit-zero/DDR/mailbox side effect is legal.
        @(negedge clk);
        dut.posted_write_ring.producer_sequence = 32'hffffffff;
        cycles_before_exhaustion = dut.accumulated9;
        add_arm9_cycles(8'd29);
        writes_before_exhaustion = posted_ddr_writes;
        mailboxes_before_exhaustion = mailbox_requests;
        @(negedge clk);
        cpu_is_arm9 = 1;
        read_not_write = 0;
        address = 32'h04000450;
        access = 2'b10;
        write_data = 32'hdeadc0de;
        request = 1;
        repeat (16) begin
            @(posedge clk);
            #1;
            if (done || dut.posted_accepted || dut.posted_done ||
                ddram_read || ddram_write || debug_oracle_request ||
                cpu_pause || dut.posted_write_ring.state != 0)
                $fatal(1,
                    "exhausted memory-system request had a side effect");
        end
        if (!dut.posted_sequence_exhausted ||
            dut.accumulated9 !== cycles_before_exhaustion + 29 ||
            posted_ddr_writes != writes_before_exhaustion ||
            mailbox_requests != mailboxes_before_exhaustion ||
            dut.posted_producer_sequence != 32'hffffffff)
            $fatal(1,
                "exhausted request reset cycles or published wrap cycles=%h/%h writes=%0d/%0d mailboxes=%0d/%0d",
                dut.accumulated9, cycles_before_exhaustion + 29,
                posted_ddr_writes, writes_before_exhaustion,
                mailbox_requests, mailboxes_before_exhaustion);
        @(negedge clk);
        request = 0;
        repeat (2) @(posedge clk);
        if (!dut.posted_sequence_exhausted)
            $fatal(1, "memory-system exhaustion diagnostic was not sticky");

        $display("PASS: default-off candidate posts only exact ARM9 aligned GX words into the existing ordered VRAM ring");
        $finish;
    end
endmodule
