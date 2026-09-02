module tb_nds_posted_ring_physical_accept;
    localparam logic [28:0] BASE = 29'h00310000;
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

    logic outer_read;
    logic outer_write;
    logic [7:0] outer_burst;
    logic [28:0] outer_address;
    logic [63:0] outer_write_data;
    logic [7:0] outer_be;
    logic physical_busy = 1;
    logic [63:0] physical_read_data = 0;
    logic physical_read_ready = 0;

    logic b_busy;
    logic [63:0] b_dout;
    logic b_dout_ready;
    logic b_command_accepted;

    logic [63:0] memory [0:31];
    logic [28:0] accepted_address [0:3];
    integer physical_write_accepts = 0;

    always #5 clk = ~clk;

`ifdef LEGACY_RING
    // The authoritative r191 source has no physical-acceptance input.
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
        .consumer_ack(1'b0),
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
        .ddram_read_data(64'h0),
        .ddram_read_data_ready(1'b0)
    );
`else
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
`endif

    nds_ddram_arbiter arbiter (
        .clk, .reset,
        .a_rd(ring_read), .a_we(ring_write),
        .a_burstcnt(ring_burst), .a_addr(ring_address),
        .a_din(ring_write_data), .a_be(ring_be),
        .a_busy(ring_busy), .a_dout(), .a_dout_ready(),
        .a_command_accepted(ring_command_accepted),
        .b_rd(1'b0), .b_we(1'b0), .b_burstcnt(8'd1),
        .b_addr(29'd0), .b_din(64'd0), .b_be(8'hff),
        .b_busy, .b_dout, .b_dout_ready, .b_command_accepted,
        .ddram_rd(outer_read), .ddram_we(outer_write),
        .ddram_burstcnt(outer_burst), .ddram_addr(outer_address),
        .ddram_din(outer_write_data), .ddram_be(outer_be),
        .ddram_busy(physical_busy),
        .ddram_dout(physical_read_data),
        .ddram_dout_ready(physical_read_ready)
    );

    always_ff @(posedge clk) begin
        if (outer_write && !physical_busy) begin
            accepted_address[physical_write_accepts] <= outer_address;
            memory[outer_address - BASE] <= outer_write_data;
            physical_write_accepts <= physical_write_accepts + 1;
        end
    end

    initial begin : timeout_guard
        repeat (300) @(posedge clk);
        $fatal(1,
            "timeout writes=%0d producer=%0d state=%0d pending=%0d",
            physical_write_accepts, producer_sequence,
            ring.state, arbiter.command_pending);
    end

    initial begin
        integer index;
        for (index = 0; index < 32; index = index + 1)
            memory[index] = 0;
        repeat (3) @(posedge clk);
        reset = 0;
        @(negedge clk);
        request = 1;

        // Queue the address/data beat while the physical port is stalled.
        wait (outer_write &&
              outer_address == BASE + HEADER_WORDS64);
        if (producer_sequence != 0)
            $fatal(1, "producer advanced before first physical write");

        // Accept the first two beats, then stall the final atomic commit.
        @(negedge clk);
        physical_busy = 0;
        wait (physical_write_accepts == 2);

        wait (outer_write &&
              outer_address == BASE + HEADER_WORDS64 + 2);
        // The command is now held in the outer queue but has not yet reached
        // a physical acceptance edge.
        physical_busy = 1;
        #1;
        if (producer_sequence != 0)
            $fatal(1,
                "sequence retired at queue admission before physical accept");
        repeat (3) begin
            @(posedge clk);
            #1;
            if (producer_sequence != 0 || done)
                $fatal(1,
                    "stalled commit advanced producer or asserted done");
        end

        @(negedge clk);
        physical_busy = 0;
        wait (physical_write_accepts == 3);
        #1;
        if (producer_sequence != 1 || !done)
            $fatal(1, "physical commit did not retire exactly once");
        if (accepted_address[0] != BASE + HEADER_WORDS64 ||
            accepted_address[1] != BASE + HEADER_WORDS64 + 1 ||
            accepted_address[2] != BASE + HEADER_WORDS64 + 2)
            $fatal(1, "posted entry beats reached DDR out of order");
        if (memory[HEADER_WORDS64 + 2] != 64'h0000000000000001)
            $fatal(1, "atomic sequence word was not physically committed");

        @(negedge clk);
        request = 0;
        wait (!active);
        $display("PASS: posted ring retires each beat only after its physical DDR acceptance");
        $finish;
    end
endmodule
