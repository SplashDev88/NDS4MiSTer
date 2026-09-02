`timescale 1ns/1ps
`default_nettype none

module tb_nds_sound_output_adapter;
    logic signed [15:0] raw_audio_left;
    logic signed [15:0] raw_audio_right;
    logic master_enable;
    logic [1:0] left_output_source;
    logic [1:0] right_output_source;
    logic exclude_channel_1_from_mixer;
    logic exclude_channel_3_from_mixer;
    logic [9:0] sound_bias;
    logic capture_0_active;
    logic capture_1_active;
    logic [15:0] soundcnt_value;
    logic [15:0] soundcap_value;
    logic controls_settled;

    logic signed [15:0] fpga_audio_left;
    logic signed [15:0] fpga_audio_right;
    logic fpga_audio_supported;
    logic fpga_audio_valid;
    logic fallback_required;

    integer code;
    integer left_mode;
    integer right_mode;
    integer master;
    integer bias_code;
    integer capture_mask;
    integer exclusion_mask;
    integer supported_count;
    logic expected_supported;
    logic signed [15:0] expected_left;
    logic signed [15:0] expected_right;

    nds_sound_output_adapter dut (
        .raw_audio_left,
        .raw_audio_right,
        .master_enable,
        .left_output_source,
        .right_output_source,
        .exclude_channel_1_from_mixer,
        .exclude_channel_3_from_mixer,
        .sound_bias,
        .capture_0_active,
        .capture_1_active,
        .soundcnt_value,
        .soundcap_value,
        .controls_settled,
        .fpga_audio_left,
        .fpga_audio_right,
        .fpga_audio_supported,
        .fpga_audio_valid,
        .fallback_required
    );

    function automatic logic signed [15:0] reference_scale (
        input logic signed [15:0] sample
    );
        integer value;
        begin
            // Deliberately independent integer reference: no shift or slice
            // from the implementation is reused here.
            value = $signed(sample) * 16;
            if (value > 32767)
                reference_scale = 16'sh7fff;
            else if (value < -32768)
                reference_scale = 16'sh8000;
            else
                reference_scale = value[15:0];
        end
    endfunction

    task automatic set_supported_controls;
        begin
            master_enable = 1'b1;
            left_output_source = 2'b00;
            right_output_source = 2'b00;
            exclude_channel_1_from_mixer = 1'b0;
            exclude_channel_3_from_mixer = 1'b0;
            sound_bias = 10'h200;
            capture_0_active = 1'b0;
            capture_1_active = 1'b0;
            soundcnt_value = 16'h807f;
            soundcap_value = 16'h0000;
            controls_settled = 1'b1;
        end
    endtask

    task automatic set_nsmb_capture_proxy_controls;
        begin
            // Exact released-write shadow values from the native NSMB
            // transition.  This remains a live-mixer capture proxy rather
            // than complete capture support.
            master_enable = 1'b1;
            left_output_source = 2'b01;
            right_output_source = 2'b10;
            exclude_channel_1_from_mixer = 1'b1;
            exclude_channel_3_from_mixer = 1'b1;
            sound_bias = 10'h200;
            capture_0_active = 1'b1;
            capture_1_active = 1'b1;
            soundcnt_value = 16'hb97f;
            soundcap_value = 16'h8080;
            controls_settled = 1'b1;
        end
    endtask

    task automatic require_supported_outputs (
        input logic signed [15:0] wanted_left,
        input logic signed [15:0] wanted_right,
        input integer case_id
    );
        begin
            if (fpga_audio_supported !== 1'b1 ||
                fpga_audio_valid !== 1'b1 ||
                fallback_required !== 1'b0 ||
                fpga_audio_left !== wanted_left ||
                fpga_audio_right !== wanted_right)
                $fatal(1,
                    "supported mismatch context=%0d raw=%0d/%0d got=%0d/%0d supported=%b valid=%b fallback=%b expected=%0d/%0d",
                    case_id, $signed(raw_audio_left),
                    $signed(raw_audio_right), $signed(fpga_audio_left),
                    $signed(fpga_audio_right), fpga_audio_supported,
                    fpga_audio_valid, fallback_required,
                    $signed(wanted_left), $signed(wanted_right));
        end
    endtask

    task automatic require_fallback (input integer case_id);
        begin
            if (fpga_audio_supported !== 1'b0 ||
                fpga_audio_valid !== 1'b0 ||
                fallback_required !== 1'b1 ||
                fpga_audio_left !== 16'sd0 ||
                fpga_audio_right !== 16'sd0)
                $fatal(1,
                    "fallback mismatch context=%0d got=%0d/%0d supported=%b valid=%b fallback=%b",
                    case_id, $signed(fpga_audio_left),
                    $signed(fpga_audio_right), fpga_audio_supported,
                    fpga_audio_valid, fallback_required);
        end
    endtask

    task automatic check_threshold (
        input logic signed [15:0] sample,
        input logic signed [15:0] wanted
    );
        begin
            set_supported_controls();
            raw_audio_left = sample;
            raw_audio_right = sample;
            #1;
            require_supported_outputs(
                wanted, wanted, {{16{sample[15]}}, sample});
        end
    endtask

    initial begin
        raw_audio_left = 16'sd0;
        raw_audio_right = 16'sd0;
        set_supported_controls();
        #1;

        // Explicit boundary cases make the saturation contract reviewable.
        check_threshold(16'sh8000,    16'sh8000);
        check_threshold(-16'sd2049,  -16'sd32768);
        check_threshold(-16'sd2048,  -16'sd32768);
        check_threshold(-16'sd2047,  -16'sd32752);
        check_threshold(-16'sd1,     -16'sd16);
        check_threshold(16'sd0,       16'sd0);
        check_threshold(16'sd1,       16'sd16);
        check_threshold(16'sd2047,    16'sd32752);
        check_threshold(16'sd2048,    16'sd32767);
        check_threshold(16'sd32767,   16'sd32767);

        // Every possible signed input is exercised on each channel. The XOR
        // permutation makes left/right values different while covering the
        // complete 16-bit domain independently on both sides.
        set_supported_controls();
        for (code = 0; code < 65536; code = code + 1) begin
            raw_audio_left = code[15:0];
            raw_audio_right = (code[15:0] ^ 16'ha5a5);
            #1;
            expected_left = reference_scale(raw_audio_left);
            expected_right = reference_scale(raw_audio_right);
            require_supported_outputs(expected_left, expected_right, code);
        end

        // The r209 dual-capture proxy selects normal-mixer-scaled raw slices
        // after its channel-1/channel-3 exclusions despite SOUNDCNT requesting
        // CH1-left/CH3-right.  Exhaust the full signed domain again under the
        // exact NSMB control tuple so the exception cannot accidentally
        // select direct-path scaling.
        set_nsmb_capture_proxy_controls();
        for (code = 0; code < 65536; code = code + 1) begin
            raw_audio_left = (code[15:0] ^ 16'h3c5a);
            raw_audio_right = code[15:0];
            #1;
            expected_left = reference_scale(raw_audio_left);
            expected_right = reference_scale(raw_audio_right);
            require_supported_outputs(
                expected_left, expected_right, code + 65536);
        end

        // Exhaust the entire declared control space: 4x4 routes, two master
        // states, all 1024 biases, four capture states, and four exclusion
        // states. Exactly the normal mixer tuple and the title-proven exposed
        // NSMB capture-proxy tuple may claim FPGA audio ownership.
        raw_audio_left = 16'sd2047;
        raw_audio_right = -16'sd2048;
        supported_count = 0;
        for (left_mode = 0; left_mode < 4;
             left_mode = left_mode + 1)
        for (right_mode = 0; right_mode < 4;
             right_mode = right_mode + 1)
        for (master = 0; master < 2; master = master + 1)
        for (bias_code = 0; bias_code < 1024;
             bias_code = bias_code + 1)
        for (capture_mask = 0; capture_mask < 4;
             capture_mask = capture_mask + 1)
        for (exclusion_mask = 0; exclusion_mask < 4;
             exclusion_mask = exclusion_mask + 1) begin
            left_output_source = left_mode[1:0];
            right_output_source = right_mode[1:0];
            master_enable = master[0];
            sound_bias = bias_code[9:0];
            capture_0_active = capture_mask[0];
            capture_1_active = capture_mask[1];
            exclude_channel_1_from_mixer = exclusion_mask[0];
            exclude_channel_3_from_mixer = exclusion_mask[1];
            soundcnt_value = 16'h007f;
            soundcnt_value[15] = master[0];
            soundcnt_value[9:8] = left_mode[1:0];
            soundcnt_value[11:10] = right_mode[1:0];
            soundcnt_value[12] = exclusion_mask[0];
            soundcnt_value[13] = exclusion_mask[1];
            soundcap_value = 16'h0000;
            soundcap_value[7] = capture_mask[0];
            soundcap_value[15] = capture_mask[1];
            expected_supported =
                master == 1 &&
                bias_code == 512 &&
                ((left_mode == 0 &&
                  right_mode == 0 &&
                  capture_mask == 0 &&
                  exclusion_mask == 0) ||
                 (left_mode == 1 &&
                  right_mode == 2 &&
                  capture_mask == 3 &&
                  exclusion_mask == 3));
            #1;

            if (expected_supported) begin
                supported_count = supported_count + 1;
                require_supported_outputs(
                    16'sd32752, -16'sd32768, 1000000);
            end else begin
                require_fallback(2000000);
            end
        end
        if (supported_count != 2)
            $fatal(1, "expected two supported control combinations, got %0d",
                supported_count);

        // The new full-word inputs must not narrow r208's pre-existing normal
        // mixer contract.  They are title pins only for the capture proxy.
        set_supported_controls();
        for (code = 0; code < 65536; code = code + 1) begin
            soundcnt_value = code[15:0];
            soundcap_value = ~code[15:0];
            #1;
            require_supported_outputs(
                16'sd32752, -16'sd32768, 2500000 + code);
        end

        // Conversely, every bit of both full title-specific register shadows
        // is exhaustive for the proxy.  Exactly b97f/8080 may pass; all volume,
        // reserved-neighbor, and non-start capture-bit variations fail closed.
        set_nsmb_capture_proxy_controls();
        for (code = 0; code < 65536; code = code + 1) begin
            soundcnt_value = code[15:0];
            #1;
            if (code == 32'h0000b97f)
                require_supported_outputs(
                    16'sd32752, -16'sd32768, 2600000 + code);
            else
                require_fallback(2600000 + code);
        end
        soundcnt_value = 16'hb97f;
        for (code = 0; code < 65536; code = code + 1) begin
            soundcap_value = code[15:0];
            #1;
            if (code == 32'h00008080)
                require_supported_outputs(
                    16'sd32752, -16'sd32768, 2700000 + code);
            else
                require_fallback(2700000 + code);
        end

        set_supported_controls();
        controls_settled = 1'b0;
        #1;
        require_fallback(2800000);
        set_nsmb_capture_proxy_controls();
        controls_settled = 1'b0;
        #1;
        require_fallback(2800001);

`ifndef VERILATOR
        // Four-state simulation must fail closed rather than propagating an
        // unknown into an apparent FPGA-audio ownership claim.
        set_supported_controls();
        left_output_source = 2'bx;
        #1;
        require_fallback(3000001);
        set_supported_controls();
        master_enable = 1'bx;
        #1;
        require_fallback(3000002);
        set_supported_controls();
        sound_bias[0] = 1'bx;
        #1;
        require_fallback(3000003);
        set_supported_controls();
        capture_0_active = 1'bx;
        #1;
        require_fallback(3000004);
        set_supported_controls();
        exclude_channel_3_from_mixer = 1'bx;
        #1;
        require_fallback(3000005);
        set_supported_controls();
        controls_settled = 1'bx;
        #1;
        require_fallback(3000006);
        set_nsmb_capture_proxy_controls();
        soundcnt_value[0] = 1'bx;
        #1;
        require_fallback(3000007);
        set_nsmb_capture_proxy_controls();
        soundcap_value[0] = 1'bx;
        #1;
        require_fallback(3000008);
`endif

        $display(
            "PASS: both supported tuples exhaust all 65536 signed inputs per channel and saturate after widened mixer x16 without wrap");
        $display(
            "PASS: all 524288 exposed routing/master/bias/capture/exclusion combinations fail closed except normal mixing and the narrow NSMB capture proxy");
        $display(
            "PASS: normal mixing remains full-shadow agnostic while all 65536 SOUNDCNT and SOUNDCAP values pin the proxy to b97f/8080 only");
        $display(
            "PASS: unsupported configurations assert fallback, clear valid, and drive no candidate audio");
        $finish;
    end

endmodule

`default_nettype wire
