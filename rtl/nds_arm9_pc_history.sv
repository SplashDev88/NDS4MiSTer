// Non-intrusive ARM9 retirement recorder. It observes the dedicated execute
// PC and the CPU's existing completed-instruction pulse outside gba_cpu.
// Sampling only on retire is essential: the fetch address can visit a
// fall-through or branch target speculatively and is not an architectural
// step trace. Only main-RAM PCs are retained, matching the filtered melonDS
// reference trace used to find the first divergence.
module nds_arm9_pc_history #(
    // Zero preserves the original pre-trigger ring. One records the trigger
    // followed by DEPTH-1 retired main-RAM instructions, which is the useful
    // breakpoint/step mode for comparing forward against a native reference.
    parameter bit CAPTURE_AFTER_TRIGGER = 0,
    // Diagnostic mode for a pre-trigger trace that crosses ARM9 main RAM,
    // mirrored ITCM, low ITCM, and high BIOS. The 22 stored bits become a two-bit
    // region tag plus the low 20 PC bits:
    //   00 = 0x02000000..0x020fffff main RAM boot/code window
    //   01 = 0x01f00000..0x01ffffff mirrored ITCM
    //   10 = 0xfff00000..0xffffffff high BIOS
    //   11 = 0x00000000..0x00007fff low ITCM
    // This keeps a full 1,024-entry history inside the existing 32-bit
    // phase/PC publication word.
    parameter bit NORMALIZE_ARM9_REGIONS = 0,
    // Deep pre-trigger mode uses the architectural halfword alignment of
    // ARM/Thumb PCs to fit four execution regions into 19 bits:
    //   0xxxx = main RAM 0x02000000..0x0207ffff, PC[18:1]
    //   1000x = mirrored ITCM 0x01ff0000..0x01ffffff, PC[15:1]
    //   1001x = high BIOS 0xffff0000..0xffff7fff, PC[15:1]
    //   1010x = low ITCM 0x00000000..0x00007fff, PC[15:1]
    // With PHASE_BITS=13 and PC_BITS=19 this retains 8,192 retirements
    // without losing any executable address bit used by the current boot.
    parameter bit COMPACT_ALIGNED_ARM9_REGIONS = 0,
    // The published word packs phase above the retained PC bits. The defaults
    // preserve the original 1,024 x 22-bit trace format. r169 uses 13/19 for
    // an 8,192-entry trace covering 0x02000000 through 0x0207ffff.
    parameter int PHASE_BITS = 10,
    parameter int PC_BITS = 22
) (
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] encoded_pc,
    input  logic [31:0] trigger_pc,
    input  logic        retire,
    input  logic        advance,
    output logic [31:0] telemetry_pc,
    output logic        frozen
);
    localparam logic [31:0] ARM9_TAG = 32'h40000000;
    localparam int DEPTH = 1 << PHASE_BITS;
    (* ramstyle = "M10K" *) logic [PC_BITS-1:0] history [0:DEPTH-1];
    logic [PHASE_BITS-1:0] write_index, trigger_index, read_index;
    logic [PHASE_BITS:0] captured_count;
    logic [PHASE_BITS-1:0] phase, pending_phase;
    logic [1:0] read_wait;
    logic [PC_BITS-1:0] ram_q, output_pc;
    logic triggered;

    wire [31:0] decoded_pc = encoded_pc ^ ARM9_TAG;
    wire main_ram_pc =
        (decoded_pc >> PC_BITS) == (32'h02000000 >> PC_BITS);
    wire normalized_main_ram =
        decoded_pc >= 32'h02000000 && decoded_pc < 32'h02100000;
    wire normalized_itcm =
        decoded_pc >= 32'h01f00000 && decoded_pc < 32'h02000000;
    wire normalized_high_bios =
        decoded_pc >= 32'hfff00000;
    wire normalized_low_itcm =
        decoded_pc < 32'h00008000;
    wire normalized_region_pc =
        normalized_main_ram || normalized_itcm || normalized_high_bios ||
        normalized_low_itcm;
    wire compact_main_ram =
        decoded_pc >= 32'h02000000 && decoded_pc < 32'h02080000;
    wire compact_itcm =
        decoded_pc >= 32'h01ff0000 && decoded_pc < 32'h02000000;
    wire compact_high_bios =
        decoded_pc >= 32'hffff0000 && decoded_pc < 32'hffff8000;
    wire compact_low_itcm =
        decoded_pc < 32'h00008000;
    wire compact_region_pc =
        !decoded_pc[0] && (compact_main_ram || compact_itcm ||
        compact_high_bios || compact_low_itcm);
    wire [21:0] normalized_pc =
        normalized_main_ram ? {2'b00, decoded_pc[19:0]} :
        normalized_itcm ? {2'b01, decoded_pc[19:0]} :
        normalized_high_bios ? {2'b10, decoded_pc[19:0]} :
        {2'b11, decoded_pc[19:0]};
    wire [18:0] compact_pc =
        compact_main_ram ? {1'b0, decoded_pc[18:1]} :
        compact_itcm ? {4'b1000, decoded_pc[15:1]} :
        compact_high_bios ? {4'b1001, decoded_pc[15:1]} :
        {4'b1010, decoded_pc[15:1]};
    wire [31:0] compact_pc_wide = {13'b0, compact_pc};
    wire [PC_BITS-1:0] stored_pc = COMPACT_ALIGNED_ARM9_REGIONS
        ? compact_pc_wide[PC_BITS-1:0] :
        NORMALIZE_ARM9_REGIONS
            ? normalized_pc[PC_BITS-1:0] : decoded_pc[PC_BITS-1:0];
    wire capture = retire &&
        (COMPACT_ALIGNED_ARM9_REGIONS ? compact_region_pc :
        NORMALIZE_ARM9_REGIONS ? normalized_region_pc : main_ram_pc);
    wire write_enable = !reset && !frozen && capture &&
        (!CAPTURE_AFTER_TRIGGER || triggered || decoded_pc == trigger_pc);

    assign telemetry_pc = frozen
        ? ({phase, output_pc} ^ ARM9_TAG) : encoded_pc;

    // Canonical synchronous simple-dual-port inference form. The control
    // process waits two clocks after changing read_index before consuming q.
    always_ff @(posedge clk) begin
        if (write_enable)
            history[write_index] <= stored_pc;
        ram_q <= history[read_index];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            write_index <= 0;
            trigger_index <= 0;
            read_index <= 0;
            captured_count <= 0;
            phase <= 0;
            pending_phase <= 0;
            read_wait <= 0;
            output_pc <= 0;
            triggered <= 0;
            frozen <= 0;
        end else if (!frozen) begin
            if (capture) begin
                if (!CAPTURE_AFTER_TRIGGER) begin
                    if (decoded_pc == trigger_pc) begin
                        trigger_index <= write_index;
                        phase <= 0;
                        output_pc <= stored_pc;
                        frozen <= 1;
                    end else begin
                        write_index <= write_index + 1'b1;
                    end
                end else if (!triggered && decoded_pc == trigger_pc) begin
                    // The trigger is forward-trace entry zero.
                    triggered <= 1;
                    write_index <= 1;
                    captured_count <= 1;
                end else if (triggered) begin
                    if (&captured_count[PHASE_BITS-1:0]) begin
                        // This edge writes entry DEPTH-1. Phase zero can be
                        // published immediately because it is the trigger.
                        phase <= 0;
                        output_pc <= trigger_pc[PC_BITS-1:0];
                        frozen <= 1;
                    end else begin
                        write_index <= write_index + 1'b1;
                        captured_count <= captured_count + 1'b1;
                    end
                end
            end
        end else if (read_wait == 2) begin
            output_pc <= ram_q;
            phase <= pending_phase;
            read_wait <= 0;
        end else if (read_wait == 1) begin
            read_wait <= 2;
        end else if (advance) begin
            pending_phase <= phase + 1'b1;
            if (CAPTURE_AFTER_TRIGGER)
                read_index <= phase + 1'b1;
            else
                read_index <= trigger_index - (phase + 1'b1);
            read_wait <= 1;
        end
    end
endmodule
