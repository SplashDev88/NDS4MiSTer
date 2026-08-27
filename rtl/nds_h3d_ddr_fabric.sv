// Hybrid-3D outer DDR fabric.
//
// The legacy Nitro DDR controller remains client zero and therefore keeps the
// reset/default grant.  The H3D plane reader is client one and receives the
// arbiter's bounded video-priority hint.  Event-ring and control-initializer
// traffic use clients two and three.  All four client ports use the same
// contract as the standalone H3D blocks:
//
//   * a requester presents RD/WE and holds its payload until busy is low;
//   * this fabric copies that command into a one-entry physical-port queue;
//   * command_accepted pulses only when MiSTer's DDR port accepts the command;
//   * read data, including every beat of a burst, returns only to its owner.
//
// The wrapper contains no independent ownership state.  Reset quarantine,
// physical command registration, response ownership, plane priority, and
// bounded fairness all come from the separately tested four-client arbiter.
module nds_h3d_ddr_fabric #(
    parameter integer RESET_QUIET_CYCLES = 4,
    parameter integer STICKY_GRANT_LIMIT = 8
) (
    input  logic        clk,
    input  logic        reset,

    // Client 0: complete pre-H3D Nitro DDR controller.
    input  logic        legacy_read,
    input  logic        legacy_write,
    input  logic [7:0]  legacy_burst_count,
    input  logic [28:0] legacy_address,
    input  logic [63:0] legacy_write_data,
    input  logic [7:0]  legacy_byte_enable,
    output logic        legacy_busy,
    output logic        legacy_command_accepted,
    output logic [63:0] legacy_read_data,
    output logic        legacy_read_data_ready,

    // Client 1: scan-line plane reader (bounded video-priority hint).
    input  logic        plane_read,
    input  logic        plane_write,
    input  logic [7:0]  plane_burst_count,
    input  logic [28:0] plane_address,
    input  logic [63:0] plane_write_data,
    input  logic [7:0]  plane_byte_enable,
    output logic        plane_busy,
    output logic        plane_command_accepted,
    output logic [63:0] plane_read_data,
    output logic        plane_read_data_ready,

    // Client 2: lossless H3D event-ring producer.
    input  logic        event_read,
    input  logic        event_write,
    input  logic [7:0]  event_burst_count,
    input  logic [28:0] event_address,
    input  logic [63:0] event_write_data,
    input  logic [7:0]  event_byte_enable,
    output logic        event_busy,
    output logic        event_command_accepted,
    output logic [63:0] event_read_data,
    output logic        event_read_data_ready,

    // Client 3: H3D control/session initializer and monitor.
    input  logic        control_read,
    input  logic        control_write,
    input  logic [7:0]  control_burst_count,
    input  logic [28:0] control_address,
    input  logic [63:0] control_write_data,
    input  logic [7:0]  control_byte_enable,
    output logic        control_busy,
    output logic        control_command_accepted,
    output logic [63:0] control_read_data,
    output logic        control_read_data_ready,

    // Single physical MiSTer DDR port.
    output logic        ddram_read,
    output logic        ddram_write,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    output logic [63:0] ddram_write_data,
    output logic [7:0]  ddram_byte_enable,
    input  logic        ddram_busy,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready,

    // Epoch diagnostics.  epoch_quiescent is the only positive indication
    // that reset-response quarantine has completed without an owner error.
    output logic        epoch_quiescent,
    output logic        protocol_error,
    output logic [31:0] debug_state
);
    nds_ddram_arbiter_4client #(
        .RESET_QUIET_CYCLES(RESET_QUIET_CYCLES),
        .STICKY_GRANT_LIMIT(STICKY_GRANT_LIMIT),
        .CLIENT_ENABLE_MASK(4'b1111),
        .VIDEO_PRIORITY_GRANT(1'b1),
        .VIDEO_PRIORITY_FAIR_CREDIT(1'b1)
    ) fabric (
        .clk,
        .reset,

        .cpu_rd(legacy_read),
        .cpu_we(legacy_write),
        .cpu_burstcnt(legacy_burst_count),
        .cpu_addr(legacy_address),
        .cpu_din(legacy_write_data),
        .cpu_be(legacy_byte_enable),
        .cpu_busy(legacy_busy),
        .cpu_dout(legacy_read_data),
        .cpu_dout_ready(legacy_read_data_ready),
        .cpu_command_accepted(legacy_command_accepted),

        .video_rd(plane_read),
        .video_we(plane_write),
        .video_burstcnt(plane_burst_count),
        .video_addr(plane_address),
        .video_din(plane_write_data),
        .video_be(plane_byte_enable),
        .video_busy(plane_busy),
        .video_dout(plane_read_data),
        .video_dout_ready(plane_read_data_ready),
        .video_command_accepted(plane_command_accepted),

        .sound_rd(event_read),
        .sound_we(event_write),
        .sound_burstcnt(event_burst_count),
        .sound_addr(event_address),
        .sound_din(event_write_data),
        .sound_be(event_byte_enable),
        .sound_busy(event_busy),
        .sound_dout(event_read_data),
        .sound_dout_ready(event_read_data_ready),
        .sound_command_accepted(event_command_accepted),

        .credit_rd(control_read),
        .credit_we(control_write),
        .credit_burstcnt(control_burst_count),
        .credit_addr(control_address),
        .credit_din(control_write_data),
        .credit_be(control_byte_enable),
        .credit_busy(control_busy),
        .credit_dout(control_read_data),
        .credit_dout_ready(control_read_data_ready),
        .credit_command_accepted(control_command_accepted),

        .ddram_rd(ddram_read),
        .ddram_we(ddram_write),
        .ddram_burstcnt(ddram_burst_count),
        .ddram_addr(ddram_address),
        .ddram_din(ddram_write_data),
        .ddram_be(ddram_byte_enable),
        .ddram_busy,
        .ddram_dout(ddram_read_data),
        .ddram_dout_ready(ddram_read_data_ready),

        .epoch_quiescent,
        .debug_state,
        .protocol_error
    );
endmodule
