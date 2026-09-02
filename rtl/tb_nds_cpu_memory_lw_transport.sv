`timescale 1ns/1ps
// Integrated transport test: real CPU-memory whitelist -> posted DDR ring ->
// commit-qualified LW doorbell -> validated HPS acknowledgement -> ring credit.
// It deliberately holds a postable CPU request across an unarmed/reset
// session and injects deterministic DDR stalls.
module tb_nds_cpu_memory_lw_transport;
    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7 = 29'h001a0000;
    localparam logic [28:0] ORACLE = 29'h00200000;
    localparam logic [28:0] POSTED = 29'h00300000;

    logic clk = 0;
    logic reset = 1;
    logic transport_reset = 1;
    always #5 clk = ~clk;

    logic request = 0;
    logic cpu_is_arm9 = 1;
    logic [7:0] arm9_cycles = 0, arm7_cycles = 0;
    logic arm9_cycles_valid = 0, arm7_cycles_valid = 0;
    logic [31:0] address = 32'h0600c000;
    logic read_not_write = 0;
    logic [1:0] access = 2'b01;
    logic [31:0] write_data = 0;
    logic [31:0] read_data;
    logic done, irq_arm9, irq_arm7, halt_arm9, halt_arm7, cpu_pause;
    logic debug_oracle_request, debug_mailbox_request, debug_mailbox_done;
    logic [3:0] debug_mailbox_state;
    logic [1:0] debug_tick_state;

    logic [18:0] lw_reg_raddr = 0, lw_reg_waddr = 0;
    logic [31:0] lw_reg_rdata, lw_reg_wdata = 0;
    logic [3:0] lw_reg_be = 4'hf;
    logic lw_reg_write = 0;
    logic lw_request_pending_irq;

    logic ddram_read, ddram_write;
    logic [7:0] ddram_burst_count, ddram_byte_enable;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic ddram_busy = 0;
    logic ddram_command_accepted;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;

    logic [63:0] posted_memory [0:63];
    logic [7:0] stall_lfsr = 8'h5a;
    integer physical_writes = 0;
    integer commit_writes = 0;
    integer errors = 0;

    assign ddram_command_accepted =
        (ddram_read || ddram_write) && !ddram_busy;

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7),
        .ORACLE_BASE_WORD(ORACLE),
        .POSTED_RING_BASE_WORD(POSTED),
        .TIME_FLUSH_CYCLES(32'h7fffffff),
        .HALT_POLL_CLOCKS(32'h7fffffff),
        .GX_POSTED_ENABLE(1),
        .LW_MAILBOX_ENABLE(1)
    ) dut (
        .clk, .reset, .transport_reset, .request, .cpu_is_arm9,
        .arm9_cycles, .arm9_cycles_valid,
        .arm7_cycles, .arm7_cycles_valid,
        .arm9_debug_pc(32'h02001000),
        .arm7_debug_pc(32'h037f8000),
        .request_debug_pc(32'h02001000),
        .arm9_dtcm_region(32'h0300000a),
        .arm9_dtcm_enable(1'b1),
        .arm9_dtcm_seed_valid(1'b1),
        .arm9_dtcm_irq_vector(32'h01ffd5ec),
        .address, .read_not_write, .access, .write_data,
        .read_data, .done, .irq_arm9, .irq_arm7,
        .halt_arm9, .halt_arm7, .cpu_pause,
        .debug_oracle_request, .debug_mailbox_request,
        .debug_mailbox_done, .debug_mailbox_state,
        .lw_reg_raddr, .lw_reg_rdata,
        .lw_reg_waddr, .lw_reg_wdata, .lw_reg_be, .lw_reg_write,
        .lw_request_pending_irq, .debug_tick_state,
        .ddram_read, .ddram_write, .ddram_burst_count,
        .ddram_address, .ddram_write_data, .ddram_byte_enable,
        .ddram_busy, .ddram_command_accepted,
        .ddram_read_data, .ddram_read_data_ready
    );

    always_ff @(posedge clk) begin
        stall_lfsr <= {stall_lfsr[6:0],
                       stall_lfsr[7] ^ stall_lfsr[5] ^
                       stall_lfsr[4] ^ stall_lfsr[3]};
        ddram_busy <= stall_lfsr[0] & stall_lfsr[3];
        ddram_read_data_ready <= 0;
        if (ddram_command_accepted && ddram_write) begin
            if (ddram_address < POSTED || ddram_address >= POSTED + 64)
                $fatal(1, "posted transport wrote outside ring: %h",
                       ddram_address);
            posted_memory[ddram_address - POSTED] <= ddram_write_data;
            physical_writes <= physical_writes + 1;
            if ((ddram_address - POSTED) >= 8 &&
                ((ddram_address - POSTED - 8) % 3) == 2)
                commit_writes <= commit_writes + 1;
        end
        if (ddram_command_accepted && ddram_read) begin
            if (ddram_address != POSTED + 1)
                $fatal(1, "unexpected ring header read: %h", ddram_address);
            ddram_read_data <= posted_memory[1];
            ddram_read_data_ready <= 1;
        end

        // Once a producer sequence exists, its IRQ may only appear after the
        // same number of physical commit-marker writes have been accepted.
        if (lw_request_pending_irq &&
            dut.posted_producer_sequence != 0 &&
            commit_writes < dut.posted_producer_sequence)
            $fatal(1, "doorbell preceded physical DDR commit visibility");
    end

    task automatic lw_write(
        input logic [18:0] word_address,
        input logic [31:0] value
    );
        begin
            @(negedge clk);
            lw_reg_waddr = word_address;
            lw_reg_wdata = value;
            lw_reg_be = 4'hf;
            lw_reg_write = 1;
            @(negedge clk);
            lw_reg_write = 0;
        end
    endtask

    task automatic check_lw(
        input logic [18:0] word_address,
        input logic [31:0] expected,
        input string label
    );
        begin
            lw_reg_raddr = word_address;
            #1;
            if (lw_reg_rdata !== expected) begin
                $display("FAIL %s: got=%08x expected=%08x",
                         label, lw_reg_rdata, expected);
                errors = errors + 1;
            end
        end
    endtask

    task automatic issue_posted(
        input logic [31:0] bus_address,
        input logic [31:0] bus_data
    );
        integer guard;
        begin
            @(negedge clk);
            address = bus_address;
            write_data = bus_data;
            request = 1;
            guard = 0;
            while (!done && guard < 300) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (!done) $fatal(1, "posted request timed out");
            @(negedge clk);
            request = 0;
            wait (!dut.posted_active);
        end
    endtask

    task automatic pulse_reset;
        begin
            @(negedge clk); reset = 1; transport_reset = 1;
            repeat (3) @(negedge clk);
            reset = 0; transport_reset = 0;
            repeat (3) @(negedge clk);
        end
    endtask

    integer index;
    integer writes_before;
    initial begin
        for (index = 0; index < 64; index = index + 1)
            posted_memory[index] = 0;
        repeat (4) @(negedge clk);

        // Reproduce MiSTer startup ordering: the CPU/TCM reset remains held
        // by the sound supervisor while the transport reset is released so
        // HPS can arm its session before publishing the boot descriptor.
        transport_reset = 0;
        repeat (3) @(negedge clk);
        check_lw(19'hb, 32'h4e445332, "ABI while CPU reset is held");
        check_lw(19'h17, 32'h0000000f,
                 "VRAM/GX/epoch/two-phase capabilities");
        check_lw(19'ha, 32'h11, "session required while CPU reset is held");
        lw_write(19'hc, 32'h10203040);
        repeat (2) @(negedge clk);
        check_lw(19'hc, 32'h10203040,
                 "session claims before CPU reset release");
        check_lw(19'h18, 32'h0, "claim remains disarmed before DDR init");
        check_lw(19'ha, 32'h11,
                 "claim alone keeps startup doorbell asserted");
        lw_write(19'h18, 32'h10203040);
        repeat (2) @(negedge clk);
        check_lw(19'h18, 32'h10203040,
                 "matching arm completes startup session");
        check_lw(19'ha, 32'h0,
                 "armed idle transport clears startup doorbell");
        if (reset !== 1'b1)
            $fatal(1, "CPU reset unexpectedly released during session arm");

        // Begin the functional test from a second clean session so the held
        // unarmed-request case below remains covered too.
        transport_reset = 1;
        repeat (3) @(negedge clk);
        transport_reset = 0;
        reset = 0;
        repeat (3) @(negedge clk);

        check_lw(19'hb, 32'h4e445332, "ABI identity");
        check_lw(19'h17, 32'h0000000f, "capability forwarding");
        check_lw(19'ha, 32'h11, "fresh session requires initialization");
        if (!lw_request_pending_irq)
            $fatal(1, "fresh session did not request HPS initialization");

        // A postable request held before the handshake must stall without any
        // ring write, then resume automatically after HPS installs the cookie.
        writes_before = physical_writes;
        @(negedge clk);
        write_data = 32'h00001234;
        request = 1;
        repeat (12) begin
            @(posedge clk); #1;
            if (done || physical_writes != writes_before)
                $fatal(1, "unarmed session admitted posted write");
        end
        lw_write(19'hc, 32'h13579bdf);
        repeat (12) begin
            @(posedge clk); #1;
            if (done || physical_writes != writes_before)
                $fatal(1, "SESSION claim admitted held posted write before ARM");
        end
        check_lw(19'ha, 32'h11,
                 "claimed held request remains transport-not-ready");
        lw_write(19'h18, 32'h13579bdf);
        begin : wait_first_done
            integer guard;
            guard = 0;
            while (!done && guard < 300) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (!done) $fatal(1, "armed held request did not resume");
        end
        @(negedge clk); request = 0;
        wait (!dut.posted_active);
        wait (lw_request_pending_irq);
        check_lw(19'h8, 32'd1, "first committed producer");
        if (physical_writes != writes_before + 3 || commit_writes != 1)
            $fatal(1, "first entry did not commit in exactly three writes");
        if (posted_memory[10] !== 64'h13579bdf00000001)
            $fatal(1, "first NDS2 commit omitted session epoch: %h",
                   posted_memory[10]);
        lw_write(19'h9, 32'd1);
        repeat (3) @(negedge clk);
        if (lw_request_pending_irq)
            $fatal(1, "validated ACK did not clear level IRQ");
        if (dut.posted_write_ring.consumer_sequence != 1)
            $fatal(1, "validated ACK did not advance ring credit");

        // Coalesce two completed entries under one level and acknowledge only
        // after both are actually committed.
        issue_posted(32'h0600c002, 32'h00005678);
        issue_posted(32'h0600c004, 32'h00009abc);
        check_lw(19'h8, 32'd3, "coalesced producer");
        check_lw(19'h9, 32'd1, "consumer remains behind");
        if (!lw_request_pending_irq || commit_writes != 3)
            $fatal(1, "coalesced work lost its level IRQ");
        lw_write(19'h9, 32'd3);
        repeat (3) @(negedge clk);
        if (lw_request_pending_irq ||
            dut.posted_write_ring.consumer_sequence != 3)
            $fatal(1, "coalesced ACK did not retire exact work");

        // A future credit is a protocol fault. It must revoke the session and
        // prevent any later whitelisted request from writing DDR or completing
        // until reset establishes a fresh session.
        lw_write(19'h9, 32'd4);
        repeat (3) @(negedge clk);
        check_lw(19'ha, 32'h13, "future ACK fail-stop doorbell");
        if (dut.lw_transport_ready)
            $fatal(1, "future ACK did not revoke transport admission");
        writes_before = physical_writes;
        @(negedge clk);
        address = 32'h0600c006;
        write_data = 32'h0000def0;
        request = 1;
        repeat (12) begin
            @(posedge clk); #1;
            if (done || physical_writes != writes_before)
                $fatal(1, "protocol fault admitted a later posted write");
        end
        @(negedge clk);
        request = 0;

        // Runtime reset invalidates both sides. Posting remains blocked until
        // a new HPS session cookie is installed, then sequence restarts at one.
        pulse_reset();
        check_lw(19'h8, 32'd0, "reset producer");
        check_lw(19'h9, 32'd0, "reset consumer");
        check_lw(19'ha, 32'h11, "reset requires new session");
        writes_before = physical_writes;
        @(negedge clk);
        address = 32'h0600c006;
        write_data = 32'h0000def0;
        request = 1;
        repeat (10) @(posedge clk);
        if (physical_writes != writes_before || done)
            $fatal(1, "post-reset request bypassed session gate");
        lw_write(19'hc, 32'h2468ace0);
        repeat (8) @(posedge clk);
        if (physical_writes != writes_before || done)
            $fatal(1, "post-reset claim bypassed ARM gate");
        lw_write(19'h18, 32'h2468ace0);
        begin : wait_reset_done
            integer guard;
            guard = 0;
            while (!done && guard < 300) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (!done) $fatal(1, "post-reset rearm did not resume request");
        end
        @(negedge clk); request = 0;
        wait (!dut.posted_active);
        check_lw(19'h8, 32'd1, "new session producer restarted");
        if (posted_memory[10] !== 64'h2468ace000000001)
            $fatal(1, "new session reused stale commit epoch: %h",
                   posted_memory[10]);

        if (errors == 0)
            $display("PASS: NDS2 claim/arm gate, capability forwarding, epoch-tagged commit, fail-stop faults, coalescing, reset, and validated ring credit");
        else
            $fatal(1, "integrated LW transport errors=%0d", errors);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "integrated LW transport timeout");
    end
endmodule
