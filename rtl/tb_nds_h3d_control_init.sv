module tb_nds_h3d_control_init #(
    parameter integer ENTRY_COUNT = 8,
    parameter bit PACKET_MODE = 1'b0
);
    localparam logic [28:0] BASE = 29'h00370000;
    localparam integer HEADER_WORDS64 = 16;
    localparam integer MEMORY_WORDS = HEADER_WORDS64 + ENTRY_COUNT * 4;
    localparam logic [63:0] VALID_HEADER =
        {16'd128, 16'd1, 32'h31443348};
    localparam logic [63:0] QUIESCE_HEADER =
        {16'd128, 16'd1, 32'h51443348};
    localparam logic [31:0] CONFIG_HIGH =
        PACKET_MODE ? 32'd0 : 32'(ENTRY_COUNT);
    localparam integer COMMIT_CLEAR_WRITES =
        PACKET_MODE ? 0 : ENTRY_COUNT;
    localparam integer CONFIG_WRITE_INDEX = 15 + COMMIT_CLEAR_WRITES;
    localparam integer MAGIC_WRITE_INDEX = 16 + COMMIT_CLEAR_WRITES;
    localparam integer INITIALIZATION_WRITE_COUNT =
        17 + COMMIT_CLEAR_WRITES;
    localparam logic [3:0] STATE_READ_QUIESCE_ACK_ISSUE = 4'd5;
    localparam logic [3:0] STATE_READ_QUIESCE_ACK_WAIT = 4'd6;
    localparam logic [3:0] STATE_FAULT_HOLD = 4'd14;

    logic clk = 0;
    logic reset = 1;
    logic [31:0] requested_session = 0;
    logic [31:0] external_fault_bits = 0;
    logic [31:0] fpga_heartbeat_value = 32'h12345678;
    logic [31:0] fpga_telemetry_value = 32'h89abcdef;
    logic [2:0] telemetry_index;
    logic diagnostic_hold;

    logic active;
    logic initialized;
    logic console_release;
    logic [31:0] active_session;
    logic fault;
    logic [31:0] fault_bits;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic grant_blocked = 0;
    logic physical_accept_enable = 0;
    logic force_physical_stall = 0;

    // Minimal registered-arbiter model.  A client request is captured once
    // while busy is low, then the client's request outputs may drop.  Physical
    // command acceptance is reported later from the registered payload.
    logic arb_command_pending = 0;
    logic arb_read = 0;
    logic arb_write = 0;
    logic [28:0] arb_address = 0;
    logic [63:0] arb_write_data = 0;
    logic [7:0] arb_byte_enable = 0;
    logic arb_zero_latency = 0;

    logic response_pending = 0;
    logic [63:0] delayed_read_data = 0;
    logic delayed_read_ready = 0;
    integer response_delay = 0;
    logic [63:0] memory [0:MEMORY_WORDS-1];

    wire ddram_busy =
        grant_blocked || arb_command_pending || response_pending;
    wire ddram_command_accepted =
        arb_command_pending && physical_accept_enable &&
        !force_physical_stall;
    wire zero_latency_response =
        ddram_command_accepted && arb_read && arb_zero_latency;
    wire [63:0] ddram_read_data = zero_latency_response
        ? memory[arb_address - BASE] : delayed_read_data;
    wire ddram_read_data_ready =
        zero_latency_response || delayed_read_ready;

    logic random_stalls = 0;
    logic hps_ack_pending = 0;
    logic [31:0] hps_ack_token = 0;
    integer hps_ack_delay = 0;
    logic exact_ack_returned = 0;

    logic monitor_initialization = 0;
    logic [31:0] expected_session = 0;
    integer initialization_write = 0;
    integer accepted_writes = 0;
    integer accepted_reads = 0;
    integer stalled_requests = 0;
    integer busy_cycles = 0;
    integer completed_initializations = 0;
    integer initialization_writes_total = 0;
    integer commit_clear_writes = 0;
    integer locally_queued_commands = 0;
    integer queued_reads = 0;
    integer accepted_with_request_dropped = 0;
    integer zero_latency_reads = 0;

    always #5 clk = ~clk;

    nds_h3d_control_init #(
        .BASE_WORD(BASE),
        .ENTRY_COUNT(ENTRY_COUNT),
        .PACKET_MODE(PACKET_MODE),
        .HEADER_WORDS64(HEADER_WORDS64),
        .HPS_HEARTBEAT_TIMEOUT_CYCLES(512),
        .DIAGNOSTIC_HOLD_CYCLES(32)
    ) dut (
        .*
    );

    task automatic begin_session(input logic [31:0] session);
        begin
            @(negedge clk);
            expected_session = 0;
            initialization_write = 0;
            monitor_initialization = 1;
            requested_session = session;
        end
    endtask

    task automatic wait_for_initialized;
        integer timeout;
        begin
            timeout = 0;
            while (!initialized || active_session != expected_session ||
                monitor_initialization) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
                if (timeout > 10000)
                    $fatal(1, "timed out waiting for initialized");
            end
        end
    endtask

    task automatic wait_for_release;
        integer timeout;
        begin
            timeout = 0;
            while (!console_release) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
                if (timeout > 10000)
                    $fatal(1, "timed out waiting for console release");
            end
        end
    endtask

    task automatic wait_for_fault;
        integer timeout;
        begin
            timeout = 0;
            while (!fault) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
                if (timeout > 10000)
                    $fatal(1, "timed out waiting for fail-closed fault");
            end
            if (console_release)
                $fatal(1, "console remained released after fault");

            timeout = 0;
            while (memory[4][31:0] == 0) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
                if (timeout > 10000)
                    $fatal(1, "FPGA fault word was not published");
            end
        end
    endtask

    task automatic verify_fresh_header(input logic [31:0] session);
        integer index;
        integer commit_word;
        begin
            if (memory[0] !== VALID_HEADER)
                $fatal(1, "valid H3D1 header word is wrong");
            if (memory[1] !== {CONFIG_HIGH, session})
                $fatal(1,
                    "session/config word is wrong in packet mode %0d: got %h expected {%h,%h}",
                    PACKET_MODE, memory[1], CONFIG_HIGH, session);
            if (PACKET_MODE && memory[1][63:32] !== 0)
                $fatal(1,
                    "packet mode published a legacy entry count");
            if (memory[2] !== 0 || memory[3] !== 0)
                $fatal(1,
                    "producer/ack counters were not cleared");
            for (index = 2; index < 14; index = index + 1) begin
                if (memory[index] !== 0)
                    $fatal(1, "header word %0d was not cleared", index);
            end
            if (memory[14] !== {32'd0, session} ||
                memory[15] !== {32'd0, session})
                $fatal(1,
                    "active H3D1 request/ack token was not preserved");
            if (!PACKET_MODE)
                for (index = 0; index < ENTRY_COUNT; index = index + 1) begin
                    commit_word = HEADER_WORDS64 + index * 4 + 3;
                    if (memory[commit_word] !== 0)
                        $fatal(1, "slot %0d stale commit survived", index);
                end
        end
    endtask

    task automatic seed_stale_memory;
        integer index;
        begin
            for (index = 0; index < MEMORY_WORDS; index = index + 1)
                memory[index] =
                    64'hcafe000000000000 ^ 64'(index * 64'h01010101);
        end
    endtask

    always @(negedge clk) begin
        if (random_stalls) begin
            grant_blocked <= ($urandom_range(0, 3) == 0);
            physical_accept_enable <= ($urandom_range(0, 2) != 0);
        end
    end

    always @(posedge clk) begin
        integer word_index;
        integer expected_address_index;
        integer byte_index;
        logic [63:0] updated_word;

        delayed_read_ready <= 1'b0;

        if (hps_ack_pending) begin
            if (hps_ack_delay == 0) begin
                memory[15] <= {32'd0, hps_ack_token};
                hps_ack_pending <= 1'b0;
            end else begin
                hps_ack_delay <= hps_ack_delay - 1;
            end
        end

        if (ddram_read_data_ready &&
            (dut.state == STATE_READ_QUIESCE_ACK_WAIT ||
             (dut.state == STATE_READ_QUIESCE_ACK_ISSUE &&
              ddram_command_accepted)) &&
            ddram_read_data == {32'd0, dut.active_session})
            exact_ack_returned <= 1'b1;

        if (ddram_busy)
            busy_cycles <= busy_cycles + 1;
        if (arb_command_pending && !ddram_command_accepted)
            stalled_requests <= stalled_requests + 1;

        if (ddram_busy && (ddram_read || ddram_write))
            $fatal(1, "DDR request asserted while busy is high");
        if (ddram_burst_count != 1)
            $fatal(1, "control initializer issued a DDR burst");
        if (ddram_read && ddram_write)
            $fatal(1, "simultaneous local DDR read and write");

        // Capture the client's one-cycle handoff into a registered queue.
        if ((ddram_read || ddram_write) && !ddram_busy) begin
            if (arb_command_pending || response_pending)
                $fatal(1, "registered arbiter accepted while occupied");
            arb_command_pending <= 1'b1;
            arb_read <= ddram_read;
            arb_write <= ddram_write;
            arb_address <= ddram_address;
            arb_write_data <= ddram_write_data;
            arb_byte_enable <= ddram_byte_enable;
            arb_zero_latency <= ddram_read && !queued_reads[0];
            locally_queued_commands <= locally_queued_commands + 1;
            if (ddram_read)
                queued_reads <= queued_reads + 1;
        end

        if (response_pending) begin
            if (response_delay == 0) begin
                delayed_read_ready <= 1'b1;
                response_pending <= 1'b0;
            end else begin
                response_delay <= response_delay - 1;
            end
        end

        if (ddram_command_accepted) begin
            if (!arb_command_pending || (!arb_read && !arb_write))
                $fatal(1, "acceptance had no registered command");
            if (ddram_read || ddram_write)
                $fatal(1,
                    "client request did not drop after registered handoff");
            accepted_with_request_dropped <=
                accepted_with_request_dropped + 1;
            arb_command_pending <= 1'b0;

            word_index = arb_address - BASE;
            if (word_index < 0 || word_index >= MEMORY_WORDS)
                $fatal(1, "registered DDR address is outside H3D memory");

            if (arb_read) begin
                if (response_pending)
                    $fatal(1,
                        "second DDR read accepted while response pending");
                accepted_reads <= accepted_reads + 1;
                if (arb_zero_latency) begin
                    zero_latency_reads <= zero_latency_reads + 1;
                end else begin
                    delayed_read_data <= memory[word_index];
                    response_delay <= $urandom_range(0, 3);
                    response_pending <= 1'b1;
                end
            end

            if (arb_write) begin
                updated_word = memory[word_index];
                for (byte_index = 0; byte_index < 8;
                    byte_index = byte_index + 1) begin
                    if (arb_byte_enable[byte_index])
                        updated_word[byte_index * 8 +: 8] =
                            arb_write_data[byte_index * 8 +: 8];
                end
                memory[word_index] <= updated_word;
                accepted_writes <= accepted_writes + 1;

                if (arb_address == BASE &&
                    arb_write_data == QUIESCE_HEADER) begin
                    if (memory[14][63:32] != 0 ||
                        memory[14][31:0] != dut.active_session)
                        $fatal(1,
                            "H3DQ published before exact quiesce request");
                    hps_ack_token <= dut.active_session;
                    hps_ack_delay <= $urandom_range(0, 4);
                    hps_ack_pending <= 1'b1;
                    // Model final writes by the old service before its ack.
                    memory[5] <= 64'hfeedfacecafebeef;
                end

            // A heartbeat write already issued by the previous active session
            // may retire after begin_session() starts watching for the next
            // initialization.  It necessarily precedes the word-14 quiesce
            // request, so exclude it from the initialization write sequence.
            if (monitor_initialization && initialization_write == 0 &&
                word_index == 12) begin
                if (arb_write_data[63:32] != fpga_telemetry_value)
                    $fatal(1,
                        "FPGA heartbeat telemetry word was malformed");
            end else if (monitor_initialization) begin
                    initialization_writes_total <=
                        initialization_writes_total + 1;
                    if (arb_byte_enable != 8'hff)
                        $fatal(1, "initialization used a partial write");

                    if (initialization_write == 0) begin
                        expected_address_index = 14;
                        if (arb_write_data[63:32] !== 0 ||
                            arb_write_data[31:0] == 0)
                            $fatal(1,
                                "new quiesce request token was malformed");
                        expected_session = arb_write_data[31:0];
                        exact_ack_returned <= 1'b0;
                    end else if (initialization_write == 1) begin
                        expected_address_index = 0;
                        if (arb_write_data !== QUIESCE_HEADER)
                            $fatal(1, "H3DQ was not published after request");
                    end else if (initialization_write <= 14) begin
                        expected_address_index = initialization_write - 1;
                        if (arb_write_data !== 0)
                            $fatal(1, "header clear write was not zero");
                    end else if (initialization_write <=
                        14 + COMMIT_CLEAR_WRITES) begin
                        expected_address_index = HEADER_WORDS64 +
                            (initialization_write - 15) * 4 + 3;
                        if (arb_write_data !== 0)
                            $fatal(1, "commit clear write was not zero");
                        commit_clear_writes <= commit_clear_writes + 1;
                    end else if (initialization_write ==
                        CONFIG_WRITE_INDEX) begin
                        expected_address_index = 1;
                        if (arb_write_data !==
                            {CONFIG_HIGH, expected_session})
                            $fatal(1, "configuration write was wrong");
                    end else if (initialization_write == MAGIC_WRITE_INDEX) begin
                        expected_address_index = 0;
                        if (arb_write_data !== VALID_HEADER)
                            $fatal(1,
                                "valid magic was not published last");
                    end else begin
                        $fatal(1, "too many initialization writes");
                    end

                    if (word_index != expected_address_index)
                        $fatal(1,
                            "initialization write %0d used word %0d, expected %0d",
                            initialization_write, word_index,
                            expected_address_index);

                    if (initialization_write >= 2 && !exact_ack_returned)
                        $fatal(1,
                            "FPGA cleared shared state before exact HPS ack");

                    if (initialization_write == MAGIC_WRITE_INDEX) begin
                        monitor_initialization <= 1'b0;
                        completed_initializations <=
                            completed_initializations + 1;
                    end
                    initialization_write <= initialization_write + 1;
                end
            end
        end
    end

    initial begin
        integer index;
        logic [31:0] session1;
        logic [31:0] session2;
        logic [31:0] session3;
        logic [31:0] session4;
        logic [31:0] session5;
        logic [31:0] session6;
        logic [31:0] active1;
        logic [31:0] active2;
        logic [31:0] active3;
        logic [31:0] active4;
        logic [31:0] active5;
        logic [31:0] active6;
        logic [31:0] active7;
        logic [31:0] active8;

        session1 = 32'h11223344;
        session2 = 32'h55667788;
        session3 = 32'h89abcdef;
        session4 = 32'h13579bdf;
        session5 = 32'h2468ace0;
        session6 = 32'h10293847;
        seed_stale_memory();
        if (memory[2] == 0 || memory[3] == 0)
            $fatal(1, "test did not seed dirty producer/ack counters");
        // Persistent counter wrap must skip zero; the new full request write
        // also repairs a malformed old reserved high word.
        memory[14] = 64'hdeadbeefffffffff;

        repeat (5) @(posedge clk);

        // Product outer-fabric ownership survives a shell reset, while this
        // client resets.  Model a stale pre-reset read that is accepted just
        // after control reset deasserts.  It must be ignored as an orphan,
        // then the new epoch must initialize normally rather than publishing
        // a false BAD_HEADER fault.
        arb_command_pending = 1'b1;
        arb_read = 1'b1;
        arb_write = 1'b0;
        arb_address = BASE + 29'd3;
        arb_zero_latency = 1'b0;
        physical_accept_enable = 1'b1;
        reset = 0;
        @(posedge clk);
        @(negedge clk);
        if (arb_command_pending)
            $fatal(1, "stale pre-reset command did not drain");
        if (fault || dut.state != 4'd0)
            $fatal(1,
                "orphan pre-reset acceptance faulted the fresh epoch");
        // Exclude the deliberately injected old-epoch transaction from the
        // fresh-epoch accounting assertions below.
        accepted_reads = 0;
        accepted_with_request_dropped = 0;
        random_stalls = 1;

        repeat (20) @(posedge clk);
        if (active || initialized || console_release || fault)
            $fatal(1, "zero session did not remain fail closed and idle");
        if (accepted_writes != 0 || accepted_reads != 0)
            $fatal(1, "zero session accessed DDR");

        begin_session(session1);
        wait_for_initialized();
        active1 = active_session;
        verify_fresh_header(active1);
        if (active1 != 32'd1)
            $fatal(1, "persistent session counter wrap did not skip zero");
        if (console_release)
            $fatal(1, "console released before HPS Ready");

        // HPS accepts the clean session and reports exact Ready.
        @(negedge clk);
        memory[5] = {active1, 32'd2};
        wait_for_release();
        if (memory[12] !== {fpga_telemetry_value, fpga_heartbeat_value})
            $fatal(1, "FPGA heartbeat/telemetry was not published");

        // An accepted-session mismatch must fail closed and publish a local
        // fault without overwriting the HPS-owned high word.
        @(negedge clk);
        memory[5] = {32'hdeadbeef, 32'd2};
        wait_for_fault();
        if ((fault_bits & 32'h00000002) == 0)
            $fatal(1, "bad session did not set session fault bit");

        // A different nonzero session restarts the complete stale-memory
        // clear, including packet producer/ack counters, all prior fault
        // state, and every legacy-mode commit beat.
        @(negedge clk);
        memory[2] = 64'hffffffff12345678;
        memory[3] = 64'hfeedface87654321;
        for (index = 0; index < ENTRY_COUNT; index = index + 1)
            memory[HEADER_WORDS64 + index * 4 + 3] =
                {32'hffffffff, 32'(index + 1)};
        begin_session(session2);
        wait_for_initialized();
        active2 = active_session;
        verify_fresh_header(active2);
        if (active2 == 0 || active2 != active1 + 1'b1)
            $fatal(1, "persistent session token did not advance");
        if (fault || console_release)
            $fatal(1, "new session did not clear fault/release state");
        @(negedge clk);
        memory[5] = {active2, 32'd2};
        wait_for_release();

        // A nonzero reserved high half is malformed and must fail closed.
        @(negedge clk);
        memory[2][63:32] = 32'h00000001;
        wait_for_fault();
        if ((fault_bits & 32'h00000001) == 0)
            $fatal(1, "bad reserved counter half did not set header fault");

        // Restart once more, then prove an HPS fault is detected and its
        // HPS-owned word is preserved by the FPGA's partial fault write.
        begin_session(session3);
        wait_for_initialized();
        active3 = active_session;
        verify_fresh_header(active3);
        if (active3 == 0 || active3 != active2 + 1'b1)
            $fatal(1, "third persistent session token did not advance");
        @(negedge clk);
        memory[5] = {active3, 32'd2};
        wait_for_release();

        // Hold a registered poll read after the client request has dropped,
        // then request another external session.  The old read must physically
        // complete and return before the new quiesce sequence begins.
        @(negedge clk);
        random_stalls = 0;
        grant_blocked = 0;
        physical_accept_enable = 1;
        force_physical_stall = 1;
        wait (arb_command_pending && arb_read);
        @(negedge clk);
        expected_session = 0;
        initialization_write = 0;
        monitor_initialization = 1;
        requested_session = session4;
        #1;
        if (ddram_read || ddram_write || console_release)
            $fatal(1,
                "queued old read was not isolated from session restart");
        repeat (3) begin
            @(posedge clk);
            #1;
            if (ddram_read || ddram_write)
                $fatal(1,
                    "new session command escaped before old acceptance");
        end
        @(negedge clk);
        force_physical_stall = 0;
        random_stalls = 1;
        wait_for_initialized();
        active4 = active_session;
        verify_fresh_header(active4);
        if (active4 == 0 || active4 != active3 + 1'b1)
            $fatal(1, "queued-command restart token did not advance");
        @(negedge clk);
        memory[5] = {active4, 32'd2};
        wait_for_release();

        // RestartRequested is an ordered reinitialization request, not a
        // service fault.  It must run the same quiesce handshake without an
        // external token change.
        @(negedge clk);
        expected_session = 0;
        initialization_write = 0;
        monitor_initialization = 1;
        memory[5] = {active4, 32'd4};
        wait_for_initialized();
        active5 = active_session;
        verify_fresh_header(active5);
        if (active5 == 0 || active5 != active4 + 1'b1)
            $fatal(1, "service-requested session token did not advance");
        if (fault)
            $fatal(1, "RestartRequested was treated as a fault");
        @(negedge clk);
        memory[5] = {active5, 32'd2};
        wait_for_release();

        // A service can die after it reports Initializing but before it
        // accepts the session.  Its replacement reports RestartRequested with
        // accepted_session zero.  This is a valid reinit request.
        @(negedge clk);
        memory[5] = {32'd0, 32'd1};
        repeat (40) @(posedge clk);
        if (fault)
            $fatal(1, "Initializing with accepted_session zero faulted");
        @(negedge clk);
        expected_session = 0;
        initialization_write = 0;
        monitor_initialization = 1;
        memory[5] = {32'd0, 32'd4};
        wait_for_initialized();
        active6 = active_session;
        verify_fresh_header(active6);
        if (active6 == 0 || active6 != active5 + 1'b1)
            $fatal(1,
                "accepted-zero RestartRequested token did not advance");
        if (fault)
            $fatal(1,
                "accepted-zero RestartRequested was treated as a fault");
        @(negedge clk);
        memory[5] = {active6, 32'd2};
        wait_for_release();

        // Prove an HPS fault is detected and the HPS-owned high word is
        // preserved by the FPGA's partial fault write.
        @(negedge clk);
        memory[4] = {32'h00000020, 32'd0};
        wait_for_fault();
        if (memory[4][63:32] !== 32'h00000020)
            $fatal(1, "FPGA fault write overwrote HPS fault bits");
        if ((fault_bits & 32'h00000004) == 0)
            $fatal(1, "HPS fault did not set local HPS-fault marker");

        // A fresh session clears the HPS fault. Advancing HPS heartbeats keep
        // a Ready service alive; stale Ready from a dead service must fail
        // closed inside the configured bound.
        begin_session(session5);
        wait_for_initialized();
        active7 = active_session;
        verify_fresh_header(active7);
        if (active7 == 0 || active7 != active6 + 1'b1)
            $fatal(1, "heartbeat test session did not advance");
        @(negedge clk);
        memory[13] = {32'd0, 32'd1};
        memory[5] = {active7, 32'd2};
        wait_for_release();
        // A changed nonzero high word requests one bounded, fail-safe CPU
        // hold. It is diagnostic data, not a malformed counter reserve.
        @(negedge clk);
        memory[13][63:32] = 32'h00000042;
        wait (diagnostic_hold);
        if (fault || !console_release)
            $fatal(1, "diagnostic hold token faulted the active session");
        wait (!diagnostic_hold);
        repeat (40) @(posedge clk);
        if (diagnostic_hold)
            $fatal(1, "diagnostic hold did not release itself");
        repeat (3) begin
            repeat (160) @(posedge clk);
            @(negedge clk);
            memory[13][31:0] = memory[13][31:0] + 1'b1;
            repeat (40) @(posedge clk);
            if (fault || !console_release)
                $fatal(1, "advancing HPS heartbeat did not keep release");
        end
        wait_for_fault();
        if ((fault_bits & 32'h00000008) == 0)
            $fatal(1, "stale HPS heartbeat did not set service fault");

        // Another clean session clears the liveness fault. A synchronized
        // product-path fault is FPGA-owned, sticky, published in the low half
        // of word4, and must close console_release on its own.
        begin_session(session6);
        wait_for_initialized();
        active8 = active_session;
        verify_fresh_header(active8);
        if (active8 == 0 || active8 != active7 + 1'b1)
            $fatal(1, "external-fault test session did not advance");
        @(negedge clk);
        memory[13] = {32'd0, 32'd1};
        memory[5] = {active8, 32'd2};
        wait_for_release();
        @(negedge clk);
        external_fault_bits = 32'h00000100;
        wait_for_fault();
        if ((fault_bits & 32'h00000100) == 0 ||
            (memory[4][31:0] & 32'h00000100) == 0)
            $fatal(1, "external product fault was not published");
        external_fault_bits = 32'd0;
        wait (dut.state == STATE_FAULT_HOLD);

        // Zero is an idle trigger, not a teardown request.  It cannot erase
        // the persistent active token or start DDR work by itself.
        @(negedge clk);
        requested_session = 0;
        repeat (10) @(posedge clk);
        if (!initialized || console_release || !fault ||
            active_session != active8 || memory[0] != VALID_HEADER)
            $fatal(1, "zero trigger incorrectly changed active session");

        if (completed_initializations != 8)
            $fatal(1, "expected eight complete session initializations");
        if (initialization_writes_total !=
            completed_initializations * INITIALIZATION_WRITE_COUNT)
            $fatal(1,
                "initialization write count did not match packet mode %0d",
                PACKET_MODE);
        if (commit_clear_writes !=
            completed_initializations * COMMIT_CLEAR_WRITES)
            $fatal(1,
                "legacy commit-clear count did not match packet mode %0d",
                PACKET_MODE);
        if (PACKET_MODE && commit_clear_writes != 0)
            $fatal(1, "packet mode issued an event commit-clear write");
        if (stalled_requests == 0 || busy_cycles == 0)
            $fatal(1, "test did not exercise DDR acceptance stalls");
        if (zero_latency_reads == 0)
            $fatal(1, "test did not exercise acceptance-edge read data");
        if (locally_queued_commands !=
            accepted_writes + accepted_reads ||
            accepted_with_request_dropped != locally_queued_commands)
            $fatal(1,
                "registered arbiter queue/physical acceptance count mismatch");

        $display(
            "PASS: H3D control init packet_mode=%0d %0d sessions, %0d init writes, %0d commit clears, %0d writes, %0d reads, %0d accept stalls, %0d busy cycles",
            PACKET_MODE, completed_initializations,
            initialization_writes_total, commit_clear_writes,
            accepted_writes, accepted_reads, stalled_requests, busy_cycles);
        $finish;
    end
endmodule
