module tb_nds_sound_credit_drain_coordinator;
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
    logic credit_valid = 0;
    logic credit_ready;
    logic [31:0] credit_epoch = 0;
    logic [31:0] credit_ack_sequence = 0;
    logic credit_cpu_arm9 = 0;
    logic [31:0] credit_cycles = 0;
    logic [1:0] credit_kind = 0;
    logic [7:0] sound_cycles;
    logic sound_cycles_valid;
    logic sound_cycles_ready = 1;
    logic drain_token_valid;
    logic drain_token_ready = 0;
    logic [31:0] drain_token_epoch;
    logic [31:0] drain_token_ack_sequence;
    logic [63:0] arm9_timestamp;
    logic [63:0] arm7_timestamp;
    logic [63:0] shared_timestamp;
    logic [63:0] remaining_delta_cycles;
    logic busy;
    logic sequence_exhausted;
    logic protocol_error;
    logic overflow;

    integer next_ack = 1;
    integer accepted_credits = 0;
    integer accepted_tokens = 0;
    integer sound_beats = 0;
    integer clocks = 0;
    longint unsigned sound_sum = 0;
    logic stall_sound = 0;

    logic previous_sound_valid = 0;
    logic previous_sound_ready = 0;
    logic [7:0] previous_sound_cycles = 0;
    logic previous_sound_fire = 0;
    logic previous_token_valid = 0;
    logic previous_token_ready = 0;
    logic [31:0] previous_token_epoch = 0;
    logic [31:0] previous_token_sequence = 0;

    always #5 clk = ~clk;

    nds_sound_credit_drain_coordinator dut (.*);

    always @(negedge clk) begin
        if (stall_sound)
            sound_cycles_ready =
                ((clocks % 7) != 1) &&
                ((clocks % 13) != 4) &&
                ((clocks % 19) != 8);
    end

    always @(posedge clk) begin
        clocks <= clocks + 1;
        if (!reset && credit_valid && credit_ready)
            accepted_credits <= accepted_credits + 1;
        if (!reset && drain_token_valid && drain_token_ready)
            accepted_tokens <= accepted_tokens + 1;
        if (!reset && sound_cycles_valid && sound_cycles_ready) begin
            if (sound_cycles == 0)
                $fatal(1, "zero scaled sound beat");
            sound_sum <= sound_sum + {56'd0, sound_cycles};
            sound_beats <= sound_beats + 1;
        end

        if (!reset && previous_sound_valid && !previous_sound_ready) begin
            if (!sound_cycles_valid ||
                sound_cycles != previous_sound_cycles)
                $fatal(1, "sound output changed while backpressured");
        end
        if (!reset && previous_sound_fire && sound_cycles_valid)
            $fatal(1, "Robert-compatible valid-low bubble was omitted");

        if (!reset && previous_token_valid && !previous_token_ready) begin
            if (!drain_token_valid ||
                drain_token_epoch != previous_token_epoch ||
                drain_token_ack_sequence != previous_token_sequence)
                $fatal(1, "drain token changed while backpressured");
        end

        previous_sound_valid <= sound_cycles_valid;
        previous_sound_ready <= sound_cycles_ready;
        previous_sound_cycles <= sound_cycles;
        previous_sound_fire <=
            sound_cycles_valid && sound_cycles_ready;
        previous_token_valid <= drain_token_valid;
        previous_token_ready <= drain_token_ready;
        previous_token_epoch <= drain_token_epoch;
        previous_token_sequence <= drain_token_ack_sequence;
    end

    task automatic establish_epoch(input logic [31:0] epoch);
        begin
            @(negedge clk);
            transport_quiescent = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_begin = epoch;
            epoch_begin_fresh = 1;
            epoch_begin_valid = 1;
            do @(posedge clk); while (!epoch_begin_ready);
            @(negedge clk);
            epoch_begin_valid = 0;
            epoch_begin = 0;
            // Credit readiness is quarantined through the synchronous tracker
            // reset on the epoch_started pulse.
            while (epoch_started) @(posedge clk);
            #1;
            if (!epoch_active || active_epoch != epoch ||
                protocol_error || overflow)
                $fatal(1, "valid epoch did not start");
            next_ack = 1;
        end
    endtask

    task automatic send_credit(
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [1:0] kind,
        output logic [31:0] ack_seq
    );
        begin
            ack_seq = next_ack;
            @(negedge clk);
            credit_epoch = active_epoch;
            credit_ack_sequence = next_ack;
            credit_cpu_arm9 = cpu_arm9;
            credit_cycles = cycles;
            credit_kind = kind;
            credit_valid = 1;
            do @(posedge clk); while (!credit_ready);
            @(negedge clk);
            credit_valid = 0;
            credit_epoch = 0;
            credit_ack_sequence = 0;
            credit_cpu_arm9 = 0;
            credit_cycles = 0;
            credit_kind = 0;
            next_ack = next_ack + 1;
            if (protocol_error || overflow)
                $fatal(1, "valid credit failed");
        end
    endtask

    task automatic consume_token(
        input logic [31:0] expected_sequence,
        input integer hold_clocks
    );
        begin
            while (!drain_token_valid) @(posedge clk);
            #1;
            if (drain_token_epoch != active_epoch ||
                drain_token_ack_sequence != expected_sequence)
                $fatal(1, "wrong drain token epoch/sequence");
            repeat (hold_clocks) begin
                @(posedge clk);
                #1;
                if (!drain_token_valid || credit_ready)
                    $fatal(1, "token did not retain/backpressure next credit");
            end
            @(negedge clk);
            drain_token_ready = 1;
            @(posedge clk);
            @(negedge clk);
            drain_token_ready = 0;
            #1;
            if (drain_token_valid)
                $fatal(1, "token was emitted more than once");
        end
    endtask

    logic [31:0] ack_seq;
    longint unsigned before_sum;
    integer before_beats;

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // A stale high quiescence level cannot start the first epoch.
        epoch_begin = 32'h11112222;
        epoch_begin_valid = 1;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (epoch_begin_ready || epoch_active)
                $fatal(1, "stale-high transport escaped quarantine");
        end
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin = 0;
        establish_epoch(32'h11112222);

        // ARM9 alone cannot move canonical shared time.  Even with no delta,
        // its exact credit gets one retained token rather than sampling an old
        // idle level.
        send_credit(1'b1, 32'd100, 2'b01, ack_seq);
        consume_token(ack_seq, 5);
        if (arm9_timestamp != 100 || arm7_timestamp != 0 ||
            shared_timestamp != 0 || sound_sum != 0)
            $fatal(1, "ARM9-only min-unchanged credit mismatch");

        // Zero cycles are ordered and tokenized but cannot create audio time.
        send_credit(1'b0, 32'd0, 2'b01, ack_seq);
        consume_token(ack_seq, 2);
        if (arm7_timestamp != 0 || shared_timestamp != 0 || sound_sum != 0)
            $fatal(1, "zero-cycle credit fabricated time");

        // ARM7 catch-up advances shared time by 40 and therefore delivers
        // exactly 80 SCALE=2 cycles before its token.
        before_sum = sound_sum;
        send_credit(1'b0, 32'd40, 2'b10, ack_seq);
        consume_token(ack_seq, 1);
        if (shared_timestamp != 40 || sound_sum - before_sum != 80)
            $fatal(1, "first halt catch-up mismatch delta=%0d",
                sound_sum - before_sum);

        // ARM9 advances but remains ahead of the minimum: no scaled output.
        before_sum = sound_sum;
        send_credit(1'b1, 32'd10, 2'b10, ack_seq);
        consume_token(ack_seq, 0);
        if (shared_timestamp != 40 || sound_sum != before_sum)
            $fatal(1, "min-unchanged halt emitted sound cycles");

        // ARM7 reaches ARM9, advancing canonical time by exactly 70.
        before_sum = sound_sum;
        send_credit(1'b0, 32'd70, 2'b10, ack_seq);
        consume_token(ack_seq, 0);
        if (arm9_timestamp != 110 || arm7_timestamp != 110 ||
            shared_timestamp != 110 || sound_sum - before_sum != 140)
            $fatal(1, "second halt catch-up mismatch");

        // A very large interval proves arbitrary delta chunking, SCALE=2
        // conservation, retained output stalls, and no early token.
        send_credit(1'b1, 32'd1000123, 2'b00, ack_seq);
        consume_token(ack_seq, 0);
        before_sum = sound_sum;
        before_beats = sound_beats;
        stall_sound = 1;
        send_credit(1'b0, 32'd1000123, 2'b01, ack_seq);
        consume_token(ack_seq, 4);
        stall_sound = 0;
        sound_cycles_ready = 1;
        if (shared_timestamp != 64'd1000233 ||
            sound_sum - before_sum != 64'd2000246 ||
            sound_beats - before_beats < 7000 ||
            remaining_delta_cycles != 0)
            $fatal(1,
                "huge chunk mismatch sum=%0d beats=%0d remaining=%0d",
                sound_sum - before_sum, sound_beats - before_beats,
                remaining_delta_cycles);

        if (accepted_credits != accepted_tokens ||
            accepted_credits != 7 || busy || sequence_exhausted ||
            protocol_error || overflow)
            $fatal(1,
                "final coordinator accounting mismatch credits=%0d tokens=%0d busy=%b",
                accepted_credits, accepted_tokens, busy);

        // A fully drained fresh epoch resets both CPU timestamps and ACK
        // numbering without leaking the old absolute baseline.
        establish_epoch(32'h33334444);
        if (arm9_timestamp != 0 || arm7_timestamp != 0 ||
            shared_timestamp != 0)
            $fatal(1, "fresh epoch did not reset canonical time");
        send_credit(1'b0, 32'd9, 2'b01, ack_seq);
        consume_token(ack_seq, 0);
        if (ack_seq != 1 || shared_timestamp != 0)
            $fatal(1, "fresh epoch sequence/min baseline mismatch");

        $display(
            "PASS: keyed credit coordinator drains min-time, huge SCALE=2 chunks, stalls, bubbles, zero/min-unchanged/halt credits, and one token per ACK");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "coordinator timeout");
    end
endmodule
