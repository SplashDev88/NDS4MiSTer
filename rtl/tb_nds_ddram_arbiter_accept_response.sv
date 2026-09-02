module tb_nds_ddram_arbiter_accept_response;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic a_rd = 0, a_we = 0, b_rd = 0, b_we = 0;
    logic [7:0] a_burst = 1, b_burst = 1;
    logic [28:0] a_addr = 29'h00123456, b_addr = 0;
    logic [63:0] a_din = 0, b_din = 0;
    logic [7:0] a_be = 8'hff, b_be = 8'hff;
    logic a_busy, b_busy, a_ready, b_ready;
    logic [63:0] a_dout, b_dout;
    logic ddram_rd, ddram_we;
    logic [7:0] ddram_burst, ddram_be;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din, ddram_dout = 0;
    logic ddram_busy = 0, ddram_ready = 0;

    integer accepted_responses = 0;
    integer b_accepted_responses = 0;

    nds_ddram_arbiter dut (
        .clk, .reset,
        .a_rd, .a_we, .a_burstcnt(a_burst), .a_addr, .a_din, .a_be,
        .a_busy, .a_dout, .a_dout_ready(a_ready),
        .b_rd, .b_we, .b_burstcnt(b_burst), .b_addr, .b_din, .b_be,
        .b_busy, .b_dout, .b_dout_ready(b_ready),
        .ddram_rd, .ddram_we, .ddram_burstcnt(ddram_burst),
        .ddram_addr, .ddram_din, .ddram_be,
        .ddram_busy, .ddram_dout, .ddram_dout_ready(ddram_ready)
    );

    always @(posedge clk) begin
        if (a_ready) begin
            case (accepted_responses)
                0: if (a_dout !== 64'h1122334455667788)
                    $fatal(1, "one-beat same-edge data mismatch %h", a_dout);
                1: if (a_dout !== 64'haabbccddeeff0011)
                    $fatal(1, "burst first same-edge data mismatch %h", a_dout);
                2: if (a_dout !== 64'h0123456789abcdef)
                    $fatal(1, "burst trailing data mismatch %h", a_dout);
                default:
                    $fatal(1, "duplicate acceptance-edge response");
            endcase
            accepted_responses <= accepted_responses + 1;
        end
        if (b_ready) begin
            if (b_accepted_responses != 0 ||
                b_dout !== 64'hfedcba9876543210)
                $fatal(1, "client-B same-edge data mismatch %h", b_dout);
            b_accepted_responses <= b_accepted_responses + 1;
        end
    end

    initial begin
        repeat (300) @(posedge clk);
        $fatal(1,
            "timeout responses=%0d/%0d a_busy=%0d selected_b=%0d dwell=%0d selected_request=%0d pending=%0d read_pending=%0d beats=%0d rd=%0d ready=%0d",
            accepted_responses, b_accepted_responses, a_busy,
            dut.selected_b, dut.grant_dwell,
            dut.selected_request, dut.command_pending, dut.read_pending,
            dut.beats_remaining, ddram_rd, ddram_ready);
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Model a registered client issuing one read after observing its
        // grant. The physical DDR port accepts the queued command and returns
        // its one-beat response on that same clock edge. MiSTer's interface
        // permits this; the arbiter must route and retire the beat rather than
        // entering read_pending after the only response has already passed.
        do @(negedge clk); while (a_busy);
        a_rd = 1;
        @(posedge clk);
        @(negedge clk);
        if (!dut.command_pending || !ddram_rd)
            $fatal(1, "one-beat request was not queued");
        a_rd = 0;
        if (ddram_addr !== a_addr || ddram_burst !== 1)
            $fatal(1, "queued read payload mismatch");
        ddram_dout = 64'h1122334455667788;
        ddram_ready = 1;
        @(posedge clk);
        @(negedge clk);
        ddram_ready = 0;

        repeat (4) @(posedge clk);
        if (accepted_responses != 1)
            $fatal(1, "acceptance-edge response was lost: responses=%0d",
                   accepted_responses);
        if (dut.read_pending || dut.command_pending)
            $fatal(1, "arbiter deadlocked after acceptance-edge response");

        // A two-beat command can return its first beat on the acceptance edge
        // as well. Count that beat immediately and retain ownership for only
        // the one remaining response.
        a_burst = 2;
        do @(negedge clk); while (a_busy);
        a_rd = 1;
        @(posedge clk);
        @(negedge clk);
        if (!dut.command_pending || !ddram_rd)
            $fatal(1, "two-beat request was not queued");
        a_rd = 0;
        if (ddram_addr !== a_addr || ddram_burst !== 2)
            $fatal(1, "queued burst payload mismatch");
        ddram_dout = 64'haabbccddeeff0011;
        ddram_ready = 1;
        @(posedge clk);
        @(negedge clk);
        ddram_ready = 0;
        if (!dut.read_pending || dut.beats_remaining !== 1)
            $fatal(1, "burst did not retain exactly one trailing beat");

        // Keep a full low cycle between response beats so the testbench never
        // relies on event-order races between clocked logic and stimulus.
        @(posedge clk);
        @(negedge clk);
        ddram_dout = 64'h0123456789abcdef;
        ddram_ready = 1;
        @(posedge clk);
        @(negedge clk);
        ddram_ready = 0;

        repeat (4) @(posedge clk);
        if (accepted_responses != 3 || dut.read_pending ||
            dut.command_pending)
            $fatal(1, "acceptance-edge burst accounting failed");

        // Exercise the other ownership branch too. The immediate beat must be
        // routed from the queued command owner, never whichever client becomes
        // selected after the command retires.
        do @(negedge clk); while (b_busy);
        b_rd = 1;
        @(posedge clk);
        @(negedge clk);
        if (!dut.command_pending || !dut.command_owner_b || !ddram_rd)
            $fatal(1, "client-B request was not queued with B ownership");
        b_rd = 0;
        ddram_dout = 64'hfedcba9876543210;
        ddram_ready = 1;
        @(posedge clk);
        @(negedge clk);
        ddram_ready = 0;

        repeat (4) @(posedge clk);
        if (accepted_responses != 3 || b_accepted_responses != 1 ||
            dut.read_pending || dut.command_pending)
            $fatal(1, "client-B acceptance-edge routing failed");

        $display("PASS: DDR arbiter retains acceptance-edge read responses");
        $finish;
    end
endmodule
