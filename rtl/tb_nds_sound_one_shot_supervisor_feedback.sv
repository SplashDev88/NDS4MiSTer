`timescale 1ns/1ps
`default_nettype none

// Closes the same health loop used by the private r204 top: infrastructure
// cannot be healthy unless the composition feature is enabled, and the
// supervisor receives that infrastructure health as ownership_valid.  This
// directed integration rejected the former ARMED-state equation
// feature_enable <- takeover <- ownership <- feature_enable.
module tb_nds_sound_one_shot_supervisor_feedback;
    localparam logic [31:0] TEST_EPOCH = 32'h64a0d10f;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic pll_locked = 1'b0;
    logic request_sound = 1'b1;
    logic core_reset = 1'b1;
    logic cpu_runtime_reset = 1'b1;
    logic standalone_enabled = 1'b1;
    logic boot_valid = 1'b0;
    logic boot_error = 1'b0;
    logic [31:0] boot_generation = 32'd0;
    logic transport_quiescent = 1'b0;

    logic composition_feature_enable;
    logic composition_reset;
    logic epoch_request_valid;
    logic epoch_request_ready = 1'b0;
    logic [31:0] epoch_request_generation;
    logic epoch_request_fresh;
    logic composition_session_active = 1'b0;
    logic composition_operating = 1'b0;
    logic [31:0] composition_active_epoch = 32'd0;
    logic composition_terminal_fault = 1'b0;
    logic infrastructure_ready = 1'b0;
    wire ownership_valid =
        composition_feature_enable && infrastructure_ready;

    logic cpu_start_hold;
    logic takeover_permitted;
    logic sound_data_plane_enable;
    logic armed_once;
    logic invalidated;
    logic hps_fallback;
    logic [7:0] status;

    nds_sound_one_shot_supervisor #(
        .COMPOSITION_RESET_LOCK_CYCLES(1),
        .STARTUP_TIMEOUT_CYCLES(64)
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
        .external_epoch_fresh(1'b1),
        .composition_feature_enable,
        .composition_reset,
        .epoch_request_valid,
        .composition_epoch_request_ready(epoch_request_ready),
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

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic require(
        input logic condition,
        input string message
    );
        begin
            if (condition !== 1'b1)
                $fatal(1, "%s", message);
        end
    endtask

    integer timeout;
    initial begin
        #1;
        require(composition_reset === 1'b1,
            "composition reset not asserted at configuration");
        require(takeover_permitted === 1'b0,
            "takeover asserted at configuration");

        pll_locked = 1'b1;
        tick();
        require(composition_reset === 1'b0,
            "composition reset did not release");

        core_reset = 1'b0;
        cpu_runtime_reset = 1'b0;
        boot_valid = 1'b1;
        boot_generation = TEST_EPOCH;
        transport_quiescent = 1'b1;

        timeout = 0;
        while (epoch_request_valid !== 1'b1 && timeout < 12) begin
            tick();
            timeout = timeout + 1;
        end
        require(epoch_request_valid === 1'b1,
            "epoch offer did not appear");
        require(epoch_request_generation === TEST_EPOCH,
            "wrong offered epoch");
        require(composition_feature_enable === 1'b1,
            "feature not enabled during epoch offer");

        epoch_request_ready = 1'b1;
        tick();
        epoch_request_ready = 1'b0;
        composition_session_active = 1'b1;
        composition_operating = 1'b1;
        composition_active_epoch = TEST_EPOCH;
        infrastructure_ready = 1'b1;
        tick();

        require(armed_once === 1'b1,
            "closed-loop composition did not arm");
        require(composition_feature_enable === 1'b1,
            "feature collapsed on ARMED transition");
        require(ownership_valid === 1'b1,
            "derived ownership did not remain valid");
        require(takeover_permitted === 1'b1,
            "closed-loop composition did not take ownership");
        require(sound_data_plane_enable === 1'b1,
            "data plane not enabled after closed-loop arm");
        require(cpu_start_hold === 1'b0,
            "CPU hold not released after closed-loop arm");
        require(hps_fallback === 1'b0,
            "HPS fallback remained selected after closed-loop arm");

        // Health loss must remove audio ownership without depending on the
        // feature output, then permanently disable the feature at the next
        // clock.  This avoids both a glitch and a rearming fixed point.
        infrastructure_ready = 1'b0;
        #1;
        require(takeover_permitted === 1'b0,
            "ownership did not fall immediately on health loss");
        require(hps_fallback === 1'b1,
            "HPS fallback did not become immediate");
        require(composition_feature_enable === 1'b1,
            "feature fell through the derived-health feedback path");
        tick();
        require(invalidated === 1'b1,
            "health loss did not permanently invalidate");
        require(composition_feature_enable === 1'b0,
            "feature remained enabled after invalidation");
        require(takeover_permitted === 1'b0,
            "invalidated configuration regained ownership");

        $display(
            "PASS: one-shot supervisor has no ARMED health/feature feedback loop");
        $finish;
    end
endmodule

`default_nettype wire
