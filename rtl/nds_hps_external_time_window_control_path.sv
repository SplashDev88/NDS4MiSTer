// Production-shaped composition of the exact blocking ETW datapath and its
// lightweight HPS control plane.  Bulk groups remain on the dedicated DDR
// client; LW carries only immutable work snapshots and tagged completion.
//
// ENABLED defaults off.  The enclosing memory system must still arbitrate the
// dedicated DDR client, generate monotonic request identities, freeze posted
// admission through posted_admission_frozen, and demultiplex lw_reg_*_select
// before the legacy NDS2 mailbox sees extension writes.

`timescale 1ns/1ps
`default_nettype none

module nds_hps_external_time_window_control_path #(
    parameter bit ENABLED = 1'b0,
    parameter logic [28:0] BASE_WORD = 29'h0581c000,
    parameter integer SLOT_COUNT = 64,
    parameter integer HEADER_WORDS64 = 8,
    parameter integer BARRIER_REPLACEMENT_WORD_OFFSET =
        HEADER_WORDS64 + SLOT_COUNT * 21,
    parameter integer POLL_BACKOFF_CYCLES = 64
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,

    input  logic        session_begin_valid,
    output logic        session_begin_ready,
    input  logic [31:0] session_begin_epoch,
    input  logic        session_epoch_fresh,
    input  logic        transport_quiescent,
    output logic        session_started,
    output logic        session_active,
    output logic [31:0] active_epoch,
    output logic [31:0] consumer_group_sequence,
    output logic [31:0] consumed_last_event_sequence,

    input  logic        request_valid,
    input  logic [31:0] request_epoch,
    input  logic [31:0] request_group_sequence,
    input  logic [63:0] request_processed_through,
    input  logic [63:0] request_run_safe_through,
    input  logic [31:0] request_event_high_water,
    input  logic [31:0] request_barrier_sequence,
    input  logic [31:0] request_source_sequence,
    input  logic [63:0] request_verified_producer_fence,
    input  logic [4:0]  request_reserved_event_count,
    input  logic        request_cpu_arm9,
    input  logic        request_read_not_write,
    input  logic [1:0]  request_access,
    input  logic [31:0] request_address,
    input  logic [31:0] request_write_data,
    input  logic [31:0] request_execution_pc,
    input  logic        requester_waitbus,
    output logic        request_ready,
    output logic        request_accepted,
    output logic        request_owned,

    input  logic        arm9_clean_boundary,
    input  logic        arm7_clean_boundary,
    input  logic        arm9_instruction_inflight,
    input  logic        arm7_instruction_inflight,
    input  logic        arm9_data_waitbus,
    input  logic        arm7_data_waitbus,
    input  logic        arm9_cycles_valid,
    input  logic [8:0]  arm9_normalized_cycles,
    input  logic        arm7_cycles_valid,
    input  logic [8:0]  arm7_normalized_cycles,
    input  logic        irq_quiet,
    input  logic [63:0] raw_producer_sequence,
    input  logic        pending_event_delivery,
    output logic        arm9_step_permit,
    output logic        arm7_step_permit,
    output logic        posted_admission_frozen,

    output logic        requester_done,
    output logic        requester_read_data_valid,
    output logic [31:0] requester_read_data,
    output logic        halt_arm9,
    output logic        halt_arm7,

    input  logic        irq_request,
    input  logic        irq_cpu_is_arm9,
    input  logic [31:0] irq_address,
    input  logic        irq_read_not_write,
    input  logic [1:0]  irq_access,
    input  logic [31:0] irq_write_data,
    output logic [31:0] irq_read_data,
    output logic        irq_done,
    input  logic [31:0] timer9_set_mask,
    input  logic [31:0] timer7_set_mask,
    output logic [31:0] arm9_if_state,
    output logic [31:0] arm7_if_state,
    output logic        irq_arm9,
    output logic        irq_arm7,
    output logic        arm7_wake,
    output logic        barrier_irq_write_applied,

    output logic        horizon_valid,
    output logic [63:0] processed_through,
    output logic [63:0] run_safe_through,
    output logic [63:0] arm9_normalized_timestamp,
    output logic [63:0] arm7_normalized_timestamp,
    output logic [63:0] shared_timestamp,
    output logic        group_retired,
    output logic [31:0] retired_group_sequence,

    input  logic [18:0] lw_reg_raddr,
    output logic [31:0] lw_reg_rdata,
    output logic        lw_reg_read_select,
    input  logic [18:0] lw_reg_waddr,
    input  logic [31:0] lw_reg_wdata,
    input  logic [3:0]  lw_reg_be,
    input  logic        lw_reg_write,
    output logic        lw_reg_write_select,
    output logic        work_pending_irq,

    output logic        protocol_error,
    output logic        ddram_read,
    output logic        ddram_write,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    output logic [63:0] ddram_write_data,
    output logic [7:0]  ddram_byte_enable,
    input  logic        ddram_busy,
    input  logic        ddram_command_accepted,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready
);
    logic blocking_transport_quiescent;
    logic refill_needed;
    logic freeze_requested;
    logic descriptor_valid;
    logic [31:0] descriptor_epoch;
    logic [31:0] descriptor_group_sequence;
    logic [63:0] descriptor_processed_through;
    logic [63:0] descriptor_run_safe_through;
    logic [31:0] descriptor_event_high_water;
    logic [31:0] descriptor_barrier_sequence;
    logic [31:0] descriptor_source_sequence;
    logic [63:0] descriptor_verified_producer_fence;
    logic [4:0] descriptor_reserved_event_count;
    logic descriptor_cpu_arm9;
    logic descriptor_read_not_write;
    logic [1:0] descriptor_access;
    logic [31:0] descriptor_address;
    logic [31:0] descriptor_write_data;
    logic [31:0] descriptor_execution_pc;
    logic [63:0] descriptor_arm9_timestamp;
    logic [63:0] descriptor_arm7_timestamp;
    logic [63:0] descriptor_required_run_safe_through;

    logic completion_valid;
    logic [31:0] completion_epoch;
    logic [31:0] completion_replaces_group_sequence;
    logic [31:0] completion_barrier_sequence;
    logic [31:0] completion_source_sequence;
    logic [63:0] completion_verified_producer_fence;
    logic completion_cpu_arm9;
    logic completion_halt_arm9;
    logic completion_halt_arm7;
    logic [31:0] completion_read_data;
    logic completion_ready;
    logic completion_accepted;
    logic path_protocol_error;
    logic seam_protocol_error;
    logic [19:0] stop_debug_status;
    logic unused_replacement_expected;
    logic unused_replacement_applied;
    logic unused_group_final_verified;

    assign protocol_error = ENABLED &&
        (path_protocol_error || seam_protocol_error);

    nds_hps_external_time_window_lw_seam #(.ENABLED(ENABLED)) lw_seam (
        .clk, .reset, .enable,
        .session_active, .active_epoch,
        .refill_needed, .freeze_requested, .descriptor_valid,
        .requester_owned(request_owned),
        .path_protocol_error(path_protocol_error),
        .stop_debug_status,
        .snapshot_epoch(descriptor_epoch),
        .snapshot_group_sequence(descriptor_group_sequence),
        .snapshot_processed_through(descriptor_processed_through),
        .snapshot_run_safe_through(descriptor_run_safe_through),
        .snapshot_event_high_water(descriptor_event_high_water),
        .snapshot_barrier_sequence(descriptor_barrier_sequence),
        .snapshot_source_sequence(descriptor_source_sequence),
        .snapshot_verified_producer_fence(
            descriptor_verified_producer_fence),
        .snapshot_reserved_event_count(descriptor_reserved_event_count),
        .snapshot_cpu_arm9(descriptor_cpu_arm9),
        .snapshot_read_not_write(descriptor_read_not_write),
        .snapshot_access(descriptor_access),
        .snapshot_address(descriptor_address),
        .snapshot_write_data(descriptor_write_data),
        .snapshot_execution_pc(descriptor_execution_pc),
        .snapshot_arm9_timestamp(descriptor_arm9_timestamp),
        .snapshot_arm7_timestamp(descriptor_arm7_timestamp),
        .snapshot_required_run_safe_through(
            descriptor_required_run_safe_through),
        .blocking_transport_quiescent,
        .posted_admission_frozen, .work_pending_irq,
        .completion_valid, .completion_epoch,
        .completion_replaces_group_sequence,
        .completion_barrier_sequence, .completion_source_sequence,
        .completion_verified_producer_fence, .completion_cpu_arm9,
        .completion_halt_arm9, .completion_halt_arm7,
        .completion_read_data, .completion_ready, .completion_accepted,
        .requester_done,
        .reg_raddr(lw_reg_raddr), .reg_rdata(lw_reg_rdata),
        .reg_read_select(lw_reg_read_select),
        .reg_waddr(lw_reg_waddr), .reg_wdata(lw_reg_wdata),
        .reg_be(lw_reg_be), .reg_write(lw_reg_write),
        .reg_write_select(lw_reg_write_select),
        .protocol_error(seam_protocol_error)
    );

    nds_hps_external_time_window_blocking_path #(
        .ENABLED(ENABLED), .BASE_WORD(BASE_WORD),
        .SLOT_COUNT(SLOT_COUNT), .HEADER_WORDS64(HEADER_WORDS64),
        .BARRIER_REPLACEMENT_WORD_OFFSET(
            BARRIER_REPLACEMENT_WORD_OFFSET),
        .POLL_BACKOFF_CYCLES(POLL_BACKOFF_CYCLES)
    ) blocking_path (
        .clk, .reset, .enable,
        .session_begin_valid, .session_begin_ready, .session_begin_epoch,
        .session_epoch_fresh, .transport_quiescent,
        .session_started, .session_active, .active_epoch,
        .consumer_group_sequence, .consumed_last_event_sequence,
        .blocking_transport_quiescent,
        .request_valid(request_valid && !seam_protocol_error),
        .request_epoch, .request_group_sequence,
        .request_processed_through, .request_run_safe_through,
        .request_event_high_water, .request_barrier_sequence,
        .request_source_sequence, .request_verified_producer_fence,
        .request_reserved_event_count, .request_cpu_arm9,
        .request_read_not_write, .request_access, .request_address,
        .request_write_data, .request_execution_pc, .requester_waitbus,
        .request_ready, .request_accepted, .request_owned,
        .refill_needed, .freeze_requested, .descriptor_valid,
        .descriptor_epoch, .descriptor_group_sequence,
        .descriptor_processed_through, .descriptor_run_safe_through,
        .descriptor_event_high_water, .descriptor_barrier_sequence,
        .descriptor_source_sequence,
        .descriptor_verified_producer_fence,
        .descriptor_reserved_event_count, .descriptor_cpu_arm9,
        .descriptor_read_not_write, .descriptor_access,
        .descriptor_address, .descriptor_write_data,
        .descriptor_execution_pc, .descriptor_arm9_timestamp,
        .descriptor_arm7_timestamp,
        .descriptor_required_run_safe_through,
        .arm9_clean_boundary, .arm7_clean_boundary,
        .arm9_instruction_inflight, .arm7_instruction_inflight,
        .arm9_data_waitbus, .arm7_data_waitbus,
        .arm9_cycles_valid, .arm9_normalized_cycles,
        .arm7_cycles_valid, .arm7_normalized_cycles,
        .irq_quiet, .posted_admission_frozen, .raw_producer_sequence,
        .pending_event_delivery,
        .arm9_step_permit, .arm7_step_permit, .quiescent_ack(),
        .stop_debug_status,
        .completion_valid, .completion_epoch,
        .completion_replaces_group_sequence,
        .completion_barrier_sequence, .completion_source_sequence,
        .completion_verified_producer_fence, .completion_cpu_arm9,
        .completion_halt_arm9, .completion_halt_arm7,
        .completion_read_data, .completion_ready, .completion_accepted,
        .requester_done, .requester_read_data_valid,
        .requester_read_data, .halt_arm9, .halt_arm7,
        .irq_request, .irq_cpu_is_arm9, .irq_address,
        .irq_read_not_write, .irq_access, .irq_write_data,
        .irq_read_data, .irq_done, .timer9_set_mask, .timer7_set_mask,
        .arm9_if_state, .arm7_if_state, .irq_arm9, .irq_arm7,
        .arm7_wake,
        .barrier_irq_write_applied,
        .horizon_valid, .processed_through, .run_safe_through,
        .arm9_normalized_timestamp, .arm7_normalized_timestamp,
        .shared_timestamp,
        .replacement_expected(unused_replacement_expected),
        .replacement_applied(unused_replacement_applied),
        .group_final_verified(unused_group_final_verified),
        .group_retired, .retired_group_sequence,
        .protocol_error(path_protocol_error),
        .ddram_read, .ddram_write, .ddram_burst_count, .ddram_address,
        .ddram_write_data, .ddram_byte_enable, .ddram_busy,
        .ddram_command_accepted, .ddram_read_data,
        .ddram_read_data_ready
    );
endmodule

`default_nettype wire
