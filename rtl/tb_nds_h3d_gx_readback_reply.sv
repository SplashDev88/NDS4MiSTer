`timescale 1ns/1ps

module tb_nds_h3d_gx_readback_reply #(
    parameter integer CLOCK_CASE = 0
);
    localparam logic [28:0] CONTROL_BASE = 29'h01f80000;
    localparam logic [28:0] REPLY_BASE = CONTROL_BASE + 29'd64;
    localparam integer REPLY_INDEX = 128;
    localparam integer SOURCE_HALF = CLOCK_CASE == 1 ? 5 : CLOCK_CASE == 2 ? 13 : 7;
    localparam integer DDR_HALF = CLOCK_CASE == 1 ? 11 : CLOCK_CASE == 2 ? 3 : 5;
    localparam integer DDR_PHASE = CLOCK_CASE == 1 ? 1 : CLOCK_CASE == 2 ? 0 : 2;
    logic source_clk = 0, ddr_clk = 0;
    always #(SOURCE_HALF) source_clk = !source_clk;
    initial begin
        #(DDR_PHASE);
        forever #(DDR_HALF) ddr_clk = !ddr_clk;
    end
    logic reset = 1, session_flush = 0;
    logic [31:0] session = 32'h5e551001;
    logic request_valid = 0;
    logic [31:0] request_id = 0;
    wire request_ready, response_valid, source_fault;
    wire [31:0] response_id, response_status;
    logic [4:0] read_index = 0;
    wire [31:0] read_data;
    wire ddram_read;
    wire [7:0] ddram_burst_count;
    wire [28:0] ddram_address;
    wire ddram_busy;
    logic ddram_command_accepted = 0;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;

    nds_h3d_gx_readback_reply dut (.*);

    // Physical transactions deliberately survive reader reset/flush. The
    // owner keeps busy asserted until stale data drains, like the product
    // adapter/fabric; no new command can inherit that old response.
    logic [31:0] memory [0:255];
    logic [31:0] expected_cache [0:31];
    integer txn_stage = 0, delay_left = 0;
    logic [28:0] queued_address = 0;
    logic force_busy = 0, immediate_response = 0;
    integer accept_delay = 4, data_delay = 6;
    integer handoffs = 0, accepts = 0, returned = 0;
    assign ddram_busy = force_busy || txn_stage != 0;

    always @(posedge ddr_clk) begin
        ddram_command_accepted <= 0;
        ddram_read_data_ready <= 0;
        case (txn_stage)
            0: if (ddram_read && !ddram_busy) begin
                if (ddram_burst_count !== 8'd1)
                    $fatal(1, "reply reader issued a non-single-beat request");
                if (ddram_address < REPLY_BASE || ddram_address > REPLY_BASE + 15)
                    $fatal(1, "reader touched unrelated control word %h", ddram_address);
                queued_address <= ddram_address;
                handoffs <= handoffs + 1;
                if (immediate_response) begin
                    ddram_command_accepted <= 1;
                    accepts <= accepts + 1;
                    ddram_read_data <= {
                        memory[2*(ddram_address-CONTROL_BASE)+1],
                        memory[2*(ddram_address-CONTROL_BASE)]};
                    ddram_read_data_ready <= 1;
                    returned <= returned + 1;
                    txn_stage <= 3;
                end else begin
                    delay_left <= accept_delay;
                    txn_stage <= 1;
                end
            end
            1: if (delay_left == 0) begin
                ddram_command_accepted <= 1;
                accepts <= accepts + 1;
                delay_left <= data_delay;
                txn_stage <= 2;
            end else delay_left <= delay_left - 1;
            2: if (delay_left == 0) begin
                ddram_read_data <= {
                    memory[2*(queued_address-CONTROL_BASE)+1],
                    memory[2*(queued_address-CONTROL_BASE)]};
                ddram_read_data_ready <= 1;
                returned <= returned + 1;
                txn_stage <= 3;
            end else delay_left <= delay_left - 1;
            3: txn_stage <= 0;
            default: $fatal(1, "bad DDR model state");
        endcase
    end

    logic previous_stalled = 0;
    logic [28:0] stalled_address;
    always @(posedge ddr_clk) begin
        if (reset || session_flush || dut.ddr_reset_local) begin
            previous_stalled <= 0;
        end else begin
            if (previous_stalled && (!ddram_read || ddram_address != stalled_address))
                $fatal(1, "request changed before busy handoff");
            previous_stalled <= ddram_read && ddram_busy;
            stalled_address <= ddram_address;
            if (dut.issued_command && ddram_read)
                $fatal(1, "queued request was presented twice before acceptance");
        end
    end

    integer responses = 0;
    logic permit_response = 0, previous_response = 0;
    logic [31:0] expected_response_id = 0, expected_status = 0;
    always @(posedge source_clk) begin
        #1;
        if (response_valid) begin
            if (previous_response) $fatal(1, "response_valid was not a single pulse");
            if (!permit_response) $fatal(1, "false/stale completion id=%h", response_id);
            if (response_id !== expected_response_id || response_status !== expected_status)
                $fatal(1, "wrong completion id/status %h/%h", response_id, response_status);
            responses = responses + 1;
            permit_response = 0;
        end
        previous_response = response_valid;
    end

    task automatic wait_ready;
        integer timeout;
        begin
            timeout = 0;
            while (!request_ready && timeout < 400) begin
                @(negedge source_clk);
                timeout = timeout + 1;
            end
            if (!request_ready) $fatal(1, "source never became ready");
        end
    endtask

    task automatic issue(input logic [31:0] id);
        begin
            wait_ready();
            @(negedge source_clk);
            request_id = id;
            expected_response_id = id;
            request_valid = 1;
            @(negedge source_clk);
            request_valid = 0;
            if (id != 0 && request_ready) $fatal(1, "request was not held outstanding");
        end
    endtask

    task automatic make_reply(input logic [31:0] reply_session,
                              input logic [31:0] id,
                              input logic [31:0] seed,
                              input logic publish);
        integer i;
        begin
            memory[REPLY_INDEX+30] = 0;
            for (i = 0; i < 32; i = i + 1)
                if (i != 30) memory[REPLY_INDEX+i] = seed + 32'(i);
            memory[REPLY_INDEX] = 32'h31523348;
            memory[REPLY_INDEX+1] = reply_session;
            memory[REPLY_INDEX+2] = id;
            memory[REPLY_INDEX+3] = 0;
            memory[REPLY_INDEX+31] = 0;
            if (publish) memory[REPLY_INDEX+30] = id;
        end
    endtask

    task automatic allow_current_reply;
        integer i;
        begin
            expected_status = memory[REPLY_INDEX+4];
            for (i = 0; i < 32; i = i + 1)
                expected_cache[i] = memory[REPLY_INDEX+i];
            permit_response = 1;
        end
    endtask

    task automatic await_response(input integer target);
        integer timeout;
        begin
            timeout = 0;
            while (responses < target && timeout < 4000) begin
                @(negedge source_clk);
                timeout = timeout + 1;
                if (source_fault) $fatal(1, "unexpected source fault waiting for reply");
            end
            if (responses != target) $fatal(1, "reply never completed");
        end
    endtask

    task automatic check_cache;
        integer i;
        logic [31:0] old_read_data;
        begin
            for (i = 0; i < 32; i = i + 1) begin
                @(negedge source_clk);
                old_read_data = read_data;
                read_index = 5'(i);
                #1;
                if (read_data !== old_read_data)
                    $fatal(1, "cache read was asynchronous");
                @(posedge source_clk);
                #2;
                if (read_data !== expected_cache[i])
                    $fatal(1, "cache[%0d]=%h expected %h", i, read_data, expected_cache[i]);
            end
        end
    endtask

    task automatic no_completion(input integer clocks);
        integer before_count;
        begin
            before_count = responses;
            repeat (clocks) @(negedge ddr_clk);
            if (responses != before_count || source_fault)
                $fatal(1, "stale reply caused completion/fault");
        end
    endtask

    task automatic cancel_epoch(input logic flush);
        begin
            permit_response = 0;
            #3;
            if (flush) session_flush = 1;
            else reset = 1;
            repeat (5) @(negedge source_clk);
            if (response_valid || source_fault || request_ready || ddram_read)
                $fatal(1, "reset/flush did not cancel outputs");
            session = session + 1;
            if (flush) session_flush = 0;
            else reset = 0;
            wait_ready();
        end
    endtask

    integer i, saved_handoffs, fault_case;
    initial begin
        for (i = 0; i < 256; i = i + 1) memory[i] = 32'hcafe0000 + 32'(i);
        make_reply(session, 0, 32'h11000000, 0);
        repeat (6) @(negedge source_clk);
        reset = 0;
        wait_ready();
        no_completion(20);

        // Delayed publication, held request/backpressure, old session, stale
        // commit, and matching commit with a different header request ID.
        force_busy = 1;
        issue(32'd11);
        wait (ddram_read);
        saved_handoffs = handoffs;
        no_completion(25);
        if (handoffs != saved_handoffs || ddram_address != REPLY_BASE)
            $fatal(1, "busy request was not held at initial session address");
        force_busy = 0;
        no_completion(100);
        make_reply(session-1, 32'd11, 32'h22000000, 1);
        no_completion(750);
        make_reply(session, 32'd10, 32'h33000000, 1);
        no_completion(100);
        memory[REPLY_INDEX+30] = 11;
        no_completion(750);
        make_reply(session, 32'd11, 32'h44000000, 1);
        allow_current_reply();
        await_response(1);
        check_cache();
        saved_handoffs = handoffs;
        make_reply(session, 32'd99, 32'h55000000, 1);
        check_cache();
        no_completion(70);
        if (handoffs != saved_handoffs) $fatal(1, "cache idle owner kept polling DDR");

        // The matching commit must remain valid through the final re-read.
        // Withdraw it only after the in-cache commit has already been read.
        immediate_response = 1;
        issue(32'd12);
        make_reply(session, 32'd12, 32'h66000000, 1);
        wait (dut.state == 4 && dut.beat_index == 15);
        @(negedge ddr_clk);
        memory[REPLY_INDEX+30] = 0;
        no_completion(100);
        make_reply(session, 32'd12, 32'h77000000, 0);
        no_completion(40);
        memory[REPLY_INDEX+30] = 12;
        allow_current_reply();
        await_response(2);
        check_cache();
        immediate_response = 0;

        // Reset while waiting for physical acceptance, with that old command
        // still alive. Reusing an ID in a NEW session must reject the old page.
        accept_delay = 65;
        issue(32'd21);
        make_reply(session, 32'd21, 32'h88000000, 1);
        wait (txn_stage == 1);
        cancel_epoch(0);
        issue(32'd21);
        accept_delay = 2;
        no_completion(750);
        make_reply(session, 32'd21, 32'h99000000, 1);
        allow_current_reply();
        await_response(3);
        check_cache();

        // Reset in the response wait for a cache-fill read (not just a poll).
        issue(32'd22);
        make_reply(session, 32'd22, 32'haa000000, 1);
        data_delay = 45;
        wait (txn_stage == 2 && queued_address == REPLY_BASE + 4);
        cancel_epoch(0);
        data_delay = 2;
        issue(32'd22);
        no_completion(650);
        make_reply(session, 32'd22, 32'hbb000000, 1);
        allow_current_reply();
        await_response(4);
        check_cache();

        // Session flush also aborts partial RAM filling and suppresses the
        // old completion while the adapter drains the previous transaction.
        issue(32'd23);
        make_reply(session, 32'd23, 32'hcc000000, 1);
        data_delay = 50;
        wait (txn_stage == 2 && queued_address == REPLY_BASE + 7);
        cancel_epoch(1);
        data_delay = 3;
        issue(32'd23);
        no_completion(650);
        make_reply(session, 32'd23, 32'hdd000000, 1);
        allow_current_reply();
        await_response(5);
        check_cache();

        // Stable malformed data for our exact tag fails closed. A repaired
        // page alone does not clear the fault; reset/flush is mandatory.
        immediate_response = 1;
        for (fault_case = 0; fault_case < 3; fault_case = fault_case + 1) begin
            issue(32'd40 + 32'(fault_case));
            make_reply(session, request_id, 32'hee000000, 1);
            case (fault_case)
                0: memory[REPLY_INDEX+3] = 1;
                1: memory[REPLY_INDEX] = 32'hffffffff;
                2: memory[REPLY_INDEX+31] = 1;
            endcase
            wait (source_fault);
            make_reply(session, request_id, 32'hef000000, 1);
            repeat (60) @(negedge source_clk);
            if (!source_fault || request_ready || response_valid)
                $fatal(1, "malformed reply did not fail closed");
            cancel_epoch(1);
        end

        issue(0);
        repeat (4) @(negedge source_clk);
        if (!source_fault) $fatal(1, "zero request ID was accepted");
        cancel_epoch(1);
        issue(32'd60);
        make_reply(session, 32'd60, 32'hf0000000, 1);
        allow_current_reply();
        await_response(6);
        check_cache();

        for (i = 0; i < 256; i = i + 1)
            if ((i < REPLY_INDEX || i >= REPLY_INDEX+32) &&
                memory[i] !== 32'hcafe0000 + 32'(i))
                $fatal(1, "unrelated control word changed at %0d", i);
        if (handoffs != accepts || accepts != returned)
            $fatal(1, "unbalanced handoffs/acceptances/responses: %0d/%0d/%0d",
                handoffs, accepts, returned);
        $display("PASS: GX reply CDC, tag/commit validation, held DDR handoff, delayed/simultaneous response, cache ownership, reset/flush, malformed reply (clock case %0d, %0d DDR reads)", CLOCK_CASE, handoffs);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "GX reply test watchdog");
    end
endmodule
