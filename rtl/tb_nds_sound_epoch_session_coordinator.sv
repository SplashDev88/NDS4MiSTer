module tb_nds_sound_epoch_session_coordinator;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic transport_quiescent;
    logic epoch_request_valid;
    logic epoch_request_ready;
    logic [31:0] epoch_request;
    logic epoch_request_fresh;

    logic ring_session_begin_valid;
    logic ring_session_begin_ready;
    logic [31:0] ring_session_begin_epoch;
    logic ring_session_epoch_fresh;
    logic ring_session_started;
    logic ring_session_active;
    logic [31:0] ring_active_epoch;
    logic ring_sequence_exhausted;
    logic ring_protocol_error;

    logic broadcaster_epoch_begin_valid;
    logic broadcaster_epoch_begin_ready;
    logic [31:0] broadcaster_epoch_begin;
    logic broadcaster_epoch_begin_fresh;
    logic broadcaster_epoch_started;
    logic broadcaster_epoch_active;
    logic [31:0] broadcaster_active_epoch;
    logic broadcaster_sequence_exhausted;
    logic broadcaster_protocol_error;

    logic queue_epoch_begin_valid;
    logic queue_epoch_begin_ready;
    logic [31:0] queue_epoch_begin;
    logic queue_epoch_begin_fresh;
    logic queue_epoch_started;
    logic queue_epoch_active;
    logic [31:0] queue_active_epoch;
    logic queue_capture_overflow;
    logic queue_sequence_exhausted;
    logic queue_protocol_error;

    logic drain_epoch_begin_valid;
    logic drain_epoch_begin_ready;
    logic [31:0] drain_epoch_begin;
    logic drain_epoch_begin_fresh;
    logic drain_epoch_started;
    logic drain_epoch_active;
    logic [31:0] drain_active_epoch;
    logic drain_sequence_exhausted;
    logic drain_protocol_error;
    logic drain_overflow;

    logic sound_data_activity;
    logic sound_epoch_ready;
    logic [31:0] active_epoch;
    logic sound_data_enable;
    logic sound_shadow_enable;
    logic sound_shadow_reset;
    logic protocol_error;
    logic terminal_fault;
    logic premature_activity;
    logic [7:0] fault_code;

    nds_sound_epoch_session_coordinator dut (
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

    task automatic drive_defaults;
        begin
            transport_quiescent = 1'b1;
            epoch_request_valid = 1'b0;
            epoch_request = 32'd0;
            epoch_request_fresh = 1'b0;

            ring_session_begin_ready = 1'b0;
            ring_session_started = 1'b0;
            ring_session_active = 1'b0;
            ring_active_epoch = 32'd0;
            ring_sequence_exhausted = 1'b0;
            ring_protocol_error = 1'b0;

            broadcaster_epoch_begin_ready = 1'b0;
            broadcaster_epoch_started = 1'b0;
            broadcaster_epoch_active = 1'b0;
            broadcaster_active_epoch = 32'd0;
            broadcaster_sequence_exhausted = 1'b0;
            broadcaster_protocol_error = 1'b0;

            queue_epoch_begin_ready = 1'b0;
            queue_epoch_started = 1'b0;
            queue_epoch_active = 1'b0;
            queue_active_epoch = 32'd0;
            queue_capture_overflow = 1'b0;
            queue_sequence_exhausted = 1'b0;
            queue_protocol_error = 1'b0;

            drain_epoch_begin_ready = 1'b0;
            drain_epoch_started = 1'b0;
            drain_epoch_active = 1'b0;
            drain_active_epoch = 32'd0;
            drain_sequence_exhausted = 1'b0;
            drain_protocol_error = 1'b0;
            drain_overflow = 1'b0;

            sound_data_activity = 1'b0;
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            drive_defaults();
            reset = 1'b1;
            repeat (3)
                tick();
            @(negedge clk);
            reset = 1'b0;
            tick();
            if (sound_epoch_ready || sound_data_enable ||
                sound_shadow_enable || !sound_shadow_reset ||
                active_epoch != 0 || protocol_error)
                $fatal(1, "reset did not close every sound gate");
        end
    endtask

    task automatic qualify_quiescence;
        begin
            // Merely being high after reset is insufficient.
            repeat (3) begin
                tick();
                if (epoch_request_ready)
                    $fatal(1,
                        "epoch accepted without low/high quarantine");
            end
            @(negedge clk);
            transport_quiescent = 1'b0;
            repeat (2)
                tick();
            @(negedge clk);
            transport_quiescent = 1'b1;
            tick();
        end
    endtask

    task automatic request_epoch(input logic [31:0] epoch);
        integer timeout;
        begin
            @(negedge clk);
            epoch_request = epoch;
            epoch_request_fresh = 1'b1;
            epoch_request_valid = 1'b1;
            timeout = 0;
            while (!epoch_request_ready && timeout < 20) begin
                tick();
                timeout = timeout + 1;
            end
            if (!epoch_request_ready)
                $fatal(1, "external epoch request never became ready");
            tick();
            @(negedge clk);
            epoch_request_valid = 1'b0;
            epoch_request = 32'd0;
            epoch_request_fresh = 1'b0;
            tick();
        end
    endtask

    task automatic accept_ring_after_stall(
        input logic [31:0] epoch,
        input integer stall_cycles
    );
        integer index;
        begin
            while (!ring_session_begin_valid)
                tick();
            for (index = 0; index < stall_cycles; index = index + 1) begin
                if (!ring_session_begin_valid ||
                    ring_session_begin_epoch != epoch ||
                    !ring_session_epoch_fresh)
                    $fatal(1,
                        "ring request was not retained through stall");
                tick();
            end
            @(negedge clk);
            ring_session_begin_ready = 1'b1;
            tick();
            @(negedge clk);
            ring_session_begin_ready = 1'b0;
            repeat (5)
                tick();
            @(negedge clk);
            ring_active_epoch = epoch;
            ring_session_active = 1'b1;
            ring_session_started = 1'b1;
            tick();
            @(negedge clk);
            ring_session_started = 1'b0;
            tick();
        end
    endtask

    task automatic accept_consumer(
        input integer which_consumer,
        input logic [31:0] epoch,
        input integer stall_cycles,
        input integer start_delay
    );
        integer index;
        begin
            case (which_consumer)
                0: while (!broadcaster_epoch_begin_valid) tick();
                1: while (!queue_epoch_begin_valid) tick();
                2: while (!drain_epoch_begin_valid) tick();
                default: $fatal(1, "bad consumer selector");
            endcase

            for (index = 0; index < stall_cycles;
                 index = index + 1) begin
                case (which_consumer)
                    0: if (!broadcaster_epoch_begin_valid ||
                           broadcaster_epoch_begin != epoch ||
                           !broadcaster_epoch_begin_fresh)
                        $fatal(1,
                            "broadcaster request changed in stall");
                    1: if (!queue_epoch_begin_valid ||
                           queue_epoch_begin != epoch ||
                           !queue_epoch_begin_fresh)
                        $fatal(1,
                            "queue request changed in stall");
                    2: if (!drain_epoch_begin_valid ||
                           drain_epoch_begin != epoch ||
                           !drain_epoch_begin_fresh)
                        $fatal(1,
                            "drain request changed in stall");
                endcase
                tick();
            end

            @(negedge clk);
            case (which_consumer)
                0: broadcaster_epoch_begin_ready = 1'b1;
                1: queue_epoch_begin_ready = 1'b1;
                2: drain_epoch_begin_ready = 1'b1;
            endcase
            tick();
            @(negedge clk);
            case (which_consumer)
                0: broadcaster_epoch_begin_ready = 1'b0;
                1: queue_epoch_begin_ready = 1'b0;
                2: drain_epoch_begin_ready = 1'b0;
            endcase
            repeat (start_delay)
                tick();
            @(negedge clk);
            case (which_consumer)
                0: begin
                    broadcaster_active_epoch = epoch;
                    broadcaster_epoch_active = 1'b1;
                    broadcaster_epoch_started = 1'b1;
                end
                1: begin
                    queue_active_epoch = epoch;
                    queue_epoch_active = 1'b1;
                    queue_epoch_started = 1'b1;
                end
                2: begin
                    drain_active_epoch = epoch;
                    drain_epoch_active = 1'b1;
                    drain_epoch_started = 1'b1;
                end
            endcase
            tick();
            @(negedge clk);
            case (which_consumer)
                0: broadcaster_epoch_started = 1'b0;
                1: queue_epoch_started = 1'b0;
                2: drain_epoch_started = 1'b0;
            endcase
            tick();
        end
    endtask

    task automatic expect_fault(input logic [7:0] expected_code);
        begin
            tick();
            if (!protocol_error || !terminal_fault ||
                fault_code != expected_code || sound_epoch_ready ||
                sound_data_enable || sound_shadow_enable ||
                !sound_shadow_reset || active_epoch != 0)
                $fatal(1,
                    "fail-closed mismatch expected=%02x got=%02x",
                    expected_code, fault_code);
            repeat (3) begin
                tick();
                if (!protocol_error || fault_code != expected_code ||
                    sound_epoch_ready || !sound_shadow_reset)
                    $fatal(1, "terminal fault was not sticky");
            end
        end
    endtask

    initial begin
        logic [31:0] epoch;
        integer timeout;
        epoch = 32'h10203040;
        drive_defaults();

        // Successful, heavily staggered startup.  The external request is
        // deliberately asserted before the required low/high transition.
        apply_reset();
        @(negedge clk);
        epoch_request_valid = 1'b1;
        epoch_request = epoch;
        epoch_request_fresh = 1'b1;
        repeat (3)
            tick();
        if (epoch_request_ready)
            $fatal(1, "early epoch unexpectedly accepted");
        @(negedge clk);
        transport_quiescent = 1'b0;
        repeat (2)
            tick();
        @(negedge clk);
        transport_quiescent = 1'b1;
        timeout = 0;
        while (!epoch_request_ready && timeout < 10) begin
            tick();
            timeout = timeout + 1;
        end
        if (!epoch_request_ready)
            $fatal(1, "retained early request never reached ready");
        tick();
        @(negedge clk);
        epoch_request_valid = 1'b0;
        epoch_request = 32'd0;
        epoch_request_fresh = 1'b0;
        accept_ring_after_stall(epoch, 37);

        // Stagger both acceptance and active/start confirmation.  No one
        // consumer's ready may affect another retained valid.
        accept_consumer(0, epoch, 2, 7);
        if (!queue_epoch_begin_valid || !drain_epoch_begin_valid)
            $fatal(1, "independent fanout was not retained");
        accept_consumer(1, epoch, 13, 3);
        if (!drain_epoch_begin_valid)
            $fatal(1, "long-stalled drain request was withdrawn");
        accept_consumer(2, epoch, 61, 11);

        timeout = 0;
        while (!sound_epoch_ready && timeout < 20) begin
            tick();
            timeout = timeout + 1;
        end
        if (!sound_epoch_ready || active_epoch != epoch ||
            !sound_data_enable || !sound_shadow_enable ||
            sound_shadow_reset || protocol_error)
            $fatal(1, "all-consumer startup did not open gate");

        // Data is permitted only now.
        @(negedge clk);
        sound_data_activity = 1'b1;
        tick();
        @(negedge clk);
        sound_data_activity = 1'b0;
        if (protocol_error)
            $fatal(1, "ready data activity was rejected");

        // Active loss closes the combinational gate immediately and becomes
        // terminal on the next edge.
        @(negedge clk);
        queue_epoch_active = 1'b0;
        #1;
        if (sound_epoch_ready || sound_data_enable ||
            !sound_shadow_reset)
            $fatal(1, "active loss did not immediately close gate");
        expect_fault(8'h30);

        // A data request before readiness is both suppressed and flagged.
        apply_reset();
        @(negedge clk);
        sound_data_activity = 1'b1;
        expect_fault(8'h03);
        if (!premature_activity)
            $fatal(1, "premature activity diagnostic missing");

        // An early request must not mutate while waiting for quiescence.
        apply_reset();
        @(negedge clk);
        epoch_request_valid = 1'b1;
        epoch_request = 32'h11111111;
        epoch_request_fresh = 1'b1;
        tick();
        @(negedge clk);
        epoch_request = 32'h22222222;
        expect_fault(8'h02);

        // Nor may that early request be withdrawn before acceptance.
        apply_reset();
        @(negedge clk);
        epoch_request_valid = 1'b1;
        epoch_request = 32'h33333333;
        epoch_request_fresh = 1'b1;
        tick();
        @(negedge clk);
        epoch_request_valid = 1'b0;
        expect_fault(8'h02);

        // Zero and an externally unproven/reused epoch are terminal.
        apply_reset();
        qualify_quiescence();
        @(negedge clk);
        epoch_request_valid = 1'b1;
        epoch_request = 32'd0;
        epoch_request_fresh = 1'b1;
        tick();
        expect_fault(8'h01);

        apply_reset();
        qualify_quiescence();
        @(negedge clk);
        epoch_request_valid = 1'b1;
        epoch_request = epoch;
        epoch_request_fresh = 1'b0;
        tick();
        expect_fault(8'h01);

        // Reset never restores an old session by itself.  Even the same
        // numeric epoch is rejected when the persistent owner does not prove
        // it fresh; FPGA-local reset history is intentionally not a proof.
        apply_reset();
        repeat (4)
            tick();
        if (sound_epoch_ready || !sound_shadow_reset)
            $fatal(1, "reset resurrected an earlier epoch");

        // Quiescence must remain asserted through ring validation/startup.
        qualify_quiescence();
        request_epoch(32'h44444444);
        while (!ring_session_begin_valid)
            tick();
        @(negedge clk);
        transport_quiescent = 1'b0;
        expect_fault(8'h04);

        // A ring start without an authorized retained handshake is terminal.
        apply_reset();
        @(negedge clk);
        ring_session_started = 1'b1;
        ring_session_active = 1'b1;
        ring_active_epoch = 32'h55555555;
        expect_fault(8'h10);

        // Ring validation on a different epoch is never forwarded.
        apply_reset();
        qualify_quiescence();
        request_epoch(32'h66666666);
        while (!ring_session_begin_valid)
            tick();
        @(negedge clk);
        ring_session_begin_ready = 1'b1;
        tick();
        @(negedge clk);
        ring_session_begin_ready = 1'b0;
        ring_session_started = 1'b1;
        ring_session_active = 1'b1;
        ring_active_epoch = 32'h66666667;
        expect_fault(8'h10);

        // A downstream fault and a terminal sequence condition both close
        // the gate before any private sound logic can run.
        apply_reset();
        @(negedge clk);
        drain_protocol_error = 1'b1;
        expect_fault(8'h41);

        apply_reset();
        @(negedge clk);
        ring_sequence_exhausted = 1'b1;
        expect_fault(8'h11);

        // Once one epoch has been accepted, a valid-low-separated second
        // request (same or different) is an unexpected/reused session.
        apply_reset();
        qualify_quiescence();
        request_epoch(32'h77777777);
        repeat (2)
            tick();
        @(negedge clk);
        epoch_request_valid = 1'b1;
        epoch_request = 32'h77777777;
        epoch_request_fresh = 1'b1;
        expect_fault(8'h05);

        $display(
            "PASS: sound epoch coordinator is retained, stagger-safe, and fail-closed");
        $finish;
    end
endmodule
