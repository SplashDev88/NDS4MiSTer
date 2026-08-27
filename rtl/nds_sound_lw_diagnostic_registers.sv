// Passive read-only FPGA-audio diagnostics in unused lightweight-bridge words.
//
// The production mailbox owns words 0x00..0x0c.  This module forwards every
// other read unchanged except the explicitly documented 0x0d..0x16 window.
// It has no write input, no state, and no path back into the mailbox, sound
// engine, audio mux, CPU, DDR, or interrupt logic.
//
// Byte offsets from 0xff200000:
//   0x34 magic             0x41554431 ("AUD1")
//   0x38 ownership bitmap  exact nds_sound_ownership_diagnostic predicates
//   0x3c detail            supervisor/fault and immediate health flags
//   0x40 raw stereo        {raw_left, raw_right}
//   0x44 post stereo       {fpga_left, fpga_right}
//   0x48 final stereo      {selected_left, selected_right}
//   0x4c cause             existing passive r211 cause word
//   0x50 activity          existing passive r211 activity word
//   0x54 boot generation
//   0x58 shadow active epoch
`timescale 1ns/1ps
`default_nettype none

module nds_sound_lw_diagnostic_registers (
    input  logic [18:0] reg_raddr,
    input  logic [31:0] transport_rdata,

    input  logic [31:0] ownership_predicates,
    input  logic [7:0]  supervisor_status,
    input  logic [7:0]  fault_code,
    input  logic [3:0]  sample_unsupported_reason,
    input  logic        sample_unsupported_request,
    input  logic        sample_unsupported_seen,
    input  logic        sample_protocol_error,
    input  logic        terminal_fault,
    input  logic        output_controls_valid,
    input  logic        candidate_healthy,
    input  logic        infrastructure_healthy,
    input  logic        fpga_audio_supported,
    input  logic        fpga_audio_valid,
    input  logic        fallback_required,
    input  logic        supervisor_takeover,
    input  logic        final_audio_takeover,

    input  logic signed [15:0] raw_audio_left,
    input  logic signed [15:0] raw_audio_right,
    input  logic signed [15:0] post_audio_left,
    input  logic signed [15:0] post_audio_right,
    input  logic signed [15:0] final_audio_left,
    input  logic signed [15:0] final_audio_right,
    input  logic [31:0] cause_word,
    input  logic [31:0] activity_word,
    input  logic [31:0] boot_generation,
    input  logic [31:0] shadow_active_epoch,

    output logic [31:0] reg_rdata
);
    localparam logic [18:0] REG_MAGIC       = 19'h00d;
    localparam logic [18:0] REG_PREDICATES  = 19'h00e;
    localparam logic [18:0] REG_DETAIL      = 19'h00f;
    localparam logic [18:0] REG_RAW_AUDIO   = 19'h010;
    localparam logic [18:0] REG_POST_AUDIO  = 19'h011;
    localparam logic [18:0] REG_FINAL_AUDIO = 19'h012;
    localparam logic [18:0] REG_CAUSE       = 19'h013;
    localparam logic [18:0] REG_ACTIVITY    = 19'h014;
    localparam logic [18:0] REG_BOOT_EPOCH  = 19'h015;
    localparam logic [18:0] REG_SOUND_EPOCH = 19'h016;
    localparam logic [31:0] DIAGNOSTIC_MAGIC = 32'h41554431;

    logic [31:0] detail_word;

    always_comb begin
        detail_word = {
            supervisor_status,
            fault_code,
            sample_unsupported_reason,
            sample_unsupported_request,
            sample_unsupported_seen,
            sample_protocol_error,
            terminal_fault,
            output_controls_valid,
            candidate_healthy,
            infrastructure_healthy,
            fpga_audio_supported,
            fpga_audio_valid,
            fallback_required,
            supervisor_takeover,
            final_audio_takeover
        };

        case (reg_raddr)
            REG_MAGIC:       reg_rdata = DIAGNOSTIC_MAGIC;
            REG_PREDICATES:  reg_rdata = ownership_predicates;
            REG_DETAIL:      reg_rdata = detail_word;
            REG_RAW_AUDIO:   reg_rdata = {raw_audio_left, raw_audio_right};
            REG_POST_AUDIO:  reg_rdata = {post_audio_left, post_audio_right};
            REG_FINAL_AUDIO: reg_rdata = {final_audio_left, final_audio_right};
            REG_CAUSE:       reg_rdata = cause_word;
            REG_ACTIVITY:    reg_rdata = activity_word;
            REG_BOOT_EPOCH:  reg_rdata = boot_generation;
            REG_SOUND_EPOCH: reg_rdata = shadow_active_epoch;
            default:         reg_rdata = transport_rdata;
        endcase
    end
endmodule

`default_nettype wire
