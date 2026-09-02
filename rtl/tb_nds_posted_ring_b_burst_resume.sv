module tb_nds_posted_ring_b_burst_resume;
    localparam logic [28:0] BASE = 29'h00310000;
    localparam logic [28:0] B_ADDRESS = 29'h00420000;
    localparam integer HEADER_WORDS64 = 8;

    logic clk = 0;
    logic reset = 1;
    logic request = 0;
    logic accepted;
    logic active;
    logic ring_ddr_active;
    logic done;
    logic [31:0] producer_sequence;
    logic ring_read;
    logic ring_write;
    logic [7:0] ring_burst;
    logic [28:0] ring_address;
    logic [63:0] ring_write_data;
    logic [7:0] ring_be;
    logic ring_busy;
    logic ring_command_accepted;

    logic b_read = 0;
    logic b_busy;
    logic [63:0] b_dout;
    logic b_dout_ready;
    logic b_command_accepted;

    logic outer_read;
    logic outer_write;
    logic [7:0] outer_burst;
    logic [28:0] outer_address;
    logic [63:0] outer_write_data;
    logic [7:0] outer_be;
    logic physical_busy;
    logic [63:0] physical_read_data = 0;
    logic trailing_read_ready = 0;
    logic first_read_ready_enable = 1;
    wire acceptance_edge_read_ready =
        first_read_ready_enable && outer_read && !physical_busy &&
        outer_address == B_ADDRESS;
    wire physical_read_ready =
        acceptance_edge_read_ready || trailing_read_ready;

    logic [28:0] accepted_write_address [0:2];
    integer physical_write_accepts = 0;
    integer physical_read_accepts = 0;
    integer b_response_beats = 0;
    integer a_response_beats = 0;

    always #5 clk = ~clk;

    // Model MiSTer's legal idle-high waitrequest behavior. The queued outer
    // command makes a request visible, which then opens exactly one physical
    // acceptance edge before command_pending retires it.
    assign physical_busy = !(outer_read || outer_write);

    nds_hps_posted_write_ring #(
        .BASE_WORD(BASE),
        .ENTRY_COUNT(4),
        .HEADER_WORDS64(HEADER_WORDS64)
    ) ring (
        .clk, .reset, .request,
        .cpu_is_arm9(1'b1),
        .elapsed_cycles(32'h1234),
        .address(32'h0600c000),
        .access(2'b01),
        .write_data(32'h000055aa),
        .session_epoch(32'h0),
        .session_capabilities(32'h0),
        .consumer_ack(1'b0),
        .consumer_ack_epoch(32'h0),
        .consumer_ack_sequence(32'h0),
        .accepted, .active,
        .ddram_active(ring_ddr_active),
        .done, .producer_sequence,
        .ddram_read(ring_read),
        .ddram_write(ring_write),
        .ddram_burst_count(ring_burst),
        .ddram_address(ring_address),
        .ddram_write_data(ring_write_data),
        .ddram_byte_enable(ring_be),
        .ddram_busy(ring_busy),
        .ddram_command_accepted(ring_command_accepted),
        .ddram_read_data(64'h0),
        .ddram_read_data_ready(1'b0)
    );

    nds_ddram_arbiter arbiter (
        .clk, .reset,
        .a_rd(ring_read), .a_we(ring_write),
        .a_burstcnt(ring_burst), .a_addr(ring_address),
        .a_din(ring_write_data), .a_be(ring_be),
        .a_busy(ring_busy), .a_dout(), .a_dout_ready(),
        .a_command_accepted(ring_command_accepted),
        .b_rd(b_read), .b_we(1'b0), .b_burstcnt(8'd8),
        .b_addr(B_ADDRESS), .b_din(64'd0), .b_be(8'hff),
        .b_busy, .b_dout, .b_dout_ready,
        .b_command_accepted,
        .ddram_rd(outer_read), .ddram_we(outer_write),
        .ddram_burstcnt(outer_burst), .ddram_addr(outer_address),
        .ddram_din(outer_write_data), .ddram_be(outer_be),
        .ddram_busy(physical_busy),
        .ddram_dout(physical_read_data),
        .ddram_dout_ready(physical_read_ready)
    );

    always_ff @(posedge clk) begin
        if (outer_write && !physical_busy) begin
            if (physical_write_accepts >= 3)
                $fatal(1, "unexpected fourth physical A write");
            accepted_write_address[physical_write_accepts] <= outer_address;
            physical_write_accepts <= physical_write_accepts + 1;
        end
        if (outer_read && !physical_busy) begin
            if (outer_address != B_ADDRESS || outer_burst != 8)
                $fatal(1, "unexpected physical B read %h/%0d",
                       outer_address, outer_burst);
            physical_read_accepts <= physical_read_accepts + 1;
            first_read_ready_enable <= 0;
        end
        if (a_response_beats != 0)
            $fatal(1, "B response was routed to A");
        if (b_dout_ready)
            b_response_beats <= b_response_beats + 1;
    end

    // This client-A output is intentionally unused by the write-only ring,
    // but count it explicitly so response-owner errors cannot pass silently.
    always_ff @(posedge clk) begin
        if (arbiter.a_dout_ready)
            a_response_beats <= a_response_beats + 1;
    end

    initial begin : timeout_guard
        repeat (400) @(posedge clk);
        $fatal(1,
            "timeout writes=%0d reads=%0d responses=%0d state=%0d pending=%0d read_pending=%0d remaining=%0d",
            physical_write_accepts, physical_read_accepts,
            b_response_beats, ring.state, arbiter.command_pending,
            arbiter.read_pending, arbiter.beats_remaining);
    end

    initial begin
        integer beat;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        request = 1;

        // Let address/data and cycles/control commit first. Their second
        // physical acceptance advances the ring into WRITE_SEQUENCE and hands
        // the outer arbiter's next grant to B on the same edge.
        wait (physical_write_accepts == 2);
        #1;
        if (ring.state != 6 || producer_sequence != 0)
            $fatal(1,
                "ring did not wait at sequence commit after A beat2");

        @(negedge clk);
        b_read = 1;
        @(posedge clk);
        @(negedge clk);
        if (!arbiter.command_pending || !arbiter.command_owner_b ||
            !outer_read || outer_address != B_ADDRESS || outer_burst != 8)
            $fatal(1, "B burst was not queued before the A commit");
        b_read = 0;

        // Beat zero is returned on the same edge that the queued B read is
        // physically accepted. r191's acceptance-edge logic must route it and
        // retain exactly seven trailing responses.
        wait (physical_read_accepts == 1);
        #1;
        if (!arbiter.read_pending || arbiter.beats_remaining != 7 ||
            b_response_beats != 1)
            $fatal(1,
                "acceptance-edge first beat was not counted: pending=%0d remaining=%0d responses=%0d",
                arbiter.read_pending, arbiter.beats_remaining,
                b_response_beats);
        if (physical_write_accepts != 2)
            $fatal(1, "A commit passed B before its responses completed");

        // Return six more beats with a low sampled cycle between each. Seven
        // total responses must leave the arbiter waiting for exactly one.
        for (beat = 1; beat <= 6; beat = beat + 1) begin
            @(negedge clk);
            physical_read_data = 64'hb000000000000000 | beat;
            trailing_read_ready = 1;
            @(posedge clk);
            @(negedge clk);
            trailing_read_ready = 0;
        end
        #1;
        if (!arbiter.read_pending || arbiter.beats_remaining != 1 ||
            b_response_beats != 7)
            $fatal(1,
                "seven responses did not retain exactly one beat: pending=%0d remaining=%0d responses=%0d",
                arbiter.read_pending, arbiter.beats_remaining,
                b_response_beats);
        if (physical_write_accepts != 2 || producer_sequence != 0 || done)
            $fatal(1, "A commit retired before the eighth B response");

        // The eighth response retires B. The held posted sequence command must
        // then regain A, enter the outer queue, and reach physical acceptance.
        @(negedge clk);
        physical_read_data = 64'hb000000000000007;
        trailing_read_ready = 1;
        @(posedge clk);
        @(negedge clk);
        trailing_read_ready = 0;

        wait (physical_write_accepts == 3);
        #1;
        if (arbiter.read_pending || b_response_beats != 8)
            $fatal(1, "B burst did not retire after exactly eight responses");
        if (physical_read_accepts != 1)
            $fatal(1, "B read command was accepted more than once");
        if (accepted_write_address[0] != BASE + HEADER_WORDS64 ||
            accepted_write_address[1] != BASE + HEADER_WORDS64 + 1 ||
            accepted_write_address[2] != BASE + HEADER_WORDS64 + 2)
            $fatal(1, "A write order changed around B burst");
        if (producer_sequence != 1 || !done)
            $fatal(1, "A commit did not retire after the complete B burst");

        @(negedge clk);
        request = 0;
        wait (!active);
        $display("PASS: posted A commit resumes after an acceptance-edge eight-beat B burst with idle-high waitrequest");
        $finish;
    end
endmodule
