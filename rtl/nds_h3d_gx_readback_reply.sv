`timescale 1ns/1ps

// One outstanding, session-tagged H3R1 result fetch. The request/completion
// toggles cross through two flops; their associated buses remain held until
// the opposite domain has consumed them. Only the RAM read port is clocked
// by source_clk. No asynchronous, flattened result-register bus is exposed.
//
// The client command is held through busy, handed off once at !busy, and
// retired only on command_accepted (which can be much later). The enclosing
// DDR fabric must preserve single-command response ownership and quarantine
// pre-reset responses, as nds_h3d_ddr_fabric does. Untagged DDR responses alone
// cannot distinguish an old physical command from a new reset epoch.
//
// Host publication must invalidate commit before changing a reply and write
// commit last after its release fence. Request IDs must be nonzero and not
// reused within a session. No response timeout is imposed: an old/wrong-session
// reply is simply polled again. A stable malformed reply for our exact tag is
// a sticky fault requiring reset/session_flush.
// A preliminary session read MUST precede the first matching commit poll:
// otherwise a reused request ID from an old session could produce an ABA
// commit while the full scan straddles publication of the new session.
module nds_h3d_gx_readback_reply #(
    parameter logic [28:0] CONTROL_BASE_WORD = 29'h01f80000
) (
    input  logic        source_clk,
    input  logic        ddr_clk,
    input  logic        reset,
    input  logic        session_flush,
    input  logic [31:0] session,
    input  logic        request_valid,
    input  logic [31:0] request_id,
    output logic        request_ready,
    output logic        response_valid,
    output logic [31:0] response_id,
    output logic [31:0] response_status,
    input  logic [4:0]  read_index,
    output logic [31:0] read_data,
    output logic        source_fault,

    output logic        ddram_read,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    input  logic        ddram_busy,
    input  logic        ddram_command_accepted,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready
);
    localparam logic [28:0] REPLY_BASE_WORD = CONTROL_BASE_WORD + 29'd64;
    localparam logic [31:0] REPLY_MAGIC = 32'h31523348;

    wire reset_async = reset || session_flush;
    logic [2:0] source_reset_pipe, ddr_reset_pipe;
    wire source_reset_local = source_reset_pipe[2];
    wire ddr_reset_local = ddr_reset_pipe[2];
    always_ff @(posedge source_clk or posedge reset_async) begin
        if (reset_async) source_reset_pipe <= 3'b111;
        else source_reset_pipe <= {source_reset_pipe[1:0], 1'b0};
    end
    always_ff @(posedge ddr_clk or posedge reset_async) begin
        if (reset_async) ddr_reset_pipe <= 3'b111;
        else ddr_reset_pipe <= {ddr_reset_pipe[1:0], 1'b0};
    end

    logic source_up, ddr_up;
    (* async_reg = "true" *) logic ddr_up_meta, ddr_up_sync;
    (* async_reg = "true" *) logic source_up_meta, source_up_sync;
    logic request_toggle, source_pending, source_local_fault;
    logic [31:0] held_session, held_id;
    (* async_reg = "true" *) logic request_meta, request_sync;
    logic request_seen, active_toggle;
    logic [31:0] active_session, active_id;
    logic completion_toggle;
    logic [31:0] completion_session, completion_id, completion_status;
    (* async_reg = "true" *) logic completion_meta, completion_sync;
    logic ddr_fault;
    (* async_reg = "true" *) logic fault_meta, fault_sync;

    assign source_fault = source_local_fault || fault_sync;
    assign request_ready = !reset_async && !source_reset_local &&
        ddr_up_sync && !source_pending && !source_fault;

    always_ff @(posedge source_clk or posedge source_reset_local) begin
        if (source_reset_local) begin
            source_up <= 1'b0;
            ddr_up_meta <= 1'b0;
            ddr_up_sync <= 1'b0;
            completion_meta <= 1'b0;
            completion_sync <= 1'b0;
            fault_meta <= 1'b0;
            fault_sync <= 1'b0;
            request_toggle <= 1'b0;
            source_pending <= 1'b0;
            source_local_fault <= 1'b0;
            held_session <= 32'd0;
            held_id <= 32'd0;
            response_valid <= 1'b0;
            response_id <= 32'd0;
            response_status <= 32'd0;
        end else begin
            source_up <= 1'b1;
            ddr_up_meta <= ddr_up;
            ddr_up_sync <= ddr_up_meta;
            completion_meta <= completion_toggle;
            completion_sync <= completion_meta;
            fault_meta <= ddr_fault;
            fault_sync <= fault_meta;
            response_valid <= 1'b0;
            if (request_valid && request_ready) begin
                if (request_id == 0 || session == 0) begin
                    source_local_fault <= 1'b1;
                end else begin
                    held_session <= session;
                    held_id <= request_id;
                    request_toggle <= !request_toggle;
                    source_pending <= 1'b1;
                end
            end
            if (source_pending && completion_sync == request_toggle &&
                !source_fault) begin
                if (completion_session == held_session &&
                    completion_id == held_id && session == held_session) begin
                    response_id <= completion_id;
                    response_status <= completion_status;
                    response_valid <= 1'b1;
                    source_pending <= 1'b0;
                end else begin
                    source_local_fault <= 1'b1;
                end
            end
        end
    end

    typedef enum logic [2:0] {
        IDLE, READ_ISSUE, READ_WAIT, STORE_LOW, STORE_HIGH, FAULT_HOLD
    } state_t;
    typedef enum logic [1:0] {
        POLL_HEADER, POLL_COMMIT, FILL_CACHE, VERIFY_COMMIT
    } phase_t;
    state_t state;
    phase_t phase;
    logic issued_command;
    logic [3:0] beat_index;
    logic [63:0] beat_data;
    logic [31:0] snapshot_status;
    logic magic_ok, session_ok, id_ok, reserved_ok, inside_commit_ok;

    // One 32x32 simple dual-port RAM: one DDR write per clock, synchronous
    // source read. Deliberately no RAM reset/clear loop (preserves inference).
    // Contents are undefined before a completed request, and may change only
    // while a later accepted request owns the cache. response_valid commits
    // all 32 entries atomically to the source consumer.
    (* ramstyle = "M10K, no_rw_check" *) logic [31:0] result_cache [0:31];
    wire cache_write = state == STORE_LOW || state == STORE_HIGH;
    wire [4:0] cache_write_index = {beat_index, state == STORE_HIGH};
    wire [31:0] cache_write_data = state == STORE_HIGH ?
        beat_data[63:32] : beat_data[31:0];
    always_ff @(posedge ddr_clk) begin
        if (cache_write) result_cache[cache_write_index] <= cache_write_data;
    end
    always_ff @(posedge source_clk)
        read_data <= result_cache[read_index];

    assign ddram_read = state == READ_ISSUE && !issued_command &&
        !ddr_reset_local && !reset_async;
    assign ddram_burst_count = 8'd1;
    assign ddram_address = REPLY_BASE_WORD +
        (phase == POLL_HEADER ? 29'd0 :
         phase == FILL_CACHE ? {25'd0, beat_index} : 29'd15);
    wire handoff = ddram_read && !ddram_busy;
    wire accepted_read = ddram_command_accepted &&
        (issued_command || handoff);
    wire response_now = ddram_read_data_ready &&
        (state == READ_WAIT || (state == READ_ISSUE && accepted_read));

    always_ff @(posedge ddr_clk or posedge ddr_reset_local) begin
        if (ddr_reset_local) begin
            ddr_up <= 1'b0;
            source_up_meta <= 1'b0;
            source_up_sync <= 1'b0;
            request_meta <= 1'b0;
            request_sync <= 1'b0;
            request_seen <= 1'b0;
            active_toggle <= 1'b0;
            active_session <= 32'd0;
            active_id <= 32'd0;
            completion_toggle <= 1'b0;
            completion_session <= 32'd0;
            completion_id <= 32'd0;
            completion_status <= 32'd0;
            ddr_fault <= 1'b0;
            state <= IDLE;
            phase <= POLL_HEADER;
            issued_command <= 1'b0;
            beat_index <= 4'd0;
            beat_data <= 64'd0;
            snapshot_status <= 32'd0;
            magic_ok <= 1'b0;
            session_ok <= 1'b0;
            id_ok <= 1'b0;
            reserved_ok <= 1'b0;
            inside_commit_ok <= 1'b0;
        end else begin
            ddr_up <= 1'b1;
            source_up_meta <= source_up;
            source_up_sync <= source_up_meta;
            request_meta <= request_toggle;
            request_sync <= request_meta;

            if (handoff) issued_command <= 1'b1;
            if (accepted_read) issued_command <= 1'b0;

            case (state)
                IDLE: begin
                    if (source_up_sync && request_sync != request_seen) begin
                        // held_* has been stable since before request_meta.
                        active_session <= held_session;
                        active_id <= held_id;
                        active_toggle <= request_sync;
                        request_seen <= request_sync;
                        phase <= POLL_HEADER;
                        state <= READ_ISSUE;
                    end
                end
                READ_ISSUE: begin
                    if (accepted_read) state <= READ_WAIT;
                end
                STORE_LOW: state <= STORE_HIGH;
                STORE_HIGH: begin
                    if (beat_index == 4'd15) phase <= VERIFY_COMMIT;
                    else beat_index <= beat_index + 4'd1;
                    state <= READ_ISSUE;
                end
                default: begin end
            endcase

            if (response_now) begin
                case (phase)
                    POLL_HEADER: begin
                        if (ddram_read_data[63:32] == active_session)
                            phase <= POLL_COMMIT;
                        state <= READ_ISSUE;
                    end
                    POLL_COMMIT: begin
                        if (ddram_read_data[31:0] == active_id) begin
                            beat_index <= 4'd0;
                            magic_ok <= 1'b0;
                            session_ok <= 1'b0;
                            id_ok <= 1'b0;
                            reserved_ok <= 1'b1;
                            inside_commit_ok <= 1'b0;
                            phase <= FILL_CACHE;
                        end
                        state <= READ_ISSUE;
                    end
                    FILL_CACHE: begin
                        beat_data <= ddram_read_data;
                        case (beat_index)
                            4'd0: begin
                                magic_ok <= ddram_read_data[31:0] == REPLY_MAGIC;
                                session_ok <= ddram_read_data[63:32] == active_session;
                            end
                            4'd1: begin
                                id_ok <= ddram_read_data[31:0] == active_id;
                                reserved_ok <= reserved_ok && ddram_read_data[63:32] == 0;
                            end
                            4'd2: snapshot_status <= ddram_read_data[31:0];
                            4'd15: begin
                                inside_commit_ok <= ddram_read_data[31:0] == active_id;
                                reserved_ok <= reserved_ok && ddram_read_data[63:32] == 0;
                            end
                            default: begin end
                        endcase
                        state <= STORE_LOW;
                    end
                    VERIFY_COMMIT: begin
                        if (ddram_read_data[31:0] != active_id ||
                            !inside_commit_ok || !session_ok || !id_ok) begin
                            phase <= POLL_HEADER;
                            state <= READ_ISSUE;
                        end else if (!magic_ok || !reserved_ok ||
                                     ddram_read_data[63:32] != 0) begin
                            ddr_fault <= 1'b1;
                            state <= FAULT_HOLD;
                        end else begin
                            completion_session <= active_session;
                            completion_id <= active_id;
                            completion_status <= snapshot_status;
                            completion_toggle <= active_toggle;
                            state <= IDLE;
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end
endmodule
