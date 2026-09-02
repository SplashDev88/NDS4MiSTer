// r211-only atomic transport for the completed KEYINPUT witness and the five
// passive FPGA-audio diagnostic pages.
//
// Eight pages are emitted in a fixed rotation:
//   page 0, F0/F1: completed KEYINPUT status/response payload
//   page 1, F2/F3: first ARM9 retirement PC
//   page 2, F4/F5: later ARM9 retirement PC
//   page 3, F6/F7: audio cause
//   page 4, F8/F9: raw audio witness
//   page 5, FA/FB: post-adapter audio witness
//   page 6, FC/FD: final-mux audio witness
//   page 7, FE/FF: audio activity/sample-DDR summary
//
// The even marker is the fail-closed form.  Input pages use the completed
// witness validity and audio pages use final-audio takeover.  An unknown
// qualifier or unknown selected payload can never produce an odd marker or
// leak X payload bits into the transport.  The first complete, fully known
// input bundle whose response is not the all-released 03FF value is frozen
// for the reset epoch.  Thus an earlier released witness cannot hide the
// later held-button witness, and later KEYINPUT reads cannot mix status and
// PCs from different witnesses during sparse capture.  Marker, payload, and
// page are captured together only on the phase-3 to phase-0 page boundary.
// Physical joystick bits 11:0 remain a live combinational pass-through in
// every phase.
`timescale 1ns/1ps
`default_nettype none

module nds_r211_combined_diagnostic_serializer #(
    parameter integer PHASE_DIVIDER_WIDTH = 15
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        input_completed_valid,
    input  logic [31:0] input_status_payload,
    input  logic [31:0] input_first_retire_pc,
    input  logic [31:0] input_later_retire_pc,

    input  logic        final_audio_takeover,
    input  logic [31:0] audio_page_cause,
    input  logic [31:0] audio_page_raw,
    input  logic [31:0] audio_page_post,
    input  logic [31:0] audio_page_final,
    input  logic [31:0] audio_page_activity,

    input  logic [11:0] joystick,

    output logic [1:0]  diagnostic_phase,
    output logic [2:0]  diagnostic_page,
    output logic [7:0]  diagnostic_marker,
    output logic [31:0] diagnostic_snapshot,
    output logic        diagnostic_snapshot_strobe,
    output logic [31:0] diagnostic_word
);
    logic [PHASE_DIVIDER_WIDTH-1:0] phase_divider;
    logic [2:0] page_to_capture;
    logic [31:0] selected_live_payload;
    logic [31:0] safe_capture_payload;
    logic selected_payload_known;
    logic live_input_bundle_known;
    logic input_bundle_frozen;
    logic [31:0] frozen_input_status_payload;
    logic [31:0] frozen_input_first_retire_pc;
    logic [31:0] frozen_input_later_retire_pc;
    logic selected_page_valid;
    logic [7:0] selected_base_marker;
    logic [7:0] rotated_byte;

    function automatic logic [7:0] base_marker_for_page (
        input logic [2:0] page
    );
        begin
            case (page)
                3'd0: base_marker_for_page = 8'hf0;
                3'd1: base_marker_for_page = 8'hf2;
                3'd2: base_marker_for_page = 8'hf4;
                3'd3: base_marker_for_page = 8'hf6;
                3'd4: base_marker_for_page = 8'hf8;
                3'd5: base_marker_for_page = 8'hfa;
                3'd6: base_marker_for_page = 8'hfc;
                3'd7: base_marker_for_page = 8'hfe;
                default: base_marker_for_page = 8'hf0;
            endcase
        end
    endfunction

    always_comb begin
        case (page_to_capture)
            3'd0: selected_live_payload = frozen_input_status_payload;
            3'd1: selected_live_payload =
                frozen_input_first_retire_pc;
            3'd2: selected_live_payload =
                frozen_input_later_retire_pc;
            3'd3: selected_live_payload = audio_page_cause;
            3'd4: selected_live_payload = audio_page_raw;
            3'd5: selected_live_payload = audio_page_post;
            3'd6: selected_live_payload = audio_page_final;
            3'd7: selected_live_payload = audio_page_activity;
            default: selected_live_payload = 32'd0;
        endcase
    end

    assign live_input_bundle_known =
        (^input_status_payload !== 1'bx) &&
        (^input_first_retire_pc !== 1'bx) &&
        (^input_later_retire_pc !== 1'bx);
    assign selected_payload_known =
        (^selected_live_payload !== 1'bx);
    assign safe_capture_payload =
        selected_payload_known ? selected_live_payload : 32'd0;
    assign selected_base_marker =
        base_marker_for_page(page_to_capture);

    // Case equality makes an unknown validity/takeover qualifier false.
    // Requiring both a frozen bundle and currently valid/known observer
    // outputs prevents three input pages from advertising a stale or
    // mutually inconsistent witness after an observer fault.
    always_comb begin
        if (page_to_capture <= 3'd2) begin
            selected_page_valid =
                input_bundle_frozen &&
                input_completed_valid === 1'b1 &&
                live_input_bundle_known &&
                selected_payload_known;
        end else begin
            selected_page_valid =
                final_audio_takeover === 1'b1 &&
                selected_payload_known;
        end
    end

    always_comb begin
        case (diagnostic_phase)
            2'd0: rotated_byte = diagnostic_snapshot[7:0];
            2'd1: rotated_byte = diagnostic_snapshot[15:8];
            2'd2: rotated_byte = diagnostic_snapshot[23:16];
            2'd3: rotated_byte = diagnostic_snapshot[31:24];
            default: rotated_byte = 8'd0;
        endcase
    end

    assign diagnostic_word = {
        diagnostic_marker,
        1'b0,
        diagnostic_phase,
        1'b0,
        rotated_byte,
        joystick
    };

    initial begin
        if (PHASE_DIVIDER_WIDTH < 1)
            $fatal(1, "PHASE_DIVIDER_WIDTH must be positive");
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            phase_divider <= '0;
            diagnostic_phase <= 2'd0;
            page_to_capture <= 3'd0;
            diagnostic_page <= 3'd0;
            diagnostic_marker <= 8'hf0;
            diagnostic_snapshot <= 32'd0;
            diagnostic_snapshot_strobe <= 1'b0;
            input_bundle_frozen <= 1'b0;
            frozen_input_status_payload <= 32'd0;
            frozen_input_first_retire_pc <= 32'd0;
            frozen_input_later_retire_pc <= 32'd0;
        end else begin
            // Capture exactly one non-released completed witness for this CPU
            // reset epoch. Later successful reads may replace the observer's
            // sticky outputs, but cannot tear this three-page publication.
            if (!input_bundle_frozen &&
                input_completed_valid === 1'b1 &&
                live_input_bundle_known &&
                input_status_payload[15:10] == 6'd0 &&
                input_status_payload[9:0] != 10'h3ff) begin
                input_bundle_frozen <= 1'b1;
                frozen_input_status_payload <= input_status_payload;
                frozen_input_first_retire_pc <=
                    input_first_retire_pc;
                frozen_input_later_retire_pc <=
                    input_later_retire_pc;
            end

            diagnostic_snapshot_strobe <= 1'b0;
            if (&phase_divider) begin
                phase_divider <= '0;
                if (diagnostic_phase == 2'd3) begin
                    // These three fields sample the same page and the same
                    // validity decision on this one boundary edge.
                    diagnostic_phase <= 2'd0;
                    diagnostic_page <= page_to_capture;
                    diagnostic_marker <= selected_base_marker |
                        {7'd0, selected_page_valid};
                    diagnostic_snapshot <= safe_capture_payload;
                    diagnostic_snapshot_strobe <= 1'b1;
                    page_to_capture <= page_to_capture + 3'd1;
                end else begin
                    diagnostic_phase <= diagnostic_phase + 2'd1;
                end
            end else begin
                phase_divider <= phase_divider + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
