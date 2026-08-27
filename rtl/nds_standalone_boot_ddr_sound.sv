// Candidate-only composition of the existing standalone boot/CPU/video DDR
// path with an additional FPGA sound sample client.
//
// sound_enable is sampled only while reset is asserted.  Changing it while
// reset is low never changes DDR ownership: the latched path remains active
// and sound_mode_change_ignored records that a reset is required.
//
// The default-off branch is a literal nds_standalone_boot_ddr instance. Its
// client and physical DDR signals are selected directly, preserving the
// production two-client behavior cycle-for-cycle. The active branch uses a
// masked four-client arbiter. Its reverse-credit client is compile-time
// default-off and can select this infrastructure independently of sound.
module nds_standalone_boot_ddr_sound #(
    // This is a response-silence filter, not a substitute for the deployment
    // gate's menu dwell.  Sixty-four clocks are negligible at 60 MHz while
    // avoiding the former four-clock assumption.
    parameter integer SOUND_RESET_QUIET_CYCLES = 64,
    parameter integer SOUND_STICKY_GRANT_LIMIT = 8,
    // Let the raster jump the DDR round robin; see the arbiter.
    parameter bit VIDEO_PRIORITY_GRANT = 0,
    // Simulator-first reverse consumed-credit DDR seam. Zero preserves the
    // literal 4'b0111 sound-path mask and every older named instantiation.
    // One selects the active infrastructure even when sound remains off.
    parameter bit ENABLE_CREDIT_CLIENT = 1'b0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,
    input  logic        sound_enable,
    output logic        sound_mode_active,
    output logic        sound_mode_change_ignored,
    output logic        boot_valid,
    output logic        boot_error,
    output logic [31:0] boot_generation,
    output logic [31:0] arm9_dtcm_irq_vector,
    output logic [31:0] arm9_trace_trigger,
    output logic [31:0] arm9_entry,
    output logic [31:0] arm7_entry,
    output logic [31:0] arm9_current_sp,
    output logic [31:0] arm9_irq_sp,
    output logic [31:0] arm9_saved_sp,
    output logic [31:0] arm7_current_sp,
    output logic [31:0] arm7_irq_sp,
    output logic [31:0] arm7_saved_sp,
    output logic [31:0] initial_cpsr,

    input  logic        cpu_rd,
    input  logic        cpu_we,
    input  logic [7:0]  cpu_burstcnt,
    input  logic [28:0] cpu_addr,
    input  logic [63:0] cpu_din,
    input  logic [7:0]  cpu_be,
    output logic        cpu_busy,
    output logic [63:0] cpu_dout,
    output logic        cpu_dout_ready,
    output logic        cpu_command_accepted,

    input  logic        video_rd,
    input  logic        video_we,
    input  logic [7:0]  video_burstcnt,
    input  logic [28:0] video_addr,
    input  logic [63:0] video_din,
    input  logic [7:0]  video_be,
    output logic        video_busy,
    output logic [63:0] video_dout,
    output logic        video_dout_ready,
    output logic        video_command_accepted,

    input  logic        sound_rd,
    input  logic        sound_we,
    input  logic [7:0]  sound_burstcnt,
    input  logic [28:0] sound_addr,
    input  logic [63:0] sound_din,
    input  logic [7:0]  sound_be,
    output logic        sound_busy,
    output logic [63:0] sound_dout,
    output logic        sound_dout_ready,
    output logic        sound_command_accepted,

    input  logic        credit_rd,
    input  logic        credit_we,
    input  logic [7:0]  credit_burstcnt,
    input  logic [28:0] credit_addr,
    input  logic [63:0] credit_din,
    input  logic [7:0]  credit_be,
    output logic        credit_busy,
    output logic [63:0] credit_dout,
    output logic        credit_dout_ready,
    output logic        credit_command_accepted,

    output logic        ddram_rd,
    output logic        ddram_we,
    output logic [7:0]  ddram_burstcnt,
    output logic [28:0] ddram_addr,
    output logic [63:0] ddram_din,
    output logic [7:0]  ddram_be,
    input  logic        ddram_busy,
    input  logic [63:0] ddram_dout,
    input  logic        ddram_dout_ready,

    output logic        epoch_quiescent,
    output logic [31:0] debug_arbiter_state,
    output logic        protocol_error
);
    logic sound_mode_latched;
    logic active_path_selected;
    logic legacy_reset;
    logic active_reset;

    // Sampling on every asserted-reset edge makes the value at reset release
    // authoritative while guaranteeing no runtime ownership transition.
    always_ff @(posedge clk) begin
        if (reset) begin
            sound_mode_latched <= sound_enable;
            sound_mode_change_ignored <= 1'b0;
        end else if (sound_enable != sound_mode_latched) begin
            sound_mode_change_ignored <= 1'b1;
        end
    end

    assign sound_mode_active = sound_mode_latched;
    assign active_path_selected =
        sound_mode_latched || ENABLE_CREDIT_CLIENT;
    // Hold the unselected implementation in reset. The selected branch still
    // sees the unmodified external reset waveform.
    assign legacy_reset = reset || active_path_selected;
    assign active_reset = reset || !active_path_selected;

    logic legacy_boot_valid;
    logic legacy_boot_error;
    logic [31:0] legacy_boot_generation;
    logic [31:0] legacy_arm9_dtcm_irq_vector;
    logic [31:0] legacy_arm9_trace_trigger;
    logic [31:0] legacy_arm9_entry;
    logic [31:0] legacy_arm7_entry;
    logic [31:0] legacy_arm9_current_sp;
    logic [31:0] legacy_arm9_irq_sp;
    logic [31:0] legacy_arm9_saved_sp;
    logic [31:0] legacy_arm7_current_sp;
    logic [31:0] legacy_arm7_irq_sp;
    logic [31:0] legacy_arm7_saved_sp;
    logic [31:0] legacy_initial_cpsr;
    logic legacy_cpu_busy;
    logic [63:0] legacy_cpu_dout;
    logic legacy_cpu_dout_ready;
    logic legacy_cpu_command_accepted;
    logic legacy_video_busy;
    logic [63:0] legacy_video_dout;
    logic legacy_video_dout_ready;
    logic legacy_video_command_accepted;
    logic [17:0] legacy_debug_state;
    logic legacy_ddram_rd;
    logic legacy_ddram_we;
    logic [7:0] legacy_ddram_burstcnt;
    logic [28:0] legacy_ddram_addr;
    logic [63:0] legacy_ddram_din;
    logic [7:0] legacy_ddram_be;

    logic active_boot_valid;
    logic active_boot_error;
    logic [31:0] active_boot_generation;
    logic [31:0] active_arm9_dtcm_irq_vector;
    logic [31:0] active_arm9_trace_trigger;
    logic [31:0] active_arm9_entry;
    logic [31:0] active_arm7_entry;
    logic [31:0] active_arm9_current_sp;
    logic [31:0] active_arm9_irq_sp;
    logic [31:0] active_arm9_saved_sp;
    logic [31:0] active_arm7_current_sp;
    logic [31:0] active_arm7_irq_sp;
    logic [31:0] active_arm7_saved_sp;
    logic [31:0] active_initial_cpsr;

    // This instance is deliberately not refactored into the sound path.  It
    // is the exact production wrapper selected for reset-latched sound-off.
    nds_standalone_boot_ddr legacy_path (
        .clk,
        .reset(legacy_reset),
        .enable,
        .boot_valid(legacy_boot_valid),
        .boot_error(legacy_boot_error),
        .boot_generation(legacy_boot_generation),
        .arm9_dtcm_irq_vector(legacy_arm9_dtcm_irq_vector),
        .arm9_trace_trigger(legacy_arm9_trace_trigger),
        .arm9_entry(legacy_arm9_entry),
        .arm7_entry(legacy_arm7_entry),
        .arm9_current_sp(legacy_arm9_current_sp),
        .arm9_irq_sp(legacy_arm9_irq_sp),
        .arm9_saved_sp(legacy_arm9_saved_sp),
        .arm7_current_sp(legacy_arm7_current_sp),
        .arm7_irq_sp(legacy_arm7_irq_sp),
        .arm7_saved_sp(legacy_arm7_saved_sp),
        .initial_cpsr(legacy_initial_cpsr),
        .cpu_rd,
        .cpu_we,
        .cpu_burstcnt,
        .cpu_addr,
        .cpu_din,
        .cpu_be,
        .cpu_busy(legacy_cpu_busy),
        .cpu_dout(legacy_cpu_dout),
        .cpu_dout_ready(legacy_cpu_dout_ready),
        .cpu_command_accepted(legacy_cpu_command_accepted),
        .video_rd,
        .video_we,
        .video_burstcnt,
        .video_addr,
        .video_din,
        .video_be,
        .video_busy(legacy_video_busy),
        .video_dout(legacy_video_dout),
        .video_dout_ready(legacy_video_dout_ready),
        .video_command_accepted(legacy_video_command_accepted),
        .debug_arbiter_state(legacy_debug_state),
        .ddram_rd(legacy_ddram_rd),
        .ddram_we(legacy_ddram_we),
        .ddram_burstcnt(legacy_ddram_burstcnt),
        .ddram_addr(legacy_ddram_addr),
        .ddram_din(legacy_ddram_din),
        .ddram_be(legacy_ddram_be),
        .ddram_busy,
        .ddram_dout,
        .ddram_dout_ready
    );

    logic active_boot_rd;
    logic active_boot_client_busy;
    logic active_boot_client_ready;
    logic [7:0] active_boot_burst;
    logic [28:0] active_boot_addr;
    logic active_a_busy;
    logic [63:0] active_a_dout;
    logic active_a_ready;
    logic active_a_command_accepted;

    logic active_video_busy;
    logic [63:0] active_video_dout;
    logic active_video_dout_ready;
    logic active_video_command_accepted;
    logic active_sound_busy;
    logic [63:0] active_sound_dout;
    logic active_sound_dout_ready;
    logic active_sound_command_accepted;

    logic active_credit_busy;
    logic [63:0] active_credit_dout;
    logic active_credit_dout_ready;
    logic active_credit_command_accepted;

    logic active_ddram_rd;
    logic active_ddram_we;
    logic [7:0] active_ddram_burstcnt;
    logic [28:0] active_ddram_addr;
    logic [63:0] active_ddram_din;
    logic [7:0] active_ddram_be;
    logic active_epoch_quiescent;
    logic [31:0] active_debug_state;
    logic active_protocol_error;

    nds_boot_descriptor_reader active_descriptor (
        .clk,
        .reset(active_reset),
        .enable,
        .valid(active_boot_valid),
        .format_error(active_boot_error),
        .generation(active_boot_generation),
        .arm9_dtcm_irq_vector(active_arm9_dtcm_irq_vector),
        .arm9_trace_trigger(active_arm9_trace_trigger),
        .arm9_entry(active_arm9_entry),
        .arm7_entry(active_arm7_entry),
        .arm9_current_sp(active_arm9_current_sp),
        .arm9_irq_sp(active_arm9_irq_sp),
        .arm9_saved_sp(active_arm9_saved_sp),
        .arm7_current_sp(active_arm7_current_sp),
        .arm7_irq_sp(active_arm7_irq_sp),
        .arm7_saved_sp(active_arm7_saved_sp),
        .initial_cpsr(active_initial_cpsr),
        .ddram_read(active_boot_rd),
        .ddram_burst_count(active_boot_burst),
        .ddram_address(active_boot_addr),
        .ddram_busy(active_boot_client_busy),
        .ddram_read_data(active_a_dout),
        .ddram_read_data_ready(active_boot_client_ready)
    );

    assign active_boot_client_busy =
        active_boot_valid || active_a_busy;
    assign active_boot_client_ready =
        !active_boot_valid && active_a_ready;

    nds_ddram_arbiter_4client #(
        .RESET_QUIET_CYCLES(SOUND_RESET_QUIET_CYCLES),
        .STICKY_GRANT_LIMIT(SOUND_STICKY_GRANT_LIMIT),
        .VIDEO_PRIORITY_GRANT(VIDEO_PRIORITY_GRANT),
        .CLIENT_ENABLE_MASK(
            ENABLE_CREDIT_CLIENT ? 4'b1111 : 4'b0111)
    ) sound_path_arbiter (
        .clk,
        .reset(active_reset),
        .cpu_rd(active_boot_valid ? cpu_rd : active_boot_rd),
        .cpu_we(active_boot_valid ? cpu_we : 1'b0),
        .cpu_burstcnt(active_boot_valid ? cpu_burstcnt :
            active_boot_burst),
        .cpu_addr(active_boot_valid ? cpu_addr : active_boot_addr),
        .cpu_din(active_boot_valid ? cpu_din : 64'd0),
        .cpu_be(active_boot_valid ? cpu_be : 8'hff),
        .cpu_busy(active_a_busy),
        .cpu_dout(active_a_dout),
        .cpu_dout_ready(active_a_ready),
        .cpu_command_accepted(active_a_command_accepted),
        // Make the CRC-checked, generation-rechecked descriptor the first
        // post-quarantine DDR transaction.  Any residual untagged response can
        // only make boot fail closed; it cannot be routed into video or CPUs.
        .video_rd(active_boot_valid ? video_rd : 1'b0),
        .video_we(active_boot_valid ? video_we : 1'b0),
        .video_burstcnt,
        .video_addr,
        .video_din,
        .video_be,
        .video_busy(active_video_busy),
        .video_dout(active_video_dout),
        .video_dout_ready(active_video_dout_ready),
        .video_command_accepted(active_video_command_accepted),
        // Sample traffic is held closed until the descriptor is accepted.
        .sound_rd(active_boot_valid && sound_mode_latched
            ? sound_rd : 1'b0),
        .sound_we(active_boot_valid && sound_mode_latched
            ? sound_we : 1'b0),
        .sound_burstcnt(sound_burstcnt),
        .sound_addr(sound_addr),
        .sound_din(sound_din),
        .sound_be(sound_be),
        .sound_busy(active_sound_busy),
        .sound_dout(active_sound_dout),
        .sound_dout_ready(active_sound_dout_ready),
        .sound_command_accepted(active_sound_command_accepted),
        // The credit client is the external-time-window bootstrap transport.
        // It must be able to read its DDR descriptor and publish its initial
        // consumer position before the HPS publishes the boot descriptor.
        // CPU, video, and sound remain behind active_boot_valid above.
        .credit_rd(ENABLE_CREDIT_CLIENT ? credit_rd : 1'b0),
        .credit_we(ENABLE_CREDIT_CLIENT ? credit_we : 1'b0),
        .credit_burstcnt(ENABLE_CREDIT_CLIENT
            ? credit_burstcnt : 8'd1),
        .credit_addr(ENABLE_CREDIT_CLIENT ? credit_addr : 29'd0),
        .credit_din(ENABLE_CREDIT_CLIENT ? credit_din : 64'd0),
        .credit_be(ENABLE_CREDIT_CLIENT ? credit_be : 8'hff),
        .credit_busy(active_credit_busy),
        .credit_dout(active_credit_dout),
        .credit_dout_ready(active_credit_dout_ready),
        .credit_command_accepted(active_credit_command_accepted),
        .ddram_rd(active_ddram_rd),
        .ddram_we(active_ddram_we),
        .ddram_burstcnt(active_ddram_burstcnt),
        .ddram_addr(active_ddram_addr),
        .ddram_din(active_ddram_din),
        .ddram_be(active_ddram_be),
        .ddram_busy,
        .ddram_dout,
        .ddram_dout_ready,
        .epoch_quiescent(active_epoch_quiescent),
        .debug_state(active_debug_state),
        .protocol_error(active_protocol_error)
    );

    // Keep the CPU contract identical to the original wrapper: descriptor
    // ownership blocks CPU DDR until the atomic descriptor is valid.
    logic active_cpu_busy;
    logic [63:0] active_cpu_dout;
    logic active_cpu_dout_ready;
    logic active_cpu_command_accepted;
    assign active_cpu_busy = !active_boot_valid || active_a_busy;
    assign active_cpu_dout = active_a_dout;
    assign active_cpu_dout_ready = active_boot_valid && active_a_ready;
    assign active_cpu_command_accepted =
        active_boot_valid && active_a_command_accepted;

    // Sound must also remain blocked before boot, irrespective of the
    // four-client arbiter's currently exposed grant.
    logic active_sound_client_busy;
    logic active_sound_client_dout_ready;
    logic active_sound_client_command_accepted;
    logic active_credit_client_busy;
    logic active_credit_client_dout_ready;
    logic active_credit_client_command_accepted;
    logic active_disabled_credit_fault;
    assign active_sound_client_busy =
        !sound_mode_latched || !active_boot_valid || active_sound_busy;
    assign active_sound_client_dout_ready =
        sound_mode_latched && active_boot_valid &&
        active_sound_dout_ready;
    assign active_sound_client_command_accepted =
        sound_mode_latched && active_boot_valid &&
        active_sound_command_accepted;
    assign active_credit_client_busy =
        !ENABLE_CREDIT_CLIENT || active_credit_busy;
    assign active_credit_client_dout_ready =
        ENABLE_CREDIT_CLIENT && active_credit_dout_ready;
    assign active_credit_client_command_accepted =
        ENABLE_CREDIT_CLIENT && active_credit_command_accepted;
    assign active_disabled_credit_fault =
        !ENABLE_CREDIT_CLIENT &&
        (active_credit_command_accepted ||
         active_credit_dout_ready ||
         !active_credit_busy ||
         (active_credit_dout_ready &&
          (^active_credit_dout === 1'bx)));

    always_comb begin
        if (active_path_selected) begin
            boot_valid = active_boot_valid;
            boot_error = active_boot_error;
            boot_generation = active_boot_generation;
            arm9_dtcm_irq_vector = active_arm9_dtcm_irq_vector;
            arm9_trace_trigger = active_arm9_trace_trigger;
            arm9_entry = active_arm9_entry;
            arm7_entry = active_arm7_entry;
            arm9_current_sp = active_arm9_current_sp;
            arm9_irq_sp = active_arm9_irq_sp;
            arm9_saved_sp = active_arm9_saved_sp;
            arm7_current_sp = active_arm7_current_sp;
            arm7_irq_sp = active_arm7_irq_sp;
            arm7_saved_sp = active_arm7_saved_sp;
            initial_cpsr = active_initial_cpsr;
            cpu_busy = active_cpu_busy;
            cpu_dout = active_cpu_dout;
            cpu_dout_ready = active_cpu_dout_ready;
            cpu_command_accepted = active_cpu_command_accepted;
            video_busy = !active_boot_valid || active_video_busy;
            video_dout = active_video_dout;
            video_dout_ready =
                active_boot_valid && active_video_dout_ready;
            video_command_accepted =
                active_boot_valid && active_video_command_accepted;
            sound_busy = active_sound_client_busy;
            sound_dout = sound_mode_latched
                ? active_sound_dout : 64'd0;
            sound_dout_ready = active_sound_client_dout_ready;
            sound_command_accepted =
                active_sound_client_command_accepted;
            credit_busy = active_credit_client_busy;
            credit_dout = ENABLE_CREDIT_CLIENT
                ? active_credit_dout : 64'd0;
            credit_dout_ready = active_credit_client_dout_ready;
            credit_command_accepted =
                active_credit_client_command_accepted;
            ddram_rd = active_ddram_rd;
            ddram_we = active_ddram_we;
            ddram_burstcnt = active_ddram_burstcnt;
            ddram_addr = active_ddram_addr;
            ddram_din = active_ddram_din;
            ddram_be = active_ddram_be;
            epoch_quiescent =
                active_epoch_quiescent &&
                !active_disabled_credit_fault;
            debug_arbiter_state = active_debug_state;
            protocol_error =
                active_protocol_error ||
                active_disabled_credit_fault;
        end else begin
            boot_valid = legacy_boot_valid;
            boot_error = legacy_boot_error;
            boot_generation = legacy_boot_generation;
            arm9_dtcm_irq_vector = legacy_arm9_dtcm_irq_vector;
            arm9_trace_trigger = legacy_arm9_trace_trigger;
            arm9_entry = legacy_arm9_entry;
            arm7_entry = legacy_arm7_entry;
            arm9_current_sp = legacy_arm9_current_sp;
            arm9_irq_sp = legacy_arm9_irq_sp;
            arm9_saved_sp = legacy_arm9_saved_sp;
            arm7_current_sp = legacy_arm7_current_sp;
            arm7_irq_sp = legacy_arm7_irq_sp;
            arm7_saved_sp = legacy_arm7_saved_sp;
            initial_cpsr = legacy_initial_cpsr;
            cpu_busy = legacy_cpu_busy;
            cpu_dout = legacy_cpu_dout;
            cpu_dout_ready = legacy_cpu_dout_ready;
            cpu_command_accepted = legacy_cpu_command_accepted;
            video_busy = legacy_video_busy;
            video_dout = legacy_video_dout;
            video_dout_ready = legacy_video_dout_ready;
            video_command_accepted =
                legacy_video_command_accepted;
            // Default-off sound is fail-closed and cannot affect DDR.
            sound_busy = 1'b1;
            sound_dout = 64'd0;
            sound_dout_ready = 1'b0;
            sound_command_accepted = 1'b0;
            credit_busy = 1'b1;
            credit_dout = 64'd0;
            credit_dout_ready = 1'b0;
            credit_command_accepted = 1'b0;
            ddram_rd = legacy_ddram_rd;
            ddram_we = legacy_ddram_we;
            ddram_burstcnt = legacy_ddram_burstcnt;
            ddram_addr = legacy_ddram_addr;
            ddram_din = legacy_ddram_din;
            ddram_be = legacy_ddram_be;
            epoch_quiescent = 1'b0;
            debug_arbiter_state = {
                13'd0, sound_mode_change_ignored, legacy_debug_state
            };
            protocol_error = 1'b0;
        end
    end
endmodule
