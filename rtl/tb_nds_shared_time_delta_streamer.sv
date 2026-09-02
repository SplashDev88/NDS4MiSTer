module tb_nds_shared_time_delta_streamer;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 1;
    logic epoch_begin_valid = 0;
    logic epoch_begin_ready;
    logic [31:0] epoch_begin = 0;
    logic epoch_begin_fresh = 1;
    logic epoch_started;
    logic epoch_active;
    logic [31:0] active_epoch;
    logic timestamp_valid = 0;
    logic timestamp_ready;
    logic [31:0] timestamp_epoch = 0;
    logic [63:0] timestamp = 0;
    logic timestamp_overflow = 0;
    logic delta_valid;
    logic delta_ready;
    logic [7:0] delta_cycles;
    logic [63:0] accepted_timestamp;
    logic [63:0] remaining_cycles;
    logic protocol_error;
    logic overflow;

    logic downstream_enable = 1;
    logic scaler_source_ready;
    logic scaler_source_valid;
    logic [7:0] scaled_cycles;
    logic scaled_cycles_valid;
    logic scaler_idle;
    logic scaler_overflow;
    logic gate_open = 0;

    longint unsigned raw_sum = 0;
    longint unsigned scaled_sum = 0;
    integer raw_beats = 0;
    integer scaled_beats = 0;
    integer clocks = 0;
    logic stalled = 0;
    logic [7:0] stalled_cycles = 0;

    always #5 clk = ~clk;

    // A one-beat ready/valid gate models an independently stalling consumer.
    // Once a beat is exposed to the scaler, gate_open remains asserted until
    // the scaler accepts it; changing downstream_enable therefore cannot
    // violate either side's payload-retention contract.
    assign scaler_source_valid = delta_valid && gate_open;
    assign delta_ready = scaler_source_ready && gate_open;

    always @(posedge clk) begin
        if (reset) begin
            gate_open <= 0;
        end else if (gate_open) begin
            if (delta_valid && scaler_source_ready)
                gate_open <= 0;
        end else if (delta_valid && downstream_enable) begin
            gate_open <= 1;
        end
    end

    nds_shared_time_delta_streamer dut (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_begin_valid,
        .epoch_begin_ready,
        .epoch_begin,
        .epoch_begin_fresh,
        .epoch_started,
        .epoch_active,
        .active_epoch,
        .timestamp_valid,
        .timestamp_ready,
        .timestamp_epoch,
        .timestamp,
        .timestamp_overflow,
        .delta_valid,
        .delta_ready,
        .delta_cycles,
        .accepted_timestamp,
        .remaining_cycles,
        .protocol_error,
        .overflow
    );

    nds_sound_cycle_scaler #(
        .SCALE(2),
        .PENDING_BITS(16)
    ) scaler (
        .clk,
        .reset,
        .source_cycles(delta_cycles),
        .source_cycles_valid(scaler_source_valid),
        .source_ready(scaler_source_ready),
        .sound_cycles(scaled_cycles),
        .sound_cycles_valid(scaled_cycles_valid),
        .idle(scaler_idle),
        .overflow(scaler_overflow)
    );

    always @(posedge clk) begin
        clocks <= clocks + 1;
        if (reset) begin
            raw_sum <= 0;
            scaled_sum <= 0;
            raw_beats <= 0;
            scaled_beats <= 0;
            stalled <= 0;
            stalled_cycles <= 0;
        end else begin
            if (delta_valid && delta_cycles == 0)
                $fatal(1, "streamer emitted a zero delta");
            if (delta_valid && !delta_ready) begin
                if (stalled && delta_cycles !== stalled_cycles)
                    $fatal(1,
                        "delta payload changed while stalled old=%0d new=%0d",
                        stalled_cycles, delta_cycles);
                stalled <= 1;
                stalled_cycles <= delta_cycles;
            end else begin
                stalled <= 0;
            end
            if (delta_valid && delta_ready) begin
                raw_sum <= raw_sum + {56'd0, delta_cycles};
                raw_beats <= raw_beats + 1;
            end
            if (scaled_cycles_valid) begin
                if (scaled_cycles == 0)
                    $fatal(1, "SCALE=2 composition emitted zero");
                scaled_sum <= scaled_sum + {56'd0, scaled_cycles};
                scaled_beats <= scaled_beats + 1;
            end
            if (scaler_overflow)
                $fatal(1, "lossless composition overflowed its scaler");
        end
    end

    task automatic hard_reset;
        begin
            @(negedge clk);
            reset = 1;
            transport_quiescent = 1;
            epoch_begin_valid = 0;
            epoch_begin = 0;
            epoch_begin_fresh = 1;
            timestamp_valid = 0;
            timestamp_epoch = 0;
            timestamp = 0;
            timestamp_overflow = 0;
            downstream_enable = 1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    task automatic establish_epoch(
        input logic [31:0] epoch,
        input logic fresh
    );
        begin
            // The post-reset/previous-epoch low-to-high transition is
            // mandatory; a stale high level cannot release quarantine.
            @(negedge clk);
            transport_quiescent = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_begin = epoch;
            epoch_begin_fresh = fresh;
            epoch_begin_valid = 1;
            while (!epoch_begin_ready) @(posedge clk);
            @(posedge clk);
            #1;
            epoch_begin_valid = 0;
            epoch_begin = 0;
            epoch_begin_fresh = 1;
        end
    endtask

    task automatic send_timestamp(
        input logic [31:0] epoch,
        input logic [63:0] absolute
    );
        begin
            @(negedge clk);
            timestamp_epoch = epoch;
            timestamp = absolute;
            timestamp_valid = 1;
            while (!timestamp_ready) @(posedge clk);
            @(posedge clk);
            #1;
            timestamp_valid = 0;
        end
    endtask

    task automatic wait_drained;
        begin
            while (remaining_cycles != 0 || delta_valid || !scaler_idle)
                @(posedge clk);
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        hard_reset();

        // A stale-high quiescence input after reset cannot release quarantine.
        @(negedge clk);
        epoch_begin = 32'h1001;
        epoch_begin_valid = 1;
        repeat (4) begin
            @(posedge clk);
            #1;
            if (epoch_begin_ready || epoch_active || epoch_started)
                $fatal(1, "stale-high quiescence released reset quarantine");
        end
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin = 0;
        establish_epoch(32'h1001, 1);
        if (!epoch_active || active_epoch != 32'h1001 ||
            protocol_error || overflow)
            $fatal(1, "valid epoch did not start cleanly");

        // More than 16 bits of catch-up proves the streamer itself has no
        // bounded pending accumulator. Deterministic downstream stalls also
        // drive the SCALE=2 block into and back out of source backpressure.
        fork
            begin : stall_driver
                repeat (24000) begin
                    @(negedge clk);
                    downstream_enable =
                        ((clocks % 11) != 2) &&
                        ((clocks % 17) != 5) &&
                        ((clocks % 29) != 7);
                end
                downstream_enable = 1;
            end
            begin : large_catchup
                send_timestamp(32'h1001, 64'd1000123);
                wait_drained();
            end
        join
        if (raw_sum != 64'd1000123 ||
            scaled_sum != 64'd2000246 ||
            raw_beats != ((1000123 + 254) / 255))
            $fatal(1,
                "large catch-up mismatch raw=%0d scaled=%0d beats=%0d",
                raw_sum, scaled_sum, raw_beats);

        // Repeating an absolute timestamp is a legal no-op.
        send_timestamp(32'h1001, 64'd1000123);
        repeat (8) @(posedge clk);
        if (remaining_cycles != 0 || delta_valid ||
            raw_sum != 64'd1000123 || scaled_sum != 64'd2000246)
            $fatal(1, "same-value timestamp emitted a delta");

        send_timestamp(32'h1001, 64'd1000634);
        wait_drained();
        if (raw_sum != 64'd1000634 ||
            scaled_sum != 64'd2001268)
            $fatal(1, "second monotonic interval was not conserved");

        // A fresh epoch resets the absolute baseline without emitting the old
        // timestamp as a delta.
        establish_epoch(32'h1002, 1);
        if (accepted_timestamp != 0 || active_epoch != 32'h1002)
            $fatal(1, "fresh epoch did not reset absolute baseline");
        send_timestamp(32'h1002, 64'd300);
        wait_drained();
        if (raw_sum != 64'd1000934 ||
            scaled_sum != 64'd2001868)
            $fatal(1, "fresh-epoch interval mismatch");

        // An old epoch presented after replacement is stale and poisons the
        // stream without leaking any output.
        send_timestamp(32'h1001, 64'd301);
        if (!protocol_error || epoch_active || delta_valid ||
            remaining_cycles != 0)
            $fatal(1, "stale timestamp epoch did not fail closed");

        // Backward absolute time is independently epoch-fatal.
        hard_reset();
        establish_epoch(32'h2001, 1);
        send_timestamp(32'h2001, 64'd1000);
        wait_drained();
        send_timestamp(32'h2001, 64'd999);
        if (!protocol_error || epoch_active || delta_valid ||
            remaining_cycles != 0)
            $fatal(1, "backward timestamp did not fail closed");

        // An explicitly non-fresh epoch is rejected after the full quarantine
        // handshake rather than silently aliasing prior transport data.
        hard_reset();
        establish_epoch(32'h3001, 0);
        if (!protocol_error || epoch_active)
            $fatal(1, "non-fresh epoch did not fail closed");

        // Source overflow is distinct and sticky. It also discards a retained
        // interval so a prefix can never masquerade as complete elapsed time.
        hard_reset();
        establish_epoch(32'h4001, 1);
        downstream_enable = 0;
        send_timestamp(32'h4001, 64'd50000);
        while (!delta_valid) @(posedge clk);
        @(negedge clk);
        timestamp_overflow = 1;
        @(posedge clk);
        #1;
        timestamp_overflow = 0;
        if (!overflow || protocol_error || epoch_active || delta_valid ||
            remaining_cycles != 0 || timestamp_ready)
            $fatal(1, "timestamp overflow did not fail closed");
        repeat (8) @(posedge clk);
        if (!overflow || delta_valid || remaining_cycles != 0)
            $fatal(1, "stream resumed after sticky overflow");

        $display(
            "PASS: absolute shared time streams losslessly through <=255-cycle deltas and SCALE=2 with epoch quarantine and fail-closed faults");
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "shared-time delta streamer timeout");
    end
endmodule
