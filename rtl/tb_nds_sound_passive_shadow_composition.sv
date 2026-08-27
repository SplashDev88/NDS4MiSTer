`timescale 1ns/1ps

module tb_nds_sound_passive_shadow_composition;
    localparam integer LEDGER_DEPTH = 256;
    localparam integer MAILBOX_CREDIT_DEPTH = 64;
    localparam integer WRITE_QUEUE_DEPTH = 64;
    localparam integer ENGINE_RESPONSE_DELAY = 40;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic shadow_feature_enable = 1'b0;
    logic transport_quiescent = 1'b1;
    logic epoch_request_valid = 1'b0;
    logic epoch_request_ready;
    logic [31:0] epoch_request_generation = 32'd0;
    logic epoch_request_fresh = 1'b0;

    logic mailbox_explicit_launch = 1'b0;
    logic mailbox_request = 1'b0;
    logic [3:0] mailbox_debug_state = 4'd0;
    logic mailbox_cpu_arm9 = 1'b0;
    logic [31:0] mailbox_elapsed_cycles = 32'd0;
    logic [31:0] mailbox_fence_sequence = 32'd0;
    logic [31:0] mailbox_address = 32'd0;
    logic mailbox_read_not_write = 1'b0;
    logic [1:0] mailbox_access = 2'd0;
    logic [31:0] mailbox_write_data = 32'd0;
    logic mailbox_done = 1'b0;
    logic [31:0] mailbox_completed_fence_sequence = 32'd0;

    logic posted_request = 1'b0;
    logic posted_active = 1'b0;
    logic posted_accepted = 1'b0;
    logic posted_sequence_exhausted = 1'b0;
    logic [31:0] posted_producer_sequence = 32'd0;
    logic posted_cpu_arm9 = 1'b0;
    logic [31:0] posted_elapsed_cycles = 32'd0;

    logic engine_cpu_request;
    logic engine_cpu_is_arm9;
    logic engine_cpu_write;
    logic [31:0] engine_cpu_address;
    logic [1:0] engine_cpu_access;
    logic [31:0] engine_cpu_write_data;
    logic engine_cpu_done = 1'b0;
    logic engine_cpu_rejected = 1'b0;

    logic [7:0] engine_cycles;
    logic engine_cycles_valid;
    logic engine_cycles_ready = 1'b0;

    logic engine_sample_request = 1'b0;
    logic [31:0] engine_sample_address = 32'd0;
    logic engine_sample_done;
    logic [31:0] engine_sample_data;
    logic sample_client_request;
    logic [31:0] sample_client_address;
    logic sample_client_done = 1'b0;
    logic [31:0] sample_client_data = 32'd0;

    logic output_master_enable;
    logic [1:0] output_left_source;
    logic [1:0] output_right_source;
    logic output_exclude_channel_1;
    logic output_exclude_channel_3;
    logic [9:0] output_sound_bias;
    logic output_capture_0_active;
    logic output_capture_1_active;
    logic [15:0] output_soundcnt_value;
    logic [15:0] output_soundcap_value;
    logic output_controls_valid;

    logic shadow_session_active;
    logic shadow_operating;
    logic [31:0] shadow_active_epoch;
    logic engine_reset;
    logic terminal_fault;
    logic [7:0] fault_code;
    logic [31:0] next_mailbox_source_generation;
    logic [$clog2(LEDGER_DEPTH + 1)-1:0] posted_ledger_level;
    logic [$clog2(WRITE_QUEUE_DEPTH + 1)-1:0]
        retained_write_level;
    logic debug_ack_fire;
    logic [31:0] debug_ack_sequence;
    logic [1:0] debug_ack_kind;
    logic [31:0] debug_ack_source_id;
    logic debug_released_write_fire;
    logic [31:0] debug_released_write_source_id;
    logic [31:0] debug_released_write_address;
    logic [1:0] debug_released_write_access;
    logic [31:0] debug_released_write_data;
    logic [63:0] debug_arm9_timestamp;
    logic [63:0] debug_arm7_timestamp;
    logic [63:0] debug_shared_timestamp;

    integer clock_count = 0;
    integer ack_count = 0;
    integer released_count = 0;
    integer engine_request_count = 0;
    integer cycle_sum = 0;
    integer engine_response_countdown = 0;
    logic previous_engine_request = 1'b0;
    logic [31:0] observed_engine_address [0:2];
    logic [1:0] observed_engine_access [0:2];
    logic [31:0] observed_engine_data [0:2];
    logic [31:0] observed_released_source [0:2];
    logic [31:0] observed_released_data [0:2];
    logic disabled_monitor_enable = 1'b0;
    logic sample_response_seen = 1'b0;

    always #5 clk = ~clk;

    nds_sound_passive_shadow_composition #(
        .LEDGER_DEPTH(LEDGER_DEPTH),
        .MAILBOX_CREDIT_DEPTH(MAILBOX_CREDIT_DEPTH),
        .WRITE_QUEUE_DEPTH(WRITE_QUEUE_DEPTH),
        .USE_EXPLICIT_MAILBOX_LAUNCH(1'b1)
    ) dut (.*);

    always @(posedge clk) begin
        clock_count <= clock_count + 1;
        if (reset || !shadow_operating)
            engine_cycles_ready <= 1'b0;
        else
            // Deliberately asymmetric, bursty Robert-side backpressure.
            engine_cycles_ready <=
                clock_count[2:0] == 3'd0 ||
                clock_count[2:0] == 3'd3 ||
                clock_count[2:0] == 3'd4;
    end

    always @(posedge clk) begin
        if (reset || engine_reset) begin
            engine_cpu_done <= 1'b0;
            engine_response_countdown <= 0;
            previous_engine_request <= 1'b0;
        end else begin
            engine_cpu_done <= 1'b0;
            if (engine_cpu_request && !previous_engine_request) begin
                if (engine_request_count >= 3)
                    $fatal(1, "VHDL write driver duplicated a request");
                observed_engine_address[engine_request_count] <=
                    engine_cpu_address;
                observed_engine_access[engine_request_count] <=
                    engine_cpu_access;
                observed_engine_data[engine_request_count] <=
                    engine_cpu_write_data;
                engine_request_count <= engine_request_count + 1;
                engine_response_countdown <= ENGINE_RESPONSE_DELAY;
            end else if (engine_cpu_request &&
                         engine_response_countdown > 1) begin
                engine_response_countdown <=
                    engine_response_countdown - 1;
            end else if (engine_cpu_request &&
                         engine_response_countdown == 1) begin
                engine_cpu_done <= 1'b1;
                engine_response_countdown <= 0;
            end
            previous_engine_request <= engine_cpu_request;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            ack_count <= 0;
            released_count <= 0;
            engine_request_count <= 0;
            cycle_sum <= 0;
            sample_response_seen <= 1'b0;
        end else begin
            if (debug_ack_fire) begin
                if (debug_ack_sequence != ack_count + 1)
                    $fatal(1,
                        "duplicate/gapped ACK got=%0d expected=%0d",
                        debug_ack_sequence, ack_count + 1);
                if (ack_count < 256) begin
                    if (debug_ack_kind != 2'b00 ||
                        debug_ack_source_id != 32'd18 + ack_count)
                        $fatal(1,
                            "posted ACK %0d wrong kind/source %0d/%0d",
                            ack_count, debug_ack_kind,
                            debug_ack_source_id);
                end else begin
                    if (debug_ack_kind != 2'b01 ||
                        debug_ack_source_id != 32'd8 +
                            (ack_count - 256))
                        $fatal(1,
                            "mailbox ACK %0d wrong kind/source %0d/%0d",
                            ack_count, debug_ack_kind,
                            debug_ack_source_id);
                end
                ack_count <= ack_count + 1;
            end

            if (debug_released_write_fire) begin
                if (released_count >= 3)
                    $fatal(1, "released write duplicated");
                if (debug_released_write_source_id !=
                        32'd8 + released_count)
                    $fatal(1,
                        "released source order wrong got=%0d expected=%0d",
                        debug_released_write_source_id,
                        8 + released_count);
                observed_released_source[released_count] <=
                    debug_released_write_source_id;
                observed_released_data[released_count] <=
                    debug_released_write_data;
                released_count <= released_count + 1;
            end

            if (engine_cycles_valid && engine_cycles_ready)
                cycle_sum <= cycle_sum + engine_cycles;

            if (engine_sample_done) begin
                if (engine_sample_data != 32'h89abcdef)
                    $fatal(1, "sample return data was corrupted");
                if (sample_response_seen)
                    $fatal(1, "sample completion duplicated");
                sample_response_seen <= 1'b1;
            end
        end
    end

    // Feature-off, reset, startup, and terminal fault are externally passive.
    always @(posedge clk) begin
        #1;
        if (disabled_monitor_enable && !shadow_operating) begin
            if (engine_cpu_request || engine_cpu_is_arm9 ||
                engine_cpu_write || engine_cpu_address != 32'd0 ||
                engine_cpu_access != 2'd0 ||
                engine_cpu_write_data != 32'd0 ||
                engine_cycles_valid || engine_cycles != 8'd0 ||
                sample_client_request ||
                sample_client_address != 32'd0 ||
                engine_sample_done ||
                engine_sample_data != 32'd0 ||
                output_controls_valid || !engine_reset)
                $fatal(1,
                    "disabled/reset/fault shadow was not passive");
        end
    end

    task automatic clear_inputs;
        begin
            shadow_feature_enable = 1'b0;
            transport_quiescent = 1'b1;
            epoch_request_valid = 1'b0;
            epoch_request_generation = 32'd0;
            epoch_request_fresh = 1'b0;
            mailbox_explicit_launch = 1'b0;
            mailbox_request = 1'b0;
            mailbox_debug_state = 4'd0;
            mailbox_cpu_arm9 = 1'b0;
            mailbox_elapsed_cycles = 32'd0;
            mailbox_fence_sequence = 32'd0;
            mailbox_address = 32'd0;
            mailbox_read_not_write = 1'b0;
            mailbox_access = 2'd0;
            mailbox_write_data = 32'd0;
            mailbox_done = 1'b0;
            mailbox_completed_fence_sequence = 32'd0;
            posted_request = 1'b0;
            posted_active = 1'b0;
            posted_accepted = 1'b0;
            posted_sequence_exhausted = 1'b0;
            posted_producer_sequence = 32'd0;
            posted_cpu_arm9 = 1'b0;
            posted_elapsed_cycles = 32'd0;
            engine_cpu_rejected = 1'b0;
            engine_sample_request = 1'b0;
            engine_sample_address = 32'd0;
            sample_client_done = 1'b0;
            sample_client_data = 32'd0;
        end
    endtask

    task automatic hard_reset;
        begin
            @(negedge clk);
            clear_inputs();
            reset = 1'b1;
            repeat (4) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
            disabled_monitor_enable = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic issue_disabled_mailbox(
        input logic [31:0] fence
    );
        begin
            @(negedge clk);
            mailbox_fence_sequence = fence;
            mailbox_completed_fence_sequence = fence;
            mailbox_explicit_launch = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mailbox_explicit_launch = 1'b0;
            @(posedge clk);
            @(negedge clk);
            mailbox_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mailbox_done = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic issue_disabled_posted;
        begin
            @(negedge clk);
            posted_request = 1'b1;
            posted_active = 1'b0;
            posted_cpu_arm9 = posted_producer_sequence[0];
            posted_elapsed_cycles = 32'd9;
            @(posedge clk);
            @(negedge clk);
            posted_active = 1'b1;
            posted_accepted = 1'b1;
            @(posedge clk);
            @(negedge clk);
            posted_accepted = 1'b0;
            posted_request = 1'b0;
            posted_active = 1'b0;
            posted_producer_sequence =
                posted_producer_sequence + 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic issue_posted_credit(
        input logic cpu_arm9,
        input logic [31:0] cycles
    );
        begin
            @(negedge clk);
            posted_request = 1'b1;
            posted_active = 1'b0;
            posted_cpu_arm9 = cpu_arm9;
            posted_elapsed_cycles = cycles;
            @(posedge clk);
            @(negedge clk);
            posted_active = 1'b1;
            @(posedge clk);
            @(negedge clk);
            posted_accepted = 1'b1;
            @(posedge clk);
            @(negedge clk);
            posted_accepted = 1'b0;
            posted_request = 1'b0;
            posted_active = 1'b0;
            posted_producer_sequence =
                posted_producer_sequence + 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic issue_mailbox_credit(
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [31:0] fence,
        input logic [31:0] address,
        input logic [1:0] access,
        input logic [31:0] data
    );
        begin
            @(negedge clk);
            mailbox_cpu_arm9 = cpu_arm9;
            mailbox_elapsed_cycles = cycles;
            mailbox_fence_sequence = fence;
            mailbox_completed_fence_sequence = fence;
            mailbox_address = address;
            mailbox_read_not_write = 1'b0;
            mailbox_access = access;
            mailbox_write_data = data;
            mailbox_explicit_launch = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mailbox_explicit_launch = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            mailbox_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mailbox_done = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic start_epoch(
        input logic [31:0] generation
    );
        integer timeout;
        begin
            @(negedge clk);
            shadow_feature_enable = 1'b1;
            transport_quiescent = 1'b0;
            epoch_request_valid = 1'b1;
            epoch_request_generation = generation;
            epoch_request_fresh = 1'b1;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1'b1;

            timeout = 0;
            while (!epoch_request_ready && timeout < 100) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!epoch_request_ready)
                $fatal(1, "persistent epoch request was never accepted");
            @(posedge clk);
            @(negedge clk);
            epoch_request_valid = 1'b0;
            epoch_request_generation = 32'd0;
            epoch_request_fresh = 1'b0;

            timeout = 0;
            while (!shadow_operating && !terminal_fault &&
                   timeout < 100) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            #1;
            if (terminal_fault || !shadow_operating ||
                shadow_active_epoch != generation)
                $fatal(1,
                    "sound epoch failed to become operational fault=%02x",
                    fault_code);
        end
    endtask

    task automatic wait_for_main_completion;
        integer timeout;
        begin
            timeout = 0;
            while ((ack_count != 259 ||
                    released_count != 3 ||
                    engine_request_count != 3 ||
                    engine_cpu_request ||
                    posted_ledger_level != 0 ||
                    retained_write_level != 0 ||
                    debug_shared_timestamp != 64'd138 ||
                    cycle_sum != 276) &&
                   !terminal_fault && timeout < 100000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            #1;
            if (terminal_fault)
                $fatal(1,
                    "composition faulted during main flow code=%02x",
                    fault_code);
            if (timeout >= 100000)
                $fatal(1,
                    "main flow timed out ack=%0d write=%0d engine=%0d ledger=%0d queue=%0d time=%0d cycles=%0d",
                    ack_count, released_count, engine_request_count,
                    posted_ledger_level, retained_write_level,
                    debug_shared_timestamp, cycle_sum);
        end
    endtask

    integer i;
    integer timeout;
    initial begin
        hard_reset();

        // Arbitrary production traffic while disabled must remain invisible,
        // while the mailbox generation and posted frontier still advance.
        for (i = 0; i < 7; i = i + 1)
            issue_disabled_mailbox(posted_producer_sequence);
        for (i = 0; i < 17; i = i + 1)
            issue_disabled_posted();
        #1;
        if (next_mailbox_source_generation != 32'd0)
            $fatal(1,
                "mailbox seed became valid before low/high quarantine");
        if (terminal_fault)
            $fatal(1, "disabled traffic poisoned passive shadow");

        start_epoch(32'h70000001);
        if (dut.write_queue.expected_completion_source != 32'd8 ||
            dut.write_queue.expected_posted_source != 32'd18)
            $fatal(1,
                "runtime late-epoch queue seeds were not captured");

        // Fill the entire mandatory 256-record posted ledger before one
        // mailbox fence releases it.  An intentionally asymmetric 138/118
        // split plus 20 later ARM7 cycles makes both final timestamps 138.
        for (i = 0; i < 256; i = i + 1)
            issue_posted_credit(i < 138, 32'd1);
        #1;
        if (posted_ledger_level != 256)
            $fatal(1,
                "256-entry posted ledger did not fill exactly: %0d",
                posted_ledger_level);

        issue_mailbox_credit(
            1'b0, 32'd4, 32'd273,
            32'h04000500, 2'b01, 32'h00008000);
        issue_mailbox_credit(
            1'b0, 32'd10, 32'd273,
            32'h04000500, 2'b01, 32'h00008e00);
        issue_mailbox_credit(
            1'b0, 32'd6, 32'd273,
            32'h04000504, 2'b01, 32'h00000210);

        // The first write reaches the engine, but the deliberately slow
        // engine keeps the second queue valid held.  Control state must not
        // apply that held record until the real queue/driver fire.
        timeout = 0;
        while (released_count < 1 && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 50000)
            $fatal(1, "first released write never arrived");
        @(posedge clk);
        #1;
        if (!output_master_enable ||
            output_left_source != 2'b00 ||
            output_right_source != 2'b00 ||
            output_soundcnt_value != 16'h8000 ||
            output_soundcap_value != 16'h0000)
            $fatal(1, "first output-control write did not apply");
        while (engine_cpu_request && released_count == 1) begin
            @(posedge clk);
            #1;
            if (output_left_source != 2'b00 ||
                output_right_source != 2'b00)
                $fatal(1,
                    "held queue valid updated output controls early");
        end

        wait_for_main_completion();

        if (debug_arm9_timestamp != 64'd138 ||
            debug_arm7_timestamp != 64'd138 ||
            debug_shared_timestamp != 64'd138)
            $fatal(1, "asymmetric CPU timestamps reconstructed wrongly");
        if (!output_master_enable ||
            output_left_source != 2'b10 ||
            output_right_source != 2'b11 ||
            output_sound_bias != 10'h210 ||
            output_soundcnt_value != 16'h8e00 ||
            output_soundcap_value != 16'h0000)
            $fatal(1, "released output-control order/data was wrong");
        for (i = 0; i < 3; i = i + 1) begin
            if (observed_engine_address[i] !=
                    (i == 2 ? 32'h04000504 : 32'h04000500) ||
                observed_engine_access[i] != 2'b01 ||
                observed_engine_data[i] !=
                    (i == 0 ? 32'h00008000 :
                     i == 1 ? 32'h00008e00 :
                              32'h00000210))
                $fatal(1, "engine write %0d was reordered/corrupted", i);
        end

        // The sample seam is one-outstanding and payload preserving.
        @(negedge clk);
        engine_sample_address = 32'h02001234;
        engine_sample_request = 1'b1;
        #1;
        if (!sample_client_request ||
            sample_client_address != 32'h02001234)
            $fatal(1, "sample request was not forwarded");
        @(posedge clk);
        @(negedge clk);
        engine_sample_request = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        sample_client_data = 32'h89abcdef;
        sample_client_done = 1'b1;
        #1;
        if (!engine_sample_done ||
            engine_sample_data != 32'h89abcdef)
            $fatal(1, "sample response was not returned");
        @(posedge clk);
        @(negedge clk);
        sample_client_done = 1'b0;
        sample_client_data = 32'd0;
        repeat (3) @(posedge clk);
        #1;
        if (!sample_response_seen || terminal_fault)
            $fatal(1, "valid sample transaction poisoned session");

        // Feature loss is terminal and immediately removes every external
        // side effect.
        @(negedge clk);
        shadow_feature_enable = 1'b0;
        @(posedge clk);
        #1;
        if (!terminal_fault || fault_code != 8'h04)
            $fatal(1, "active feature loss did not fail closed");

        // Reset clears the terminal state but never makes outputs live.  A
        // malformed persistent epoch is accepted once and fails closed.
        hard_reset();
        @(negedge clk);
        shadow_feature_enable = 1'b1;
        transport_quiescent = 1'b0;
        epoch_request_valid = 1'b1;
        epoch_request_generation = 32'd0;
        epoch_request_fresh = 1'b1;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1'b1;
        timeout = 0;
        while (!epoch_request_ready && timeout < 100) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!epoch_request_ready)
            $fatal(1, "malformed epoch did not reach validation");
        @(posedge clk);
        #1;
        if (!terminal_fault || fault_code != 8'h02)
            $fatal(1, "zero epoch did not fail closed");

        // A persistent owner may assert before ready, but it may not withdraw
        // or mutate that generation while quarantine is still incomplete.
        hard_reset();
        @(negedge clk);
        shadow_feature_enable = 1'b1;
        transport_quiescent = 1'b0;
        epoch_request_valid = 1'b1;
        epoch_request_generation = 32'h70000003;
        epoch_request_fresh = 1'b1;
        @(posedge clk);
        @(negedge clk);
        epoch_request_generation = 32'h70000004;
        @(posedge clk);
        #1;
        if (!terminal_fault || fault_code != 8'h01)
            $fatal(1,
                "mutated held epoch did not fail closed: %02x",
                fault_code);

        // A client completion without an outstanding sample request is also
        // terminal, proving the composed fault gate rather than one leaf.
        hard_reset();
        start_epoch(32'h70000002);
        @(negedge clk);
        sample_client_done = 1'b1;
        sample_client_data = 32'h12345678;
        @(posedge clk);
        @(negedge clk);
        sample_client_done = 1'b0;
        @(posedge clk);
        #1;
        if (!terminal_fault || fault_code != 8'h18)
            $fatal(1,
                "ownerless sample completion did not fail closed: %02x",
                fault_code);

        $display(
            "PASS: passive sound composition is disabled-safe, late-seeded, 256-post fenced, exactly ordered, time exact, and fail-closed");
        $finish;
    end
endmodule
