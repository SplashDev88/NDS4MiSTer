module tb_nds_standalone_boot_ddr_sound_legacy;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic enable = 1'b0;
    logic sound_enable = 1'b0;
    always #5 clk = ~clk;

    logic cpu_rd = 1'b0;
    logic cpu_we = 1'b0;
    logic [7:0] cpu_burstcnt = 8'd1;
    logic [28:0] cpu_addr = 29'd0;
    logic [63:0] cpu_din = 64'd0;
    logic [7:0] cpu_be = 8'hff;
    logic video_rd = 1'b0;
    logic video_we = 1'b0;
    logic [7:0] video_burstcnt = 8'd1;
    logic [28:0] video_addr = 29'd0;
    logic [63:0] video_din = 64'd0;
    logic [7:0] video_be = 8'hff;
    logic sound_rd = 1'b0;
    logic sound_we = 1'b0;
    logic [7:0] sound_burstcnt = 8'd1;
    logic [28:0] sound_addr = 29'd0;
    logic [63:0] sound_din = 64'd0;
    logic [7:0] sound_be = 8'hff;
    logic ddram_busy = 1'b0;
    logic [63:0] ddram_dout = 64'd0;
    logic ddram_dout_ready = 1'b0;

    logic w_sound_mode_active;
    logic w_sound_mode_change_ignored;
    logic w_boot_valid;
    logic w_boot_error;
    logic [31:0] w_boot_generation;
    logic [31:0] w_arm9_dtcm_irq_vector;
    logic [31:0] w_arm9_trace_trigger;
    logic [31:0] w_arm9_entry;
    logic [31:0] w_arm7_entry;
    logic [31:0] w_arm9_current_sp;
    logic [31:0] w_arm9_irq_sp;
    logic [31:0] w_arm9_saved_sp;
    logic [31:0] w_arm7_current_sp;
    logic [31:0] w_arm7_irq_sp;
    logic [31:0] w_arm7_saved_sp;
    logic [31:0] w_initial_cpsr;
    logic w_cpu_busy;
    logic [63:0] w_cpu_dout;
    logic w_cpu_dout_ready;
    logic w_cpu_command_accepted;
    logic w_video_busy;
    logic [63:0] w_video_dout;
    logic w_video_dout_ready;
    logic w_video_command_accepted;
    logic w_sound_busy;
    logic [63:0] w_sound_dout;
    logic w_sound_dout_ready;
    logic w_sound_command_accepted;
    logic w_ddram_rd;
    logic w_ddram_we;
    logic [7:0] w_ddram_burstcnt;
    logic [28:0] w_ddram_addr;
    logic [63:0] w_ddram_din;
    logic [7:0] w_ddram_be;
    logic w_epoch_quiescent;
    logic [31:0] w_debug;
    logic w_protocol_error;

    logic r_boot_valid;
    logic r_boot_error;
    logic [31:0] r_boot_generation;
    logic [31:0] r_arm9_dtcm_irq_vector;
    logic [31:0] r_arm9_trace_trigger;
    logic [31:0] r_arm9_entry;
    logic [31:0] r_arm7_entry;
    logic [31:0] r_arm9_current_sp;
    logic [31:0] r_arm9_irq_sp;
    logic [31:0] r_arm9_saved_sp;
    logic [31:0] r_arm7_current_sp;
    logic [31:0] r_arm7_irq_sp;
    logic [31:0] r_arm7_saved_sp;
    logic [31:0] r_initial_cpsr;
    logic r_cpu_busy;
    logic [63:0] r_cpu_dout;
    logic r_cpu_dout_ready;
    logic r_cpu_command_accepted;
    logic r_video_busy;
    logic [63:0] r_video_dout;
    logic r_video_dout_ready;
    logic r_video_command_accepted;
    logic [17:0] r_debug;
    logic r_ddram_rd;
    logic r_ddram_we;
    logic [7:0] r_ddram_burstcnt;
    logic [28:0] r_ddram_addr;
    logic [63:0] r_ddram_din;
    logic [7:0] r_ddram_be;

    nds_standalone_boot_ddr_sound wrapped (
        .clk,
        .reset,
        .enable,
        .sound_enable,
        .sound_mode_active(w_sound_mode_active),
        .sound_mode_change_ignored(w_sound_mode_change_ignored),
        .boot_valid(w_boot_valid),
        .boot_error(w_boot_error),
        .boot_generation(w_boot_generation),
        .arm9_dtcm_irq_vector(w_arm9_dtcm_irq_vector),
        .arm9_trace_trigger(w_arm9_trace_trigger),
        .arm9_entry(w_arm9_entry),
        .arm7_entry(w_arm7_entry),
        .arm9_current_sp(w_arm9_current_sp),
        .arm9_irq_sp(w_arm9_irq_sp),
        .arm9_saved_sp(w_arm9_saved_sp),
        .arm7_current_sp(w_arm7_current_sp),
        .arm7_irq_sp(w_arm7_irq_sp),
        .arm7_saved_sp(w_arm7_saved_sp),
        .initial_cpsr(w_initial_cpsr),
        .cpu_rd,
        .cpu_we,
        .cpu_burstcnt,
        .cpu_addr,
        .cpu_din,
        .cpu_be,
        .cpu_busy(w_cpu_busy),
        .cpu_dout(w_cpu_dout),
        .cpu_dout_ready(w_cpu_dout_ready),
        .cpu_command_accepted(w_cpu_command_accepted),
        .video_rd,
        .video_we,
        .video_burstcnt,
        .video_addr,
        .video_din,
        .video_be,
        .video_busy(w_video_busy),
        .video_dout(w_video_dout),
        .video_dout_ready(w_video_dout_ready),
        .video_command_accepted(w_video_command_accepted),
        .sound_rd,
        .sound_we,
        .sound_burstcnt,
        .sound_addr,
        .sound_din,
        .sound_be,
        .sound_busy(w_sound_busy),
        .sound_dout(w_sound_dout),
        .sound_dout_ready(w_sound_dout_ready),
        .sound_command_accepted(w_sound_command_accepted),
        .ddram_rd(w_ddram_rd),
        .ddram_we(w_ddram_we),
        .ddram_burstcnt(w_ddram_burstcnt),
        .ddram_addr(w_ddram_addr),
        .ddram_din(w_ddram_din),
        .ddram_be(w_ddram_be),
        .ddram_busy,
        .ddram_dout,
        .ddram_dout_ready,
        .epoch_quiescent(w_epoch_quiescent),
        .debug_arbiter_state(w_debug),
        .protocol_error(w_protocol_error)
    );

    nds_standalone_boot_ddr reference (
        .clk,
        .reset,
        .enable,
        .boot_valid(r_boot_valid),
        .boot_error(r_boot_error),
        .boot_generation(r_boot_generation),
        .arm9_dtcm_irq_vector(r_arm9_dtcm_irq_vector),
        .arm9_trace_trigger(r_arm9_trace_trigger),
        .arm9_entry(r_arm9_entry),
        .arm7_entry(r_arm7_entry),
        .arm9_current_sp(r_arm9_current_sp),
        .arm9_irq_sp(r_arm9_irq_sp),
        .arm9_saved_sp(r_arm9_saved_sp),
        .arm7_current_sp(r_arm7_current_sp),
        .arm7_irq_sp(r_arm7_irq_sp),
        .arm7_saved_sp(r_arm7_saved_sp),
        .initial_cpsr(r_initial_cpsr),
        .cpu_rd,
        .cpu_we,
        .cpu_burstcnt,
        .cpu_addr,
        .cpu_din,
        .cpu_be,
        .cpu_busy(r_cpu_busy),
        .cpu_dout(r_cpu_dout),
        .cpu_dout_ready(r_cpu_dout_ready),
        .cpu_command_accepted(r_cpu_command_accepted),
        .video_rd,
        .video_we,
        .video_burstcnt,
        .video_addr,
        .video_din,
        .video_be,
        .video_busy(r_video_busy),
        .video_dout(r_video_dout),
        .video_dout_ready(r_video_dout_ready),
        .video_command_accepted(r_video_command_accepted),
        .debug_arbiter_state(r_debug),
        .ddram_rd(r_ddram_rd),
        .ddram_we(r_ddram_we),
        .ddram_burstcnt(r_ddram_burstcnt),
        .ddram_addr(r_ddram_addr),
        .ddram_din(r_ddram_din),
        .ddram_be(r_ddram_be),
        .ddram_busy,
        .ddram_dout,
        .ddram_dout_ready
    );

    task automatic compare_legacy;
        begin
            if ({
                w_boot_valid, w_boot_error, w_boot_generation,
                w_arm9_dtcm_irq_vector, w_arm9_trace_trigger,
                w_arm9_entry, w_arm7_entry, w_arm9_current_sp,
                w_arm9_irq_sp, w_arm9_saved_sp, w_arm7_current_sp,
                w_arm7_irq_sp, w_arm7_saved_sp, w_initial_cpsr,
                w_cpu_busy, w_cpu_dout, w_cpu_dout_ready,
                w_cpu_command_accepted, w_video_busy, w_video_dout,
                w_video_dout_ready, w_video_command_accepted,
                w_ddram_rd, w_ddram_we, w_ddram_burstcnt,
                w_ddram_addr, w_ddram_din, w_ddram_be
            } !== {
                r_boot_valid, r_boot_error, r_boot_generation,
                r_arm9_dtcm_irq_vector, r_arm9_trace_trigger,
                r_arm9_entry, r_arm7_entry, r_arm9_current_sp,
                r_arm9_irq_sp, r_arm9_saved_sp, r_arm7_current_sp,
                r_arm7_irq_sp, r_arm7_saved_sp, r_initial_cpsr,
                r_cpu_busy, r_cpu_dout, r_cpu_dout_ready,
                r_cpu_command_accepted, r_video_busy, r_video_dout,
                r_video_dout_ready, r_video_command_accepted,
                r_ddram_rd, r_ddram_we, r_ddram_burstcnt,
                r_ddram_addr, r_ddram_din, r_ddram_be
            })
                $fatal(1,
                    "sound-off path diverged from literal legacy instance");
            if (w_debug !== {
                13'd0, w_sound_mode_change_ignored, r_debug
            })
                $fatal(1, "legacy debug state changed");
            if (w_sound_mode_active || !w_sound_busy ||
                w_sound_dout !== 64'd0 || w_sound_dout_ready ||
                w_sound_command_accepted || w_epoch_quiescent ||
                w_protocol_error)
                $fatal(1, "sound-off candidate did not fail closed");
        end
    endtask

    integer cycle;
    logic [31:0] random_word;
    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        enable = 1'b1;

        for (cycle = 0; cycle < 320; cycle = cycle + 1) begin
            @(negedge clk);
            random_word = $urandom;
            cpu_rd = random_word[0];
            cpu_we = random_word[1] && !cpu_rd;
            cpu_burstcnt = {6'd0, random_word[3:2]} + 8'd1;
            cpu_addr = random_word[28:0];
            cpu_din = {random_word, $urandom};
            cpu_be = random_word[15:8];
            random_word = $urandom;
            video_rd = random_word[0];
            video_we = random_word[1] && !video_rd;
            video_burstcnt = {6'd0, random_word[3:2]} + 8'd1;
            video_addr = random_word[28:0];
            video_din = {random_word, $urandom};
            video_be = random_word[15:8];
            random_word = $urandom;
            sound_rd = random_word[0];
            sound_we = random_word[1] && !sound_rd;
            sound_burstcnt = {6'd0, random_word[3:2]} + 8'd1;
            sound_addr = random_word[28:0];
            sound_din = {random_word, $urandom};
            sound_be = random_word[15:8];
            random_word = $urandom;
            ddram_busy = random_word[0];
            ddram_dout = {$urandom, $urandom};
            ddram_dout_ready = random_word[1];
            if (cycle == 80)
                sound_enable = 1'b1;
            #1;
            compare_legacy();
        end

        if (!w_sound_mode_change_ignored || !w_debug[18])
            $fatal(1,
                "runtime sound request was not recorded as reset-required");
        $display(
            "PASS: reset-latched sound-off uses the original DDR wrapper cycle-for-cycle under randomized stalls and responses");
        $finish;
    end
endmodule
