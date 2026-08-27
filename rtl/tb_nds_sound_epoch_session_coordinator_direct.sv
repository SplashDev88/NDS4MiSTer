module tb_nds_sound_epoch_session_coordinator_direct;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic transport_quiescent = 1'b1;
    logic epoch_request_valid = 1'b0;
    logic epoch_request_ready;
    logic [31:0] epoch_request = 32'd0;
    logic epoch_request_fresh = 1'b0;

    logic ring_session_begin_valid;
    logic ring_session_begin_ready = 1'b1;
    logic [31:0] ring_session_begin_epoch;
    logic ring_session_epoch_fresh;
    logic ring_session_started = 1'b0;
    logic ring_session_active = 1'b0;
    logic [31:0] ring_active_epoch = 32'd0;
    logic ring_sequence_exhausted = 1'b0;
    logic ring_protocol_error = 1'b0;

    logic broadcaster_epoch_begin_valid;
    logic broadcaster_epoch_begin_ready = 1'b0;
    logic [31:0] broadcaster_epoch_begin;
    logic broadcaster_epoch_begin_fresh;
    logic broadcaster_epoch_started = 1'b0;
    logic broadcaster_epoch_active = 1'b0;
    logic [31:0] broadcaster_active_epoch = 32'd0;
    logic broadcaster_sequence_exhausted = 1'b0;
    logic broadcaster_protocol_error = 1'b0;

    logic queue_epoch_begin_valid;
    logic queue_epoch_begin_ready = 1'b0;
    logic [31:0] queue_epoch_begin;
    logic queue_epoch_begin_fresh;
    logic queue_epoch_started = 1'b0;
    logic queue_epoch_active = 1'b0;
    logic [31:0] queue_active_epoch = 32'd0;
    logic queue_capture_overflow = 1'b0;
    logic queue_sequence_exhausted = 1'b0;
    logic queue_protocol_error = 1'b0;

    logic drain_epoch_begin_valid;
    logic drain_epoch_begin_ready = 1'b0;
    logic [31:0] drain_epoch_begin;
    logic drain_epoch_begin_fresh;
    logic drain_epoch_started = 1'b0;
    logic drain_epoch_active = 1'b0;
    logic [31:0] drain_active_epoch = 32'd0;
    logic drain_sequence_exhausted = 1'b0;
    logic drain_protocol_error = 1'b0;
    logic drain_overflow = 1'b0;

    logic sound_data_activity = 1'b0;
    logic sound_epoch_ready;
    logic [31:0] active_epoch;
    logic sound_data_enable;
    logic sound_shadow_enable;
    logic sound_shadow_reset;
    logic protocol_error;
    logic terminal_fault;
    logic premature_activity;
    logic [7:0] fault_code;

    nds_sound_epoch_session_coordinator #(
        .DIRECT_COMPLETION_MODE(1'b1)
    ) dut (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_request_valid,
        .epoch_request_ready,
        .epoch_request,
        .epoch_request_fresh,
        .ring_session_begin_valid,
        .ring_session_begin_ready,
        .ring_session_begin_epoch,
        .ring_session_epoch_fresh,
        .ring_session_started,
        .ring_session_active,
        .ring_active_epoch,
        .ring_sequence_exhausted,
        .ring_protocol_error,
        .broadcaster_epoch_begin_valid,
        .broadcaster_epoch_begin_ready,
        .broadcaster_epoch_begin,
        .broadcaster_epoch_begin_fresh,
        .broadcaster_epoch_started,
        .broadcaster_epoch_active,
        .broadcaster_active_epoch,
        .broadcaster_sequence_exhausted,
        .broadcaster_protocol_error,
        .queue_epoch_begin_valid,
        .queue_epoch_begin_ready,
        .queue_epoch_begin,
        .queue_epoch_begin_fresh,
        .queue_epoch_started,
        .queue_epoch_active,
        .queue_active_epoch,
        .queue_capture_overflow,
        .queue_sequence_exhausted,
        .queue_protocol_error,
        .drain_epoch_begin_valid,
        .drain_epoch_begin_ready,
        .drain_epoch_begin,
        .drain_epoch_begin_fresh,
        .drain_epoch_started,
        .drain_epoch_active,
        .drain_active_epoch,
        .drain_sequence_exhausted,
        .drain_protocol_error,
        .drain_overflow,
        .sound_data_activity,
        .sound_epoch_ready,
        .active_epoch,
        .sound_data_enable,
        .sound_shadow_enable,
        .sound_shadow_reset,
        .protocol_error,
        .terminal_fault,
        .premature_activity,
        .fault_code
    );

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        logic [31:0] epoch;
        integer index;
        epoch = 32'h89abcdef;

        repeat (3)
            tick();
        @(negedge clk);
        reset = 1'b0;
        repeat (2)
            tick();
        if (epoch_request_ready)
            $fatal(1, "direct mode skipped low/high quarantine");

        @(negedge clk);
        transport_quiescent = 1'b0;
        tick();
        @(negedge clk);
        transport_quiescent = 1'b1;
        epoch_request_valid = 1'b1;
        epoch_request = epoch;
        epoch_request_fresh = 1'b1;
        while (!epoch_request_ready)
            tick();
        tick();
        @(negedge clk);
        epoch_request_valid = 1'b0;
        epoch_request = 32'd0;
        epoch_request_fresh = 1'b0;

        // The unused ring must stay completely passive.
        repeat (8) begin
            tick();
            if (ring_session_begin_valid ||
                ring_session_epoch_fresh)
                $fatal(1, "direct mode attempted ring startup");
        end
        if (!broadcaster_epoch_begin_valid ||
            !queue_epoch_begin_valid ||
            !drain_epoch_begin_valid)
            $fatal(1, "direct mode did not fan out epoch");

        // Accept in three widely separated cycles and prove retained payload.
        @(negedge clk);
        queue_epoch_begin_ready = 1'b1;
        tick();
        @(negedge clk);
        queue_epoch_begin_ready = 1'b0;
        queue_epoch_active = 1'b1;
        queue_active_epoch = epoch;
        queue_epoch_started = 1'b1;
        tick();
        @(negedge clk);
        queue_epoch_started = 1'b0;

        repeat (17) begin
            tick();
            if (!broadcaster_epoch_begin_valid ||
                broadcaster_epoch_begin != epoch ||
                !broadcaster_epoch_begin_fresh ||
                !drain_epoch_begin_valid ||
                drain_epoch_begin != epoch ||
                !drain_epoch_begin_fresh)
                $fatal(1, "direct fanout changed during long stall");
        end

        @(negedge clk);
        drain_epoch_begin_ready = 1'b1;
        tick();
        @(negedge clk);
        drain_epoch_begin_ready = 1'b0;
        drain_epoch_active = 1'b1;
        drain_active_epoch = epoch;
        drain_epoch_started = 1'b1;
        tick();
        @(negedge clk);
        drain_epoch_started = 1'b0;

        repeat (11)
            tick();
        @(negedge clk);
        broadcaster_epoch_begin_ready = 1'b1;
        tick();
        @(negedge clk);
        broadcaster_epoch_begin_ready = 1'b0;
        repeat (5)
            tick();
        @(negedge clk);
        broadcaster_epoch_active = 1'b1;
        broadcaster_active_epoch = epoch;
        broadcaster_epoch_started = 1'b1;
        tick();
        @(negedge clk);
        broadcaster_epoch_started = 1'b0;

        index = 0;
        while (!sound_epoch_ready && index < 20) begin
            tick();
            index = index + 1;
        end
        if (!sound_epoch_ready || active_epoch != epoch ||
            !sound_data_enable || !sound_shadow_enable ||
            sound_shadow_reset || protocol_error)
            $fatal(1, "direct completion mode did not become ready");

        // An unused ring fault is outside the direct authority and therefore
        // cannot tear down a valid direct-completion session.
        @(negedge clk);
        ring_protocol_error = 1'b1;
        ring_sequence_exhausted = 1'b1;
        tick();
        if (!sound_epoch_ready || protocol_error)
            $fatal(1, "unused ring poisoned direct completion mode");

        // The selected consumer authority remains fail-closed.
        @(negedge clk);
        drain_overflow = 1'b1;
        tick();
        if (!protocol_error || !terminal_fault ||
            fault_code != 8'h41 || sound_epoch_ready ||
            !sound_shadow_reset)
            $fatal(1, "direct consumer fault did not close gate");

        $display(
            "PASS: direct mailbox-completion mode skips ring without weakening epoch gates");
        $finish;
    end
endmodule
