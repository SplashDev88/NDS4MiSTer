// Default-off external-time-window DDR consumer with exact blocking-MMIO
// barrier replacement support.
//
// The ordinary ETWQ record remains the original 21-word ABI.  A replacement
// has a matching nine-word BRRP sidecar in a disjoint physical ring:
//
//   +0 {32'h42525250, 16'd0, reserved_count[7:0], count[7:0]}
//   +1 {barrier_sequence, active_grant_group_sequence}
//   +2 {32'd0, source_sequence}
//   +3 verified_producer_fence[63:0]
//   +4 B
//   +5 {replacement_last_event_sequence, prior_event_high_water}
//   +6 {epoch, 31'd0, requester_arm9}
//   +7 required_run_safe_through[63:0]
//   +8 {epoch, replacement_group_sequence} (sidecar commit)
//
// The producer makes the sidecar commit visible before the unchanged ordinary
// group commit.  replacement_expected is the independent immutable admission
// proof which makes a missing sidecar distinguishable from a legal ordinary
// group.  Every ordinary and sidecar payload word is acquired twice before
// any grant/event output, both commits and the descriptor are rechecked, and
// both complete payloads are compared again before final_verified.  The
// sidecar and ordinary commits are cleared only after final_verified is
// accepted.  The consumer ACK is written last, then read back and matched
// exactly before retirement is exposed.  ENABLED defaults to zero and this
// module is intentionally absent from the production top/QSF.

`timescale 1ns/1ps
`default_nettype none

module nds_hps_external_time_window_barrier_ddr_ring #(
    parameter bit          ENABLED = 1'b0,
    parameter logic [28:0] BASE_WORD = 29'h0581c000,
    parameter integer      SLOT_COUNT = 64,
    parameter integer      HEADER_WORDS64 = 8,
    parameter integer      CONSUMER_WORD_OFFSET = 0,
    parameter integer      DESCRIPTOR_WORD_OFFSET = 1,
    parameter integer      BARRIER_REPLACEMENT_WORD_OFFSET =
        HEADER_WORDS64 + SLOT_COUNT * 21,
    parameter integer      POLL_BACKOFF_CYCLES = 64
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

    // Exact immutable admission descriptor for the next group.  It must stay
    // stable from ordinary-commit observation through final verification.
    input  logic        replacement_expected,
    input  logic [31:0] expected_active_grant_group_sequence,
    input  logic [31:0] expected_barrier_sequence,
    input  logic [31:0] expected_source_sequence,
    input  logic [63:0] expected_verified_producer_fence,
    input  logic [63:0] expected_barrier_timestamp,
    input  logic [31:0] expected_prior_event_high_water,
    input  logic [4:0]  expected_event_count,
    input  logic        expected_requester_arm9,
    input  logic [63:0] expected_required_run_safe_through,

    output logic        grant_valid,
    input  logic        grant_ready,
    output logic [31:0] grant_epoch,
    output logic [31:0] grant_group_sequence,
    output logic [63:0] grant_processed_through,
    output logic [63:0] grant_run_safe_through,
    output logic [31:0] grant_last_event_sequence,
    output logic [4:0]  grant_event_count,
    output logic        grant_replaces_barrier,
    output logic [31:0] replacement_active_grant_group_sequence,
    output logic [31:0] replacement_barrier_sequence,
    output logic [31:0] replacement_source_sequence,
    output logic [63:0] replacement_verified_producer_fence,
    output logic [63:0] replacement_barrier_timestamp,
    output logic [31:0] replacement_prior_event_high_water,
    output logic [4:0]  replacement_reserved_event_count,
    output logic        replacement_requester_arm9,
    output logic [63:0] replacement_required_run_safe_through,
    output logic [31:0] replacement_group_sequence,

    output logic        event_valid,
    input  logic        event_ready,
    output logic [31:0] event_epoch,
    output logic [31:0] event_group_sequence,
    output logic [63:0] event_timestamp,
    output logic [31:0] event_sequence,
    output logic        event_cpu_arm9,
    output logic        event_set,
    output logic [31:0] event_mask,

    output logic        final_verified_valid,
    input  logic        final_verified_ready,
    output logic [31:0] final_verified_epoch,
    output logic [31:0] final_verified_group_sequence,
    output logic        group_final_verified,
    output logic [31:0] verified_group_sequence,

    output logic        group_retired,
    output logic [31:0] retired_epoch,
    output logic [31:0] retired_group_sequence,

    output logic        active,
    output logic        ddram_active,
    output logic        sequence_exhausted,
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
    localparam logic [31:0] DESCRIPTOR_MAGIC = 32'h45545751;
    localparam logic [31:0] REPLACEMENT_MAGIC = 32'h42525250;
    localparam integer ORDINARY_SLOT_WORDS = 21;
    localparam integer ORDINARY_PAYLOAD_WORDS = 20;
    localparam integer REPLACEMENT_SLOT_WORDS = 9;
    localparam integer REPLACEMENT_PAYLOAD_WORDS = 8;
    localparam integer MAX_EVENTS = 16;
    localparam integer SLOT_INDEX_BITS =
        SLOT_COUNT <= 2 ? 1 : $clog2(SLOT_COUNT);
    localparam integer SCAN_INDEX_BITS = SLOT_INDEX_BITS;
    localparam logic [28:0] HEADER_OFFSET = 29'(HEADER_WORDS64);
    localparam logic [28:0] CONSUMER_OFFSET =
        29'(CONSUMER_WORD_OFFSET);
    localparam logic [28:0] DESCRIPTOR_OFFSET =
        29'(DESCRIPTOR_WORD_OFFSET);
    localparam logic [28:0] REPLACEMENT_OFFSET =
        29'(BARRIER_REPLACEMENT_WORD_OFFSET);
    localparam logic [63:0] MAPPING_END = {35'd0, BASE_WORD} +
        64'(BARRIER_REPLACEMENT_WORD_OFFSET) +
        64'(SLOT_COUNT * REPLACEMENT_SLOT_WORDS);

    typedef enum logic [6:0] {
        ST_IDLE,
        ST_READ_DESCRIPTOR_ISSUE,
        ST_READ_DESCRIPTOR_WAIT,
        ST_SCAN_ORDINARY_ISSUE,
        ST_SCAN_ORDINARY_WAIT,
        ST_SCAN_SIDECAR_ISSUE,
        ST_SCAN_SIDECAR_WAIT,
        ST_RECHECK_SESSION_DESCRIPTOR_ISSUE,
        ST_RECHECK_SESSION_DESCRIPTOR_WAIT,
        ST_WRITE_INITIAL_CONSUMER,
        ST_POLL_BACKOFF,
        ST_POLL_ORDINARY_COMMIT_ISSUE,
        ST_POLL_ORDINARY_COMMIT_WAIT,
        ST_READ_SIDECAR_COMMIT1_ISSUE,
        ST_READ_SIDECAR_COMMIT1_WAIT,
        ST_READ_ORDINARY_PAYLOAD_ISSUE,
        ST_READ_ORDINARY_PAYLOAD_WAIT,
        ST_READ_ORDINARY_PAYLOAD2_ISSUE,
        ST_READ_ORDINARY_PAYLOAD2_WAIT,
        ST_READ_SIDECAR_PAYLOAD1_ISSUE,
        ST_READ_SIDECAR_PAYLOAD1_WAIT,
        ST_READ_SIDECAR_COMMIT2_ISSUE,
        ST_READ_SIDECAR_COMMIT2_WAIT,
        ST_READ_SIDECAR_PAYLOAD2_ISSUE,
        ST_READ_SIDECAR_PAYLOAD2_WAIT,
        ST_READ_SIDECAR_COMMIT3_ISSUE,
        ST_READ_SIDECAR_COMMIT3_WAIT,
        ST_RECHECK_ORDINARY_COMMIT_ISSUE,
        ST_RECHECK_ORDINARY_COMMIT_WAIT,
        ST_RECHECK_GROUP_DESCRIPTOR_ISSUE,
        ST_RECHECK_GROUP_DESCRIPTOR_WAIT,
        ST_GRANT_OUTPUT_WAIT,
        ST_EVENT_OUTPUT_WAIT,
        ST_FINAL_SIDECAR_COMMIT1_ISSUE,
        ST_FINAL_SIDECAR_COMMIT1_WAIT,
        ST_FINAL_SIDECAR_PAYLOAD_ISSUE,
        ST_FINAL_SIDECAR_PAYLOAD_WAIT,
        ST_FINAL_SIDECAR_COMMIT2_ISSUE,
        ST_FINAL_SIDECAR_COMMIT2_WAIT,
        ST_FINAL_ORDINARY_PAYLOAD_ISSUE,
        ST_FINAL_ORDINARY_PAYLOAD_WAIT,
        ST_FINAL_ORDINARY_COMMIT_ISSUE,
        ST_FINAL_ORDINARY_COMMIT_WAIT,
        ST_FINAL_DESCRIPTOR_ISSUE,
        ST_FINAL_DESCRIPTOR_WAIT,
        ST_FINAL_VERIFIED_OUTPUT_WAIT,
        ST_CLEAR_SIDECAR_LOW,
        ST_CLEAR_SIDECAR_HIGH,
        ST_VERIFY_SIDECAR_CLEAR_ISSUE,
        ST_VERIFY_SIDECAR_CLEAR_WAIT,
        ST_CLEAR_ORDINARY_LOW,
        ST_CLEAR_ORDINARY_HIGH,
        ST_VERIFY_ORDINARY_CLEAR_ISSUE,
        ST_VERIFY_ORDINARY_CLEAR_WAIT,
        ST_WRITE_CONSUMER,
        ST_VERIFY_CONSUMER_ACK_ISSUE,
        ST_VERIFY_CONSUMER_ACK_WAIT,
        ST_FAULT
    } state_t;

    state_t state;
    logic [31:0] requested_epoch;
    logic [31:0] last_epoch;
    logic [31:0] expected_group_sequence;
    logic [31:0] poll_backoff_count;
    logic [SCAN_INDEX_BITS-1:0] scan_index;
    logic [4:0] ordinary_payload_index;
    logic [3:0] sidecar_payload_index;
    logic [4:0] output_event_index;
    logic [63:0] saved_ordinary_commit;
    logic [63:0] saved_sidecar_commit;
    logic [63:0] ordinary_payload [0:ORDINARY_PAYLOAD_WORDS-1];
    logic [63:0] sidecar_payload [0:REPLACEMENT_PAYLOAD_WORDS-1];
    logic buffered_read_valid;
    logic [63:0] buffered_read_data;
    logic [63:0] processed_high_water;
    logic [63:0] run_safe_high_water;
    logic have_high_water;
    logic [31:0] last_barrier_sequence;
    logic [31:0] last_barrier_source_sequence;
    logic [63:0] last_verified_producer_fence;
    logic replacement_mode;

    logic expected_replacement_r;
    logic [31:0] expected_active_group_r;
    logic [31:0] expected_barrier_sequence_r;
    logic [31:0] expected_source_sequence_r;
    logic [63:0] expected_fence_r;
    logic [63:0] expected_b_r;
    logic [31:0] expected_prior_event_r;
    logic [4:0] expected_count_r;
    logic expected_requester_arm9_r;
    logic [63:0] expected_required_run_safe_through_r;

    logic [28:0] scan_ordinary_base;
    logic [28:0] scan_sidecar_base;
    logic [28:0] expected_ordinary_base;
    logic [28:0] expected_sidecar_base;
    logic read_response_valid;
    logic [63:0] read_response_data;
    logic effective_enable;
    logic decoded_common_valid;
    logic decoded_ordinary_valid;
    logic decoded_replacement_valid;
    logic expected_descriptor_stable;
    logic [7:0] decoded_event_count;
    logic [31:0] decoded_last_event_sequence;
    logic [31:0] decoded_event_delta;
    logic [31:0] decoded_control_bitmap;
    integer validation_index;
    integer reset_index;

    function automatic logic [28:0] ordinary_base_for(
        input logic [31:0] sequence_value);
        logic [SLOT_INDEX_BITS-1:0] slot;
        begin
            slot = sequence_value[SLOT_INDEX_BITS-1:0] - 1'b1;
            ordinary_base_for = BASE_WORD + HEADER_OFFSET +
                29'(slot) * 29'(ORDINARY_SLOT_WORDS);
        end
    endfunction

    function automatic logic [28:0] sidecar_base_for(
        input logic [31:0] sequence_value);
        logic [SLOT_INDEX_BITS-1:0] slot;
        begin
            slot = sequence_value[SLOT_INDEX_BITS-1:0] - 1'b1;
            sidecar_base_for = BASE_WORD + REPLACEMENT_OFFSET +
                29'(slot) * 29'(REPLACEMENT_SLOT_WORDS);
        end
    endfunction

    initial begin
        if (SLOT_COUNT < 2 ||
            (SLOT_COUNT & (SLOT_COUNT - 1)) != 0)
            $fatal(1, "BRRP SLOT_COUNT must be power of two >= 2");
        if (HEADER_WORDS64 < 2 || CONSUMER_WORD_OFFSET < 0 ||
            CONSUMER_WORD_OFFSET >= HEADER_WORDS64 ||
            DESCRIPTOR_WORD_OFFSET < 0 ||
            DESCRIPTOR_WORD_OFFSET >= HEADER_WORDS64 ||
            CONSUMER_WORD_OFFSET == DESCRIPTOR_WORD_OFFSET)
            $fatal(1, "BRRP header layout is invalid");
        if (BARRIER_REPLACEMENT_WORD_OFFSET <
            HEADER_WORDS64 + SLOT_COUNT * ORDINARY_SLOT_WORDS)
            $fatal(1, "BRRP sidecar overlaps ordinary ETWQ ring");
        if (MAPPING_END > 64'd536870912)
            $fatal(1, "BRRP mapping exceeds DDR word address space");
    end

    always_comb begin
        effective_enable = ENABLED && enable;
        scan_ordinary_base = BASE_WORD + HEADER_OFFSET +
            29'(scan_index) * 29'(ORDINARY_SLOT_WORDS);
        scan_sidecar_base = BASE_WORD + REPLACEMENT_OFFSET +
            29'(scan_index) * 29'(REPLACEMENT_SLOT_WORDS);
        expected_ordinary_base = ordinary_base_for(expected_group_sequence);
        expected_sidecar_base = sidecar_base_for(expected_group_sequence);

        decoded_event_count = ordinary_payload[2][7:0];
        decoded_last_event_sequence = ordinary_payload[2][63:32];
        decoded_event_delta = decoded_last_event_sequence -
            consumed_last_event_sequence;
        decoded_control_bitmap = ordinary_payload[3][31:0];

        expected_descriptor_stable =
            replacement_expected == expected_replacement_r;
        if (expected_replacement_r) begin
            expected_descriptor_stable &=
                expected_active_grant_group_sequence ==
                    expected_active_group_r &&
                expected_barrier_sequence ==
                    expected_barrier_sequence_r &&
                expected_source_sequence == expected_source_sequence_r &&
                expected_verified_producer_fence == expected_fence_r &&
                expected_barrier_timestamp == expected_b_r &&
                expected_prior_event_high_water ==
                    expected_prior_event_r &&
                expected_event_count == expected_count_r &&
                expected_requester_arm9 == expected_requester_arm9_r &&
                expected_required_run_safe_through ==
                    expected_required_run_safe_through_r;
        end

        decoded_common_valid =
            saved_ordinary_commit ==
                {active_epoch, expected_group_sequence} &&
            expected_group_sequence != 0 &&
            ordinary_payload[2][31:8] == 0 &&
            ordinary_payload[3][63:32] == 0 &&
            decoded_event_count <= MAX_EVENTS &&
            ordinary_payload[1] >= ordinary_payload[0] &&
            decoded_last_event_sequence >=
                consumed_last_event_sequence &&
            consumed_last_event_sequence <=
                32'hffffffff - decoded_event_count &&
            decoded_event_delta == decoded_event_count;
        if (decoded_event_count != 0)
            decoded_common_valid &= decoded_last_event_sequence != 0;

        for (validation_index = 0;
             validation_index < MAX_EVENTS;
             validation_index = validation_index + 1) begin
            if (validation_index < decoded_event_count) begin
                decoded_common_valid &=
                    ordinary_payload[validation_index + 4][63:32] != 0 &&
                    ordinary_payload[validation_index + 4][31:0] != 0 &&
                    ordinary_payload[validation_index + 4][31:0] ==
                        consumed_last_event_sequence +
                        validation_index + 1;
            end else begin
                decoded_common_valid &=
                    ordinary_payload[validation_index + 4] == 0 &&
                    decoded_control_bitmap[
                        validation_index * 2 +: 2] == 0;
            end
        end

        decoded_ordinary_valid = decoded_common_valid &&
            !replacement_mode && !expected_replacement_r;
        if (have_high_water) begin
            decoded_ordinary_valid &=
                ordinary_payload[0] >= processed_high_water &&
                ordinary_payload[1] >= run_safe_high_water &&
                (ordinary_payload[0] > processed_high_water ||
                 ordinary_payload[1] > run_safe_high_water);
            if (decoded_event_count != 0)
                decoded_ordinary_valid &=
                    ordinary_payload[0] > run_safe_high_water;
        end

        decoded_replacement_valid = decoded_common_valid &&
            replacement_mode && expected_replacement_r &&
            expected_descriptor_stable && have_high_water &&
            expected_active_group_r == consumer_group_sequence &&
            expected_prior_event_r == consumed_last_event_sequence &&
            expected_count_r <= MAX_EVENTS &&
            expected_barrier_sequence_r != 0 &&
            last_barrier_sequence != 32'hffffffff &&
            expected_barrier_sequence_r == last_barrier_sequence + 1'b1 &&
            expected_source_sequence_r != 0 &&
            expected_source_sequence_r > last_barrier_source_sequence &&
            expected_fence_r >= {32'd0, expected_source_sequence_r} &&
            expected_fence_r >= last_verified_producer_fence &&
            expected_b_r >= processed_high_water &&
            expected_b_r <= run_safe_high_water &&
            expected_required_run_safe_through_r >= expected_b_r &&
            ordinary_payload[0] == expected_b_r &&
            ordinary_payload[1] >= expected_b_r &&
            decoded_event_count <= {3'd0, expected_count_r} &&
            sidecar_payload[0][63:32] == REPLACEMENT_MAGIC &&
            sidecar_payload[0][31:16] == 0 &&
            sidecar_payload[0][15:8] == {3'd0, expected_count_r} &&
            sidecar_payload[0][7:0] == decoded_event_count &&
            sidecar_payload[1] ==
                {expected_barrier_sequence_r, expected_active_group_r} &&
            sidecar_payload[2] == {32'd0, expected_source_sequence_r} &&
            sidecar_payload[3] == expected_fence_r &&
            sidecar_payload[4] == expected_b_r &&
            sidecar_payload[5] ==
                {decoded_last_event_sequence, expected_prior_event_r} &&
            sidecar_payload[6] ==
                {active_epoch, 31'd0, expected_requester_arm9_r} &&
            sidecar_payload[7] ==
                expected_required_run_safe_through_r &&
            decoded_last_event_sequence ==
                expected_prior_event_r + decoded_event_count;

        session_begin_ready = effective_enable && state == ST_IDLE &&
            !session_active && transport_quiescent &&
            session_epoch_fresh && !protocol_error &&
            !sequence_exhausted;
        active = effective_enable && state != ST_IDLE &&
            state != ST_FAULT;
        ddram_active = active && state != ST_POLL_BACKOFF &&
            state != ST_GRANT_OUTPUT_WAIT &&
            state != ST_EVENT_OUTPUT_WAIT &&
            state != ST_FINAL_VERIFIED_OUTPUT_WAIT;

        ddram_read = 1'b0;
        ddram_write = 1'b0;
        ddram_burst_count = 8'd1;
        ddram_address = BASE_WORD;
        ddram_write_data = 64'd0;
        ddram_byte_enable = 8'hff;
        read_response_valid = buffered_read_valid ||
            ddram_read_data_ready;
        read_response_data = buffered_read_valid
            ? buffered_read_data : ddram_read_data;

        case (state)
            ST_READ_DESCRIPTOR_ISSUE,
            ST_RECHECK_SESSION_DESCRIPTOR_ISSUE,
            ST_RECHECK_GROUP_DESCRIPTOR_ISSUE,
            ST_FINAL_DESCRIPTOR_ISSUE: begin
                ddram_address = BASE_WORD + DESCRIPTOR_OFFSET;
                ddram_read = 1'b1;
            end
            ST_SCAN_ORDINARY_ISSUE: begin
                ddram_address = scan_ordinary_base + 29'd20;
                ddram_read = 1'b1;
            end
            ST_SCAN_SIDECAR_ISSUE: begin
                ddram_address = scan_sidecar_base + 29'd8;
                ddram_read = 1'b1;
            end
            ST_POLL_ORDINARY_COMMIT_ISSUE,
            ST_RECHECK_ORDINARY_COMMIT_ISSUE,
            ST_FINAL_ORDINARY_COMMIT_ISSUE,
            ST_VERIFY_ORDINARY_CLEAR_ISSUE: begin
                ddram_address = expected_ordinary_base + 29'd20;
                ddram_read = 1'b1;
            end
            ST_READ_SIDECAR_COMMIT1_ISSUE,
            ST_READ_SIDECAR_COMMIT2_ISSUE,
            ST_READ_SIDECAR_COMMIT3_ISSUE,
            ST_FINAL_SIDECAR_COMMIT1_ISSUE,
            ST_FINAL_SIDECAR_COMMIT2_ISSUE,
            ST_VERIFY_SIDECAR_CLEAR_ISSUE: begin
                ddram_address = expected_sidecar_base + 29'd8;
                ddram_read = 1'b1;
            end
            ST_READ_ORDINARY_PAYLOAD_ISSUE,
            ST_READ_ORDINARY_PAYLOAD2_ISSUE,
            ST_FINAL_ORDINARY_PAYLOAD_ISSUE: begin
                ddram_address = expected_ordinary_base +
                    29'(ordinary_payload_index);
                ddram_read = 1'b1;
            end
            ST_READ_SIDECAR_PAYLOAD1_ISSUE,
            ST_READ_SIDECAR_PAYLOAD2_ISSUE,
            ST_FINAL_SIDECAR_PAYLOAD_ISSUE: begin
                ddram_address = expected_sidecar_base +
                    29'(sidecar_payload_index);
                ddram_read = 1'b1;
            end
            ST_WRITE_INITIAL_CONSUMER: begin
                ddram_address = BASE_WORD + CONSUMER_OFFSET;
                ddram_write_data = {requested_epoch, 32'd0};
                ddram_write = 1'b1;
            end
            ST_CLEAR_SIDECAR_LOW: begin
                ddram_address = expected_sidecar_base + 29'd8;
                ddram_byte_enable = 8'h0f;
                ddram_write = 1'b1;
            end
            ST_CLEAR_SIDECAR_HIGH: begin
                ddram_address = expected_sidecar_base + 29'd8;
                ddram_byte_enable = 8'hf0;
                ddram_write = 1'b1;
            end
            ST_CLEAR_ORDINARY_LOW: begin
                ddram_address = expected_ordinary_base + 29'd20;
                ddram_byte_enable = 8'h0f;
                ddram_write = 1'b1;
            end
            ST_CLEAR_ORDINARY_HIGH: begin
                ddram_address = expected_ordinary_base + 29'd20;
                ddram_byte_enable = 8'hf0;
                ddram_write = 1'b1;
            end
            ST_WRITE_CONSUMER: begin
                ddram_address = BASE_WORD + CONSUMER_OFFSET;
                ddram_write_data =
                    {active_epoch, expected_group_sequence};
                ddram_write = 1'b1;
            end
            ST_VERIFY_CONSUMER_ACK_ISSUE: begin
                ddram_address = BASE_WORD + CONSUMER_OFFSET;
                ddram_read = 1'b1;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= ST_IDLE;
            requested_epoch <= 32'd0;
            last_epoch <= 32'd0;
            expected_group_sequence <= 32'd1;
            poll_backoff_count <= 32'd0;
            scan_index <= '0;
            ordinary_payload_index <= 5'd0;
            sidecar_payload_index <= 4'd0;
            output_event_index <= 5'd0;
            saved_ordinary_commit <= 64'd0;
            saved_sidecar_commit <= 64'd0;
            for (reset_index = 0;
                 reset_index < ORDINARY_PAYLOAD_WORDS;
                 reset_index = reset_index + 1)
                ordinary_payload[reset_index] <= 64'd0;
            for (reset_index = 0;
                 reset_index < REPLACEMENT_PAYLOAD_WORDS;
                 reset_index = reset_index + 1)
                sidecar_payload[reset_index] <= 64'd0;
            buffered_read_valid <= 1'b0;
            buffered_read_data <= 64'd0;
            processed_high_water <= 64'd0;
            run_safe_high_water <= 64'd0;
            have_high_water <= 1'b0;
            last_barrier_sequence <= 32'd0;
            last_barrier_source_sequence <= 32'd0;
            last_verified_producer_fence <= 64'd0;
            replacement_mode <= 1'b0;
            expected_replacement_r <= 1'b0;
            expected_active_group_r <= 32'd0;
            expected_barrier_sequence_r <= 32'd0;
            expected_source_sequence_r <= 32'd0;
            expected_fence_r <= 64'd0;
            expected_b_r <= 64'd0;
            expected_prior_event_r <= 32'd0;
            expected_count_r <= 5'd0;
            expected_requester_arm9_r <= 1'b0;
            expected_required_run_safe_through_r <= 64'd0;
            session_started <= 1'b0;
            session_active <= 1'b0;
            active_epoch <= 32'd0;
            consumer_group_sequence <= 32'd0;
            consumed_last_event_sequence <= 32'd0;
            grant_valid <= 1'b0;
            grant_epoch <= 32'd0;
            grant_group_sequence <= 32'd0;
            grant_processed_through <= 64'd0;
            grant_run_safe_through <= 64'd0;
            grant_last_event_sequence <= 32'd0;
            grant_event_count <= 5'd0;
            grant_replaces_barrier <= 1'b0;
            replacement_active_grant_group_sequence <= 32'd0;
            replacement_barrier_sequence <= 32'd0;
            replacement_source_sequence <= 32'd0;
            replacement_verified_producer_fence <= 64'd0;
            replacement_barrier_timestamp <= 64'd0;
            replacement_prior_event_high_water <= 32'd0;
            replacement_reserved_event_count <= 5'd0;
            replacement_requester_arm9 <= 1'b0;
            replacement_required_run_safe_through <= 64'd0;
            replacement_group_sequence <= 32'd0;
            event_valid <= 1'b0;
            event_epoch <= 32'd0;
            event_group_sequence <= 32'd0;
            event_timestamp <= 64'd0;
            event_sequence <= 32'd0;
            event_cpu_arm9 <= 1'b0;
            event_set <= 1'b0;
            event_mask <= 32'd0;
            final_verified_valid <= 1'b0;
            final_verified_epoch <= 32'd0;
            final_verified_group_sequence <= 32'd0;
            group_final_verified <= 1'b0;
            verified_group_sequence <= 32'd0;
            group_retired <= 1'b0;
            retired_epoch <= 32'd0;
            retired_group_sequence <= 32'd0;
            sequence_exhausted <= 1'b0;
            protocol_error <= 1'b0;
        end else if (!ENABLED) begin
            state <= ST_IDLE;
            session_started <= 1'b0;
            session_active <= 1'b0;
            grant_valid <= 1'b0;
            event_valid <= 1'b0;
            final_verified_valid <= 1'b0;
            group_final_verified <= 1'b0;
            group_retired <= 1'b0;
            buffered_read_valid <= 1'b0;
            protocol_error <= 1'b0;
        end else if (!enable) begin
            if (state != ST_IDLE || session_active)
                protocol_error <= 1'b1;
            if (protocol_error || state != ST_IDLE || session_active)
                state <= ST_FAULT;
            else
                state <= ST_IDLE;
            session_started <= 1'b0;
            session_active <= 1'b0;
            grant_valid <= 1'b0;
            event_valid <= 1'b0;
            final_verified_valid <= 1'b0;
            group_final_verified <= 1'b0;
            group_retired <= 1'b0;
            buffered_read_valid <= 1'b0;
        end else if (protocol_error) begin
            state <= ST_FAULT;
            session_started <= 1'b0;
            session_active <= 1'b0;
            grant_valid <= 1'b0;
            event_valid <= 1'b0;
            final_verified_valid <= 1'b0;
            group_final_verified <= 1'b0;
            group_retired <= 1'b0;
            buffered_read_valid <= 1'b0;
        end else begin
            session_started <= 1'b0;
            group_final_verified <= 1'b0;
            group_retired <= 1'b0;

            if (ddram_command_accepted && ddram_read &&
                ddram_read_data_ready) begin
                buffered_read_valid <= 1'b1;
                buffered_read_data <= ddram_read_data;
            end

            case (state)
                ST_IDLE: begin
                    if (session_begin_valid && session_begin_ready) begin
                        if (session_begin_epoch == 0 ||
                            session_begin_epoch == last_epoch) begin
                            protocol_error <= 1'b1;
                            state <= ST_FAULT;
                        end else begin
                            requested_epoch <= session_begin_epoch;
                            scan_index <= '0;
                            state <= ST_READ_DESCRIPTOR_ISSUE;
                        end
                    end
                end
                ST_READ_DESCRIPTOR_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_READ_DESCRIPTOR_WAIT;
                ST_READ_DESCRIPTOR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data[31:0] == 0) begin
                            state <= ST_READ_DESCRIPTOR_ISSUE;
                        end else if (read_response_data ==
                            {DESCRIPTOR_MAGIC, requested_epoch}) begin
                            scan_index <= '0;
                            state <= ST_SCAN_ORDINARY_ISSUE;
                        end else begin
                            protocol_error <= 1'b1;
                            state <= ST_FAULT;
                        end
                    end
                ST_SCAN_ORDINARY_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_SCAN_ORDINARY_WAIT;
                ST_SCAN_ORDINARY_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != 0) begin
                            protocol_error <= 1'b1;
                            state <= ST_FAULT;
                        end else begin
                            state <= ST_SCAN_SIDECAR_ISSUE;
                        end
                    end
                ST_SCAN_SIDECAR_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_SCAN_SIDECAR_WAIT;
                ST_SCAN_SIDECAR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != 0) begin
                            protocol_error <= 1'b1;
                            state <= ST_FAULT;
                        end else if (scan_index == SLOT_COUNT - 1) begin
                            state <=
                                ST_RECHECK_SESSION_DESCRIPTOR_ISSUE;
                        end else begin
                            scan_index <= scan_index + 1'b1;
                            state <= ST_SCAN_ORDINARY_ISSUE;
                        end
                    end
                ST_RECHECK_SESSION_DESCRIPTOR_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_RECHECK_SESSION_DESCRIPTOR_WAIT;
                ST_RECHECK_SESSION_DESCRIPTOR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                            {DESCRIPTOR_MAGIC, requested_epoch}) begin
                            protocol_error <= 1'b1;
                            state <= ST_FAULT;
                        end else begin
                            state <= ST_WRITE_INITIAL_CONSUMER;
                        end
                    end
                ST_WRITE_INITIAL_CONSUMER:
                    if (ddram_command_accepted) begin
                        last_epoch <= requested_epoch;
                        active_epoch <= requested_epoch;
                        consumer_group_sequence <= 32'd0;
                        consumed_last_event_sequence <= 32'd0;
                        expected_group_sequence <= 32'd1;
                        processed_high_water <= 64'd0;
                        run_safe_high_water <= 64'd0;
                        have_high_water <= 1'b0;
                        last_barrier_sequence <= 32'd0;
                        last_barrier_source_sequence <= 32'd0;
                        last_verified_producer_fence <= 64'd0;
                        session_active <= 1'b1;
                        session_started <= 1'b1;
                        state <= ST_POLL_ORDINARY_COMMIT_ISSUE;
                    end
                ST_POLL_BACKOFF:
                    if (poll_backoff_count == 0)
                        state <= ST_POLL_ORDINARY_COMMIT_ISSUE;
                    else
                        poll_backoff_count <= poll_backoff_count - 1'b1;
                ST_POLL_ORDINARY_COMMIT_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_POLL_ORDINARY_COMMIT_WAIT;
                ST_POLL_ORDINARY_COMMIT_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data[31:0] == 0) begin
                            if (POLL_BACKOFF_CYCLES == 0)
                                state <= ST_POLL_ORDINARY_COMMIT_ISSUE;
                            else begin
                                poll_backoff_count <=
                                    POLL_BACKOFF_CYCLES - 1;
                                state <= ST_POLL_BACKOFF;
                            end
                        end else if (read_response_data !=
                            {active_epoch, expected_group_sequence}) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            saved_ordinary_commit <= read_response_data;
                            expected_replacement_r <=
                                replacement_expected;
                            expected_active_group_r <=
                                expected_active_grant_group_sequence;
                            expected_barrier_sequence_r <=
                                expected_barrier_sequence;
                            expected_source_sequence_r <=
                                expected_source_sequence;
                            expected_fence_r <=
                                expected_verified_producer_fence;
                            expected_b_r <= expected_barrier_timestamp;
                            expected_prior_event_r <=
                                expected_prior_event_high_water;
                            expected_count_r <= expected_event_count;
                            expected_requester_arm9_r <=
                                expected_requester_arm9;
                            expected_required_run_safe_through_r <=
                                expected_required_run_safe_through;
                            state <= ST_READ_SIDECAR_COMMIT1_ISSUE;
                        end
                    end
                ST_READ_SIDECAR_COMMIT1_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_READ_SIDECAR_COMMIT1_WAIT;
                ST_READ_SIDECAR_COMMIT1_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        saved_sidecar_commit <= read_response_data;
                        if (expected_replacement_r) begin
                            if (read_response_data !=
                                {active_epoch,
                                 expected_group_sequence}) begin
                                protocol_error <= 1'b1;
                                session_active <= 1'b0;
                                state <= ST_FAULT;
                            end else begin
                                replacement_mode <= 1'b1;
                                ordinary_payload_index <= 5'd0;
                                state <=
                                    ST_READ_ORDINARY_PAYLOAD_ISSUE;
                            end
                        end else if (read_response_data ==
                            {active_epoch, expected_group_sequence}) begin
                            // A matching sidecar can never be silently treated
                            // as an ordinary grant.
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else if (read_response_data == 0 ||
                            (read_response_data[31:0] != 0 &&
                             read_response_data[31:0] <
                                 expected_group_sequence)) begin
                            // A lower sequence is harmless physical-slot
                            // history. It cannot relabel this ordinary group.
                            replacement_mode <= 1'b0;
                            ordinary_payload_index <= 5'd0;
                            state <= ST_READ_ORDINARY_PAYLOAD_ISSUE;
                        end else begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end
                    end
                ST_READ_ORDINARY_PAYLOAD_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_READ_ORDINARY_PAYLOAD_WAIT;
                ST_READ_ORDINARY_PAYLOAD_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        ordinary_payload[ordinary_payload_index] <=
                            read_response_data;
                        if (ordinary_payload_index ==
                            ORDINARY_PAYLOAD_WORDS - 1) begin
                            ordinary_payload_index <= 5'd0;
                            state <= ST_READ_ORDINARY_PAYLOAD2_ISSUE;
                        end else begin
                            ordinary_payload_index <=
                                ordinary_payload_index + 1'b1;
                            state <= ST_READ_ORDINARY_PAYLOAD_ISSUE;
                        end
                    end
                ST_READ_ORDINARY_PAYLOAD2_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_READ_ORDINARY_PAYLOAD2_WAIT;
                ST_READ_ORDINARY_PAYLOAD2_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                            ordinary_payload[ordinary_payload_index]) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else if (ordinary_payload_index ==
                            ORDINARY_PAYLOAD_WORDS - 1) begin
                            if (replacement_mode) begin
                                sidecar_payload_index <= 4'd0;
                                state <=
                                    ST_READ_SIDECAR_PAYLOAD1_ISSUE;
                            end else begin
                                state <=
                                    ST_RECHECK_ORDINARY_COMMIT_ISSUE;
                            end
                        end else begin
                            ordinary_payload_index <=
                                ordinary_payload_index + 1'b1;
                            state <= ST_READ_ORDINARY_PAYLOAD2_ISSUE;
                        end
                    end
                ST_READ_SIDECAR_PAYLOAD1_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_READ_SIDECAR_PAYLOAD1_WAIT;
                ST_READ_SIDECAR_PAYLOAD1_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        sidecar_payload[sidecar_payload_index] <=
                            read_response_data;
                        if (sidecar_payload_index ==
                            REPLACEMENT_PAYLOAD_WORDS - 1) begin
                            state <= ST_READ_SIDECAR_COMMIT2_ISSUE;
                        end else begin
                            sidecar_payload_index <=
                                sidecar_payload_index + 1'b1;
                            state <= ST_READ_SIDECAR_PAYLOAD1_ISSUE;
                        end
                    end
                ST_READ_SIDECAR_COMMIT2_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_READ_SIDECAR_COMMIT2_WAIT;
                ST_READ_SIDECAR_COMMIT2_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != saved_sidecar_commit) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            sidecar_payload_index <= 4'd0;
                            state <= ST_READ_SIDECAR_PAYLOAD2_ISSUE;
                        end
                    end
                ST_READ_SIDECAR_PAYLOAD2_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_READ_SIDECAR_PAYLOAD2_WAIT;
                ST_READ_SIDECAR_PAYLOAD2_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                            sidecar_payload[sidecar_payload_index]) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else if (sidecar_payload_index ==
                            REPLACEMENT_PAYLOAD_WORDS - 1) begin
                            state <= ST_READ_SIDECAR_COMMIT3_ISSUE;
                        end else begin
                            sidecar_payload_index <=
                                sidecar_payload_index + 1'b1;
                            state <= ST_READ_SIDECAR_PAYLOAD2_ISSUE;
                        end
                    end
                ST_READ_SIDECAR_COMMIT3_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_READ_SIDECAR_COMMIT3_WAIT;
                ST_READ_SIDECAR_COMMIT3_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != saved_sidecar_commit) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            state <= ST_RECHECK_ORDINARY_COMMIT_ISSUE;
                        end
                    end
                ST_RECHECK_ORDINARY_COMMIT_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_RECHECK_ORDINARY_COMMIT_WAIT;
                ST_RECHECK_ORDINARY_COMMIT_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != saved_ordinary_commit) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            state <= ST_RECHECK_GROUP_DESCRIPTOR_ISSUE;
                        end
                    end
                ST_RECHECK_GROUP_DESCRIPTOR_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_RECHECK_GROUP_DESCRIPTOR_WAIT;
                ST_RECHECK_GROUP_DESCRIPTOR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                                {DESCRIPTOR_MAGIC, active_epoch} ||
                            (!replacement_mode &&
                             !decoded_ordinary_valid) ||
                            (replacement_mode &&
                             !decoded_replacement_valid)) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            grant_epoch <= active_epoch;
                            grant_group_sequence <=
                                expected_group_sequence;
                            grant_processed_through <=
                                ordinary_payload[0];
                            grant_run_safe_through <=
                                ordinary_payload[1];
                            grant_last_event_sequence <=
                                decoded_last_event_sequence;
                            grant_event_count <=
                                decoded_event_count[4:0];
                            grant_replaces_barrier <= replacement_mode;
                            if (replacement_mode) begin
                                replacement_active_grant_group_sequence <=
                                    sidecar_payload[1][31:0];
                                replacement_barrier_sequence <=
                                    sidecar_payload[1][63:32];
                                replacement_source_sequence <=
                                    sidecar_payload[2][31:0];
                                replacement_verified_producer_fence <=
                                    sidecar_payload[3];
                                replacement_barrier_timestamp <=
                                    sidecar_payload[4];
                                replacement_prior_event_high_water <=
                                    sidecar_payload[5][31:0];
                                replacement_reserved_event_count <=
                                    sidecar_payload[0][15:8];
                                replacement_requester_arm9 <=
                                    sidecar_payload[6][0];
                                replacement_required_run_safe_through <=
                                    sidecar_payload[7];
                                replacement_group_sequence <=
                                    expected_group_sequence;
                            end else begin
                                replacement_active_grant_group_sequence <=
                                    32'd0;
                                replacement_barrier_sequence <= 32'd0;
                                replacement_source_sequence <= 32'd0;
                                replacement_verified_producer_fence <= 64'd0;
                                replacement_barrier_timestamp <= 64'd0;
                                replacement_prior_event_high_water <= 32'd0;
                                replacement_reserved_event_count <= 5'd0;
                                replacement_requester_arm9 <= 1'b0;
                                replacement_required_run_safe_through <=
                                    64'd0;
                                replacement_group_sequence <= 32'd0;
                            end
                            grant_valid <= 1'b1;
                            state <= ST_GRANT_OUTPUT_WAIT;
                        end
                    end
                ST_GRANT_OUTPUT_WAIT:
                    if (grant_valid && grant_ready) begin
                        grant_valid <= 1'b0;
                        if (grant_event_count == 0) begin
                            if (replacement_mode)
                                state <=
                                    ST_FINAL_SIDECAR_COMMIT1_ISSUE;
                            else begin
                                ordinary_payload_index <= 5'd0;
                                state <=
                                    ST_FINAL_ORDINARY_PAYLOAD_ISSUE;
                            end
                        end else begin
                            output_event_index <= 5'd0;
                            event_epoch <= grant_epoch;
                            event_group_sequence <= grant_group_sequence;
                            event_timestamp <= grant_processed_through;
                            event_sequence <= ordinary_payload[4][31:0];
                            event_cpu_arm9 <= decoded_control_bitmap[0];
                            event_set <= decoded_control_bitmap[1];
                            event_mask <= ordinary_payload[4][63:32];
                            event_valid <= 1'b1;
                            state <= ST_EVENT_OUTPUT_WAIT;
                        end
                    end
                ST_EVENT_OUTPUT_WAIT:
                    if (event_valid && event_ready) begin
                        if ((replacement_mode &&
                             (event_timestamp != expected_b_r ||
                              event_sequence !=
                                expected_prior_event_r +
                                output_event_index + 1'b1))) begin
                            event_valid <= 1'b0;
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else if (output_event_index + 1'b1 ==
                                     grant_event_count) begin
                            event_valid <= 1'b0;
                            if (replacement_mode)
                                state <=
                                    ST_FINAL_SIDECAR_COMMIT1_ISSUE;
                            else begin
                                ordinary_payload_index <= 5'd0;
                                state <=
                                    ST_FINAL_ORDINARY_PAYLOAD_ISSUE;
                            end
                        end else begin
                            output_event_index <=
                                output_event_index + 1'b1;
                            event_sequence <= ordinary_payload[
                                output_event_index + 5][31:0];
                            event_cpu_arm9 <= decoded_control_bitmap[
                                (output_event_index + 1'b1) * 2];
                            event_set <= decoded_control_bitmap[
                                (output_event_index + 1'b1) * 2 + 1];
                            event_mask <= ordinary_payload[
                                output_event_index + 5][63:32];
                        end
                    end
                ST_FINAL_SIDECAR_COMMIT1_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_FINAL_SIDECAR_COMMIT1_WAIT;
                ST_FINAL_SIDECAR_COMMIT1_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != saved_sidecar_commit) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            sidecar_payload_index <= 4'd0;
                            state <= ST_FINAL_SIDECAR_PAYLOAD_ISSUE;
                        end
                    end
                ST_FINAL_SIDECAR_PAYLOAD_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_FINAL_SIDECAR_PAYLOAD_WAIT;
                ST_FINAL_SIDECAR_PAYLOAD_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                            sidecar_payload[sidecar_payload_index]) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else if (sidecar_payload_index ==
                            REPLACEMENT_PAYLOAD_WORDS - 1) begin
                            state <= ST_FINAL_SIDECAR_COMMIT2_ISSUE;
                        end else begin
                            sidecar_payload_index <=
                                sidecar_payload_index + 1'b1;
                            state <= ST_FINAL_SIDECAR_PAYLOAD_ISSUE;
                        end
                    end
                ST_FINAL_SIDECAR_COMMIT2_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_FINAL_SIDECAR_COMMIT2_WAIT;
                ST_FINAL_SIDECAR_COMMIT2_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != saved_sidecar_commit ||
                            !expected_descriptor_stable) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            ordinary_payload_index <= 5'd0;
                            state <= ST_FINAL_ORDINARY_PAYLOAD_ISSUE;
                        end
                    end
                ST_FINAL_ORDINARY_PAYLOAD_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_FINAL_ORDINARY_PAYLOAD_WAIT;
                ST_FINAL_ORDINARY_PAYLOAD_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                            ordinary_payload[ordinary_payload_index]) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else if (ordinary_payload_index ==
                            ORDINARY_PAYLOAD_WORDS - 1) begin
                            state <= ST_FINAL_ORDINARY_COMMIT_ISSUE;
                        end else begin
                            ordinary_payload_index <=
                                ordinary_payload_index + 1'b1;
                            state <= ST_FINAL_ORDINARY_PAYLOAD_ISSUE;
                        end
                    end
                ST_FINAL_ORDINARY_COMMIT_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_FINAL_ORDINARY_COMMIT_WAIT;
                ST_FINAL_ORDINARY_COMMIT_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != saved_ordinary_commit) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            state <= ST_FINAL_DESCRIPTOR_ISSUE;
                        end
                    end
                ST_FINAL_DESCRIPTOR_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_FINAL_DESCRIPTOR_WAIT;
                ST_FINAL_DESCRIPTOR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                                {DESCRIPTOR_MAGIC, active_epoch} ||
                            !expected_descriptor_stable) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            final_verified_epoch <= active_epoch;
                            final_verified_group_sequence <=
                                expected_group_sequence;
                            verified_group_sequence <=
                                expected_group_sequence;
                            final_verified_valid <= 1'b1;
                            group_final_verified <= 1'b1;
                            state <= ST_FINAL_VERIFIED_OUTPUT_WAIT;
                        end
                    end
                ST_FINAL_VERIFIED_OUTPUT_WAIT:
                    if (final_verified_valid && final_verified_ready) begin
                        final_verified_valid <= 1'b0;
                        if (replacement_mode)
                            state <= ST_CLEAR_SIDECAR_LOW;
                        else
                            state <= ST_CLEAR_ORDINARY_LOW;
                    end
                ST_CLEAR_SIDECAR_LOW:
                    if (ddram_command_accepted)
                        state <= ST_CLEAR_SIDECAR_HIGH;
                ST_CLEAR_SIDECAR_HIGH:
                    if (ddram_command_accepted)
                        state <= ST_VERIFY_SIDECAR_CLEAR_ISSUE;
                ST_VERIFY_SIDECAR_CLEAR_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_VERIFY_SIDECAR_CLEAR_WAIT;
                ST_VERIFY_SIDECAR_CLEAR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != 0) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            state <= ST_CLEAR_ORDINARY_LOW;
                        end
                    end
                ST_CLEAR_ORDINARY_LOW:
                    if (ddram_command_accepted)
                        state <= ST_CLEAR_ORDINARY_HIGH;
                ST_CLEAR_ORDINARY_HIGH:
                    if (ddram_command_accepted)
                        state <= ST_VERIFY_ORDINARY_CLEAR_ISSUE;
                ST_VERIFY_ORDINARY_CLEAR_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_VERIFY_ORDINARY_CLEAR_WAIT;
                ST_VERIFY_ORDINARY_CLEAR_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data != 0) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            state <= ST_WRITE_CONSUMER;
                        end
                    end
                ST_WRITE_CONSUMER:
                    if (ddram_command_accepted)
                        state <= ST_VERIFY_CONSUMER_ACK_ISSUE;
                ST_VERIFY_CONSUMER_ACK_ISSUE:
                    if (ddram_command_accepted)
                        state <= ST_VERIFY_CONSUMER_ACK_WAIT;
                ST_VERIFY_CONSUMER_ACK_WAIT:
                    if (read_response_valid) begin
                        buffered_read_valid <= 1'b0;
                        if (read_response_data !=
                            {active_epoch, expected_group_sequence}) begin
                            protocol_error <= 1'b1;
                            session_active <= 1'b0;
                            state <= ST_FAULT;
                        end else begin
                            // The consumer is exactly one group behind the
                            // expected sequence until terminal exhaustion.
                            // Advance the local counter instead of routing
                            // the expected register bank across the device.
                            consumer_group_sequence <=
                                consumer_group_sequence + 32'd1;
                            consumed_last_event_sequence <=
                                grant_last_event_sequence;
                            processed_high_water <=
                                grant_processed_through;
                            run_safe_high_water <= grant_run_safe_through;
                            have_high_water <= 1'b1;
                            if (replacement_mode)
                                last_barrier_sequence <=
                                    replacement_barrier_sequence;
                            if (replacement_mode)
                                last_barrier_source_sequence <=
                                    replacement_source_sequence;
                            if (replacement_mode)
                                last_verified_producer_fence <=
                                    replacement_verified_producer_fence;
                            retired_epoch <= active_epoch;
                            retired_group_sequence <=
                                expected_group_sequence;
                            group_retired <= 1'b1;
                            if (expected_group_sequence == 32'hffffffff ||
                                grant_last_event_sequence ==
                                    32'hffffffff) begin
                                sequence_exhausted <= 1'b1;
                                session_active <= 1'b0;
                                state <= ST_IDLE;
                            end else begin
                                expected_group_sequence <=
                                    expected_group_sequence + 1'b1;
                                replacement_mode <= 1'b0;
                                state <= ST_POLL_ORDINARY_COMMIT_ISSUE;
                            end
                        end
                    end
                default: begin
                    protocol_error <= 1'b1;
                    session_active <= 1'b0;
                    state <= ST_FAULT;
                end
            endcase
        end
    end

    logic unused_ddram_busy;
    assign unused_ddram_busy = ddram_busy;
endmodule

`default_nettype wire
