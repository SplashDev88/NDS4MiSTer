module tb_nds_arm9_pc_history;
    logic clk = 0;
    logic reset = 1;
    logic [31:0] encoded_pc = 32'h40000000;
    logic [31:0] trigger_pc = 32'h02005b10;
    logic retire = 0;
    logic advance = 0;
    logic [31:0] telemetry_pc;
    logic frozen;

    nds_arm9_pc_history pre_dut(.*);
    always #5 clk = ~clk;

    task automatic retire_pc(input logic [31:0] pc);
        begin
            @(negedge clk);
            encoded_pc = pc ^ 32'h40000000;
            retire = 1;
            @(posedge clk);
            #1;
            retire = 0;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // Fill the complete pre-trigger ring. Repeated PCs are distinct
        // retired instructions and therefore must consume trace entries.
        for (int index = 0; index < 1024; index++) begin
            retire_pc(32'h02004b14 + index * 4);
        end
        repeat (2) @(posedge clk);
        if (!frozen) $fatal(1, "history did not freeze at trigger");

        for (int wanted = 0; wanted < 1024; wanted++) begin
            logic [31:0] decoded;
            logic [31:0] expected;
            decoded = telemetry_pc ^ 32'h40000000;
            expected = 32'h02005b10 - wanted * 4;
            if (decoded[31:22] !== wanted[9:0])
                $fatal(1, "wrong phase wanted=%0d got=%0d",
                       wanted, decoded[31:22]);
            if (decoded[21:0] !== expected[21:0])
                $fatal(1, "wrong PC at phase %0d got=%08x expected=%08x",
                       wanted, decoded, expected);
            @(negedge clk);
            advance = 1;
            @(negedge clk);
            advance = 0;
            repeat (4) @(posedge clk);
        end
        $display("PASS: external ARM9 1024-PC history freezes and publishes");
        $finish;
    end
endmodule

module tb_nds_arm9_cross_region_pre_trigger_trace;
    logic clk = 0;
    logic reset = 1;
    logic [31:0] encoded_pc = 32'h40000000;
    logic [31:0] trigger_pc = 32'h01ffd280;
    logic retire = 0;
    logic advance = 0;
    logic [31:0] telemetry_pc;
    logic frozen;
    logic [31:0] pc_sequence [0:7];

    nds_arm9_pc_history #(
        .CAPTURE_AFTER_TRIGGER(0),
        .NORMALIZE_ARM9_REGIONS(1)
    ) dut(.*);
    always #5 clk = ~clk;

    task automatic retire_pc(input logic [31:0] pc);
        begin
            @(negedge clk);
            encoded_pc = pc ^ 32'h40000000;
            retire = 1;
            @(posedge clk);
            #1;
            retire = 0;
            @(posedge clk);
        end
    endtask

    function automatic logic [21:0] normalized(input logic [31:0] pc);
        if (pc >= 32'h02000000 && pc < 32'h02100000)
            normalized = {2'b00, pc[19:0]};
        else if (pc >= 32'h01f00000 && pc < 32'h02000000)
            normalized = {2'b01, pc[19:0]};
        else if (pc >= 32'hfff00000)
            normalized = {2'b10, pc[19:0]};
        else
            normalized = {2'b11, pc[19:0]};
    endfunction

    initial begin
        pc_sequence[0] = 32'h02068ab4;
        pc_sequence[1] = 32'h02068ab8;
        pc_sequence[2] = 32'hffff06e8;
        pc_sequence[3] = 32'hffff06ec;
        pc_sequence[4] = 32'h01ff8074;
        pc_sequence[5] = 32'h01ff80bc;
        pc_sequence[6] = 32'h01ffd27c;
        pc_sequence[7] = trigger_pc;

        repeat (3) @(posedge clk);
        reset = 0;

        // An unrelated region must not consume a history slot.
        retire_pc(32'h0380fafc);
        for (int index = 0; index < 8; index++)
            retire_pc(pc_sequence[index]);
        repeat (2) @(posedge clk);
        if (!frozen)
            $fatal(1, "cross-region history did not freeze at ITCM trigger");

        for (int wanted = 0; wanted < 8; wanted++) begin
            logic [31:0] decoded;
            logic [21:0] expected;
            decoded = telemetry_pc ^ 32'h40000000;
            expected = normalized(pc_sequence[7-wanted]);
            if (decoded[31:22] !== wanted[9:0])
                $fatal(1, "cross-region wrong phase wanted=%0d got=%0d",
                       wanted, decoded[31:22]);
            if (decoded[21:0] !== expected)
                $fatal(1,
                       "cross-region wrong code phase=%0d got=%06x expected=%06x",
                       wanted, decoded[21:0], expected);
            @(negedge clk);
            advance = 1;
            @(negedge clk);
            advance = 0;
            repeat (4) @(posedge clk);
        end
        $display("PASS: ARM9 cross-region pre-trigger history publishes");
        $finish;
    end
endmodule

module tb_nds_arm9_low_itcm_pre_trigger_trace;
    logic clk = 0;
    logic reset = 1;
    logic [31:0] encoded_pc = 32'h40000000;
    logic [31:0] trigger_pc = 32'h00000010;
    logic retire = 0;
    logic advance = 0;
    logic [31:0] telemetry_pc;
    logic frozen;
    logic [31:0] pc_sequence [0:6];

    nds_arm9_pc_history #(
        .CAPTURE_AFTER_TRIGGER(0),
        .NORMALIZE_ARM9_REGIONS(1)
    ) dut(.*);
    always #5 clk = ~clk;

    task automatic retire_pc(input logic [31:0] pc);
        begin
            @(negedge clk);
            encoded_pc = pc ^ 32'h40000000;
            retire = 1;
            @(posedge clk);
            #1;
            retire = 0;
            @(posedge clk);
        end
    endtask

    function automatic logic [21:0] normalized(input logic [31:0] pc);
        if (pc >= 32'h02000000 && pc < 32'h02100000)
            normalized = {2'b00, pc[19:0]};
        else if (pc >= 32'h01f00000 && pc < 32'h02000000)
            normalized = {2'b01, pc[19:0]};
        else if (pc >= 32'hfff00000)
            normalized = {2'b10, pc[19:0]};
        else
            normalized = {2'b11, pc[19:0]};
    endfunction

    initial begin
        pc_sequence[0] = 32'h02069514;
        pc_sequence[1] = 32'hffff06f4;
        pc_sequence[2] = 32'h01ffd698;
        pc_sequence[3] = 32'h00000000;
        pc_sequence[4] = 32'h00000004;
        pc_sequence[5] = 32'h0000000c;
        pc_sequence[6] = trigger_pc;

        repeat (3) @(posedge clk);
        reset = 0;

        for (int index = 0; index < 7; index++)
            retire_pc(pc_sequence[index]);
        repeat (2) @(posedge clk);
        if (!frozen)
            $fatal(1, "history did not freeze at the first low-ITCM trigger");

        for (int wanted = 0; wanted < 7; wanted++) begin
            logic [31:0] decoded;
            logic [21:0] expected;
            decoded = telemetry_pc ^ 32'h40000000;
            expected = normalized(pc_sequence[6-wanted]);
            if (decoded[31:22] !== wanted[9:0])
                $fatal(1, "low-ITCM wrong phase wanted=%0d got=%0d",
                       wanted, decoded[31:22]);
            if (decoded[21:0] !== expected)
                $fatal(1,
                       "low-ITCM wrong code phase=%0d got=%06x expected=%06x",
                       wanted, decoded[21:0], expected);
            @(negedge clk);
            advance = 1;
            @(negedge clk);
            advance = 0;
            repeat (4) @(posedge clk);
        end
        $display("PASS: first low-ITCM entry freezes cross-region prehistory");
        $finish;
    end
endmodule

module tb_nds_arm9_deep_low_itcm_pre_trigger_trace;
    localparam int DEPTH = 8192;
    logic clk = 0;
    logic reset = 1;
    logic [31:0] encoded_pc = 32'h40000000;
    logic [31:0] trigger_pc = 32'h00000010;
    logic retire = 0;
    logic advance = 0;
    logic [31:0] telemetry_pc;
    logic frozen;

    nds_arm9_pc_history #(
        .CAPTURE_AFTER_TRIGGER(0),
        .COMPACT_ALIGNED_ARM9_REGIONS(1),
        .PHASE_BITS(13),
        .PC_BITS(19)
    ) dut(.*);
    always #5 clk = ~clk;

    task automatic retire_pc(input logic [31:0] pc);
        begin
            @(negedge clk);
            encoded_pc = pc ^ 32'h40000000;
            retire = 1;
            @(posedge clk);
            #1;
            retire = 0;
            @(posedge clk);
        end
    endtask

    function automatic logic [31:0] sequence_pc(input int index);
        case (index & 3)
            0: sequence_pc =
                32'h02000000 + ((index * 2) & 32'h0007fffe);
            1: sequence_pc =
                32'h01ff8000 + ((index * 2) & 32'h00007ffe);
            2: sequence_pc =
                32'hffff0000 + ((index * 2) & 32'h00007ffe);
            default: sequence_pc =
                32'h00001000 + ((index * 2) & 32'h00003ffe);
        endcase
    endfunction

    function automatic logic [18:0] compact(input logic [31:0] pc);
        if (pc >= 32'h02000000 && pc < 32'h02080000)
            compact = {1'b0, pc[18:1]};
        else if (pc >= 32'h01ff0000 && pc < 32'h02000000)
            compact = {4'b1000, pc[15:1]};
        else if (pc >= 32'hffff0000 && pc < 32'hffff8000)
            compact = {4'b1001, pc[15:1]};
        else
            compact = {4'b1010, pc[15:1]};
    endfunction

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // These regions are intentionally outside the compact recorder.
        retire_pc(32'h02080000);
        retire_pc(32'hfff00000);
        retire_pc(32'h00008000);
        for (int index = 0; index < DEPTH - 1; index++)
            retire_pc(sequence_pc(index));
        retire_pc(trigger_pc);
        repeat (2) @(posedge clk);
        if (!frozen)
            $fatal(1, "deep low-ITCM history did not freeze");

        for (int wanted = 0; wanted < DEPTH; wanted++) begin
            logic [31:0] decoded;
            logic [31:0] expected_pc;
            logic [18:0] expected_code;
            decoded = telemetry_pc ^ 32'h40000000;
            expected_pc = wanted == 0
                ? trigger_pc : sequence_pc(DEPTH - 1 - wanted);
            expected_code = compact(expected_pc);
            if (decoded[31:19] !== wanted[12:0])
                $fatal(1,
                       "deep low-ITCM wrong phase wanted=%0d got=%0d",
                       wanted, decoded[31:19]);
            if (decoded[18:0] !== expected_code)
                $fatal(1,
                       "deep low-ITCM wrong code phase=%0d got=%05x expected=%05x",
                       wanted, decoded[18:0], expected_code);
            @(negedge clk);
            advance = 1;
            @(negedge clk);
            advance = 0;
            repeat (4) @(posedge clk);
        end
        $display(
            "PASS: 8,192-entry low-ITCM prehistory preserves all ARM9 regions"
        );
        $finish;
    end
endmodule

module tb_nds_arm9_post_trigger_trace;
    logic clk = 0;
    logic reset = 1;
    logic [31:0] encoded_pc = 32'h40000000;
    logic [31:0] trigger_pc = 32'h02001000;
    logic retire = 0;
    logic advance = 0;
    logic [31:0] telemetry_pc;
    logic frozen;

    nds_arm9_pc_history #(
        .CAPTURE_AFTER_TRIGGER(1)
    ) dut(.*);
    always #5 clk = ~clk;

    task automatic retire_pc(input logic [31:0] pc);
        begin
            @(negedge clk);
            encoded_pc = pc ^ 32'h40000000;
            retire = 1;
            @(posedge clk);
            #1;
            retire = 0;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // Pre-trigger traffic must not consume the forward trace.
        for (int index = 0; index < 19; index++)
            retire_pc(32'h02002000 + index * 4);
        retire_pc(32'h02001000);
        for (int index = 1; index < 1024; index++)
            // Deliberately repeat PCs: retirement traces retain loops.
            retire_pc(32'h02001000 + (index % 17) * 4);
        repeat (2) @(posedge clk);
        if (!frozen) $fatal(1, "post-trigger trace did not freeze");

        for (int wanted = 0; wanted < 1024; wanted++) begin
            logic [31:0] decoded;
            logic [31:0] expected;
            decoded = telemetry_pc ^ 32'h40000000;
            expected = wanted == 0
                ? 32'h02001000
                : 32'h02001000 + (wanted % 17) * 4;
            if (decoded[31:22] !== wanted[9:0])
                $fatal(1, "post trace wrong phase wanted=%0d got=%0d",
                       wanted, decoded[31:22]);
            if (decoded[21:0] !== expected[21:0])
                $fatal(1,
                       "post trace wrong PC at phase %0d got=%08x expected=%08x",
                       wanted, decoded, expected);
            @(negedge clk);
            advance = 1;
            @(negedge clk);
            advance = 0;
            repeat (4) @(posedge clk);
        end
        $display("PASS: ARM9 post-trigger trace publishes retired PCs");
        $finish;
    end
endmodule

module tb_nds_arm9_deep_post_trigger_trace;
    localparam int DEPTH = 8192;
    logic clk = 0;
    logic reset = 1;
    logic [31:0] encoded_pc = 32'h40000000;
    logic [31:0] trigger_pc = 32'h020670d0;
    logic retire = 0;
    logic advance = 0;
    logic [31:0] telemetry_pc;
    logic frozen;

    nds_arm9_pc_history #(
        .CAPTURE_AFTER_TRIGGER(1),
        .PHASE_BITS(13),
        .PC_BITS(19)
    ) dut(.*);
    always #5 clk = ~clk;

    task automatic retire_pc(input logic [31:0] pc);
        begin
            @(negedge clk);
            encoded_pc = pc ^ 32'h40000000;
            retire = 1;
            @(posedge clk);
            #1;
            retire = 0;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // Out-of-region and pre-trigger traffic must not consume entries.
        retire_pc(32'h01ff8120);
        for (int index = 0; index < 31; index++)
            retire_pc(32'h02069000 + index * 4);
        retire_pc(trigger_pc);
        for (int index = 1; index < DEPTH; index++)
            retire_pc(32'h020670d0 + (index % 37) * 4);
        repeat (2) @(posedge clk);
        if (!frozen) $fatal(1, "deep post-trigger trace did not freeze");

        for (int wanted = 0; wanted < DEPTH; wanted++) begin
            logic [31:0] decoded;
            logic [31:0] expected;
            decoded = telemetry_pc ^ 32'h40000000;
            expected = wanted == 0
                ? trigger_pc
                : 32'h020670d0 + (wanted % 37) * 4;
            if (decoded[31:19] !== wanted[12:0])
                $fatal(1, "deep trace wrong phase wanted=%0d got=%0d",
                       wanted, decoded[31:19]);
            if (decoded[18:0] !== expected[18:0])
                $fatal(1,
                       "deep trace wrong PC at phase %0d got=%08x expected=%08x",
                       wanted, decoded, expected);
            @(negedge clk);
            advance = 1;
            @(negedge clk);
            advance = 0;
            repeat (4) @(posedge clk);
        end
        $display("PASS: ARM9 8,192-entry post-trigger trace publishes retired PCs");
        $finish;
    end
endmodule
