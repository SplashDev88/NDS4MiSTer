`timescale 1ns/1ps
`default_nettype none

module tb_nds_sound_one_shot_supervisor;
    localparam integer RESET_LOCK_CYCLES = 3;
    localparam integer STARTUP_TIMEOUT = 24;
    localparam logic [31:0] TEST_EPOCH = 32'h5a17c0de;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic pll_locked = 1'b0;
    logic request_sound = 1'b0;
    logic core_reset = 1'b1;
    logic cpu_runtime_reset = 1'b1;
    logic standalone_enabled = 1'b0;
    logic boot_valid = 1'b0;
    logic boot_error = 1'b0;
    logic [31:0] boot_generation = 32'd0;
    logic transport_quiescent = 1'b0;
    logic external_epoch_fresh = 1'b0;

    logic composition_feature_enable;
    logic composition_reset;
    logic epoch_request_valid;
    logic composition_epoch_request_ready = 1'b0;
    logic [31:0] epoch_request_generation;
    logic epoch_request_fresh;

    logic composition_session_active = 1'b0;
    logic composition_operating = 1'b0;
    logic [31:0] composition_active_epoch = 32'd0;
    logic composition_terminal_fault = 1'b0;
    logic ownership_valid = 1'b0;

    logic cpu_start_hold;
    logic takeover_permitted;
    logic sound_data_plane_enable;
    logic armed_once;
    logic invalidated;
    logic hps_fallback;
    logic [7:0] status;

    integer scenario;
    integer handshake_count = 0;

    nds_sound_one_shot_supervisor #(
        .COMPOSITION_RESET_LOCK_CYCLES(RESET_LOCK_CYCLES),
        .STARTUP_TIMEOUT_CYCLES(STARTUP_TIMEOUT)
    ) dut (
        .clk,
        .pll_locked,
        .request_sound,
        .core_reset,
        .cpu_runtime_reset,
        .standalone_enabled,
        .boot_valid,
        .boot_error,
        .boot_generation,
        .transport_quiescent,
        .external_epoch_fresh,
        .composition_feature_enable,
        .composition_reset,
        .epoch_request_valid,
        .composition_epoch_request_ready,
        .epoch_request_generation,
        .epoch_request_fresh,
        .composition_session_active,
        .composition_operating,
        .composition_active_epoch,
        .composition_terminal_fault,
        .ownership_valid,
        .cpu_start_hold,
        .takeover_permitted,
        .sound_data_plane_enable,
        .armed_once,
        .invalidated,
        .hps_fallback,
        .status
    );

    always @(posedge clk) begin
        if (epoch_request_valid === 1'b1 &&
            composition_epoch_request_ready === 1'b1)
            handshake_count <= handshake_count + 1;
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            if (condition !== 1'b1)
                $fatal(1, "scenario %0d: %s", scenario, message);
        end
    endtask

    task automatic drive_exact_start(
        input logic [31:0] epoch
    );
        begin
            request_sound = 1'b1;
            core_reset = 1'b0;
            cpu_runtime_reset = 1'b0;
            standalone_enabled = 1'b1;
            boot_valid = 1'b1;
            boot_error = 1'b0;
            boot_generation = epoch;
            transport_quiescent = 1'b1;
            external_epoch_fresh = 1'b1;
        end
    endtask

    task automatic release_first_composition_reset;
        integer cycle;
        begin
            pll_locked = 1'b1;
            for (cycle = 0; cycle < RESET_LOCK_CYCLES; cycle++) begin
                tick();
                if (cycle + 1 < RESET_LOCK_CYCLES)
                    check(composition_reset === 1'b1,
                        "composition reset released before stable-lock count");
            end
            check(composition_reset === 1'b0,
                "composition reset did not release at stable-lock count");
        end
    endtask

    task automatic wait_for_epoch_offer;
        integer timeout;
        begin
            timeout = 0;
            while (epoch_request_valid !== 1'b1 && timeout < 12) begin
                tick();
                timeout = timeout + 1;
            end
            check(epoch_request_valid === 1'b1,
                "fresh epoch offer was not generated");
            check(epoch_request_generation === TEST_EPOCH,
                "epoch offer generation was not retained");
            check(epoch_request_fresh === 1'b1,
                "epoch offer did not carry exact fresh proof");
        end
    endtask

    task automatic complete_epoch_handshake;
        begin
            repeat (2) begin
                tick();
                check(epoch_request_valid === 1'b1,
                    "epoch valid was not held before ready");
                check(epoch_request_generation === TEST_EPOCH,
                    "held epoch generation changed");
                check(epoch_request_fresh === 1'b1,
                    "held epoch fresh proof changed");
            end

            composition_epoch_request_ready = 1'b1;
            tick();
            composition_epoch_request_ready = 1'b0;
            check(epoch_request_valid === 1'b0,
                "epoch valid did not deassert after handshake");
            check(epoch_request_generation === 32'd0,
                "epoch generation did not clear after handshake");
            check(epoch_request_fresh === 1'b0,
                "epoch fresh did not clear after handshake");
            check(handshake_count == 1,
                "external freshness was not consumed exactly once");
            external_epoch_fresh = 1'b0;
        end
    endtask

    task automatic report_exact_operating;
        begin
            composition_session_active = 1'b1;
            composition_operating = 1'b1;
            composition_active_epoch = TEST_EPOCH;
            composition_terminal_fault = 1'b0;
            ownership_valid = 1'b1;
            tick();

            check(armed_once === 1'b1,
                "exact operating epoch did not arm");
            check(takeover_permitted === 1'b1,
                "exact operating epoch did not permit takeover");
            check(sound_data_plane_enable === 1'b1,
                "sound data plane did not follow takeover");
            check(composition_feature_enable === 1'b1,
                "composition feature disabled while armed");
            check(cpu_start_hold === 1'b0,
                "CPU hold was not released after sound decision");
            check(hps_fallback === 1'b0,
                "HPS fallback remained selected while armed");
            check(invalidated === 1'b0,
                "freshly armed session was already invalidated");
            check(status === 8'h10,
                "armed status code was not reported");
        end
    endtask

    task automatic arm_exact;
        begin
            drive_exact_start(TEST_EPOCH);
            release_first_composition_reset();
            wait_for_epoch_offer();
            complete_epoch_handshake();
            report_exact_operating();
        end
    endtask

    task automatic check_immediate_fallback;
        begin
            #1;
            check(takeover_permitted === 1'b0,
                "ownership did not fall immediately");
            check(sound_data_plane_enable === 1'b0,
                "sound data plane remained enabled after invalidator");
            check(hps_fallback === 1'b1,
                "HPS fallback was not selected after invalidator");
            check(cpu_start_hold === 1'b0,
                "post-start invalidation reasserted CPU hold");
        end
    endtask

    task automatic verify_permanent_invalidation(
        input logic [7:0] expected_status
    );
        begin
            tick();
            check(invalidated === 1'b1,
                "post-arm invalidator did not latch");
            check(armed_once === 1'b1,
                "invalidation cleared armed-once history");
            check(status === expected_status,
                "wrong invalidation status");
            check(composition_reset === 1'b0,
                "invalidation reasserted composition reset");
            check(composition_feature_enable === 1'b0,
                "composition feature remained enabled after invalidation");

            drive_exact_start(TEST_EPOCH);
            pll_locked = 1'b1;
            composition_session_active = 1'b1;
            composition_operating = 1'b1;
            composition_active_epoch = TEST_EPOCH;
            composition_terminal_fault = 1'b0;
            ownership_valid = 1'b1;
            composition_epoch_request_ready = 1'b1;
            repeat (4) tick();
            check(takeover_permitted === 1'b0,
                "invalidated configuration re-armed");
            check(epoch_request_valid === 1'b0,
                "invalidated configuration repeated its epoch offer");
            check(handshake_count == 1,
                "same epoch was accepted more than once");
            check(composition_reset === 1'b0,
                "composition reset reasserted after invalidation");
        end
    endtask

    initial begin
        if (!$value$plusargs("SCENARIO=%d", scenario))
            scenario = 0;

        #1;
        check(composition_reset === 1'b1,
            "composition reset was not asserted at configuration");
        check(cpu_start_hold === 1'b1,
            "CPUs were not held before the sound-start decision");
        check(takeover_permitted === 1'b0,
            "FPGA sound owned output at configuration");
        check(sound_data_plane_enable === 1'b0,
            "sound data plane was enabled at configuration");
        check(hps_fallback === 1'b1,
            "HPS was not the default output owner");

        case (scenario)
            0: begin
                arm_exact();
            end

            1: begin
                drive_exact_start(TEST_EPOCH);
                release_first_composition_reset();
                wait_for_epoch_offer();
                repeat (2) tick();
                check(cpu_start_hold === 1'b1,
                    "stalled epoch handshake released CPUs prematurely");
                check(epoch_request_valid === 1'b1,
                    "stalled epoch handshake did not hold valid");
                repeat (STARTUP_TIMEOUT + 3) tick();
                check(cpu_start_hold === 1'b0,
                    "startup timeout did not release CPUs to HPS");
                check(hps_fallback === 1'b1,
                    "startup timeout did not latch HPS fallback");
                check(armed_once === 1'b0,
                    "startup timeout falsely armed sound");
                check(invalidated === 1'b0,
                    "startup timeout falsely reported post-arm invalidation");
                check(status === 8'h84,
                    "startup timeout status was not retained");
                check(epoch_request_valid === 1'b0,
                    "startup timeout left a stale epoch offer asserted");

                composition_epoch_request_ready = 1'b1;
                composition_session_active = 1'b1;
                composition_operating = 1'b1;
                composition_active_epoch = TEST_EPOCH;
                ownership_valid = 1'b1;
                repeat (4) tick();
                check(epoch_request_valid === 1'b0,
                    "timed-out configuration offered an epoch later");
                check(takeover_permitted === 1'b0,
                    "timed-out configuration armed later");
            end

            2: begin
                drive_exact_start(TEST_EPOCH);
                core_reset = 1'b1;
                cpu_runtime_reset = 1'b1;
                release_first_composition_reset();
                repeat (2) tick();
                check(invalidated === 1'b0,
                    "startup reset pulses falsely invalidated configuration");
                check(cpu_start_hold === 1'b1,
                    "startup reset pulses released CPUs prematurely");
                check(epoch_request_valid === 1'b0,
                    "epoch was offered while startup resets were active");

                core_reset = 1'b0;
                cpu_runtime_reset = 1'b0;
                wait_for_epoch_offer();
                complete_epoch_handshake();
                report_exact_operating();

                core_reset = 1'b1;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he0);
            end

            3: begin
                arm_exact();
                cpu_runtime_reset = 1'b1;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he1);
            end

            4: begin
                arm_exact();
                pll_locked = 1'b0;
                check_immediate_fallback();
                check(composition_reset === 1'b0,
                    "PLL loss reasserted composition reset combinationally");
                verify_permanent_invalidation(8'he2);
            end

            5: begin
                arm_exact();
                standalone_enabled = 1'b0;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he3);
            end

            6: begin
                arm_exact();
                request_sound = 1'b0;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he4);
            end

            7: begin
                arm_exact();
                boot_valid = 1'b0;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he5);
            end

            8: begin
                arm_exact();
                boot_error = 1'b1;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he6);
            end

            9: begin
                arm_exact();
                boot_generation = TEST_EPOCH + 1'b1;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he7);
            end

            10: begin
                arm_exact();
                transport_quiescent = 1'b0;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he8);
            end

            11: begin
                arm_exact();
                composition_terminal_fault = 1'b1;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he9);
            end

            12: begin
                arm_exact();
                composition_session_active = 1'b0;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he9);
            end

            13: begin
                arm_exact();
                composition_operating = 1'b0;
                check_immediate_fallback();
                verify_permanent_invalidation(8'he9);
            end

            14: begin
                arm_exact();
                composition_active_epoch = TEST_EPOCH + 1'b1;
                check_immediate_fallback();
                verify_permanent_invalidation(8'hea);
            end

            15: begin
                arm_exact();
                ownership_valid = 1'b0;
                check_immediate_fallback();
                verify_permanent_invalidation(8'heb);
            end

            16: begin
                drive_exact_start(TEST_EPOCH);
`ifndef VERILATOR
                request_sound = 1'bx;
                release_first_composition_reset();
                repeat (2) tick();
                check(epoch_request_valid === 1'b0,
                    "unknown request_sound launched an epoch");
                check(takeover_permitted === 1'b0,
                    "unknown request_sound permitted ownership");
                check(cpu_start_hold === 1'b1,
                    "unknown request_sound released CPUs");
                check(invalidated === 1'b0,
                    "unknown startup input falsely invalidated");

                request_sound = 1'b1;
`else
                release_first_composition_reset();
`endif
                wait_for_epoch_offer();
`ifndef VERILATOR
                composition_epoch_request_ready = 1'bx;
                tick();
                check(epoch_request_valid === 1'b1,
                    "unknown epoch ready completed the handshake");
                check(handshake_count == 0,
                    "unknown epoch ready consumed freshness");
                composition_epoch_request_ready = 1'b0;
`endif
                complete_epoch_handshake();
                composition_session_active = 1'b1;
                composition_operating = 1'b1;
                composition_active_epoch = TEST_EPOCH;
                composition_terminal_fault = 1'b0;
`ifndef VERILATOR
                ownership_valid = 1'bx;
                tick();
                check(armed_once === 1'b0,
                    "unknown ownership predicate armed sound");
                check(takeover_permitted === 1'b0,
                    "unknown ownership predicate permitted takeover");
                check(cpu_start_hold === 1'b1,
                    "CPU released before exact ownership became valid");

                ownership_valid = 1'b1;
`else
                ownership_valid = 1'b1;
`endif
                report_exact_operating();
`ifndef VERILATOR
                transport_quiescent = 1'bx;
`else
                transport_quiescent = 1'b0;
`endif
                check_immediate_fallback();
                verify_permanent_invalidation(8'he8);
            end

            17: begin
                // The menu-mediated loader intentionally invalidates the
                // descriptor before loading the core. The descriptor reader
                // therefore enters REJECTED while the responder is starting,
                // but retries and later accepts the published descriptor.
                request_sound = 1'b1;
                core_reset = 1'b0;
                cpu_runtime_reset = 1'b0;
                standalone_enabled = 1'b1;
                transport_quiescent = 1'b1;
                external_epoch_fresh = 1'b1;
                boot_valid = 1'b0;
                boot_error = 1'b1;
                boot_generation = 32'd0;
                release_first_composition_reset();
                repeat (4) tick();
                check(cpu_start_hold === 1'b1,
                    "transient descriptor rejection released CPUs");
                check(status === 8'h01,
                    "transient descriptor rejection latched HPS fallback");
                check(epoch_request_valid === 1'b0,
                    "invalid descriptor launched an epoch");

                boot_error = 1'b0;
                boot_valid = 1'b1;
                boot_generation = TEST_EPOCH;
                wait_for_epoch_offer();
                complete_epoch_handshake();
                report_exact_operating();
            end

            18: begin
                // A descriptor that remains rejected for the full bounded
                // window still fails closed and retains the precise cause.
                request_sound = 1'b1;
                core_reset = 1'b0;
                cpu_runtime_reset = 1'b0;
                standalone_enabled = 1'b1;
                transport_quiescent = 1'b1;
                external_epoch_fresh = 1'b1;
                boot_valid = 1'b0;
                boot_error = 1'b1;
                boot_generation = 32'd0;
                release_first_composition_reset();
                repeat (STARTUP_TIMEOUT + 3) tick();
                check(cpu_start_hold === 1'b0,
                    "persistent descriptor rejection did not fail closed");
                check(hps_fallback === 1'b1,
                    "persistent descriptor rejection did not select HPS");
                check(status === 8'h82,
                    "persistent descriptor rejection lost boot-error cause");
                check(armed_once === 1'b0,
                    "persistent descriptor rejection falsely armed sound");
            end

            default:
                $fatal(1, "unknown scenario %0d", scenario);
        endcase

        $display(
            "PASS: one-shot sound supervisor scenario %0d", scenario);
        $finish;
    end
endmodule

`default_nettype wire
