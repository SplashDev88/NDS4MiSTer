module tb_nds_sound_timer_scale_contract;
    localparam integer TIMER_COUNT = 6;

    logic clk = 0;
    logic reset = 1;
    logic [7:0] source_cycles = 0;
    logic source_cycles_valid = 0;
    logic source_ready;
    logic [7:0] sound_cycles;
    logic sound_cycles_valid;
    logic idle;
    logic overflow;

    logic [15:0] timer_reload [0:TIMER_COUNT-1];
    longint unsigned robert_threshold [0:TIMER_COUNT-1];
    longint unsigned robert_phase [0:TIMER_COUNT-1];
    longint unsigned robert_ticks [0:TIMER_COUNT-1];
    longint unsigned accepted_shared_cycles = 0;
    longint unsigned emitted_scaled_cycles = 0;
    logic previous_output_valid = 0;

    always #5 clk = ~clk;

    nds_sound_cycle_scaler #(
        .SCALE(2),
        .PENDING_BITS(16)
    ) dut (.*);

    always @(posedge clk) begin
        if (!reset && source_cycles_valid && source_ready)
            accepted_shared_cycles =
                accepted_shared_cycles + longint'(source_cycles);

        if (!reset && sound_cycles_valid) begin
            emitted_scaled_cycles =
                emitted_scaled_cycles + longint'(sound_cycles);
            for (integer channel = 0; channel < TIMER_COUNT; channel++) begin
                robert_phase[channel] =
                    robert_phase[channel] + longint'(sound_cycles);
                robert_ticks[channel] =
                    robert_ticks[channel] +
                    (robert_phase[channel] / robert_threshold[channel]);
                robert_phase[channel] =
                    robert_phase[channel] % robert_threshold[channel];
            end
        end

        if (!reset && sound_cycles_valid && previous_output_valid)
            $fatal(1,
                "timer contract stream omitted Robert-compatible valid-low bubble");
        previous_output_valid = !reset && sound_cycles_valid;
    end

    task automatic send(input logic [7:0] cycles);
        begin
            @(negedge clk);
            source_cycles = cycles;
            source_cycles_valid = 1;
            do begin
                @(posedge clk);
            end while (!source_ready);
            @(negedge clk);
            source_cycles_valid = 0;
            source_cycles = 0;
        end
    endtask

    initial begin
        timer_reload[0] = 16'h0000;
        timer_reload[1] = 16'h8000;
        timer_reload[2] = 16'hf000;
        timer_reload[3] = 16'hfe00;
        timer_reload[4] = 16'hff80;
        timer_reload[5] = 16'hffff;

        for (integer channel = 0; channel < TIMER_COUNT; channel++) begin
            // This is the literal threshold in Robert's VHDL:
            // 0x40000 - (TMR * 4) == 4 * (65536 - TMR).
            robert_threshold[channel] =
                4 * (65536 - longint'(timer_reload[channel]));
            robert_phase[channel] = 0;
            robert_ticks[channel] = 0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Deterministic nonuniform reports exercise split beats and sustained
        // backpressure while crossing both the shortest and longest timer
        // periods many times.
        for (integer report = 0; report < 4096; report++)
            send(8'(((report * 73) % 255) + 1));

        wait (idle);
        @(posedge clk);
        #1;

        if (overflow)
            $fatal(1, "timer scale contract overflowed");
        if (emitted_scaled_cycles != accepted_shared_cycles * 2)
            $fatal(1,
                "scaled time mismatch shared=%0d scaled=%0d",
                accepted_shared_cycles, emitted_scaled_cycles);

        for (integer channel = 0; channel < TIMER_COUNT; channel++) begin
            longint unsigned shared_period;
            longint unsigned expected_ticks;
            longint unsigned expected_robert_phase;

            // melonDS increments a channel timer at 16.76 MHz. One SPU unit
            // is two 33.5 MHz shared-time units, so the sample period is
            // 2*(65536-TMR) shared units.
            shared_period =
                2 * (65536 - longint'(timer_reload[channel]));
            expected_ticks = accepted_shared_cycles / shared_period;
            expected_robert_phase =
                (accepted_shared_cycles % shared_period) * 2;

            if (robert_ticks[channel] != expected_ticks ||
                robert_phase[channel] != expected_robert_phase)
                $fatal(1,
                    "TMR=%04x mismatch ticks=%0d/%0d phase=%0d/%0d",
                    timer_reload[channel],
                    robert_ticks[channel], expected_ticks,
                    robert_phase[channel], expected_robert_phase);
        end

        $display("PASS: SCALE=2 makes Robert's 4*(65536-TMR) accumulator exactly match melonDS 16.76 MHz timer periods");
        $display("INFO: shared_cycles=%0d scaled_cycles=%0d reloads=0000,8000,f000,fe00,ff80,ffff",
            accepted_shared_cycles, emitted_scaled_cycles);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "timer scale contract timeout");
    end
endmodule
