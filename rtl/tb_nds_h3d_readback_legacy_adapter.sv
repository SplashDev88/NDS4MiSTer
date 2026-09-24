`timescale 1ns/1ps
module tb_nds_h3d_readback_legacy_adapter;
    logic clk = 0;
    logic boot_reset = 1;
    logic cancel = 0;
    logic read = 0;
    logic [28:0] address = 0;
    wire busy, command_accepted, read_data_ready, ch_request;
    wire [63:0] read_data;
    wire [27:1] ch_address;
    logic ch_ready = 0;
    logic [63:0] ch_data = 0;
    integer request_count = 0;
    integer accepted_count = 0;
    integer response_count = 0;
    integer canceled_count = 0;
    logic previous_request = 0;
    logic previous_accepted = 0;
    logic previous_response = 0;
    nds_h3d_readback_legacy_adapter dut (.*);
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (ch_request) request_count = request_count + 1;
        if (command_accepted) accepted_count = accepted_count + 1;
        if (read_data_ready) response_count = response_count + 1;
        if ((ch_request && previous_request) ||
            (command_accepted && previous_accepted) ||
            (read_data_ready && previous_response))
            $fatal(1, "adapter request/completion was not one clock pulse");
        if (command_accepted && read_data_ready)
            $fatal(1, "data arrived on acceptance edge instead of next edge");
        previous_request = ch_request;
        previous_accepted = command_accepted;
        previous_response = read_data_ready;
    end

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic launch(input logic [28:0] word_address);
        begin
            @(negedge clk);
            if (busy) $fatal(1, "launch fixture requires an idle adapter");
            address = word_address;
            read = 1;
            tick();
            if (!busy || !ch_request || command_accepted || read_data_ready ||
                ch_address !== {word_address[24:0], 2'b00})
                $fatal(1, "request pulse/address translation/early acceptance mismatch");
            // Actual legacy DDR output is {0011,ch_address[27:3]}, placing
            // reply offset 0x200 at physical DDR address 0x3fc00200 / 8.
            if (word_address == 29'h01f80040 &&
                {4'b0011, ch_address[27:3]} !== 29'h07f80040)
                $fatal(1, "reply base translated to wrong physical DDR word");
        end
    endtask

    task automatic delay_owned(input integer clocks);
        integer requests_before;
        begin
            tick(); // Observe and count the request pulse just launched.
            requests_before = request_count;
            repeat (clocks) begin
                tick();
                if (!busy || ch_request || command_accepted || read_data_ready ||
                    request_count != requests_before)
                    $fatal(1, "held upstream read duplicated or retired before channel completion");
            end
        end
    endtask

    task automatic deliver(input logic [63:0] value);
        begin
            @(negedge clk);
            ch_data = value;
            ch_ready = 1;
            tick();
            if (!command_accepted || read_data_ready || !busy || read_data !== value)
                $fatal(1, "channel completion did not produce late acceptance");
            @(negedge clk);
            read = 0;
            ch_ready = 0;
            ch_data = ~value;
            tick();
            if (command_accepted || !read_data_ready || read_data !== value || ch_request)
                $fatal(1, "data was not retained for next-cycle response");
            tick();
            if (busy || command_accepted || read_data_ready || ch_request)
                $fatal(1, "transaction did not release ownership exactly once");
        end
    endtask

    integer i;
    integer requests_before_cancel;
    integer accepts_before_cancel;
    integer responses_before_cancel;
    initial begin
        tick(); tick();
        @(negedge clk);
        boot_reset = 0;
        tick();
        if (busy || command_accepted || read_data_ready || ch_request)
            $fatal(1, "boot reset did not initialize adapter");
        launch(29'h01f80040);
        delay_owned(13);
        deliver(64'h0123456789abcdef);

        // Exercise all 16 reply beats, preserving each doubleword offset.
        for (i = 0; i < 16; i = i + 1) begin
            launch(29'h01f80040 + i);
            delay_owned(i % 4);
            deliver(64'hfeedface00000000 + i);
        end

        // Cancel after publication to channel3: the old transaction remains
        // owned. An eager new upstream read cannot reuse that channel until
        // the old ch_ready has been drained, with no stale callbacks.
        launch(29'h01f8004f);
        delay_owned(2);
        requests_before_cancel = request_count;
        accepts_before_cancel = accepted_count;
        responses_before_cancel = response_count;
        @(negedge clk);
        read = 0;
        cancel = 1;
        tick();
        @(negedge clk);
        cancel = 0;
        address = 29'h01f80040;
        read = 1;
        repeat (8) begin
            tick();
            if (!busy || ch_request || command_accepted || read_data_ready ||
                request_count != requests_before_cancel ||
                ch_address !== {25'h1f8004f, 2'b00})
                $fatal(1, "cancellation dropped old channel ownership");
        end
        @(negedge clk);
        ch_ready = 1;
        ch_data = 64'hdead0000dead0000;
        tick();
        if (busy || command_accepted || read_data_ready || ch_request)
            $fatal(1, "canceled channel completion leaked callbacks or blocked drain");
        canceled_count = canceled_count + 1;
        @(negedge clk);
        ch_ready = 0;
        tick();
        if (!busy || !ch_request ||
            ch_address !== {25'h1f80040, 2'b00} ||
            accepted_count != accepts_before_cancel ||
            response_count != responses_before_cancel)
            $fatal(1, "new transaction not isolated from drained canceled transaction");
        delay_owned(3);
        deliver(64'h1234000012340000);

        // Cancellation on the very channel-completion edge also suppresses
        // both callbacks. A held cancel continues to block fresh requests.
        launch(29'h01f80041);
        delay_owned(1);
        @(negedge clk);
        cancel = 1;
        ch_ready = 1;
        tick();
        if (!busy || command_accepted || read_data_ready || ch_request)
            $fatal(1, "cancel/completion collision leaked a callback");
        canceled_count = canceled_count + 1;
        @(negedge clk);
        ch_ready = 0;
        repeat (3) begin
            tick();
            if (!busy || ch_request || command_accepted || read_data_ready)
                $fatal(1, "held cancel admitted a new request");
        end
        @(negedge clk);
        read = 0;
        cancel = 0;
        tick();

        // Cancellation after accepted but before the delayed data edge must
        // suppress the stale data pulse; a reset reader has lost that owner.
        launch(29'h01f80042);
        delay_owned(1);
        @(negedge clk);
        ch_ready = 1;
        ch_data = 64'hbad0bad0bad0bad0;
        tick();
        if (!command_accepted || read_data_ready) $fatal(1, "missing acceptance fixture");
        responses_before_cancel = response_count;
        @(negedge clk);
        read = 0;
        ch_ready = 0;
        cancel = 1;
        tick();
        if (command_accepted || read_data_ready)
            $fatal(1, "post-accept cancellation leaked delayed data");
        canceled_count = canceled_count + 1;
        @(negedge clk);
        cancel = 0;
        tick();
        if (busy || response_count != responses_before_cancel)
            $fatal(1, "post-accept cancel failed to release ownership");

        launch(29'h01f80043);
        delay_owned(0);
        deliver(64'h777788889999aaaa);
        if (request_count != 22 || accepted_count != 20 || response_count != 19 ||
            canceled_count != 3)
            $fatal(1, "unexpected ownership totals request=%0d accepted=%0d response=%0d canceled=%0d",
                   request_count, accepted_count, response_count, canceled_count);
        $display("PASS: legacy readback DDR adapter single requests, 16 translated beats, late acceptance, next-cycle data, held reads, canceled transaction drain; requests=%0d accepted=%0d responses=%0d canceled=%0d",
                 request_count, accepted_count, response_count, canceled_count);
        $finish;
    end
    initial begin
        #50000;
        $fatal(1, "legacy readback adapter test timeout");
    end
endmodule
