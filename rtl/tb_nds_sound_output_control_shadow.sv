`timescale 1ns/1ps
`default_nettype none

module tb_nds_sound_output_control_shadow;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic released_write_valid = 0;
    logic released_write_ready;
    logic released_write_cpu_arm9 = 0;
    logic released_write_read_not_write = 0;
    logic [1:0] released_write_access = 0;
    logic [31:0] released_write_address = 0;
    logic [31:0] released_write_data = 0;
    logic source_capture_overflow = 0;
    logic source_sequence_exhausted = 0;
    logic source_protocol_error = 0;

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
    logic controls_valid;
    logic failclosed;
    logic protocol_error;

    logic signed [15:0] raw_audio_left = 16'sd100;
    logic signed [15:0] raw_audio_right = -16'sd100;
    logic signed [15:0] fpga_audio_left;
    logic signed [15:0] fpga_audio_right;
    logic fpga_audio_supported;
    logic fpga_audio_valid;
    logic fallback_required;

    logic [15:0] ref_soundcnt;
    logic [9:0] ref_soundbias;
    logic [15:0] ref_soundcap;
    logic expected_supported;
    logic [31:0] prng;
    integer target_index;
    integer lane;
    integer value;
    integer bit_index;
    integer random_index;
    integer case_counter;
    logic [31:0] target_base;
    logic [31:0] pattern;

    nds_sound_output_control_shadow dut (
        .clk,
        .reset,
        .released_write_valid,
        .released_write_ready,
        .released_write_cpu_arm9,
        .released_write_read_not_write,
        .released_write_access,
        .released_write_address,
        .released_write_data,
        .source_capture_overflow,
        .source_sequence_exhausted,
        .source_protocol_error,
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
        .controls_valid,
        .failclosed,
        .protocol_error
    );

    nds_sound_output_adapter adapter (
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
        .controls_settled(1'b1),
        .fpga_audio_left,
        .fpga_audio_right,
        .fpga_audio_supported,
        .fpga_audio_valid,
        .fallback_required
    );

    function automatic logic [31:0] selected_base(input integer index);
        case (index)
            0: selected_base = 32'h04000500;
            1: selected_base = 32'h04000504;
            default: selected_base = 32'h04000508;
        endcase
    endfunction

    task automatic reset_reference;
        begin
            ref_soundcnt = 16'h0000;
            ref_soundbias = 10'h200;
            ref_soundcap = 16'h0000;
        end
    endtask

    // Independent byte-enable reference for the reconstructed Robert wrapper.
    task automatic apply_reference_write(
        input logic [31:0] address,
        input logic [1:0] access,
        input logic [31:0] data
    );
        logic [31:0] shifted;
        logic [3:0] enables;
        logic [31:0] base;
        begin
            shifted = 32'd0;
            enables = 4'b0000;
            base = {address[31:2], 2'b00};
            case (access)
                2'b00: begin
                    case (address[1:0])
                        2'b00: begin
                            shifted[7:0] = data[7:0];
                            enables = 4'b0001;
                        end
                        2'b01: begin
                            shifted[15:8] = data[7:0];
                            enables = 4'b0010;
                        end
                        2'b10: begin
                            shifted[23:16] = data[7:0];
                            enables = 4'b0100;
                        end
                        default: begin
                            shifted[31:24] = data[7:0];
                            enables = 4'b1000;
                        end
                    endcase
                end
                2'b01: begin
                    if (address[1] == 1'b0) begin
                        shifted[15:0] = data[15:0];
                        enables = 4'b0011;
                    end else begin
                        shifted[31:16] = data[15:0];
                        enables = 4'b1100;
                    end
                end
                default: begin
                    shifted = data;
                    enables = 4'b1111;
                end
            endcase

            case (base)
                32'h04000500: begin
                    if (enables[0])
                        ref_soundcnt[7:0] = shifted[7:0];
                    if (enables[1])
                        ref_soundcnt[15:8] = shifted[15:8];
                end
                32'h04000504: begin
                    if (enables[0])
                        ref_soundbias[7:0] = shifted[7:0];
                    if (enables[1])
                        ref_soundbias[9:8] = shifted[9:8];
                end
                32'h04000508: begin
                    if (enables[0])
                        ref_soundcap[7:0] = shifted[7:0];
                    if (enables[1])
                        ref_soundcap[15:8] = shifted[15:8];
                end
                default: begin
                end
            endcase
        end
    endtask

    task automatic check_healthy(input integer case_id);
        begin
            expected_supported =
                ref_soundcnt[15] == 1'b1 &&
                ref_soundbias == 10'h200 &&
                ((ref_soundcnt[9:8] == 2'b00 &&
                  ref_soundcnt[11:10] == 2'b00 &&
                  ref_soundcnt[12] == 1'b0 &&
                  ref_soundcnt[13] == 1'b0 &&
                  ref_soundcap[7] == 1'b0 &&
                  ref_soundcap[15] == 1'b0) ||
                 (ref_soundcnt[9:8] == 2'b01 &&
                  ref_soundcnt[11:10] == 2'b10 &&
                 ref_soundcnt[12] == 1'b1 &&
                  ref_soundcnt[13] == 1'b1 &&
                  ref_soundcap[7] == 1'b1 &&
                  ref_soundcap[15] == 1'b1 &&
                  ref_soundcnt == 16'hb97f &&
                  ref_soundcap == 16'h8080));

            if (!released_write_ready || !controls_valid || failclosed ||
                protocol_error ||
                master_enable !== ref_soundcnt[15] ||
                left_output_source !== ref_soundcnt[9:8] ||
                right_output_source !== ref_soundcnt[11:10] ||
                exclude_channel_1_from_mixer !== ref_soundcnt[12] ||
                exclude_channel_3_from_mixer !== ref_soundcnt[13] ||
                sound_bias !== ref_soundbias ||
                capture_0_active !== ref_soundcap[7] ||
                capture_1_active !== ref_soundcap[15] ||
                soundcnt_value !== ref_soundcnt ||
                soundcap_value !== ref_soundcap ||
                dut.soundcnt_storage !== ref_soundcnt ||
                dut.soundbias_storage !== ref_soundbias ||
                dut.soundcap_storage !== ref_soundcap)
                $fatal(1,
                    "healthy shadow mismatch case=%0d cnt=%h/%h bias=%h/%h cap=%h/%h valid=%b fail=%b error=%b",
                    case_id, dut.soundcnt_storage, ref_soundcnt,
                    dut.soundbias_storage, ref_soundbias,
                    dut.soundcap_storage, ref_soundcap,
                    controls_valid, failclosed, protocol_error);

            if (fpga_audio_supported !== expected_supported ||
                fpga_audio_valid !== expected_supported ||
                fallback_required === expected_supported)
                $fatal(1,
                    "output-adapter predicate mismatch case=%0d expected=%b got=%b/%b/%b controls=%h/%h/%h",
                    case_id, expected_supported, fpga_audio_supported,
                    fpga_audio_valid, fallback_required,
                    ref_soundcnt, ref_soundbias, ref_soundcap);

            if (expected_supported) begin
                if (fpga_audio_left !== 16'sd1600 ||
                    fpga_audio_right !== -16'sd1600)
                    $fatal(1,
                        "supported adapter scaling mismatch case=%0d", case_id);
            end else if (fpga_audio_left !== 16'sd0 ||
                         fpga_audio_right !== 16'sd0) begin
                $fatal(1,
                    "unsupported adapter emitted audio case=%0d", case_id);
            end
        end
    endtask

    task automatic check_failed(input integer case_id);
        begin
            if (!released_write_ready || controls_valid || !failclosed ||
                !protocol_error || master_enable !== 1'b0 ||
                left_output_source !== 2'b11 ||
                right_output_source !== 2'b11 ||
                exclude_channel_1_from_mixer !== 1'b1 ||
                exclude_channel_3_from_mixer !== 1'b1 ||
                sound_bias !== 10'h000 ||
                capture_0_active !== 1'b1 ||
                capture_1_active !== 1'b1 ||
                soundcnt_value !== 16'hffff ||
                soundcap_value !== 16'hffff ||
                fpga_audio_supported || fpga_audio_valid ||
                !fallback_required ||
                fpga_audio_left !== 16'sd0 ||
                fpga_audio_right !== 16'sd0)
                $fatal(1,
                    "failclosed mismatch case=%0d ready=%b valid=%b fail=%b error=%b controls=%b/%b/%b/%b/%b/%h/%b/%b adapter=%b/%b/%b",
                    case_id, released_write_ready, controls_valid,
                    failclosed, protocol_error, master_enable,
                    left_output_source, right_output_source,
                    exclude_channel_1_from_mixer,
                    exclude_channel_3_from_mixer, sound_bias,
                    capture_0_active, capture_1_active,
                    fpga_audio_supported, fpga_audio_valid,
                    fallback_required);
        end
    endtask

    task automatic reset_shadow;
        begin
            @(negedge clk);
            reset = 1;
            released_write_valid = 0;
            released_write_cpu_arm9 = 0;
            released_write_read_not_write = 0;
            released_write_access = 0;
            released_write_address = 0;
            released_write_data = 0;
            source_capture_overflow = 0;
            source_sequence_exhausted = 0;
            source_protocol_error = 0;
            reset_reference();
            repeat (2) @(posedge clk);
            #1;
            if (released_write_ready || controls_valid || !failclosed ||
                protocol_error || master_enable !== 1'b0 ||
                left_output_source !== 2'b00 ||
                right_output_source !== 2'b00 ||
                exclude_channel_1_from_mixer !== 1'b0 ||
                exclude_channel_3_from_mixer !== 1'b0 ||
                sound_bias !== 10'h200 ||
                capture_0_active !== 1'b0 ||
                capture_1_active !== 1'b0 ||
                soundcnt_value !== 16'h0000 ||
                soundcap_value !== 16'h0000 ||
                fpga_audio_supported || fpga_audio_valid ||
                !fallback_required)
                $fatal(1, "reset/default contract mismatch");
            @(negedge clk);
            reset = 0;
            #1;
            check_healthy(-1);
        end
    endtask

    task automatic write_and_check(
        input logic [31:0] address,
        input logic [1:0] access,
        input logic [31:0] data,
        input integer case_id
    );
        begin
            @(negedge clk);
            released_write_cpu_arm9 = 0;
            released_write_read_not_write = 0;
            released_write_address = address;
            released_write_access = access;
            released_write_data = data;
            released_write_valid = 1;
            apply_reference_write(address, access, data);
            @(posedge clk);
            #1;
            check_healthy(case_id);
            @(negedge clk);
            released_write_valid = 0;
        end
    endtask

    task automatic invalid_write(
        input logic cpu_arm9,
        input logic read_not_write,
        input logic [31:0] address,
        input logic [1:0] access,
        input logic [31:0] data,
        input integer case_id
    );
        begin
            @(negedge clk);
            released_write_cpu_arm9 = cpu_arm9;
            released_write_read_not_write = read_not_write;
            released_write_address = address;
            released_write_access = access;
            released_write_data = data;
            released_write_valid = 1;
            @(posedge clk);
            #1;
            check_failed(case_id);
            @(negedge clk);
            released_write_valid = 0;
        end
    endtask

    initial begin
        repeat (1500000) @(posedge clk);
        $fatal(1, "sound output-control shadow timeout");
    end

    initial begin
        reset_reference();
        repeat (2) @(posedge clk);
        reset_shadow();
        case_counter = 0;

        // Exhaust every byte value in all four aligned lanes of all three
        // observed words.
        for (target_index = 0; target_index < 3;
             target_index = target_index + 1) begin
            target_base = selected_base(target_index);
            for (lane = 0; lane < 4; lane = lane + 1)
            for (value = 0; value < 256; value = value + 1) begin
                case_counter = case_counter + 1;
                write_and_check(
                    target_base + lane, 2'b00, value[7:0], case_counter);
            end
        end

        // Exhaust all 16-bit values in both legal halfword lanes. Upper-lane
        // writes are valid retained-state no-ops for these low-half registers.
        for (target_index = 0; target_index < 3;
             target_index = target_index + 1) begin
            target_base = selected_base(target_index);
            for (lane = 0; lane < 2; lane = lane + 1)
            for (value = 0; value < 65536; value = value + 1) begin
                case_counter = case_counter + 1;
                write_and_check(
                    target_base + (lane * 2), 2'b01,
                    value[15:0], case_counter);
            end
        end

        // The one legal word lane gets walking-one, walking-zero, boundary,
        // and deterministic pseudorandom data on each target.
        for (target_index = 0; target_index < 3;
             target_index = target_index + 1) begin
            target_base = selected_base(target_index);
            write_and_check(target_base, 2'b10, 32'h00000000,
                            case_counter + 1);
            case_counter = case_counter + 1;
            write_and_check(target_base, 2'b10, 32'hffffffff,
                            case_counter + 1);
            case_counter = case_counter + 1;
            write_and_check(target_base, 2'b10, 32'ha5a55a5a,
                            case_counter + 1);
            case_counter = case_counter + 1;
            for (bit_index = 0; bit_index < 32;
                 bit_index = bit_index + 1) begin
                pattern = 32'd1 << bit_index;
                case_counter = case_counter + 1;
                write_and_check(target_base, 2'b10, pattern, case_counter);
                case_counter = case_counter + 1;
                write_and_check(target_base, 2'b10, ~pattern, case_counter);
            end
            prng = 32'h1badf00d ^ target_index;
            for (random_index = 0; random_index < 4096;
                 random_index = random_index + 1) begin
                prng = {prng[30:0],
                        prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
                case_counter = case_counter + 1;
                write_and_check(target_base, 2'b10, prng, case_counter);
            end
        end

        // Key boot sequence: right-justified byte writes reconstruct the same
        // supported controls used by the raw PCM reference.
        reset_shadow();
        write_and_check(32'h04000504, 2'b01, 32'h00000200, 5000001);
        write_and_check(32'h04000500, 2'b00, 32'h0000007f, 5000002);
        write_and_check(32'h04000501, 2'b00, 32'h00000080, 5000003);
        if (!fpga_audio_supported)
            $fatal(1, "boot sequence did not enable supported FPGA audio");

        // Exact native NSMB write transition: the direct-route SOUNDCNT value
        // alone must fall back.  Only after both capture-start bits are present
        // may the adapter use Robert's live-normal-mixer capture proxy.  The
        // adapter cannot see SOUNDCNT volume or non-start SOUNDCAP bits, so
        // this proves the exact write sequence but does not claim full capture.
        write_and_check(
            32'h04000500, 2'b01, 32'h0000b97f, 5000004);
        if (fpga_audio_supported)
            $fatal(1,
                "SOUNDCNT 0xb97f without dual capture claimed FPGA audio");
        write_and_check(
            32'h04000508, 2'b01, 32'h00008080, 5000005);
        if (!fpga_audio_supported ||
            fpga_audio_left !== 16'sd1600 ||
            fpga_audio_right !== -16'sd1600)
            $fatal(1,
                "exact 0x807f -> 0xb97f + capture 0x8080 transition did not select the normal-scale capture proxy");

        // The proxy is pinned to the complete released-write shadows, not only
        // their decoded route/start subset.  Every SOUNDCNT bit—including all
        // master-volume and reserved neighbors—and every SOUNDCAP bit must
        // fail closed when it differs from the native title value.
        for (bit_index = 0; bit_index < 16;
             bit_index = bit_index + 1) begin
            pattern = 32'h0000b97f ^ (32'd1 << bit_index);
            write_and_check(
                32'h04000500, 2'b01, pattern,
                5100000 + (bit_index * 2));
            if (fpga_audio_supported)
                $fatal(1,
                    "SOUNDCNT bit-neighbor %0d escaped exact proxy pin",
                    bit_index);
            write_and_check(
                32'h04000500, 2'b01, 32'h0000b97f,
                5100001 + (bit_index * 2));
            if (!fpga_audio_supported)
                $fatal(1,
                    "exact SOUNDCNT did not recover proxy at bit %0d",
                    bit_index);
        end
        for (bit_index = 0; bit_index < 16;
             bit_index = bit_index + 1) begin
            pattern = 32'h00008080 ^ (32'd1 << bit_index);
            write_and_check(
                32'h04000508, 2'b01, pattern,
                5200000 + (bit_index * 2));
            if (fpga_audio_supported)
                $fatal(1,
                    "SOUNDCAP bit-neighbor %0d escaped exact proxy pin",
                    bit_index);
            write_and_check(
                32'h04000508, 2'b01, 32'h00008080,
                5200001 + (bit_index * 2));
            if (!fpga_audio_supported)
                $fatal(1,
                    "exact SOUNDCAP did not recover proxy at bit %0d",
                    bit_index);
        end

        // Every adjacent capture state remains unsupported, and returning to
        // the original normal-mixer tuple recovers the pre-existing contract.
        write_and_check(
            32'h04000508, 2'b01, 32'h00008000, 5000006);
        if (fpga_audio_supported)
            $fatal(1, "capture-1-only neighbor did not force fallback");
        write_and_check(
            32'h04000508, 2'b01, 32'h00000080, 5000007);
        if (fpga_audio_supported)
            $fatal(1, "capture-0-only neighbor did not force fallback");
        write_and_check(
            32'h04000508, 2'b01, 32'h00008080, 5000008);
        if (!fpga_audio_supported)
            $fatal(1, "exact NSMB tuple did not recover after neighbors");
        write_and_check(
            32'h04000500, 2'b01, 32'h0000807f, 5000009);
        if (fpga_audio_supported)
            $fatal(1, "normal route with captures active did not fall back");
        write_and_check(
            32'h04000508, 2'b01, 32'h00000000, 5000010);
        if (!fpga_audio_supported)
            $fatal(1, "normal 0x807f/0x0000 tuple did not recover");

        // Valid unrelated writes and upper lanes retain every observed field.
        write_and_check(32'h04000400, 2'b10, 32'hffffffff, 5000011);
        write_and_check(32'h04000502, 2'b01, 32'h0000ffff, 5000012);
        write_and_check(32'h04000506, 2'b01, 32'h00000000, 5000013);
        write_and_check(32'h0400050a, 2'b01, 32'h0000ffff, 5000014);
        write_and_check(32'h0400051f, 2'b00, 32'h000000a5, 5000015);
        if (!fpga_audio_supported)
            $fatal(1, "unrelated/upper writes corrupted retained controls");

        // Capture, direct-route, and exclusion settings independently force
        // fallback and recover when their exact byte lane is cleared.
        write_and_check(32'h04000508, 2'b00, 32'h00000080, 5000020);
        if (fpga_audio_supported)
            $fatal(1, "capture 0 did not force fallback");
        write_and_check(32'h04000508, 2'b00, 32'h00000000, 5000021);
        write_and_check(32'h04000509, 2'b00, 32'h00000080, 5000022);
        if (fpga_audio_supported)
            $fatal(1, "capture 1 did not force fallback");
        write_and_check(32'h04000509, 2'b00, 32'h00000000, 5000023);
        write_and_check(32'h04000501, 2'b00, 32'h00000081, 5000024);
        if (fpga_audio_supported)
            $fatal(1, "left direct route did not force fallback");
        write_and_check(32'h04000501, 2'b00, 32'h00000084, 5000025);
        if (fpga_audio_supported)
            $fatal(1, "right direct route did not force fallback");
        write_and_check(32'h04000501, 2'b00, 32'h00000090, 5000026);
        if (fpga_audio_supported)
            $fatal(1, "channel-1 exclusion did not force fallback");
        write_and_check(32'h04000501, 2'b00, 32'h000000a0, 5000027);
        if (fpga_audio_supported)
            $fatal(1, "channel-3 exclusion did not force fallback");
        write_and_check(32'h04000501, 2'b00, 32'h00000080, 5000028);
        if (!fpga_audio_supported)
            $fatal(1, "normal route did not recover supported audio");

        // Known malformed/released events poison the shadow without
        // backpressuring its upstream.
        reset_shadow();
        invalid_write(1, 0, 32'h04000500, 2'b10,
                      32'h0000807f, 6000001); // ARM9
        reset_shadow();
        invalid_write(0, 1, 32'h04000500, 2'b10,
                      32'h0000807f, 6000002); // read
        reset_shadow();
        invalid_write(0, 0, 32'h04000500, 2'b11,
                      32'h0000807f, 6000003); // invalid access
        reset_shadow();
        invalid_write(0, 0, 32'h04000501, 2'b01,
                      32'h0000807f, 6000004); // misaligned half
        reset_shadow();
        invalid_write(0, 0, 32'h04000502, 2'b10,
                      32'h0000807f, 6000005); // misaligned word
        reset_shadow();
        invalid_write(0, 0, 32'h040003ff, 2'b00,
                      32'h0000007f, 6000006); // below range
        reset_shadow();
        invalid_write(0, 0, 32'h04000520, 2'b10,
                      32'h0000807f, 6000007); // above range

        // Every upstream fatal input independently invalidates the controls.
        reset_shadow();
        @(negedge clk);
        source_capture_overflow = 1;
        @(posedge clk);
        #1;
        check_failed(6000010);
        reset_shadow();
        @(negedge clk);
        source_sequence_exhausted = 1;
        @(posedge clk);
        #1;
        check_failed(6000011);
        reset_shadow();
        @(negedge clk);
        source_protocol_error = 1;
        @(posedge clk);
        #1;
        check_failed(6000012);

`ifndef VERILATOR
        // Unused high data bits are intentionally irrelevant for narrow
        // writes, exactly as in the wrapper. Relevant unknowns fail closed.
        reset_shadow();
        @(negedge clk);
        released_write_address = 32'h04000501;
        released_write_access = 2'b00;
        released_write_data = {24'hxxxxxx, 8'h80};
        released_write_valid = 1;
        apply_reference_write(
            32'h04000501, 2'b00, {24'h000000, 8'h80});
        @(posedge clk);
        #1;
        check_healthy(7000000);
        @(negedge clk);
        released_write_valid = 0;

        reset_shadow();
        @(negedge clk);
        released_write_valid = 1'bx;
        @(posedge clk);
        #1;
        check_failed(7000001);
        reset_shadow();
        invalid_write(1'bx, 0, 32'h04000500, 2'b10,
                      32'h0000807f, 7000002);
        reset_shadow();
        invalid_write(0, 1'bx, 32'h04000500, 2'b10,
                      32'h0000807f, 7000003);
        reset_shadow();
        invalid_write(0, 0, 32'h04000500, 2'bxx,
                      32'h0000807f, 7000004);
        reset_shadow();
        invalid_write(0, 0, 32'h040005x0, 2'b00,
                      32'h0000007f, 7000005);
        reset_shadow();
        invalid_write(0, 0, 32'h04000500, 2'b00,
                      32'h000000xx, 7000006);
        reset_shadow();
        @(negedge clk);
        source_capture_overflow = 1'bx;
        @(posedge clk);
        #1;
        check_failed(7000007);
`endif

        $display(
            "PASS: sound output-control shadow exhausts all byte values and all halfword values in every legal lane");
        $display(
            "PASS: exact 0x807f -> 0xb97f + capture 0x8080 writes select Robert's approximate normal-scale capture proxy while adjacent exposed modes fall back");
        $display(
            "PASS: every one-bit SOUNDCNT/SOUNDCAP neighbor fails closed, including volume, reserved, and non-start capture fields");
        $display(
            "PASS: word walking/random writes, retained state, and independent capture/route/exclusion sequences match the Robert wrapper contract");
        $display(
            "PASS: ARM9/read/invalid/misaligned/out-of-range/unknown/upstream-overflow events fail closed without backpressure");
        $display(
            "PASS: output adapter claims support only for valid normal routing or the narrow exposed NSMB capture-proxy tuple, bias 0x200, and master enabled");
        $finish;
    end
endmodule

`default_nettype wire
