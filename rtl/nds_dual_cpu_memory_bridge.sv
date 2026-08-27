// Mixed-language seam between the VHDL dual-CPU arbiter and the
// SystemVerilog MiSTer DDR memory system.
module nds_dual_cpu_memory_bridge #(
    parameter logic [28:0] MAIN_RAM_BASE_WORD = 29'h05820000,
    parameter logic [28:0] SHARED_WRAM_BASE_WORD = 29'h05802000,
    parameter logic [28:0] ARM7_WRAM_BASE_WORD = 29'h05804000,
    parameter logic [28:0] ORACLE_BASE_WORD = 29'h05800000,
    parameter integer ORACLE_POLL_DELAY_CYCLES = 64,
    parameter integer TIME_FLUSH_CYCLES = 8192,
    parameter bit ARM9_BAD_WRITE_PC_TELEMETRY = 0,
    parameter bit ARM7_INVALID_WRITE_PC_TELEMETRY = 0,
    parameter bit ARM9_MATH_RUNAWAY_PC_TELEMETRY = 0,
    parameter integer ARM9_MATH_RUNAWAY_THRESHOLD = 256,
    parameter bit ARM9_POLL_ADDRESS_TELEMETRY = 0,
    parameter bit ARM9_DTCM_HANDLER_TELEMETRY = 0,
    // Forward the optional NDS2 geometry-posting capability to the memory
    // system. The production MiSTer top intentionally relies on this
    // default-off value until the v2 session/fence contract is proven.
    parameter bit GX_POSTED_ENABLE = 0,
    // Keep the ARM7 firmware-SPI BUSY shadow default-off except in an
    // explicitly validated candidate top.
    parameter bit ARM7_FIRMWARE_SPI_BUSY_SHADOW_ENABLE = 0,
    // Optional N=1 local/HPS cadence limiter; default-off preserves the
    // original unbounded shadow when that shadow is enabled.
    parameter bit ARM7_FIRMWARE_SPI_BUSY_SHADOW_BOUNDED_SYNC_ENABLE = 0,
    // Keep ARM9 DIV/SQRT local only in explicitly enabled candidates. ARM7
    // and undefined neighboring accesses continue through the oracle.
    parameter bit ARM9_MATH_LOCAL_ENABLE = 0,
    // Route the oracle mailbox over the HPS lightweight bridge. Transport
    // only; protocol and timing semantics are unchanged.
    parameter bit LW_MAILBOX_ENABLE = 0,
    // Default-off HPS->FPGA counted time/IRQ boundary. The ordinary LW FLAGS
    // write remains the only event permitted to release a stalled CPU.
    parameter bit TIME_IRQ_REVERSE_ENABLE = 0,
    // Exact external-time-window production candidate.  Default off keeps the
    // mixed-language bridge cycle-identical for every preserved build.
    parameter bit BLOCKING_ETW_ENABLE = 0,
    parameter logic [28:0] BLOCKING_ETW_BASE_WORD = 29'h0581c000
)(
    input logic clk, input logic reset, input logic transport_reset,
    // Lightweight-bridge register file, driven by nds_hps_lw_slave in the top.
    input  logic [18:0] lw_reg_raddr,
    output logic [31:0] lw_reg_rdata,
    input  logic [18:0] lw_reg_waddr,
    input  logic [31:0] lw_reg_wdata,
    input  logic [3:0]  lw_reg_be,
    input  logic        lw_reg_write,
    output logic        lw_request_pending_irq,
    output logic        time_irq_session_begin_ready,
    input  logic        time_irq_transport_quiescent,
    output logic        time_irq_session_started,
    output logic        time_irq_session_active,
    output logic [31:0] time_irq_active_epoch,
    output logic [31:0] time_irq_consumer_sequence,
    output logic        time_irq_protocol_error,
    input logic [7:0] arm9_cycles, input logic arm9_cycles_valid,
    input logic [7:0] arm7_cycles, input logic arm7_cycles_valid,
    input logic [8:0] arm9_cycles_exact, input logic [8:0] arm7_cycles_exact,
    input logic arm9_step_boundary, input logic arm7_step_boundary,
    input logic arm9_instruction_inflight,
    input logic arm7_instruction_inflight,
    input logic arm9_data_waitbus, input logic arm7_data_waitbus,
    output logic arm9_step_permit, output logic arm7_step_permit,
    input logic [31:0] arm9_debug_pc, input logic [31:0] arm7_debug_pc,
    input logic [31:0] arm9_dtcm_region, input logic arm9_dtcm_enable,
    input logic arm9_dtcm_seed_valid,
    input logic [31:0] arm9_dtcm_irq_vector,
    input logic [31:0] arm9_addr, input logic arm9_rnw, input logic arm9_ena,
    input logic [1:0] arm9_acc, input logic [31:0] arm9_wdata,
    output logic [31:0] arm9_rdata, output logic arm9_done,
    output logic arm9_irq, output logic arm9_halt,
    input logic [31:0] arm7_addr, input logic arm7_rnw, input logic arm7_ena,
    input logic [1:0] arm7_acc, input logic [31:0] arm7_wdata,
    output logic [31:0] arm7_rdata, output logic arm7_done,
    output logic arm7_irq, output logic arm7_halt,
    output logic cpu_pause,
    output logic debug_ext_ena,
    output logic debug_ext_cpu_is_arm9,
    output logic [31:0] debug_ext_address,
    output logic debug_ext_done,
    output logic debug_oracle_request,
    output logic debug_mailbox_request,
    output logic debug_mailbox_done,
    output logic [3:0] debug_mailbox_state,
    output logic [1:0] debug_tick_state,
`ifdef NDS_SOUND_OBSERVATION_EXPORTS
    output logic sound_mailbox_explicit_launch,
    output logic sound_mailbox_request,
    output logic [3:0] sound_mailbox_debug_state,
    output logic sound_mailbox_cpu_arm9,
    output logic [31:0] sound_mailbox_elapsed_cycles,
    output logic [31:0] sound_mailbox_fence_sequence,
    output logic [31:0] sound_mailbox_address,
    output logic sound_mailbox_read_not_write,
    output logic [1:0] sound_mailbox_access,
    output logic [31:0] sound_mailbox_write_data,
    output logic sound_mailbox_done,
    output logic [31:0] sound_mailbox_completed_fence_sequence,
    output logic sound_posted_request,
    output logic sound_posted_active,
    output logic sound_posted_accepted,
    output logic sound_posted_sequence_exhausted,
    output logic [31:0] sound_posted_producer_sequence,
    output logic sound_posted_cpu_arm9,
    output logic [31:0] sound_posted_elapsed_cycles,
    output logic [1:0] sound_live_wramcnt,
`endif
    // Wire these one-for-one to nds_standalone_boot_ddr_sound.credit_* when a
    // candidate top deliberately enables its fourth arbiter client.
    output logic time_irq_credit_rd, output logic time_irq_credit_we,
    output logic [7:0] time_irq_credit_burstcnt,
    output logic [28:0] time_irq_credit_addr,
    output logic [63:0] time_irq_credit_din,
    output logic [7:0] time_irq_credit_be,
    input logic time_irq_credit_busy,
    input logic [63:0] time_irq_credit_dout,
    input logic time_irq_credit_dout_ready,
    input logic time_irq_credit_command_accepted,
    output logic ddram_read, output logic ddram_write,
    output logic [7:0] ddram_burst_count, output logic [28:0] ddram_address,
    output logic [63:0] ddram_write_data, output logic [7:0] ddram_byte_enable,
    input logic ddram_busy, input logic [63:0] ddram_read_data,
    input logic ddram_read_data_ready,
    input logic ddram_command_accepted
);
    logic [31:0] ext_addr, ext_wdata, ext_rdata, ext_debug_pc;
    logic ext_rnw, ext_ena, ext_done, ext_cpu_is_arm9;
    logic [1:0] ext_acc;
    assign debug_ext_ena = ext_ena;
    assign debug_ext_cpu_is_arm9 = ext_cpu_is_arm9;
    assign debug_ext_address = ext_addr;
    assign debug_ext_done = ext_done;

    nds_dual_cpu_bus bus (
        .clk(clk), .reset(reset),
        .arm9_addr(arm9_addr), .arm9_rnw(arm9_rnw), .arm9_ena(arm9_ena),
        .arm9_acc(arm9_acc), .arm9_wdata(arm9_wdata),
        .arm9_debug_pc(arm9_debug_pc),
        .arm9_rdata(arm9_rdata), .arm9_done(arm9_done),
        .arm7_addr(arm7_addr), .arm7_rnw(arm7_rnw), .arm7_ena(arm7_ena),
        .arm7_acc(arm7_acc), .arm7_wdata(arm7_wdata),
        .arm7_debug_pc(arm7_debug_pc),
        .arm7_rdata(arm7_rdata), .arm7_done(arm7_done),
        .ext_addr(ext_addr), .ext_rnw(ext_rnw), .ext_ena(ext_ena),
        .ext_acc(ext_acc), .ext_wdata(ext_wdata),
        .ext_cpu_is_arm9(ext_cpu_is_arm9),
        .ext_debug_pc(ext_debug_pc),
        .ext_rdata(ext_rdata), .ext_done(ext_done)
    );

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN_RAM_BASE_WORD),
        .SHARED_WRAM_BASE_WORD(SHARED_WRAM_BASE_WORD),
        .ARM7_WRAM_BASE_WORD(ARM7_WRAM_BASE_WORD),
        .ORACLE_BASE_WORD(ORACLE_BASE_WORD),
        .ORACLE_POLL_DELAY_CYCLES(ORACLE_POLL_DELAY_CYCLES),
        .TIME_FLUSH_CYCLES(TIME_FLUSH_CYCLES),
        .ARM9_BAD_WRITE_PC_TELEMETRY(ARM9_BAD_WRITE_PC_TELEMETRY),
        .ARM7_INVALID_WRITE_PC_TELEMETRY(
            ARM7_INVALID_WRITE_PC_TELEMETRY),
        .ARM9_MATH_RUNAWAY_PC_TELEMETRY(
            ARM9_MATH_RUNAWAY_PC_TELEMETRY),
        .ARM9_MATH_RUNAWAY_THRESHOLD(ARM9_MATH_RUNAWAY_THRESHOLD),
        .ARM9_POLL_ADDRESS_TELEMETRY(ARM9_POLL_ADDRESS_TELEMETRY),
        .ARM9_DTCM_HANDLER_TELEMETRY(ARM9_DTCM_HANDLER_TELEMETRY),
        .GX_POSTED_ENABLE(GX_POSTED_ENABLE),
        .ARM7_FIRMWARE_SPI_BUSY_SHADOW_ENABLE(
            ARM7_FIRMWARE_SPI_BUSY_SHADOW_ENABLE),
        .ARM7_FIRMWARE_SPI_BUSY_SHADOW_BOUNDED_SYNC_ENABLE(
            ARM7_FIRMWARE_SPI_BUSY_SHADOW_BOUNDED_SYNC_ENABLE),
        .ARM9_MATH_LOCAL_ENABLE(ARM9_MATH_LOCAL_ENABLE),
        .LW_MAILBOX_ENABLE(LW_MAILBOX_ENABLE),
        .TIME_IRQ_REVERSE_ENABLE(TIME_IRQ_REVERSE_ENABLE),
        .BLOCKING_ETW_ENABLE(BLOCKING_ETW_ENABLE),
        .BLOCKING_ETW_BASE_WORD(BLOCKING_ETW_BASE_WORD)
    ) memory (
        .clk(clk), .reset(reset), .transport_reset(transport_reset),
        .request(ext_ena),
        .lw_reg_raddr(lw_reg_raddr), .lw_reg_rdata(lw_reg_rdata),
        .lw_reg_waddr(lw_reg_waddr), .lw_reg_wdata(lw_reg_wdata),
        .lw_reg_be(lw_reg_be), .lw_reg_write(lw_reg_write),
        .lw_request_pending_irq(lw_request_pending_irq),
        .time_irq_session_begin_ready,
        .time_irq_transport_quiescent,
        .time_irq_session_started,
        .time_irq_session_active,
        .time_irq_active_epoch,
        .time_irq_consumer_sequence,
        .time_irq_protocol_error,
        .arm9_cycles, .arm9_cycles_valid, .arm7_cycles, .arm7_cycles_valid,
        .arm9_cycles_exact, .arm7_cycles_exact,
        .arm9_step_boundary, .arm7_step_boundary,
        .arm9_instruction_inflight, .arm7_instruction_inflight,
        .arm9_data_waitbus, .arm7_data_waitbus,
        .arm9_step_permit, .arm7_step_permit,
        .arm9_debug_pc, .arm7_debug_pc, .request_debug_pc(ext_debug_pc),
        .arm9_dtcm_region,
        .arm9_dtcm_enable, .arm9_dtcm_seed_valid, .arm9_dtcm_irq_vector,
        .cpu_is_arm9(ext_cpu_is_arm9), .address(ext_addr),
        .read_not_write(ext_rnw), .access(ext_acc), .write_data(ext_wdata),
        .read_data(ext_rdata), .done(ext_done),
        .irq_arm9(arm9_irq), .irq_arm7(arm7_irq),
        .halt_arm9(arm9_halt), .halt_arm7(arm7_halt),
        .cpu_pause(cpu_pause),
        .debug_oracle_request,
        .debug_mailbox_request,
        .debug_mailbox_done,
        .debug_mailbox_state,
        .debug_tick_state,
`ifdef NDS_SOUND_OBSERVATION_EXPORTS
        .sound_mailbox_explicit_launch,
        .sound_mailbox_request,
        .sound_mailbox_debug_state,
        .sound_mailbox_cpu_arm9,
        .sound_mailbox_elapsed_cycles,
        .sound_mailbox_fence_sequence,
        .sound_mailbox_address,
        .sound_mailbox_read_not_write,
        .sound_mailbox_access,
        .sound_mailbox_write_data,
        .sound_mailbox_done,
        .sound_mailbox_completed_fence_sequence,
        .sound_posted_request,
        .sound_posted_active,
        .sound_posted_accepted,
        .sound_posted_sequence_exhausted,
        .sound_posted_producer_sequence,
        .sound_posted_cpu_arm9,
        .sound_posted_elapsed_cycles,
        .sound_live_wramcnt,
`endif
        .time_irq_credit_rd,
        .time_irq_credit_we,
        .time_irq_credit_burstcnt,
        .time_irq_credit_addr,
        .time_irq_credit_din,
        .time_irq_credit_be,
        .time_irq_credit_busy,
        .time_irq_credit_dout,
        .time_irq_credit_dout_ready,
        .time_irq_credit_command_accepted,
        .ddram_read(ddram_read), .ddram_write(ddram_write),
        .ddram_burst_count(ddram_burst_count), .ddram_address(ddram_address),
        .ddram_write_data(ddram_write_data), .ddram_byte_enable(ddram_byte_enable),
        .ddram_busy(ddram_busy), .ddram_read_data(ddram_read_data),
        .ddram_read_data_ready(ddram_read_data_ready),
        .ddram_command_accepted(ddram_command_accepted)
    );
endmodule
