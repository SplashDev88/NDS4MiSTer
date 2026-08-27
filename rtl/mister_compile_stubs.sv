// Simulation-only declarations used to elaborate the MiSTer glue without
// vendor PLL primitives or the complete framework. Not listed in files.qip.
module pll(input wire refclk,input wire rst,output wire outclk_0,output wire locked);
    assign outclk_0=refclk;assign locked=!rst;
endmodule
module hps_io #(parameter CONF_STR="")(
    input wire clk_sys,inout wire [45:0] HPS_BUS,output wire EXT_BUS,
    output wire [21:0] gamma_bus,output wire forced_scandoubler,
    output wire [1:0] buttons,output wire [127:0] status,
    output wire [31:0] joystick_0,output wire [31:0] joystick_1
);
    assign EXT_BUS=0;assign gamma_bus=0;assign forced_scandoubler=0;
    assign buttons=0;assign status=0;assign joystick_0=0;assign joystick_1=0;
endmodule
module nds_dual_cpu_core(
    input wire clk,input wire reset,
    input wire descriptor_valid,
    input wire [31:0] arm9_entry,input wire [31:0] arm7_entry,
    input wire [31:0] arm9_current_sp,input wire [31:0] arm9_irq_sp,
    input wire [31:0] arm9_saved_sp,input wire [31:0] arm7_current_sp,
    input wire [31:0] arm7_irq_sp,input wire [31:0] arm7_saved_sp,
    input wire [31:0] initial_cpsr,input wire global_step_enable,
    output wire boot_ready,
    output wire [7:0] arm9_cycles,output wire arm9_cycles_valid,
    output wire [7:0] arm7_cycles,output wire arm7_cycles_valid,
    output wire [31:0] arm9_debug_pc,output wire [31:0] arm7_debug_pc,
    output wire [31:0] arm9_diag_word,
    output wire [31:0] arm9_dtcm_region,output wire arm9_dtcm_enable,
    output wire [31:0] arm9_addr,output wire arm9_rnw,output wire arm9_ena,
    output wire [1:0] arm9_acc,output wire [31:0] arm9_wdata,
    input wire [31:0] arm9_rdata,input wire arm9_done,input wire arm9_irq,
    input wire arm9_halt,
    output wire [31:0] arm7_addr,output wire arm7_rnw,output wire arm7_ena,
    output wire [1:0] arm7_acc,output wire [31:0] arm7_wdata,
    input wire [31:0] arm7_rdata,input wire arm7_done,input wire arm7_irq,
    input wire arm7_halt
);
    assign arm9_addr=0;assign arm9_rnw=1;assign arm9_ena=0;
    assign arm9_acc=0;assign arm9_wdata=0;
    assign arm7_addr=0;assign arm7_rnw=1;assign arm7_ena=0;
    assign arm7_acc=0;assign arm7_wdata=0;
    assign boot_ready=descriptor_valid;
    assign arm9_cycles=0;assign arm9_cycles_valid=0;
    assign arm7_cycles=0;assign arm7_cycles_valid=0;
    assign arm9_debug_pc=0;assign arm7_debug_pc=0;assign arm9_diag_word=0;
    assign arm9_dtcm_region=32'h0300000a;assign arm9_dtcm_enable=1;
endmodule
module nds_dual_cpu_memory_bridge #(
    parameter integer TIME_FLUSH_CYCLES = 8192,
    parameter bit ARM9_BAD_WRITE_PC_TELEMETRY = 0,
    parameter bit ARM7_INVALID_WRITE_PC_TELEMETRY = 0,
    parameter bit ARM9_MATH_RUNAWAY_PC_TELEMETRY = 0,
    parameter integer ARM9_MATH_RUNAWAY_THRESHOLD = 256,
    parameter bit ARM9_POLL_ADDRESS_TELEMETRY = 0,
    parameter bit ARM9_DTCM_HANDLER_TELEMETRY = 0,
    parameter bit GX_POSTED_ENABLE = 0,
    parameter bit ARM9_MATH_LOCAL_ENABLE = 0,
    parameter bit LW_MAILBOX_ENABLE = 0
)(
    input wire clk,input wire reset,input wire transport_reset,
    input wire [18:0] lw_reg_raddr,output wire [31:0] lw_reg_rdata,
    input wire [18:0] lw_reg_waddr,input wire [31:0] lw_reg_wdata,
    input wire [3:0] lw_reg_be,input wire lw_reg_write,
    output wire lw_request_pending_irq,
    input wire [7:0] arm9_cycles,input wire arm9_cycles_valid,
    input wire [7:0] arm7_cycles,input wire arm7_cycles_valid,
    input wire [31:0] arm9_debug_pc,input wire [31:0] arm7_debug_pc,
    input wire [31:0] arm9_dtcm_region,input wire arm9_dtcm_enable,
    input wire arm9_dtcm_seed_valid,input wire [31:0] arm9_dtcm_irq_vector,
    input wire [31:0] arm9_addr,input wire arm9_rnw,input wire arm9_ena,
    input wire [1:0] arm9_acc,input wire [31:0] arm9_wdata,
    output wire [31:0] arm9_rdata,output wire arm9_done,output wire arm9_irq,
    output wire arm9_halt,
    input wire [31:0] arm7_addr,input wire arm7_rnw,input wire arm7_ena,
    input wire [1:0] arm7_acc,input wire [31:0] arm7_wdata,
    output wire [31:0] arm7_rdata,output wire arm7_done,output wire arm7_irq,
    output wire arm7_halt,output wire cpu_pause,
    output wire debug_ext_ena,output wire debug_ext_cpu_is_arm9,
    output wire [31:0] debug_ext_address,
    output wire debug_ext_done,
    output wire debug_oracle_request,output wire debug_mailbox_request,
    output wire debug_mailbox_done,
    output wire [3:0] debug_mailbox_state,
    output wire [1:0] debug_tick_state,
`ifdef NDS_SOUND_OBSERVATION_EXPORTS
    output wire sound_mailbox_explicit_launch,
    output wire sound_mailbox_request,
    output wire [3:0] sound_mailbox_debug_state,
    output wire sound_mailbox_cpu_arm9,
    output wire [31:0] sound_mailbox_elapsed_cycles,
    output wire [31:0] sound_mailbox_fence_sequence,
    output wire [31:0] sound_mailbox_address,
    output wire sound_mailbox_read_not_write,
    output wire [1:0] sound_mailbox_access,
    output wire [31:0] sound_mailbox_write_data,
    output wire sound_mailbox_done,
    output wire [31:0] sound_mailbox_completed_fence_sequence,
    output wire sound_posted_request,
    output wire sound_posted_active,
    output wire sound_posted_accepted,
    output wire sound_posted_sequence_exhausted,
    output wire [31:0] sound_posted_producer_sequence,
    output wire sound_posted_cpu_arm9,
    output wire [31:0] sound_posted_elapsed_cycles,
    output wire [1:0] sound_live_wramcnt,
`endif
    output wire ddram_read,output wire ddram_write,
    output wire [7:0] ddram_burst_count,output wire [28:0] ddram_address,
    output wire [63:0] ddram_write_data,output wire [7:0] ddram_byte_enable,
    input wire ddram_busy,input wire [63:0] ddram_read_data,
    input wire ddram_read_data_ready,input wire ddram_command_accepted
);
    assign arm9_rdata=0;assign arm9_done=0;assign arm9_irq=0;assign arm9_halt=0;
    assign arm7_rdata=0;assign arm7_done=0;assign arm7_irq=0;assign arm7_halt=0;
    assign cpu_pause=0;
    assign debug_ext_ena=0;assign debug_ext_cpu_is_arm9=0;
    assign debug_ext_address=0;assign debug_ext_done=0;
    assign debug_oracle_request=0;
    assign debug_mailbox_request=0;assign debug_mailbox_done=0;
    assign debug_mailbox_state=0;assign debug_tick_state=0;
    assign lw_reg_rdata=0;assign lw_request_pending_irq=0;
`ifdef NDS_SOUND_OBSERVATION_EXPORTS
    assign sound_mailbox_explicit_launch=0;
    assign sound_mailbox_request=0;
    assign sound_mailbox_debug_state=0;
    assign sound_mailbox_cpu_arm9=0;
    assign sound_mailbox_elapsed_cycles=0;
    assign sound_mailbox_fence_sequence=0;
    assign sound_mailbox_address=0;
    assign sound_mailbox_read_not_write=0;
    assign sound_mailbox_access=0;
    assign sound_mailbox_write_data=0;
    assign sound_mailbox_done=0;
    assign sound_mailbox_completed_fence_sequence=0;
    assign sound_posted_request=0;
    assign sound_posted_active=0;
    assign sound_posted_accepted=0;
    assign sound_posted_sequence_exhausted=0;
    assign sound_posted_producer_sequence=0;
    assign sound_posted_cpu_arm9=0;
    assign sound_posted_elapsed_cycles=0;
    assign sound_live_wramcnt=0;
`endif
    assign ddram_read=0;assign ddram_write=0;assign ddram_burst_count=0;
    assign ddram_address=0;assign ddram_write_data=0;assign ddram_byte_enable=0;
endmodule

// Intel hard-IP lightweight HPS-to-FPGA bridge placeholder used only for
// host elaboration of the real MiSTer top.
module cyclonev_hps_interface_hps2fpga_light_weight(
    input wire clk,
    output wire [11:0] awid,output wire [20:0] awaddr,
    output wire [3:0] awlen,output wire [2:0] awsize,
    output wire [1:0] awburst,output wire [1:0] awlock,
    output wire [3:0] awcache,output wire [2:0] awprot,
    output wire awvalid,input wire awready,
    output wire [11:0] wid,output wire [31:0] wdata,
    output wire [3:0] wstrb,output wire wlast,output wire wvalid,
    input wire wready,input wire [11:0] bid,input wire [1:0] bresp,
    input wire bvalid,output wire bready,
    output wire [11:0] arid,output wire [20:0] araddr,
    output wire [3:0] arlen,output wire [2:0] arsize,
    output wire [1:0] arburst,output wire [1:0] arlock,
    output wire [3:0] arcache,output wire [2:0] arprot,
    output wire arvalid,input wire arready,
    input wire [11:0] rid,input wire [31:0] rdata,
    input wire [1:0] rresp,input wire rlast,input wire rvalid,
    output wire rready
);
    assign awid=0;assign awaddr=0;assign awlen=0;assign awsize=0;
    assign awburst=0;assign awlock=0;assign awcache=0;assign awprot=0;
    assign awvalid=0;assign wid=0;assign wdata=0;assign wstrb=0;
    assign wlast=1;assign wvalid=0;assign bready=1;
    assign arid=0;assign araddr=0;assign arlen=0;assign arsize=0;
    assign arburst=0;assign arlock=0;assign arcache=0;assign arprot=0;
    assign arvalid=0;assign rready=1;
endmodule
