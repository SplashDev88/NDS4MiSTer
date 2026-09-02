`timescale 1ns/1ps

module tb_nds_cpu_memory_math_local;
    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7 = 29'h001a0000;
    localparam logic [28:0] ORACLE = 29'h00200000;

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic request = 1'b0;
    logic cpu_is_arm9 = 1'b1;
    logic [7:0] arm9_cycles = 8'd0;
    logic arm9_cycles_valid = 1'b0;
    logic [7:0] arm7_cycles = 8'd0;
    logic arm7_cycles_valid = 1'b0;
    logic [31:0] address = 32'd0;
    logic read_not_write = 1'b1;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = 32'd0;
    logic [31:0] read_data;
    logic done;
    logic irq_arm9;
    logic irq_arm7;
    logic halt_arm9;
    logic halt_arm7;
    logic cpu_pause;
    logic debug_oracle_request;
    logic debug_mailbox_request;
    logic debug_mailbox_done;
    logic [3:0] debug_mailbox_state;
    logic [1:0] debug_tick_state;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy = 1'b0;
    logic ddram_command_accepted;
    logic [63:0] ddram_read_data = 64'd0;
    logic ddram_read_data_ready = 1'b0;

    logic [63:0] oracle_mem [0:4];
    logic [31:0] response_data = 32'hfeedc0de;
    logic [31:0] response_flags = 32'd0;
    integer response_remaining = 0;
    integer oracle_payload_writes = 0;
    integer oracle_total_writes = 0;
    integer timing_requests = 0;

    logic [18:0] lw_reg_raddr = 19'd0;
    logic [31:0] lw_reg_rdata;
    logic [18:0] lw_reg_waddr = 19'd0;
    logic [31:0] lw_reg_wdata = 32'd0;
    logic [3:0] lw_reg_be = 4'd0;
    logic lw_reg_write = 1'b0;
    logic lw_request_pending_irq;

    wire [31:0] request_debug_pc = cpu_is_arm9
        ? 32'h02001000 : 32'h037f8100;
    assign ddram_command_accepted =
        (ddram_read || ddram_write) && !ddram_busy;

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7),
        .ORACLE_BASE_WORD(ORACLE),
        .ORACLE_POLL_DELAY_CYCLES(1),
        .TIME_FLUSH_CYCLES(16),
        .HALT_POLL_CLOCKS(1024),
        .ARM9_MATH_LOCAL_ENABLE(1)
    ) dut (
        .clk(clk),
        .reset(reset),
        .transport_reset(reset),
        .request(request),
        .cpu_is_arm9(cpu_is_arm9),
        .arm9_cycles(arm9_cycles),
        .arm9_cycles_valid(arm9_cycles_valid),
        .arm7_cycles(arm7_cycles),
        .arm7_cycles_valid(arm7_cycles_valid),
        .arm9_debug_pc(32'h02001000),
        .arm7_debug_pc(32'h037f8100),
        .request_debug_pc(request_debug_pc),
        .arm9_dtcm_region(32'h0300000a),
        .arm9_dtcm_enable(1'b1),
        .arm9_dtcm_seed_valid(1'b0),
        .arm9_dtcm_irq_vector(32'h01ffd5ec),
        .address(address),
        .read_not_write(read_not_write),
        .access(access),
        .write_data(write_data),
        .read_data(read_data),
        .done(done),
        .irq_arm9(irq_arm9),
        .irq_arm7(irq_arm7),
        .halt_arm9(halt_arm9),
        .halt_arm7(halt_arm7),
        .cpu_pause(cpu_pause),
        .debug_oracle_request(debug_oracle_request),
        .debug_mailbox_request(debug_mailbox_request),
        .debug_mailbox_done(debug_mailbox_done),
        .debug_mailbox_state(debug_mailbox_state),
        .lw_reg_raddr(lw_reg_raddr),
        .lw_reg_rdata(lw_reg_rdata),
        .lw_reg_waddr(lw_reg_waddr),
        .lw_reg_wdata(lw_reg_wdata),
        .lw_reg_be(lw_reg_be),
        .lw_reg_write(lw_reg_write),
        .lw_request_pending_irq(lw_request_pending_irq),
        .debug_tick_state(debug_tick_state),
        .ddram_read(ddram_read),
        .ddram_write(ddram_write),
        .ddram_burst_count(ddram_burst_count),
        .ddram_address(ddram_address),
        .ddram_write_data(ddram_write_data),
        .ddram_byte_enable(ddram_byte_enable),
        .ddram_busy(ddram_busy),
        .ddram_command_accepted(ddram_command_accepted),
        .ddram_read_data(ddram_read_data),
        .ddram_read_data_ready(ddram_read_data_ready)
    );

    always_ff @(posedge clk) begin
        ddram_read_data_ready <= 1'b0;
        if (ddram_write && ddram_address >= ORACLE &&
            ddram_address <= ORACLE + 4) begin
            oracle_mem[ddram_address - ORACLE] <= ddram_write_data;
            oracle_total_writes <= oracle_total_writes + 1;
            if (ddram_address == ORACLE + 1) begin
                if (ddram_write_data[31:0] == 32'hffffffff)
                    timing_requests <= timing_requests + 1;
                else
                    oracle_payload_writes <= oracle_payload_writes + 1;
            end
        end

        if (ddram_read) begin
            ddram_read_data_ready <= 1'b1;
            if (ddram_address == ORACLE + 3) begin
                response_remaining <= 1;
                ddram_read_data <= {oracle_mem[0][63:32], response_data};
            end else begin
                ddram_read_data <= 64'd0;
            end
        end else if (response_remaining != 0) begin
            ddram_read_data_ready <= 1'b1;
            response_remaining <= 0;
            ddram_read_data <= {32'd0, response_flags};
        end
    end

    task automatic finish_request;
        begin
            // Keep request asserted through the edge on which the CPU would
            // sample done. This also lets the timing-flush detector observe
            // a registered local completion exactly as the real bridge does.
            @(posedge clk);
            @(negedge clk);
            request = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        integer writes_before;
        integer payloads_before;
        integer timing_before;

        for (integer index = 0; index < 5; index = index + 1)
            oracle_mem[index] = 64'd0;
        repeat (3) @(posedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);

        // Enabled ARM9 math writes complete locally and never launch either
        // the router/oracle or a physical DDR mailbox command.
        writes_before = oracle_total_writes;
        @(negedge clk);
        cpu_is_arm9 = 1'b1;
        address = 32'h04000290;
        read_not_write = 1'b0;
        access = 2'b10;
        write_data = 32'h11223344;
        request = 1'b1;
        wait (done);
        #1;
        if (dut.router.request || debug_oracle_request || cpu_pause ||
            ddram_read || ddram_write || oracle_total_writes != writes_before)
            $fatal(1, "ARM9 math write escaped local path");
        finish_request();

        // Reads use the local result/data mux as well, proving that excluding
        // the request from the router does not lose completion or read data.
        writes_before = oracle_total_writes;
        @(negedge clk);
        read_not_write = 1'b1;
        request = 1'b1;
        wait (done);
        #1;
        if (read_data !== 32'h11223344 || dut.router.request ||
            debug_oracle_request || cpu_pause ||
            oracle_total_writes != writes_before)
            $fatal(1, "ARM9 math read was not local data=%h", read_data);
        finish_request();

        // The exact same address from ARM7 is not selected by the local unit.
        payloads_before = oracle_payload_writes;
        @(negedge clk);
        cpu_is_arm9 = 1'b0;
        address = 32'h04000290;
        read_not_write = 1'b1;
        request = 1'b1;
        wait (debug_oracle_request && cpu_pause);
        wait (done);
        #1;
        if (read_data !== response_data ||
            oracle_payload_writes != payloads_before + 1)
            $fatal(1, "ARM7 math address bypassed oracle data=%h writes=%0d",
                read_data, oracle_payload_writes - payloads_before);
        finish_request();

        // Undefined holes in the DIV/SQRT aperture remain authoritative HPS
        // accesses even for ARM9; the local decoder must not swallow them.
        payloads_before = oracle_payload_writes;
        @(negedge clk);
        cpu_is_arm9 = 1'b1;
        address = 32'h04000284;
        request = 1'b1;
        wait (debug_oracle_request && cpu_pause);
        wait (done);
        #1;
        if (read_data !== response_data ||
            oracle_payload_writes != payloads_before + 1)
            $fatal(1, "ARM9 math hole did not use oracle");
        finish_request();

        // A local math completion remains a normal local completion for the
        // existing scheduler: accumulated ARM9 time must still flush to HPS.
        @(negedge clk);
        arm9_cycles = 8'd16;
        arm9_cycles_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        arm9_cycles_valid = 1'b0;
        arm9_cycles = 8'd0;

        timing_before = timing_requests;
        @(negedge clk);
        address = 32'h04000290;
        read_not_write = 1'b1;
        request = 1'b1;
        wait (done);
        #1;
        // cpu_pause may assert on this completion because the purpose of the
        // transaction is to cross the timing threshold. It must be the tick,
        // never an oracle route for the math read itself.
        if (dut.router.request || debug_oracle_request ||
            read_data !== 32'h11223344)
            $fatal(1, "timed ARM9 math read was not local oracle=%b data=%h done=%b tick=%0d",
                debug_oracle_request, read_data, done, debug_tick_state);
        finish_request();
        wait (cpu_pause);
        wait (timing_requests == timing_before + 1);
        wait (!cpu_pause);
        repeat (2) @(posedge clk);
        if (oracle_mem[1][31:0] !== 32'hffffffff ||
            oracle_mem[2][63:32] !== 32'd16 || !oracle_mem[2][3])
            $fatal(1, "local math completion lost timing flush %h %h",
                oracle_mem[1], oracle_mem[2]);

        $display("PASS: enabled ARM9 DIV/SQRT is local; ARM7/holes stay oracle; timing flush remains");
        $finish;
    end
endmodule
