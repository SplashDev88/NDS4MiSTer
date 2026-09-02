module tb_nds_posted_ring_idle_high_waitrequest;
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
    logic physical_busy;
    logic b_busy;
    integer physical_write_accepts = 0;
    logic [28:0] accepted_address [0:2];

    always #5 clk = ~clk;

    // This is the important MiSTer bridge behavior missing from the earlier
    // posted-ring tests: waitrequest may remain asserted while the port is
    // idle and fall only after RD or WE is presented. Client admission must
    // therefore not depend on this raw idle level, and an idle selected
    // client must not prevent round-robin rotation.
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
        .b_rd(1'b0), .b_we(1'b0), .b_burstcnt(8'd1),
        .b_addr(29'd0), .b_din(64'd0), .b_be(8'hff),
        .b_busy, .b_dout(), .b_dout_ready(),
        .b_command_accepted(),
        .ddram_rd(outer_read), .ddram_we(outer_write),
        .ddram_burstcnt(outer_burst), .ddram_addr(outer_address),
        .ddram_din(outer_write_data), .ddram_be(outer_be),
        .ddram_busy(physical_busy),
        .ddram_dout(64'h0),
        .ddram_dout_ready(1'b0)
    );

    always_ff @(posedge clk) begin
        if (outer_write && !physical_busy) begin
            if (physical_write_accepts < 3)
                accepted_address[physical_write_accepts] <= outer_address;
            physical_write_accepts <= physical_write_accepts + 1;
        end
    end

    initial begin : timeout_guard
        repeat (80) @(posedge clk);
        $fatal(1,
            "idle-high waitrequest starved posted ring writes=%0d producer=%0d selected_b=%0d dwell=%0d pending=%0d",
            physical_write_accepts, producer_sequence,
            arbiter.selected_b, arbiter.grant_dwell,
            arbiter.command_pending);
    end

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        @(negedge clk);
        request = 1;

        wait (done);
        #1;
        if (physical_write_accepts != 3 || producer_sequence != 1)
            $fatal(1,
                "posted ring did not physically commit all three beats");
        if (accepted_address[0] != BASE + HEADER_WORDS64 ||
            accepted_address[1] != BASE + HEADER_WORDS64 + 1 ||
            accepted_address[2] != BASE + HEADER_WORDS64 + 2)
            $fatal(1, "posted ring beats reached DDR out of order");

        @(negedge clk);
        request = 0;
        wait (!active);
        $display("PASS: idle-high DDR waitrequest cannot strand an idle arbiter grant");
        $finish;
    end
endmodule
