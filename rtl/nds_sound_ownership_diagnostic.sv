// r210-only read-only diagnostic for the exact final FPGA-audio mux decision.
//
// The four rotating bytes expose every predicate involved in, or immediately
// upstream of, sound_audio_takeover while preserving the physical joystick.
// F4 identifies the diagnostic image with the legacy/HPS mux selected; F5 is
// emitted only when the exact final mux selects FPGA samples.
`timescale 1ns/1ps
`default_nettype none

module nds_sound_ownership_diagnostic (
    input  logic        final_audio_takeover,
    input  logic        supervisor_takeover,
    input  logic        candidate_healthy,
    input  logic        data_plane_enable,
    input  logic [31:0] shadow_active_epoch,
    input  logic [31:0] boot_generation,
    input  logic        boot_valid,
    input  logic        boot_error,
    input  logic        standalone_enabled,
    input  logic        cpu_runtime_reset,
    input  logic        ddr_mode_active,
    input  logic        ddr_mode_change_ignored,
    input  logic        ddr_protocol_error,
    input  logic        terminal_fault,
    input  logic        sample_protocol_error,
    input  logic        sample_unsupported_seen,
    input  logic        fpga_audio_valid,
    input  logic        fallback_required,
    input  logic        infrastructure_healthy,
    input  logic        fpga_audio_supported,
    input  logic        output_controls_valid,
    input  logic        shadow_session_active,
    input  logic        shadow_operating,
    input  logic        composition_feature_enable,
    input  logic        supervisor_armed,
    input  logic        supervisor_invalidated,
    input  logic        supervisor_hps_fallback,
    input  logic        sound_requested,
    input  logic        epoch_quiescent,
    input  logic        pll_locked,
    input  logic        core_reset,
    input  logic        sample_unsupported_request,
    input  logic [1:0]  phase,
    input  logic [11:0] joystick,
    output logic [31:0] predicate_bitmap,
    output logic [31:0] diagnostic_word
);
    logic [7:0] predicate_byte;

    always_comb begin
        // Bits 0..17 are the exact final-mux predicate chain in source order.
        predicate_bitmap[0]  = final_audio_takeover === 1'b1;
        predicate_bitmap[1]  = supervisor_takeover === 1'b1;
        predicate_bitmap[2]  = candidate_healthy === 1'b1;
        predicate_bitmap[3]  = data_plane_enable === 1'b1;
        predicate_bitmap[4]  =
            shadow_active_epoch === boot_generation;
        predicate_bitmap[5]  =
            (^boot_generation !== 1'bx) && boot_generation != 32'd0;
        predicate_bitmap[6]  = boot_valid === 1'b1;
        predicate_bitmap[7]  = boot_error === 1'b0;
        predicate_bitmap[8]  = standalone_enabled === 1'b1;
        predicate_bitmap[9]  = cpu_runtime_reset === 1'b0;
        predicate_bitmap[10] = ddr_mode_active === 1'b1;
        predicate_bitmap[11] = ddr_mode_change_ignored === 1'b0;
        predicate_bitmap[12] = ddr_protocol_error === 1'b0;
        predicate_bitmap[13] = terminal_fault === 1'b0;
        predicate_bitmap[14] = sample_protocol_error === 1'b0;
        predicate_bitmap[15] = sample_unsupported_seen === 1'b0;
        predicate_bitmap[16] = fpga_audio_valid === 1'b1;
        predicate_bitmap[17] = fallback_required === 1'b0;

        // Bits 18..31 localize the upstream cause when candidate/supervisor
        // health prevents one of the exact final conditions above.
        predicate_bitmap[18] = infrastructure_healthy === 1'b1;
        predicate_bitmap[19] = fpga_audio_supported === 1'b1;
        predicate_bitmap[20] = output_controls_valid === 1'b1;
        predicate_bitmap[21] = shadow_session_active === 1'b1;
        predicate_bitmap[22] = shadow_operating === 1'b1;
        predicate_bitmap[23] =
            composition_feature_enable === 1'b1;
        predicate_bitmap[24] = supervisor_armed === 1'b1;
        predicate_bitmap[25] = supervisor_invalidated === 1'b0;
        predicate_bitmap[26] = supervisor_hps_fallback === 1'b0;
        predicate_bitmap[27] = sound_requested === 1'b1;
        predicate_bitmap[28] = epoch_quiescent === 1'b1;
        predicate_bitmap[29] = pll_locked === 1'b1;
        predicate_bitmap[30] = core_reset === 1'b0;
        predicate_bitmap[31] =
            sample_unsupported_request === 1'b0;

        case (phase)
            2'd0: predicate_byte = predicate_bitmap[7:0];
            2'd1: predicate_byte = predicate_bitmap[15:8];
            2'd2: predicate_byte = predicate_bitmap[23:16];
            default: predicate_byte = predicate_bitmap[31:24];
        endcase

        diagnostic_word = {
            (final_audio_takeover === 1'b1) ? 8'hf5 : 8'hf4,
            1'b0,
            phase,
            1'b0,
            predicate_byte,
            joystick
        };
    end
endmodule

`default_nettype wire
