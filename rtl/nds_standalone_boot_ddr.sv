// Composes boot-descriptor loading, the CPU DDR port, and the selected video
// DDR client onto MiSTer's single external DDR interface. Before boot_valid,
// client A belongs exclusively to the descriptor reader and the CPUs observe
// busy. After atomic descriptor acceptance, ownership switches permanently to
// the CPU memory system. Video remains the fair client B throughout.
module nds_standalone_boot_ddr (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,
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
    output logic [17:0] debug_arbiter_state,

    output logic        ddram_rd,
    output logic        ddram_we,
    output logic [7:0]  ddram_burstcnt,
    output logic [28:0] ddram_addr,
    output logic [63:0] ddram_din,
    output logic [7:0]  ddram_be,
    input  logic        ddram_busy,
    input  logic [63:0] ddram_dout,
    input  logic        ddram_dout_ready
);
    logic boot_rd, boot_client_busy, boot_client_ready;
    logic [7:0] boot_burst;
    logic [28:0] boot_addr;
    logic [63:0] shared_a_dout;
    logic shared_a_ready, shared_a_busy;

    nds_boot_descriptor_reader descriptor (
        .clk, .reset, .enable, .valid(boot_valid), .format_error(boot_error),
        .generation(boot_generation), .arm9_dtcm_irq_vector,
        .arm9_trace_trigger,
        .arm9_entry, .arm7_entry, .arm9_current_sp, .arm9_irq_sp,
        .arm9_saved_sp, .arm7_current_sp, .arm7_irq_sp, .arm7_saved_sp,
        .initial_cpsr, .ddram_read(boot_rd),
        .ddram_burst_count(boot_burst), .ddram_address(boot_addr),
        .ddram_busy(boot_client_busy), .ddram_read_data(shared_a_dout),
        .ddram_read_data_ready(boot_client_ready));

    assign cpu_busy = !boot_valid || shared_a_busy;
    assign cpu_dout = shared_a_dout;
    assign cpu_dout_ready = boot_valid && shared_a_ready;
    assign boot_client_busy = boot_valid || shared_a_busy;
    assign boot_client_ready = !boot_valid && shared_a_ready;

    nds_ddram_arbiter arbiter (
        .clk, .reset,
        .a_rd(boot_valid ? cpu_rd : boot_rd),
        .a_we(boot_valid ? cpu_we : 1'b0),
        .a_burstcnt(boot_valid ? cpu_burstcnt : boot_burst),
        .a_addr(boot_valid ? cpu_addr : boot_addr),
        .a_din(boot_valid ? cpu_din : 64'd0),
        .a_be(boot_valid ? cpu_be : 8'hff),
        .a_busy(shared_a_busy), .a_dout(shared_a_dout),
        .a_dout_ready(shared_a_ready),
        .a_command_accepted(cpu_command_accepted),
        .b_rd(video_rd), .b_we(video_we), .b_burstcnt(video_burstcnt),
        .b_addr(video_addr), .b_din(video_din), .b_be(video_be),
        .b_busy(video_busy), .b_dout(video_dout),
        .b_dout_ready(video_dout_ready),
        .b_command_accepted(video_command_accepted),
        .debug_state(debug_arbiter_state),
        .ddram_rd, .ddram_we, .ddram_burstcnt, .ddram_addr,
        .ddram_din, .ddram_be, .ddram_busy, .ddram_dout,
        .ddram_dout_ready);
endmodule
