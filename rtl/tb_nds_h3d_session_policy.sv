`timescale 1ns/1ps
module tb_nds_h3d_session_policy #(
    parameter bit ZERO_LATENCY = 1'b0
);
    localparam logic [28:0] BASE = 29'h00010000;
    localparam logic [63:0] HEADER = 64'h00800001_31443348;
    localparam logic [63:0] QUIESCE = 64'h00800001_51443348;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    logic cart_ready = 0, engine_b_select = 0;
    wire [31:0] requested_session;
    wire engine_b_pixels_enable;
    logic video_quiescent = 0;
    wire active, initialized, console_release, fault, diagnostic_hold;
    wire [31:0] active_session, fault_bits;
    wire [2:0] telemetry_index;
    wire ddram_read, ddram_write;
    wire [7:0] ddram_burst_count, ddram_byte_enable;
    wire [28:0] ddram_address;
    wire [63:0] ddram_write_data;
    logic [63:0] memory [0:127];
    logic queued = 0, queued_read = 0;
    logic [28:0] queued_address;
    logic [63:0] queued_data;
    logic [7:0] queued_be;
    integer accept_delay = 0, response_delay = 0;
    logic response_pending = 0;
    logic delayed_ready = 0;
    logic [63:0] response_data, delayed_data;
    integer cycles = 0, reads = 0, writes = 0;
    logic [31:0] random_state = 32'h73657276;
    logic expect_immutable_fault = 0;
    wire ddram_busy = queued || response_pending ||
        delayed_ready || random_state[2:0] == 3'd0;
    wire ddram_command_accepted = queued && accept_delay == 0;
    wire immediate_ready = ZERO_LATENCY &&
        ddram_command_accepted && queued_read;
    wire ddram_read_data_ready = delayed_ready || immediate_ready;
    wire [63:0] ddram_read_data = immediate_ready ?
        memory[queued_address - BASE] : delayed_data;

    nds_h3d_session_policy_latch latch (
        .clk, .reset, .cart_ready, .engine_b_select,
        .session_trigger(requested_session),
        .engine_b_applied(engine_b_pixels_enable), .cart_ready_rise()
    );
    nds_h3d_control_init #(
        .BASE_WORD(BASE), .ENTRY_COUNT(8), .PACKET_MODE(1),
        .SESSION_POLICY_ENABLE(1),
        .HPS_HEARTBEAT_TIMEOUT_CYCLES(100000)
    ) dut (
        .clk, .reset, .requested_session, .engine_b_pixels_enable,
        .video_quiescent, .external_fault_bits(32'd0),
        .fpga_heartbeat_value(32'd0), .fpga_telemetry_value(32'd0),
        .telemetry_index, .diagnostic_hold, .active, .initialized,
        .console_release, .active_session, .fault, .fault_bits,
        .ddram_read, .ddram_write, .ddram_burst_count, .ddram_address,
        .ddram_write_data, .ddram_byte_enable, .ddram_busy,
        .ddram_command_accepted, .ddram_read_data, .ddram_read_data_ready
    );

    // A registered arbiter with physical backpressure and delayed read data.
    // Intentionally NOT reset with the client: a reset must tolerate old
    // queued/accepted traffic draining before the next epoch can acquire DDR.
    always @(posedge clk) begin
        cycles <= cycles + 1;
        random_state <= {random_state[30:0], random_state[31] ^
            random_state[21] ^ random_state[1] ^ random_state[0]};
        delayed_ready <= 0;
        if (response_pending) begin
            if (response_delay == 0) begin
                response_pending <= 0;
                delayed_ready <= 1;
                delayed_data <= response_data;
            end else response_delay <= response_delay - 1;
        end
        if (queued) begin
            if (accept_delay != 0) accept_delay <= accept_delay - 1;
            else begin
                queued <= 0;
                if (queued_read) begin
                    reads <= reads + 1;
                    response_pending <= !ZERO_LATENCY;
                    response_delay <= 1 + int'(random_state[5:3]);
                    response_data <= memory[queued_address - BASE];
                end else begin
                    writes <= writes + 1;
                    for (integer b = 0; b < 8; b = b + 1)
                        if (queued_be[b])
                            memory[queued_address - BASE][8*b +: 8]
                                <= queued_data[8*b +: 8];
                    // Every new request must be committed before H3D1 is
                    // physically visible; no policy write while HPS owns it.
                    if (queued_address == BASE && queued_data == HEADER) begin
                        if (memory[96] != 64'h00200001_31503348 ||
                            memory[97] != {31'd0, engine_b_pixels_enable,
                                           active_session} ||
                            memory[98] != {32'd0, active_session} ||
                            memory[99] != {32'd0, active_session})
                            $fatal(1, "H3D1 published before exact policy");
                        for (integer a = 104; a < 108; a = a + 1)
                            if (memory[a] != 0)
                                $fatal(1, "old policy ACK was not cleared");
                    end
                    if ((queued_address >= BASE+96 &&
                         queued_address <= BASE+99) ||
                        (queued_address >= BASE+104 &&
                         queued_address <= BASE+107)) begin
                        if (memory[0] != QUIESCE ||
                            memory[15] != {32'd0, active_session} ||
                            !video_quiescent)
                            $fatal(1, "policy overwritten before quiescence");
                    end
                end
            end
        end
        if (ddram_read || ddram_write) begin
            if (ddram_busy || queued || (ddram_read && ddram_write) ||
                ddram_burst_count != 1 || ddram_address < BASE ||
                ddram_address >= BASE+128)
                $fatal(1, "invalid DDR queue handoff");
            queued <= 1;
            queued_read <= ddram_read;
            queued_address <= ddram_address;
            queued_data <= ddram_write_data;
            queued_be <= ddram_byte_enable;
            accept_delay <= 1 + int'(random_state[9:6]);
        end
        if (!reset && fault && !expect_immutable_fault)
            $fatal(1, "unexpected fault %h", fault_bits);
        if (console_release && (!dut.policy_acknowledged ||
            !initialized || active_session == 0))
            $fatal(1, "release without exact policy");
        if (cycles > 150000) $fatal(1, "watchdog");
    end

    task automatic closed_for(input integer count);
        repeat (count) begin
            @(negedge clk);
            if (console_release) $fatal(1, "false completion/release");
        end
    endtask
    task automatic await_quiesce(input logic [31:0] previous);
        integer timeout;
        begin
            timeout = 0;
            while (memory[0] != QUIESCE || active_session == previous) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 10000) $fatal(1, "no new quiesce epoch");
            end
        end
    endtask
    task automatic finish_init(input logic expected_b);
        integer timeout;
        begin
            @(negedge clk);
            memory[15] = {32'd0, active_session};
            video_quiescent = 1;
            timeout = 0;
            while (memory[0] != HEADER) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 10000) $fatal(1, "initialization stuck");
            end
            if (memory[97] != {31'd0, expected_b, active_session})
                $fatal(1, "pending menu applied at wrong boundary");
            memory[5] = {active_session, 32'd2};
        end
    endtask
    task automatic valid_ack;
        @(negedge clk);
        for (integer w = 0; w < 4; w = w + 1)
            memory[104+w] = memory[96+w];
    endtask
    task automatic await_release;
        integer timeout;
        begin
            timeout = 0;
            while (!console_release) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 10000) $fatal(1, "exact policy not accepted");
            end
        end
    endtask

    logic [31:0] previous;
    initial begin
        for (integer i = 0; i < 128; i = i + 1) memory[i] = 0;
        memory[14] = 64'd9;
        memory[96] = 64'h12345678;
        memory[107] = 64'd9;
        repeat (4) @(negedge clk);
        reset = 0;
        cart_ready = 1;
        await_quiesce(0);
        if (active_session != 10) $fatal(1, "persistent epoch not advanced");
        memory[15] = {32'd0, active_session};
        closed_for(700);
        if (memory[0] != QUIESCE || memory[96] != 64'h12345678)
            $fatal(1, "video drain barrier was bypassed");
        finish_init(0);
        closed_for(1000); // legacy host Ready alone is insufficient
        for (integer bad = 0; bad < 8; bad = bad + 1) begin
            valid_ack();
            memory[104 + bad/2][32*(bad%2) +: 32] =
                memory[104 + bad/2][32*(bad%2) +: 32] ^ 32'h00000010;
            closed_for(1000);
        end
        valid_ack();
        memory[105][63:32] = 1; // supported, but not the requested Off policy
        closed_for(1000);
        valid_ack();
        memory[107] = 0; // payload written, commit delayed
        closed_for(1000);
        valid_ack();
        await_release();
        previous = active_session;
        engine_b_select = 1;
        repeat (1000) @(negedge clk);
        if (!console_release || engine_b_pixels_enable ||
            active_session != previous || requested_session != 1)
            $fatal(1, "menu change caused live switching or reset");

        // HPS-only restart must keep applied Off despite pending On.
        video_quiescent = 0;
        memory[5] = {active_session, 32'd4};
        await_quiesce(previous);
        memory[15] = {32'd0, previous};
        closed_for(500);
        finish_init(0);
        valid_ack(); await_release();
        previous = active_session;

        // Explicit Reset while a control read is in flight. DDR owner drains.
        wait (ZERO_LATENCY ? (queued && queued_read) : response_pending);
        @(negedge clk); reset = 1; video_quiescent = 0;
        repeat (5) @(negedge clk);
        reset = 0;
        await_quiesce(previous);
        finish_init(1);
        valid_ack(); await_release();
        previous = active_session;
        if (!engine_b_pixels_enable) $fatal(1, "Reset did not apply On");

        // A new ROM snapshots Off only after the loader marks it ready.
        cart_ready = 0; engine_b_select = 0;
        repeat (100) @(negedge clk);
        if (!engine_b_pixels_enable || active_session != previous)
            $fatal(1, "partial load changed policy");
        cart_ready = 1; video_quiescent = 0;
        await_quiesce(previous);
        finish_init(0);
        valid_ack(); await_release();
        // A once-valid ACK is immutable. Corruption must require a new epoch,
        // never reset/release CPUs again against the existing host state.
        expect_immutable_fault = 1;
        memory[107] = 0;
        wait (fault);
        @(negedge clk);
        if (fault_bits != 1 || console_release)
            $fatal(1, "immutable ACK violation did not fail closed");
        valid_ack();
        closed_for(1000);
        if (!fault) $fatal(1, "immutable ACK fault was not sticky");
        $display("PASS H3P1 zero_latency=%0d default/pending/reset/load/restart, 8 malformed ACK fields, opposite policy, delayed commit, immutable ACK fault, video barrier, DDR stalls/drain: reads=%0d writes=%0d cycles=%0d", ZERO_LATENCY, reads, writes, cycles);
        $finish;
    end
endmodule
