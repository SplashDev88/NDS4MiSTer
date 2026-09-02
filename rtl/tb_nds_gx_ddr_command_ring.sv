module tb_nds_gx_ddr_command_ring;
    localparam logic [28:0] BASE = 29'h00330000;
    localparam integer ENTRY_COUNT = 4;
    localparam integer HEADER_WORDS64 = 8;
    localparam integer PACKET_COUNT = 20;
    localparam integer MEMORY_WORDS = 64;

    logic clk = 0;
    logic reset = 1;

    logic command_valid = 0;
    logic command_ready;
    logic [31:0] command_frame = 0;
    logic [63:0] command_timestamp = 0;
    logic [7:0] command_id = 0;
    logic [31:0] command_parameter = 0;
    logic [31:0] command_epoch = 0;
    logic [63:0] command_fence = 0;

    logic active;
    logic ddram_active;
    logic full;
    logic packet_done;
    logic [63:0] producer_fence;
    logic [63:0] consumer_fence;
    logic protocol_error;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy = 0;
    logic ddram_accept_enable = 0;
    wire ddram_command_accepted =
        (ddram_read || ddram_write) &&
        !ddram_busy && ddram_accept_enable;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;

    logic [63:0] memory [0:MEMORY_WORDS-1];
    logic read_pending = 0;
    logic [63:0] pending_read_data = 0;
    integer read_delay = 0;
    logic random_stalls = 0;

    integer input_handshakes = 0;
    integer completed_packets = 0;
    integer accepted_writes = 0;
    integer accepted_reads = 0;
    integer stalled_request_cycles = 0;
    integer busy_cycles = 0;
    integer expected_beat = 0;
    logic [63:0] expected_fence = 0;
    logic [31:0] expected_frame = 0;
    logic [63:0] expected_timestamp = 0;
    logic [7:0] expected_command = 0;
    logic [31:0] expected_parameter = 0;
    logic [31:0] expected_epoch = 0;
    logic [63:0] observed_producer_fence = 0;
    logic commit_accepted_on_edge = 0;

    always #5 clk = ~clk;

    nds_gx_ddr_command_ring #(
        .BASE_WORD(BASE),
        .ENTRY_COUNT(ENTRY_COUNT),
        .HEADER_WORDS64(HEADER_WORDS64),
        .CONSUMER_WORD_OFFSET(0)
    ) dut (
        .*
    );

    function automatic logic [31:0] frame_for(
        input logic [63:0] fence
    );
        frame_for = 32'h10000000 + fence[31:0] * 3;
    endfunction

    function automatic logic [63:0] timestamp_for(
        input logic [63:0] fence
    );
        timestamp_for =
            64'h2000000000000000 + fence * 64'h0000000100010001;
    endfunction

    function automatic logic [7:0] command_for(
        input logic [63:0] fence
    );
        command_for = 8'h20 + fence[5:0];
    endfunction

    function automatic logic [31:0] parameter_for(
        input logic [63:0] fence
    );
        parameter_for = 32'h30000000 ^ fence[31:0] * 32'h01020305;
    endfunction

    function automatic logic [31:0] epoch_for(
        input logic [63:0] fence
    );
        epoch_for = 32'h40000000 + fence[31:0] / 5;
    endfunction

    task automatic set_expected_packet(input logic [63:0] fence);
        begin
            expected_fence = fence;
            expected_frame = frame_for(fence);
            expected_timestamp = timestamp_for(fence);
            expected_command = command_for(fence);
            expected_parameter = parameter_for(fence);
            expected_epoch = epoch_for(fence);
            expected_beat = 0;
        end
    endtask

    task automatic drive_packet(input logic [63:0] fence);
        integer target_handshakes;
        integer target_completions;
        begin
            set_expected_packet(fence);
            target_handshakes = input_handshakes + 1;
            target_completions = completed_packets + 1;
            @(negedge clk);
            command_frame = expected_frame;
            command_timestamp = expected_timestamp;
            command_id = expected_command;
            command_parameter = expected_parameter;
            command_epoch = expected_epoch;
            command_fence = expected_fence;
            command_valid = 1;

            while (input_handshakes < target_handshakes) begin
                @(posedge clk);
                #1;
            end
            @(negedge clk);
            command_valid = 0;

            while (completed_packets < target_completions) begin
                @(posedge clk);
                #1;
            end
            if (expected_beat != 4)
                $fatal(1,
                    "packet %0d completed with only %0d accepted beats",
                    fence, expected_beat);
        end
    endtask

    task automatic publish_consumer(input logic [63:0] fence);
        begin
            @(negedge clk);
            memory[0] = fence;
        end
    endtask

    // Randomized DDR waitrequest and an independent physical-accept gate.
    // A request can therefore remain visible for multiple nonbusy cycles
    // without being retired.
    always @(negedge clk) begin
        if (random_stalls) begin
            ddram_busy <= ($urandom_range(0, 3) == 0);
            ddram_accept_enable <= ($urandom_range(0, 2) != 0);
        end
    end

    always @(posedge clk) begin
        integer word_index;
        integer expected_slot;
        logic [63:0] expected_word;

        ddram_read_data_ready <= 0;

        if (ddram_busy)
            busy_cycles <= busy_cycles + 1;
        if ((ddram_read || ddram_write) && !ddram_busy &&
            !ddram_command_accepted)
            stalled_request_cycles <= stalled_request_cycles + 1;

        if (ddram_busy && (ddram_read || ddram_write))
            $fatal(1, "DDR request asserted while waitrequest/busy is high");
        if (ddram_burst_count != 1 || ddram_byte_enable != 8'hff)
            $fatal(1, "GX DDR ring used a burst or partial byte enable");

        if (command_valid && command_ready)
            input_handshakes <= input_handshakes + 1;
        if (packet_done)
            completed_packets <= completed_packets + 1;

        commit_accepted_on_edge <=
            ddram_command_accepted && ddram_write &&
            expected_beat == 3;

        if (ddram_command_accepted && ddram_write) begin
            if (ddram_address < BASE + HEADER_WORDS64 ||
                ddram_address >=
                    BASE + HEADER_WORDS64 + ENTRY_COUNT * 4)
                $fatal(1, "GX packet write outside DDR ring: %h",
                       ddram_address);

            expected_slot = (expected_fence - 1) &
                (ENTRY_COUNT - 1);
            word_index =
                HEADER_WORDS64 + expected_slot * 4 + expected_beat;
            if (ddram_address !== BASE + word_index)
                $fatal(1,
                    "packet %0d beat %0d address mismatch got=%h expected=%h",
                    expected_fence, expected_beat, ddram_address,
                    BASE + word_index);
            case (expected_beat)
                0: expected_word =
                    {24'd0, expected_command, expected_parameter};
                1: expected_word = expected_timestamp;
                2: expected_word = {expected_epoch, expected_frame};
                3: expected_word = expected_fence;
                default: expected_word = 64'hx;
            endcase
            if (ddram_write_data !== expected_word)
                $fatal(1,
                    "packet %0d beat %0d data mismatch got=%h expected=%h",
                    expected_fence, expected_beat, ddram_write_data,
                    expected_word);

            memory[word_index] <= ddram_write_data;
            accepted_writes <= accepted_writes + 1;
            expected_beat = expected_beat + 1;
        end

        if (ddram_command_accepted && ddram_read) begin
            if (ddram_address != BASE)
                $fatal(1, "consumer progress read used wrong address");
            if (read_pending)
                $fatal(1, "overlapping consumer progress reads");
            pending_read_data <= memory[0];
            read_delay <= $urandom_range(1, 5);
            read_pending <= 1;
            accepted_reads <= accepted_reads + 1;
        end

        if (read_pending) begin
            if (read_delay == 0) begin
                ddram_read_data <= pending_read_data;
                ddram_read_data_ready <= 1;
                read_pending <= 0;
            end else begin
                read_delay <= read_delay - 1;
            end
        end
    end

    // Observe state after nonblocking assignments have settled.  The producer
    // fence and done pulse must change if and only if the final beat was
    // physically accepted on the preceding rising edge.
    always @(negedge clk) begin
        if (reset) begin
            observed_producer_fence = producer_fence;
        end else begin
            if (producer_fence != observed_producer_fence) begin
                if (!commit_accepted_on_edge || !packet_done)
                    $fatal(1,
                        "producer fence retired without physical commit");
            end else if (packet_done) begin
                $fatal(1, "packet_done asserted without fence retirement");
            end
            observed_producer_fence = producer_fence;
        end
    end

    initial begin : timeout_guard
        repeat (12000) @(posedge clk);
        $fatal(1,
            "GX DDR ring timeout producer=%0d consumer=%0d state=%0d handshakes=%0d completed=%0d",
            producer_fence, consumer_fence, dut.state,
            input_handshakes, completed_packets);
    end

    initial begin
        integer index;
        integer reads_before_full;
        integer writes_before_full;
        integer handshakes_before_full;
        integer writes_before_terminal;
        integer fence;
        integer slot;

        for (index = 0; index < MEMORY_WORDS; index = index + 1)
            memory[index] = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Directed physical-acceptance gate: present beat zero for five
        // nonbusy clocks but withhold the actual acceptance indication.
        ddram_busy = 0;
        ddram_accept_enable = 0;
        fork
            drive_packet(64'd1);
            begin
                wait (ddram_write);
                repeat (5) begin
                    @(posedge clk);
                    #1;
                    if (producer_fence != 0 || packet_done ||
                        expected_beat != 0)
                        $fatal(1,
                            "unaccepted DDR request retired a packet beat");
                end
                @(negedge clk);
                ddram_accept_enable = 1;
            end
        join

        random_stalls = 1;
        drive_packet(64'd2);
        drive_packet(64'd3);
        drive_packet(64'd4);
        #1;
        if (!full || producer_fence != 4 || consumer_fence != 0)
            $fatal(1, "four committed packets did not fill depth-four ring");

        // A fifth packet must remain held without a write until HPS publishes
        // progress.  Stale control reads are allowed and must stay lossless.
        reads_before_full = accepted_reads;
        writes_before_full = accepted_writes;
        handshakes_before_full = input_handshakes;
        fork
            drive_packet(64'd5);
            begin
                repeat (60) begin
                    @(posedge clk);
                    #1;
                    if (input_handshakes != handshakes_before_full ||
                        accepted_writes != writes_before_full ||
                        producer_fence != 4)
                        $fatal(1,
                            "full GX DDR ring accepted or overwrote packet");
                end
                if (accepted_reads <= reads_before_full)
                    $fatal(1,
                        "full GX DDR ring did not poll consumer progress");
                publish_consumer(64'd2);
            end
        join
        if (producer_fence != 5 || consumer_fence != 2)
            $fatal(1, "consumer progress did not release packet five");

        // Advance HPS concurrently with packet six's four physical writes.
        // The producer learns this only when packet seven reaches the full
        // gate and reads the control word.
        fork
            drive_packet(64'd6);
            begin
                wait (dut.state == 5);
                publish_consumer(64'd4);
            end
        join
        if (!full || producer_fence != 6 || consumer_fence != 2)
            $fatal(1,
                "concurrent HPS advancement unexpectedly bypassed refresh");

        // Continue across repeated physical slot wrap.  HPS stays two packets
        // behind and may advance while the producer is active.
        for (fence = 7; fence <= PACKET_COUNT; fence = fence + 1) begin
            fork
                drive_packet(fence);
                begin
                    wait (active);
                    publish_consumer(fence - 2);
                end
            join
        end

        if (producer_fence != PACKET_COUNT ||
            completed_packets != PACKET_COUNT ||
            input_handshakes != PACKET_COUNT ||
            accepted_writes != PACKET_COUNT * 4)
            $fatal(1,
                "packet accounting mismatch producer=%0d completed=%0d handshakes=%0d writes=%0d",
                producer_fence, completed_packets, input_handshakes,
                accepted_writes);
        if (protocol_error)
            $fatal(1, "valid contiguous traffic raised protocol_error");
        if (stalled_request_cycles < 20 || busy_cycles < 20)
            $fatal(1,
                "random DDR model did not exercise enough stalls (%0d/%0d)",
                stalled_request_cycles, busy_cycles);

        // Every physical slot must contain its most recent complete packet.
        for (fence = PACKET_COUNT - ENTRY_COUNT + 1;
             fence <= PACKET_COUNT; fence = fence + 1) begin
            slot = (fence - 1) & (ENTRY_COUNT - 1);
            index = HEADER_WORDS64 + slot * 4;
            if (memory[index] !==
                {24'd0, command_for(fence), parameter_for(fence)} ||
                memory[index + 1] !== timestamp_for(fence) ||
                memory[index + 2] !==
                    {epoch_for(fence), frame_for(fence)} ||
                memory[index + 3] !== fence)
                $fatal(1,
                    "wrapped slot %0d does not contain packet %0d",
                    slot, fence);
        end

        // Terminal fence overflow fails closed and cannot write a slot.
        writes_before_terminal = accepted_writes;
        random_stalls = 0;
        @(negedge clk);
        reset = 1;
        command_valid = 0;
        ddram_busy = 0;
        ddram_accept_enable = 1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        command_fence = 64'hffffffffffffffff;
        command_valid = 1;
        repeat (4) @(posedge clk);
        #1;
        if (command_ready || producer_fence != 0 ||
            accepted_writes != writes_before_terminal ||
            !protocol_error)
            $fatal(1,
                "terminal/noncontiguous fence did not fail closed");
        @(negedge clk);
        command_valid = 0;

        $display(
            "PASS: lossless GX DDR ring physically commits 4-beat packets under arbitrary stalls, full backpressure, wrap, and concurrent HPS progress");
        $display(
            "INFO: packets=%0d writes=%0d consumer_reads=%0d request_stalls=%0d busy_cycles=%0d",
            completed_packets, accepted_writes, accepted_reads,
            stalled_request_cycles, busy_cycles);
        $finish;
    end
endmodule

// Integration-shaped acceptance test.  The real arbiter admits a client
// request into its one-entry queue, raises client busy, and reports
// ddram_command_accepted only later when the outer MiSTer DDR port physically
// accepts that queued command.  At that later edge the original client request
// is intentionally low.  This test proves the ring advances on the physical
// acceptance pulse, not on request presentation or raw busy.
module tb_nds_gx_ddr_command_ring_arbiter;
    localparam logic [28:0] BASE = 29'h00340000;
    localparam integer HEADER_WORDS64 = 8;

    logic clk = 0;
    logic reset = 1;
    logic command_valid = 0;
    logic command_ready;
    logic active;
    logic ring_ddram_active;
    logic full;
    logic packet_done;
    logic [63:0] producer_fence;
    logic [63:0] consumer_fence;
    logic protocol_error;

    logic ring_read;
    logic ring_write;
    logic [7:0] ring_burst;
    logic [28:0] ring_address;
    logic [63:0] ring_write_data;
    logic [7:0] ring_byte_enable;
    logic ring_busy;
    logic ring_command_accepted;
    logic [63:0] ring_read_data;
    logic ring_read_data_ready;

    logic outer_read;
    logic outer_write;
    logic [7:0] outer_burst;
    logic [28:0] outer_address;
    logic [63:0] outer_write_data;
    logic [7:0] outer_byte_enable;
    logic physical_busy = 1;

    logic [28:0] accepted_address [0:3];
    logic [63:0] accepted_data [0:3];
    integer physical_accepts = 0;
    integer acceptance_without_request = 0;
    integer queued_stall_cycles = 0;

    always #5 clk = ~clk;

    nds_gx_ddr_command_ring #(
        .BASE_WORD(BASE),
        .ENTRY_COUNT(4),
        .HEADER_WORDS64(HEADER_WORDS64),
        .CONSUMER_WORD_OFFSET(0)
    ) ring (
        .clk,
        .reset,
        .command_valid,
        .command_ready,
        .command_frame(32'h11223344),
        .command_timestamp(64'h5566778899aabbcc),
        .command_id(8'h23),
        .command_parameter(32'hddeeff00),
        .command_epoch(32'h12345678),
        .command_fence(64'd1),
        .active,
        .ddram_active(ring_ddram_active),
        .full,
        .packet_done,
        .producer_fence,
        .consumer_fence,
        .protocol_error,
        .ddram_read(ring_read),
        .ddram_write(ring_write),
        .ddram_burst_count(ring_burst),
        .ddram_address(ring_address),
        .ddram_write_data(ring_write_data),
        .ddram_byte_enable(ring_byte_enable),
        .ddram_busy(ring_busy),
        .ddram_command_accepted(ring_command_accepted),
        .ddram_read_data(ring_read_data),
        .ddram_read_data_ready(ring_read_data_ready)
    );

    nds_ddram_arbiter arbiter (
        .clk,
        .reset,
        .a_rd(ring_read),
        .a_we(ring_write),
        .a_burstcnt(ring_burst),
        .a_addr(ring_address),
        .a_din(ring_write_data),
        .a_be(ring_byte_enable),
        .a_busy(ring_busy),
        .a_dout(ring_read_data),
        .a_dout_ready(ring_read_data_ready),
        .a_command_accepted(ring_command_accepted),
        .b_rd(1'b0),
        .b_we(1'b0),
        .b_burstcnt(8'd1),
        .b_addr(29'd0),
        .b_din(64'd0),
        .b_be(8'hff),
        .b_busy(),
        .b_dout(),
        .b_dout_ready(),
        .b_command_accepted(),
        .debug_state(),
        .ddram_rd(outer_read),
        .ddram_we(outer_write),
        .ddram_burstcnt(outer_burst),
        .ddram_addr(outer_address),
        .ddram_din(outer_write_data),
        .ddram_be(outer_byte_enable),
        .ddram_busy(physical_busy),
        .ddram_dout(64'd0),
        .ddram_dout_ready(1'b0)
    );

    always @(posedge clk) begin
        if (outer_write && physical_busy)
            queued_stall_cycles <= queued_stall_cycles + 1;
        if (ring_command_accepted && !ring_ddram_active)
            $fatal(1,
                "ddram_active did not cover a physical acceptance edge");
        if (ring_command_accepted && !ring_write)
            acceptance_without_request <=
                acceptance_without_request + 1;
        if (outer_write && !physical_busy) begin
            if (physical_accepts >= 4)
                $fatal(1, "arbiter accepted a fifth GX packet beat");
            if (outer_read || outer_burst != 1 ||
                outer_byte_enable != 8'hff)
                $fatal(1, "bad outer GX DDR write shape");
            accepted_address[physical_accepts] <= outer_address;
            accepted_data[physical_accepts] <= outer_write_data;
            physical_accepts <= physical_accepts + 1;
        end
    end

    task automatic physically_accept_beat(
        input integer beat,
        input integer stall_cycles
    );
        integer accepts_before;
        begin
            accepts_before = physical_accepts;
            wait (outer_write);
            #1;
            if (outer_address !=
                BASE + HEADER_WORDS64 + beat)
                $fatal(1,
                    "queued arbiter beat %0d used address %h",
                    beat, outer_address);
            repeat (stall_cycles) begin
                @(posedge clk);
                #1;
                if (physical_accepts != accepts_before ||
                    producer_fence != 0 || packet_done)
                    $fatal(1,
                        "queued but stalled arbiter beat retired early");
            end
            @(negedge clk);
            physical_busy = 0;
            wait (physical_accepts == accepts_before + 1);
            #1;
            @(negedge clk);
            physical_busy = 1;
        end
    endtask

    initial begin : timeout_guard
        repeat (500) @(posedge clk);
        $fatal(1,
            "arbiter acceptance timeout accepts=%0d producer=%0d ring_state=%0d",
            physical_accepts, producer_fence, ring.state);
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;
        command_valid = 1;
        wait (command_ready);
        @(posedge clk);
        @(negedge clk);
        command_valid = 0;

        physically_accept_beat(0, 3);
        physically_accept_beat(1, 2);
        physically_accept_beat(2, 4);
        physically_accept_beat(3, 8);
        #1;

        if (physical_accepts != 4 || producer_fence != 1 ||
            !packet_done || active || full || consumer_fence != 0 ||
            protocol_error)
            $fatal(1,
                "ring did not retire exactly one arbiter-backed packet");
        if (acceptance_without_request != 4)
            $fatal(1,
                "physical acceptance did not occur behind client busy");
        if (queued_stall_cycles < 17)
            $fatal(1, "outer DDR stall coverage was incomplete");
        if (accepted_address[0] != BASE + HEADER_WORDS64 ||
            accepted_address[1] != BASE + HEADER_WORDS64 + 1 ||
            accepted_address[2] != BASE + HEADER_WORDS64 + 2 ||
            accepted_address[3] != BASE + HEADER_WORDS64 + 3)
            $fatal(1, "arbiter-backed GX packet beat order changed");
        if (accepted_data[0] !=
                {24'd0, 8'h23, 32'hddeeff00} ||
            accepted_data[1] != 64'h5566778899aabbcc ||
            accepted_data[2] !=
                {32'h12345678, 32'h11223344} ||
            accepted_data[3] != 64'd1)
            $fatal(1, "arbiter-backed GX packet payload changed");

        $display(
            "PASS: GX DDR ring retires queued beats only on the arbiter's later physical acceptance pulse");
        $display(
            "INFO: outer_accepts=%0d queued_stall_cycles=%0d accept_without_client_request=%0d",
            physical_accepts, queued_stall_cycles,
            acceptance_without_request);
        $finish;
    end
endmodule

// MiSTer's DDR bridge may return a one-beat read on the same physical edge
// that accepts the command.  Fill a depth-two ring, then use that exact arbiter
// response shape to release a held third packet.
module tb_nds_gx_ddr_command_ring_acceptance_edge_read;
    localparam logic [28:0] BASE = 29'h00350000;
    localparam integer HEADER_WORDS64 = 8;

    logic clk = 0;
    logic reset = 1;
    logic command_valid = 0;
    logic command_ready;
    logic [63:0] command_fence = 0;
    logic active;
    logic ring_ddram_active;
    logic full;
    logic packet_done;
    logic [63:0] producer_fence;
    logic [63:0] consumer_fence;
    logic protocol_error;

    logic ring_read;
    logic ring_write;
    logic [7:0] ring_burst;
    logic [28:0] ring_address;
    logic [63:0] ring_write_data;
    logic [7:0] ring_byte_enable;
    logic ring_busy;
    logic ring_command_accepted;
    logic [63:0] ring_read_data;
    logic ring_read_data_ready;

    logic outer_read;
    logic outer_write;
    logic [7:0] outer_burst;
    logic [28:0] outer_address;
    logic [63:0] outer_write_data;
    logic [7:0] outer_byte_enable;
    wire physical_busy = !(outer_read || outer_write);
    wire physical_read_ready = outer_read && !physical_busy;

    integer input_handshakes = 0;
    integer completed_packets = 0;
    integer physical_writes = 0;
    integer physical_reads = 0;
    integer same_edge_reads = 0;

    always #5 clk = ~clk;

    nds_gx_ddr_command_ring #(
        .BASE_WORD(BASE),
        .ENTRY_COUNT(2),
        .HEADER_WORDS64(HEADER_WORDS64),
        .CONSUMER_WORD_OFFSET(0)
    ) ring (
        .clk,
        .reset,
        .command_valid,
        .command_ready,
        .command_frame(32'h01020304 + command_fence[31:0]),
        .command_timestamp(
            64'h1111222233330000 + command_fence
        ),
        .command_id(8'h23),
        .command_parameter(
            32'h44550000 + command_fence[31:0]
        ),
        .command_epoch(32'h66778899),
        .command_fence,
        .active,
        .ddram_active(ring_ddram_active),
        .full,
        .packet_done,
        .producer_fence,
        .consumer_fence,
        .protocol_error,
        .ddram_read(ring_read),
        .ddram_write(ring_write),
        .ddram_burst_count(ring_burst),
        .ddram_address(ring_address),
        .ddram_write_data(ring_write_data),
        .ddram_byte_enable(ring_byte_enable),
        .ddram_busy(ring_busy),
        .ddram_command_accepted(ring_command_accepted),
        .ddram_read_data(ring_read_data),
        .ddram_read_data_ready(ring_read_data_ready)
    );

    nds_ddram_arbiter arbiter (
        .clk,
        .reset,
        .a_rd(ring_read),
        .a_we(ring_write),
        .a_burstcnt(ring_burst),
        .a_addr(ring_address),
        .a_din(ring_write_data),
        .a_be(ring_byte_enable),
        .a_busy(ring_busy),
        .a_dout(ring_read_data),
        .a_dout_ready(ring_read_data_ready),
        .a_command_accepted(ring_command_accepted),
        .b_rd(1'b0),
        .b_we(1'b0),
        .b_burstcnt(8'd1),
        .b_addr(29'd0),
        .b_din(64'd0),
        .b_be(8'hff),
        .b_busy(),
        .b_dout(),
        .b_dout_ready(),
        .b_command_accepted(),
        .debug_state(),
        .ddram_rd(outer_read),
        .ddram_we(outer_write),
        .ddram_burstcnt(outer_burst),
        .ddram_addr(outer_address),
        .ddram_din(outer_write_data),
        .ddram_be(outer_byte_enable),
        .ddram_busy(physical_busy),
        .ddram_dout(64'd1),
        .ddram_dout_ready(physical_read_ready)
    );

    always @(posedge clk) begin
        if (command_valid && command_ready)
            input_handshakes <= input_handshakes + 1;
        if (packet_done)
            completed_packets <= completed_packets + 1;
        if (outer_write && !physical_busy)
            physical_writes <= physical_writes + 1;
        if (outer_read && !physical_busy) begin
            physical_reads <= physical_reads + 1;
            if (ring_command_accepted && ring_read_data_ready &&
                ring_read_data == 64'd1)
                same_edge_reads <= same_edge_reads + 1;
        end
    end

    task automatic issue_packet(input logic [63:0] fence);
        integer target_handshakes;
        integer target_completions;
        begin
            target_handshakes = input_handshakes + 1;
            target_completions = completed_packets + 1;
            @(negedge clk);
            command_fence = fence;
            command_valid = 1;
            while (input_handshakes < target_handshakes) begin
                @(posedge clk);
                #1;
            end
            @(negedge clk);
            command_valid = 0;
            while (completed_packets < target_completions) begin
                @(posedge clk);
                #1;
            end
        end
    endtask

    initial begin : timeout_guard
        repeat (800) @(posedge clk);
        $fatal(1,
            "acceptance-edge read timeout producer=%0d consumer=%0d state=%0d",
            producer_fence, consumer_fence, ring.state);
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        issue_packet(64'd1);
        issue_packet(64'd2);
        #1;
        if (!full || producer_fence != 2 || consumer_fence != 0)
            $fatal(1, "depth-two ring did not reach full");

        issue_packet(64'd3);
        #1;
        if (producer_fence != 3 || consumer_fence != 1 ||
            completed_packets != 3 || input_handshakes != 3 ||
            physical_writes != 12 || physical_reads != 1 ||
            same_edge_reads != 1 || protocol_error)
            $fatal(1,
                "acceptance-edge consumer response was lost");
        if (!full)
            $fatal(1,
                "depth-two occupancy after packet three is incorrect");

        $display(
            "PASS: GX DDR ring consumes an HPS progress word returned on the read-command acceptance edge");
        $display(
            "INFO: packets=%0d writes=%0d reads=%0d same_edge_reads=%0d",
            completed_packets, physical_writes, physical_reads,
            same_edge_reads);
        $finish;
    end
endmodule
