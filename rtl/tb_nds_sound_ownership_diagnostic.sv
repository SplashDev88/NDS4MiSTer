`timescale 1ns/1ps
`default_nettype none

module tb_nds_sound_ownership_diagnostic;
    logic final_audio_takeover;
    logic supervisor_takeover;
    logic candidate_healthy;
    logic data_plane_enable;
    logic [31:0] shadow_active_epoch;
    logic [31:0] boot_generation;
    logic boot_valid;
    logic boot_error;
    logic standalone_enabled;
    logic cpu_runtime_reset;
    logic ddr_mode_active;
    logic ddr_mode_change_ignored;
    logic ddr_protocol_error;
    logic terminal_fault;
    logic sample_protocol_error;
    logic sample_unsupported_seen;
    logic fpga_audio_valid;
    logic fallback_required;
    logic infrastructure_healthy;
    logic fpga_audio_supported;
    logic output_controls_valid;
    logic shadow_session_active;
    logic shadow_operating;
    logic composition_feature_enable;
    logic supervisor_armed;
    logic supervisor_invalidated;
    logic supervisor_hps_fallback;
    logic sound_requested;
    logic epoch_quiescent;
    logic pll_locked;
    logic core_reset;
    logic sample_unsupported_request;
    logic [1:0] phase;
    logic [11:0] joystick;
    logic [31:0] predicate_bitmap;
    logic [31:0] diagnostic_word;

    nds_sound_ownership_diagnostic dut (.*);

    task automatic require(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "%s", message);
    endtask

    task automatic set_all_healthy;
        begin
            final_audio_takeover = 1'b1;
            supervisor_takeover = 1'b1;
            candidate_healthy = 1'b1;
            data_plane_enable = 1'b1;
            shadow_active_epoch = 32'd8;
            boot_generation = 32'd8;
            boot_valid = 1'b1;
            boot_error = 1'b0;
            standalone_enabled = 1'b1;
            cpu_runtime_reset = 1'b0;
            ddr_mode_active = 1'b1;
            ddr_mode_change_ignored = 1'b0;
            ddr_protocol_error = 1'b0;
            terminal_fault = 1'b0;
            sample_protocol_error = 1'b0;
            sample_unsupported_seen = 1'b0;
            fpga_audio_valid = 1'b1;
            fallback_required = 1'b0;
            infrastructure_healthy = 1'b1;
            fpga_audio_supported = 1'b1;
            output_controls_valid = 1'b1;
            shadow_session_active = 1'b1;
            shadow_operating = 1'b1;
            composition_feature_enable = 1'b1;
            supervisor_armed = 1'b1;
            supervisor_invalidated = 1'b0;
            supervisor_hps_fallback = 1'b0;
            sound_requested = 1'b1;
            epoch_quiescent = 1'b1;
            pll_locked = 1'b1;
            core_reset = 1'b0;
            sample_unsupported_request = 1'b0;
            phase = 2'd0;
            joystick = 12'ha55;
            #1;
        end
    endtask

    task automatic check_phase(input logic [1:0] selected_phase);
        logic [7:0] expected_byte;
        begin
            phase = selected_phase;
            #1;
            expected_byte =
                predicate_bitmap >> (selected_phase * 8);
            require(diagnostic_word[22:21] == selected_phase,
                "phase changed");
            require(diagnostic_word[19:12] == expected_byte,
                "rotated predicate byte mismatch");
            require(diagnostic_word[11:0] == joystick,
                "joystick was not preserved");
        end
    endtask

    initial begin
        set_all_healthy();
        require(predicate_bitmap == 32'hffff_ffff,
            "healthy predicate bitmap is not all ones");
        require(diagnostic_word[31:24] == 8'hf5,
            "F5 did not identify exact FPGA mux ownership");
        check_phase(2'd0);
        check_phase(2'd1);
        check_phase(2'd2);
        check_phase(2'd3);

        set_all_healthy();
        final_audio_takeover = 1'b0;
        #1;
        require(diagnostic_word[31:24] == 8'hf4,
            "F4 did not identify final-mux fallback");
        require(predicate_bitmap == 32'hffff_fffe,
            "final takeover did not clear only bit zero");

        set_all_healthy();
        fpga_audio_supported = 1'b0;
        fpga_audio_valid = 1'b0;
        fallback_required = 1'b1;
        candidate_healthy = 1'b0;
        final_audio_takeover = 1'b0;
        #1;
        require(predicate_bitmap[19:16] == 4'b0100,
            "unsupported-output cause was not localized");
        require(predicate_bitmap[2] == 1'b0,
            "unsupported output retained candidate health");

        set_all_healthy();
        supervisor_invalidated = 1'b1;
        supervisor_hps_fallback = 1'b1;
        supervisor_takeover = 1'b0;
        data_plane_enable = 1'b0;
        final_audio_takeover = 1'b0;
        #1;
        require(predicate_bitmap[26:24] == 3'b001,
            "supervisor invalidation was not localized");
        require(predicate_bitmap[3:1] == 3'b010,
            "supervisor loss did not clear takeover/data-plane bits");

        set_all_healthy();
        final_audio_takeover = 1'bx;
        #1;
        require(diagnostic_word[31:24] == 8'hf4,
            "unknown takeover did not fail closed to F4");
        require(predicate_bitmap[0] == 1'b0,
            "unknown takeover claimed predicate success");

        set_all_healthy();
        boot_generation = 32'hxxxx_xxxx;
        #1;
        require(predicate_bitmap[5:4] == 2'b00,
            "unknown generation did not fail closed");

        $display("PASS: r210 F4/F5 diagnostic rotates all 32 exact ownership predicates and preserves joystick input");
        $finish;
    end
endmodule

`default_nettype wire
