// Retains completed ARM7 sound-register writes until the exact HPS-consumed
// mailbox acknowledgement has crossed back to FPGA and the shared-time delta
// attributed through that acknowledgement has fully drained.
//
// This block is intentionally a simulator-first, default-disconnected seam.
// `completion_valid` has no ready signal: integration must feed the completed
// mailbox metadata (never request-launch metadata), and this observer can
// never stall the production CPU/mailbox path.  Finite capture overflow is
// epoch-fatal and suppresses every retained/output write rather than silently
// losing causality.
//
// `ack_*` is a ready/valid stream after the HPS-consumed ACK transport has
// validated its epoch/global sequence.  This block validates it again and may
// backpressure that reverse stream.  Mailbox/halt source IDs share the mailbox
// generation domain; posted source IDs have their own sequence domain.
//
// `drain_*` is a ready/valid completion token for each accepted global ACK.
// A token may be asserted only after every shared-time delta caused by that
// ACK has been accepted by the sound-cycle consumer.  Keying this barrier by
// ACK sequence avoids an unsafe "idle was still high" race on the ACK edge.
//
// Correctness-first serialization: after accepting the ACK for one sound
// write, no later ACK is accepted until that write's exact drain token has
// arrived and the retained write output has been consumed.  Unrelated ACKs
// before the sound ACK pass normally.
module nds_sound_write_order_queue #(
    parameter integer QUEUE_DEPTH = 16,
    parameter logic [31:0] FIRST_COMPLETION_SOURCE_ID = 32'd1,
    parameter logic [31:0] FIRST_MAILBOX_SOURCE_ID = 32'd1,
    parameter logic [31:0] FIRST_POSTED_SOURCE_ID = 32'd1,
    parameter logic [31:0] FIRST_ACK_SEQUENCE = 32'd1,
    parameter logic [31:0] FIRST_DRAIN_SEQUENCE = 32'd1,
    // Legacy/static tests retain the parameter seeds above.  Direct mailbox
    // integration enables this mode and supplies exact per-epoch runtime
    // seeds after any amount of disabled mailbox/posted traffic.
    parameter bit RUNTIME_EPOCH_SEEDS = 1'b0,
    parameter logic [31:0] SOUND_ADDRESS_FIRST = 32'h04000400,
    parameter logic [31:0] SOUND_ADDRESS_LAST = 32'h0400051f
) (
    input  logic        clk,
    input  logic        reset,

    // A fresh epoch may start only after transport quiescence has first been
    // observed low and then high.  `epoch_begin_fresh` is supplied by the
    // persistent session coordinator and proves non-reuse across FPGA reset.
    input  logic        transport_quiescent,
    input  logic        epoch_begin_valid,
    output logic        epoch_begin_ready,
    input  logic [31:0] epoch_begin,
    input  logic        epoch_begin_fresh,
    output logic        epoch_started,
    output logic        epoch_active,
    output logic [31:0] active_epoch,
    input  logic        epoch_seed_valid,
    input  logic [31:0] epoch_seed_mailbox_source_id,
    input  logic [31:0] epoch_seed_posted_base_sequence,
    input  logic [31:0] epoch_seed_global_sequence,
    input  logic        epoch_runtime_contract_active,

    // Every completed mailbox transaction, including timing-only traffic.
    // There is deliberately no completion_ready output.
    input  logic        completion_valid,
    input  logic [31:0] completion_epoch,
    input  logic [31:0] completion_source_id,
    input  logic        completion_cpu_arm9,
    input  logic        completion_read_not_write,
    // 00=byte, 01=halfword, 10=word.  11 is invalid for a sound write.
    input  logic [1:0]  completion_access,
    input  logic [31:0] completion_address,
    input  logic [31:0] completion_write_data,

    // Globally sequenced HPS-consumed ACK records.
    input  logic        ack_valid,
    output logic        ack_ready,
    input  logic [31:0] ack_epoch,
    input  logic [31:0] ack_sequence,
    input  logic        ack_cpu_arm9,
    // 0=posted write, 1=ordinary/timing mailbox, 2=synthetic halt tick.
    input  logic [1:0]  ack_kind,
    input  logic [31:0] ack_source_id,

    // One exact shared-time-drained token for every accepted global ACK.
    input  logic        drain_valid,
    output logic        drain_ready,
    input  logic [31:0] drain_epoch,
    input  logic [31:0] drain_ack_sequence,

    // Retained, exactly-once sound-register write output.
    output logic        write_valid,
    input  logic        write_ready,
    output logic [31:0] write_epoch,
    output logic [31:0] write_source_id,
    output logic [31:0] write_address,
    output logic [1:0]  write_access,
    output logic [31:0] write_data,

    output logic [$clog2(QUEUE_DEPTH + 1)-1:0] queue_level,
    output logic        pending_sound_ack,
    output logic        capture_overflow,
    output logic        sequence_exhausted,
    output logic        protocol_error
);
    localparam integer POINTER_WIDTH =
        QUEUE_DEPTH <= 1 ? 1 : $clog2(QUEUE_DEPTH);
    localparam integer LEVEL_WIDTH = $clog2(QUEUE_DEPTH + 1);
    localparam logic [POINTER_WIDTH-1:0] LAST_POINTER =
        POINTER_WIDTH'(QUEUE_DEPTH - 1);
    localparam logic [LEVEL_WIDTH-1:0] FULL_LEVEL =
        LEVEL_WIDTH'(QUEUE_DEPTH);

    logic [31:0] source_fifo [0:QUEUE_DEPTH-1];
    logic [31:0] address_fifo [0:QUEUE_DEPTH-1];
    logic [1:0]  access_fifo [0:QUEUE_DEPTH-1];
    logic [31:0] data_fifo [0:QUEUE_DEPTH-1];
    logic [POINTER_WIDTH-1:0] read_pointer;
    logic [POINTER_WIDTH-1:0] write_pointer;
    logic [LEVEL_WIDTH-1:0] level;

    logic [31:0] expected_completion_source;
    logic [31:0] expected_mailbox_source;
    logic [31:0] expected_posted_source;
    logic [31:0] expected_ack_sequence;
    logic [31:0] expected_drain_sequence;
    logic [31:0] completed_source_frontier;
    logic [31:0] accepted_ack_frontier;

    logic completion_source_exhausted;
    logic mailbox_source_exhausted;
    logic posted_source_exhausted;
    logic ack_sequence_exhausted;
    logic drain_sequence_exhausted;
    logic quarantine_low_seen;
    logic [31:0] last_epoch;

    logic pending_valid;
    logic [31:0] pending_epoch;
    logic [31:0] pending_source_id;
    logic [31:0] pending_ack_sequence;
    logic [31:0] pending_address;
    logic [1:0] pending_access;
    logic [31:0] pending_data;

    wire completion_is_sound_write =
        !completion_cpu_arm9 && !completion_read_not_write &&
        completion_address >= SOUND_ADDRESS_FIRST &&
        completion_address <= SOUND_ADDRESS_LAST;

    wire completion_record_error =
        completion_valid &&
        (!epoch_active ||
         completion_epoch == 0 ||
         completion_epoch != active_epoch ||
         completion_source_id == 0 ||
         completion_source_exhausted ||
         completion_source_id != expected_completion_source ||
         (completion_is_sound_write && completion_access == 2'b11));

    wire ack_basic_error =
        ack_valid &&
        (!epoch_active ||
         ack_epoch == 0 ||
         ack_epoch != active_epoch ||
         ack_sequence == 0 ||
         ack_sequence_exhausted ||
         ack_sequence != expected_ack_sequence ||
         ack_kind == 2'b11 ||
         ack_source_id == 0);

    wire ack_source_error =
        ack_valid && !ack_basic_error &&
        ((ack_kind == 2'b00 &&
          (posted_source_exhausted ||
           ack_source_id != expected_posted_source)) ||
         (ack_kind != 2'b00 &&
          (mailbox_source_exhausted ||
           ack_source_id != expected_mailbox_source)));

    // A reverse ACK may legitimately beat the FPGA mailbox response through
    // the independent DDR reader.  Stall it until its completion metadata has
    // been captured; never guess from request launch.
    wire ack_waits_for_completion =
        ack_valid && !ack_basic_error && !ack_source_error &&
        ack_kind != 2'b00 &&
        ack_source_id > completed_source_frontier;

    assign ack_ready =
        !protocol_error && !pending_valid && !write_valid &&
        (!ack_valid || !ack_waits_for_completion);
    wire ack_fire = ack_valid && ack_ready;

    wire drain_basic_error =
        drain_valid &&
        (!epoch_active ||
         drain_epoch == 0 ||
         drain_epoch != active_epoch ||
         drain_ack_sequence == 0 ||
         drain_sequence_exhausted ||
         drain_ack_sequence != expected_drain_sequence);

    // A drain producer may not claim a sequence the ACK seam has not accepted.
    // Exact expected-but-not-yet-accepted tokens are backpressured; malformed
    // gaps/stale tokens are accepted once and poison the epoch.
    wire drain_waits_for_ack =
        drain_valid && !drain_basic_error &&
        drain_ack_sequence > accepted_ack_frontier;

    assign drain_ready =
        !protocol_error && (!drain_valid || !drain_waits_for_ack);
    wire drain_fire = drain_valid && drain_ready;

    wire [31:0] head_source_id = source_fifo[read_pointer];
    wire sound_ack_head_missed =
        ack_fire && !ack_basic_error && !ack_source_error &&
        ack_kind != 2'b00 && level != 0 &&
        ack_source_id > head_source_id;
    wire sound_ack_head_wrong_kind =
        ack_fire && !ack_basic_error && !ack_source_error &&
        level != 0 && ack_source_id == head_source_id &&
        (ack_kind != 2'b01 || ack_cpu_arm9);
    wire sound_ack_matches_head =
        ack_fire && !ack_basic_error && !ack_source_error &&
        level != 0 && ack_source_id == head_source_id &&
        ack_kind == 2'b01 && !ack_cpu_arm9;

    wire enqueue_sound =
        completion_valid && !completion_record_error &&
        completion_is_sound_write;
    wire dequeue_sound = sound_ack_matches_head;
    wire overflow_event =
        enqueue_sound && level == FULL_LEVEL && !dequeue_sound;

    wire drain_releases_pending =
        drain_fire && !drain_basic_error && pending_valid &&
        drain_ack_sequence == pending_ack_sequence;
    wire drain_passed_pending =
        drain_fire && !drain_basic_error && pending_valid &&
        drain_ack_sequence > pending_ack_sequence;

    wire runtime_epoch_loss =
        RUNTIME_EPOCH_SEEDS && epoch_active &&
        !epoch_runtime_contract_active;
    wire runtime_epoch_seed_error =
        RUNTIME_EPOCH_SEEDS &&
        (!epoch_seed_valid ||
         !epoch_runtime_contract_active ||
         epoch_seed_mailbox_source_id == 32'd0 ||
         epoch_seed_posted_base_sequence == 32'hffffffff ||
         epoch_seed_global_sequence == 32'd0);

    wire [31:0] epoch_initial_completion_source =
        RUNTIME_EPOCH_SEEDS
            ? epoch_seed_mailbox_source_id
            : FIRST_COMPLETION_SOURCE_ID;
    wire [31:0] epoch_initial_mailbox_source =
        RUNTIME_EPOCH_SEEDS
            ? epoch_seed_mailbox_source_id
            : FIRST_MAILBOX_SOURCE_ID;
    wire [31:0] epoch_initial_posted_source =
        RUNTIME_EPOCH_SEEDS
            ? epoch_seed_posted_base_sequence + 1'b1
            : FIRST_POSTED_SOURCE_ID;
    wire [31:0] epoch_initial_ack_sequence =
        RUNTIME_EPOCH_SEEDS
            ? epoch_seed_global_sequence
            : FIRST_ACK_SEQUENCE;
    wire [31:0] epoch_initial_drain_sequence =
        RUNTIME_EPOCH_SEEDS
            ? epoch_seed_global_sequence
            : FIRST_DRAIN_SEQUENCE;

    wire event_error =
        completion_record_error ||
        (ack_fire && (ack_basic_error || ack_source_error)) ||
        sound_ack_head_missed || sound_ack_head_wrong_kind ||
        (drain_fire && drain_basic_error) ||
        drain_passed_pending || overflow_event ||
        runtime_epoch_loss;

    assign queue_level = level;
    assign pending_sound_ack = pending_valid;
    assign sequence_exhausted =
        completion_source_exhausted || mailbox_source_exhausted ||
        posted_source_exhausted || ack_sequence_exhausted ||
        drain_sequence_exhausted;

    assign epoch_begin_ready =
        quarantine_low_seen && transport_quiescent &&
        !completion_valid && !ack_valid && !drain_valid &&
        level == 0 && !pending_valid && !write_valid &&
        !protocol_error && !capture_overflow && !sequence_exhausted;

    function automatic logic [POINTER_WIDTH-1:0] increment_pointer(
        input logic [POINTER_WIDTH-1:0] pointer
    );
        if (pointer == LAST_POINTER)
            increment_pointer = '0;
        else
            increment_pointer = pointer + 1'b1;
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            epoch_started <= 1'b0;
            epoch_active <= 1'b0;
            active_epoch <= 32'd0;
            last_epoch <= 32'd0;
            quarantine_low_seen <= 1'b0;

            expected_completion_source <= FIRST_COMPLETION_SOURCE_ID;
            expected_mailbox_source <= FIRST_MAILBOX_SOURCE_ID;
            expected_posted_source <= FIRST_POSTED_SOURCE_ID;
            expected_ack_sequence <= FIRST_ACK_SEQUENCE;
            expected_drain_sequence <= FIRST_DRAIN_SEQUENCE;
            completed_source_frontier <= 32'd0;
            accepted_ack_frontier <= 32'd0;

            completion_source_exhausted <= 1'b0;
            mailbox_source_exhausted <= 1'b0;
            posted_source_exhausted <= 1'b0;
            ack_sequence_exhausted <= 1'b0;
            drain_sequence_exhausted <= 1'b0;

            read_pointer <= '0;
            write_pointer <= '0;
            level <= '0;
            pending_valid <= 1'b0;
            pending_epoch <= 32'd0;
            pending_source_id <= 32'd0;
            pending_ack_sequence <= 32'd0;
            pending_address <= 32'd0;
            pending_access <= 2'd0;
            pending_data <= 32'd0;

            write_valid <= 1'b0;
            write_epoch <= 32'd0;
            write_source_id <= 32'd0;
            write_address <= 32'd0;
            write_access <= 2'd0;
            write_data <= 32'd0;

            capture_overflow <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            epoch_started <= 1'b0;
            if (!transport_quiescent)
                quarantine_low_seen <= 1'b1;

            if (event_error) begin
                // No partial queue/output survives an unknowable causal gap.
                epoch_active <= 1'b0;
                active_epoch <= 32'd0;
                level <= '0;
                read_pointer <= '0;
                write_pointer <= '0;
                pending_valid <= 1'b0;
                write_valid <= 1'b0;
                protocol_error <= 1'b1;
                if (overflow_event)
                    capture_overflow <= 1'b1;
            end else if (epoch_begin_valid && epoch_begin_ready) begin
                quarantine_low_seen <= 1'b0;
                level <= '0;
                read_pointer <= '0;
                write_pointer <= '0;
                pending_valid <= 1'b0;
                write_valid <= 1'b0;
                completed_source_frontier <= RUNTIME_EPOCH_SEEDS
                    ? epoch_initial_mailbox_source - 1'b1
                    : 32'd0;
                accepted_ack_frontier <= RUNTIME_EPOCH_SEEDS
                    ? epoch_initial_ack_sequence - 1'b1
                    : 32'd0;
                expected_completion_source <=
                    epoch_initial_completion_source;
                expected_mailbox_source <=
                    epoch_initial_mailbox_source;
                expected_posted_source <=
                    epoch_initial_posted_source;
                expected_ack_sequence <=
                    epoch_initial_ack_sequence;
                expected_drain_sequence <=
                    epoch_initial_drain_sequence;
                completion_source_exhausted <= 1'b0;
                mailbox_source_exhausted <= 1'b0;
                posted_source_exhausted <= 1'b0;
                ack_sequence_exhausted <= 1'b0;
                drain_sequence_exhausted <= 1'b0;

                if (epoch_begin == 0 || !epoch_begin_fresh ||
                    epoch_begin == last_epoch ||
                    runtime_epoch_seed_error) begin
                    epoch_active <= 1'b0;
                    active_epoch <= 32'd0;
                    protocol_error <= 1'b1;
                end else begin
                    epoch_active <= 1'b1;
                    active_epoch <= epoch_begin;
                    last_epoch <= epoch_begin;
                    epoch_started <= 1'b1;
                end
            end else begin
                if (write_valid && write_ready)
                    write_valid <= 1'b0;

                if (completion_valid) begin
                    completed_source_frontier <= completion_source_id;
                    if (completion_source_id == 32'hffffffff)
                        completion_source_exhausted <= 1'b1;
                    else
                        expected_completion_source <=
                            expected_completion_source + 1'b1;
                end

                if (ack_fire) begin
                    accepted_ack_frontier <= ack_sequence;
                    if (ack_sequence == 32'hffffffff)
                        ack_sequence_exhausted <= 1'b1;
                    else
                        expected_ack_sequence <=
                            expected_ack_sequence + 1'b1;

                    if (ack_kind == 2'b00) begin
                        if (ack_source_id == 32'hffffffff)
                            posted_source_exhausted <= 1'b1;
                        else
                            expected_posted_source <=
                                expected_posted_source + 1'b1;
                    end else begin
                        if (ack_source_id == 32'hffffffff)
                            mailbox_source_exhausted <= 1'b1;
                        else
                            expected_mailbox_source <=
                                expected_mailbox_source + 1'b1;
                    end
                end

                if (drain_fire) begin
                    if (drain_ack_sequence == 32'hffffffff)
                        drain_sequence_exhausted <= 1'b1;
                    else
                        expected_drain_sequence <=
                            expected_drain_sequence + 1'b1;
                end

                if (enqueue_sound) begin
                    source_fifo[write_pointer] <= completion_source_id;
                    address_fifo[write_pointer] <= completion_address;
                    access_fifo[write_pointer] <= completion_access;
                    data_fifo[write_pointer] <= completion_write_data;
                    write_pointer <= increment_pointer(write_pointer);
                end

                if (dequeue_sound) begin
                    pending_valid <= 1'b1;
                    pending_epoch <= active_epoch;
                    pending_source_id <= source_fifo[read_pointer];
                    pending_ack_sequence <= ack_sequence;
                    pending_address <= address_fifo[read_pointer];
                    pending_access <= access_fifo[read_pointer];
                    pending_data <= data_fifo[read_pointer];
                    read_pointer <= increment_pointer(read_pointer);
                end

                case ({enqueue_sound, dequeue_sound})
                    2'b10: level <= level + 1'b1;
                    2'b01: level <= level - 1'b1;
                    default: begin end
                endcase

                if (drain_releases_pending) begin
                    pending_valid <= 1'b0;
                    write_valid <= 1'b1;
                    write_epoch <= pending_epoch;
                    write_source_id <= pending_source_id;
                    write_address <= pending_address;
                    write_access <= pending_access;
                    write_data <= pending_data;
                end
            end
        end
    end
endmodule
