module tb_nds_sound_ddr_read_adapter;
    logic clk = 0;
    logic reset = 1;
    logic sound_request = 0;
    logic [31:0] sound_address = 0;
    logic sound_done;
    logic [31:0] sound_data;
    logic sound_busy;
    logic protocol_error;
    logic ddram_read;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic ddram_command_accepted = 0;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;
    logic ddram_epoch_quiescent = 0;

    integer held_cycles = 0;
    integer accepted_requests = 0;

    always #5 clk = ~clk;

    nds_sound_ddr_read_adapter dut (.*);

    always @(posedge clk) begin
        if (!reset && ddram_read)
            held_cycles <= held_cycles + 1;
        if (!reset && ddram_command_accepted)
            accepted_requests <= accepted_requests + 1;
    end

    task automatic request(input logic [31:0] address);
        begin
            @(negedge clk);
            sound_address = address;
            sound_request = 1;
            @(negedge clk);
            sound_request = 0;
        end
    endtask

    task automatic release_epoch;
        begin
            @(negedge clk);
            ddram_epoch_quiescent = 1;
            @(posedge clk);
            #1;
            if (sound_busy)
                $fatal(1, "adapter did not leave reset quarantine");
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        // A stale-high acknowledgement across reset is insufficient. The
        // adapter requires an explicit low-to-high epoch handshake.
        ddram_epoch_quiescent = 1;
        reset = 0;
        repeat (2) begin
            @(posedge clk);
            #1;
            if (!sound_busy)
                $fatal(1, "stale-high epoch acknowledgement escaped quarantine");
        end
        @(negedge clk);
        ddram_epoch_quiescent = 0;
        @(posedge clk);
        release_epoch();

        // Upper 32-bit lane, with a long admission/physical-acceptance delay.
        request(32'h02000004);
        repeat (7) begin
            @(negedge clk);
            if (!ddram_read || ddram_address != 29'h05820000 ||
                ddram_burst_count != 1)
                $fatal(1, "request was not held stable before acceptance");
        end
        ddram_read_data = 64'h11223344_aabbccdd;
        ddram_read_data_ready = 1;
        ddram_command_accepted = 1;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'h11223344)
            $fatal(1, "same-edge upper-lane response mismatch");
        @(negedge clk);
        ddram_read_data_ready = 0;
        ddram_command_accepted = 0;

        // The second 4 MiB mirror maps to the same last DDR beat and selects
        // its upper word.
        request(32'h027ffffc);
        repeat (2) @(negedge clk);
        if (!ddram_read || ddram_address != 29'h0589ffff)
            $fatal(1, "second 4 MiB mirror endpoint mismatch");
        ddram_read_data = 64'h89abcdef_01234567;
        ddram_read_data_ready = 1;
        ddram_command_accepted = 1;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'h89abcdef)
            $fatal(1, "second-mirror upper-lane response mismatch");
        @(negedge clk);
        ddram_read_data_ready = 0;
        ddram_command_accepted = 0;

        // Reset in ISSUE retires the local epoch. A late acceptance/response
        // must be ignored until the wrapper proves the entire path quiescent.
        request(32'h02000300);
        repeat (2) @(negedge clk);
        ddram_epoch_quiescent = 0;
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        ddram_command_accepted = 1;
        ddram_read_data_ready = 1;
        ddram_read_data = 64'hbad0bad0_bad1bad1;
        @(posedge clk);
        #1;
        if (sound_done || !sound_busy)
            $fatal(1, "late ISSUE response escaped reset quarantine");
        @(negedge clk);
        ddram_command_accepted = 0;
        ddram_read_data_ready = 0;
        release_epoch();
        request(32'h02000300);
        repeat (2) @(negedge clk);
        ddram_command_accepted = 1;
        ddram_read_data_ready = 1;
        ddram_read_data = 64'h00000000_33333333;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'h33333333)
            $fatal(1, "post-ISSUE-reset request mismatch");
        @(negedge clk);
        ddram_command_accepted = 0;
        ddram_read_data_ready = 0;

        // Reset after physical acceptance but before response. A stale delayed
        // beat is likewise consumed only by quarantine.
        request(32'h02000400);
        repeat (2) @(negedge clk);
        ddram_command_accepted = 1;
        @(posedge clk);
        @(negedge clk);
        ddram_command_accepted = 0;
        if (ddram_read)
            $fatal(1, "WAIT_RESPONSE setup failed");
        ddram_epoch_quiescent = 0;
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        ddram_read_data_ready = 1;
        ddram_read_data = 64'hbad2bad2_bad3bad3;
        @(posedge clk);
        #1;
        if (sound_done || !sound_busy)
            $fatal(1, "late WAIT_RESPONSE beat escaped quarantine");
        @(negedge clk);
        ddram_read_data_ready = 0;
        release_epoch();
        request(32'h02000400);
        repeat (2) @(negedge clk);
        ddram_command_accepted = 1;
        ddram_read_data_ready = 1;
        ddram_read_data = 64'h00000000_44444444;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'h44444444)
            $fatal(1, "post-WAIT-reset request mismatch");
        @(negedge clk);
        ddram_command_accepted = 0;
        ddram_read_data_ready = 0;
        ddram_command_accepted = 0;

        // Lower 32-bit lane, with the response arriving after acceptance.
        request(32'h023ffff8);
        repeat (3) @(negedge clk);
        if (!ddram_read || ddram_address != 29'h0589ffff)
            $fatal(1, "4 MiB mirror/address translation mismatch");
        ddram_command_accepted = 1;
        @(negedge clk);
        ddram_command_accepted = 0;
        if (ddram_read)
            $fatal(1, "request remained asserted after physical acceptance");
        repeat (5) @(negedge clk);
        ddram_read_data = 64'hcafef00d_76543210;
        ddram_read_data_ready = 1;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'h76543210)
            $fatal(1, "delayed lower-lane response mismatch");
        @(negedge clk);
        ddram_read_data_ready = 0;

        // An overlapping pulse is rejected and cannot replace the original.
        request(32'h02000100);
        request(32'h02000200);
        if (!protocol_error)
            $fatal(1, "overlapping sound request was not rejected");
        if (ddram_address != 29'h05820020)
            $fatal(1, "overlap corrupted the outstanding address");
        ddram_command_accepted = 1;
        ddram_read_data_ready = 1;
        ddram_read_data = 64'h00000000_deadbeef;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'hdeadbeef)
            $fatal(1, "overlap changed the original response");
        @(negedge clk);
        ddram_command_accepted = 0;
        ddram_read_data_ready = 0;

        if (accepted_requests != 8)
            $fatal(1, "accepted request count mismatch: %0d",
                accepted_requests);
        if (held_cycles < 12)
            $fatal(1, "held-request coverage too low: %0d", held_cycles);

        // Reset clears the overlap error; then prove malformed unaligned
        // requests fail closed without touching DDR.
        ddram_epoch_quiescent = 0;
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        release_epoch();
        request(32'h02000002);
        if (!sound_done || sound_data != 0 || !protocol_error || ddram_read)
            $fatal(1, "unaligned sample request did not fail closed");

        $display("PASS: Robert DS sound pulse adapter holds reads, checks lanes/mirrors/alignment, and quarantines reset epochs");
        $display("INFO: held_cycles=%0d accepted_requests=%0d",
            held_cycles, accepted_requests);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "timeout");
    end
endmodule
