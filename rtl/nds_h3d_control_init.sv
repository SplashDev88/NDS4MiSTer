// H3D1 shared-DDR control-header and session initializer.
//
// The HPS must never observe a valid header until the old service has stopped
// writing and, in legacy mode, every stale event commit has been removed. For
// each changed nonzero requested_session trigger (or HPS RestartRequested
// state), this block:
//
//   1. reads persistent FPGA-owned quiesce-request word 14 and increments it,
//      skipping zero;
//   2. physically publishes that token in word 14, then H3DQ in word 0;
//   3. polls HPS-owned word 15 until it contains the exact token and zero high;
//   4. clears header words 1 through 13 and, in legacy event mode, every
//      event commit beat;
//   5. writes session/count (or session/reserved in packet mode) while magic
//      remains H3DQ; and
//   6. physically publishes valid H3D1 magic/version/size last.
//
// Words 14 and 15 retain the exact request/ack token through the active H3D1
// session.  This makes the counter persistent across reset and RBF reload.
//
// A request is handed to the registered arbiter when it is presented while
// ddram_busy is low.  The request may then disappear for many clocks before
// ddram_command_accepted reports physical acceptance.  This block remembers
// the issued command and advances only when that remembered command is
// accepted.  The downstream DDR path must preserve accepted write order.
// The 32-bit H3D1 sequence counters use the low half of a 64-bit beat and
// require the high half to stay zero. Heartbeat words are the exception:
// FPGA word 12 carries slow tagged telemetry in its high half, and HPS word
// 13 carries a one-shot diagnostic-freeze token in its high half.
//
// After publication, the block continuously polls the header.  Console
// release requires one clean header sweep, exact HPS Ready state, an exact
// accepted-session match, and no local or HPS fault.  A malformed header,
// nonzero reserved counter half, bad session, invalid service state, or HPS
// fault is sticky for the current session and fails closed.  A different
// nonzero session clears the sticky fault by running the full sequence again.
module nds_h3d_control_init #(
    // FPGA byte address 0x0fc00000 divided by the 64-bit DDR word size.
    parameter logic [28:0] BASE_WORD = 29'h01f80000,
    parameter integer ENTRY_COUNT = 16384,
    // Packet mode reuses header words 2/3 as its producer/ack counters and
    // reserves the high half of word 1.  Legacy event mode remains default.
    parameter bit PACKET_MODE = 1'b0,
    parameter integer HEADER_WORDS64 = 16,
    // One second at the product's retained 60 MHz DDR clock is deliberately
    // longer than a valid render/copy stall, but bounds stale Ready state if
    // the HPS renderer or its supervisor disappears.
    parameter integer HPS_HEARTBEAT_TIMEOUT_CYCLES = 60_000_000,
    // A manual public crash capture briefly holds both CPUs so their register
    // taps are coherent, then releases them even if the HPS process dies.
    parameter integer DIAGNOSTIC_HOLD_CYCLES = 6_000_000
) (
    input  logic        clk,
    input  logic        reset,

    input  logic [31:0] requested_session,
    // Sticky product-path faults already synchronized to this DDR clock.
    // These are folded into the FPGA-owned fault word and hold console reset.
    input  logic [31:0] external_fault_bits,
    // FPGA-owned word 12.  The product supplies compact progress counters;
    // zero retains the historical idle-heartbeat behavior in other users.
    input  logic [31:0] fpga_heartbeat_value,
    // Tagged public-crash telemetry, published in heartbeat word 12's high
    // half. telemetry_index advances slowly enough for a 100 ms HPS sampler.
    input  logic [31:0] fpga_telemetry_value,
    output logic [2:0]  telemetry_index,
    // One-shot CPU hold requested by a changed nonzero token in word 13 high.
    output logic        diagnostic_hold,

    output logic        active,
    output logic        initialized,
    output logic        console_release,
    output logic [31:0] active_session,
    output logic        fault,
    output logic [31:0] fault_bits,

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
    localparam logic [31:0] H3D_MAGIC = 32'h31443348;
    localparam logic [15:0] H3D_VERSION = 16'd1;
    localparam logic [15:0] H3D_HEADER_SIZE = 16'd128;
    localparam logic [63:0] VALID_HEADER_WORD = {
        H3D_HEADER_SIZE, H3D_VERSION, H3D_MAGIC
    };
    // H3DQ is a deliberately invalid H3D1 magic.  HPS treats it as an ordered
    // request to stop all H3D writes and acknowledge word 15.
    localparam logic [31:0] H3D_QUIESCE_MAGIC = 32'h51443348;
    localparam logic [63:0] QUIESCE_HEADER_WORD = {
        H3D_HEADER_SIZE, H3D_VERSION, H3D_QUIESCE_MAGIC
    };
    localparam logic [31:0] ENTRY_COUNT_32 = 32'(ENTRY_COUNT);
    localparam logic [31:0] CONFIG_HIGH_32 =
        PACKET_MODE ? 32'd0 : ENTRY_COUNT_32;

    localparam logic [31:0] FAULT_BAD_HEADER  = 32'h00000001;
    localparam logic [31:0] FAULT_BAD_SESSION = 32'h00000002;
    localparam logic [31:0] FAULT_HPS         = 32'h00000004;
    localparam logic [31:0] FAULT_SERVICE     = 32'h00000008;

    localparam integer COMMIT_INDEX_BITS =
        ENTRY_COUNT <= 2 ? 1 : $clog2(ENTRY_COUNT);
    localparam integer POLL_COUNT = 16;
    localparam integer HEARTBEAT_COUNTER_BITS =
        HPS_HEARTBEAT_TIMEOUT_CYCLES <= 2 ? 1 :
        $clog2(HPS_HEARTBEAT_TIMEOUT_CYCLES);
    localparam integer DIAGNOSTIC_HOLD_COUNTER_BITS =
        DIAGNOSTIC_HOLD_CYCLES <= 2 ? 1 :
        $clog2(DIAGNOSTIC_HOLD_CYCLES);
    localparam logic [COMMIT_INDEX_BITS-1:0] LAST_COMMIT_INDEX =
        COMMIT_INDEX_BITS'(ENTRY_COUNT - 1);
    localparam logic [3:0] LAST_POLL_INDEX = 4'(POLL_COUNT - 1);

    typedef enum logic [3:0] {
        WAIT_SESSION,
        READ_COUNTER_ISSUE,
        READ_COUNTER_WAIT,
        WRITE_QUIESCE_REQUEST,
        WRITE_QUIESCE_MAGIC,
        READ_QUIESCE_ACK_ISSUE,
        READ_QUIESCE_ACK_WAIT,
        CLEAR_HEADER,
        CLEAR_COMMITS,
        WRITE_CONFIG,
        WRITE_MAGIC,
        POLL_ISSUE,
        POLL_WAIT,
        WRITE_FAULT,
        FAULT_HOLD
    } state_t;
    state_t state;

    logic [4:0] header_word_index;
    logic [COMMIT_INDEX_BITS-1:0] commit_index;
    logic [3:0] poll_index;
    logic service_ready;
    logic startup_complete;
    logic heartbeat_seen;
    logic [31:0] last_hps_heartbeat;
    logic [HEARTBEAT_COUNTER_BITS-1:0] heartbeat_stale_cycles;
    // One tag lasts 8192 complete 16-word header sweeps. This adds no DDR
    // operation; it only chooses the high half of the heartbeat write that
    // the control monitor already performs.
    logic [12:0] telemetry_divider;
    logic [31:0] last_diagnostic_token;
    logic [DIAGNOSTIC_HOLD_COUNTER_BITS-1:0]
        diagnostic_hold_cycles;

    logic [31:0] last_requested_session;

    // The client request is a local one-cycle queue handoff.  Physical
    // acceptance can arrive later, when ddram_read/ddram_write are both low.
    logic issued_command;
    logic issued_read;
    logic issued_write;
    // The outer product fabric intentionally preserves a queued physical DDR
    // command across a shell reset so the unreset legacy client can drain.
    // Ignore acceptances until this fresh control epoch has itself presented
    // a command; before that point any acceptance necessarily belongs to the
    // pre-reset epoch and must not be interpreted as this FSM's transaction.
    logic epoch_command_armed;
    logic restart_pending;
    logic service_restart_pending;

    logic [28:0] commit_word_address;
    logic [4:0] current_poll_word;
    logic [31:0] validation_fault;
    logic validation_service_ready;
    logic validation_restart_requested;

    function automatic logic [4:0] poll_word(input logic [3:0] index);
        begin
            case (index)
                4'd0:  poll_word = 5'd5;  // service / accepted session
                4'd1:  poll_word = 5'd4;  // FPGA / HPS faults
                4'd2:  poll_word = 5'd1;  // session / entry count
                4'd3:  poll_word = 5'd0;  // magic / version / size
                4'd4:  poll_word = 5'd2;  // producer / reserved
                4'd5:  poll_word = 5'd3;  // consumer / reserved
                4'd6:  poll_word = 5'd6;  // frame publish / reserved
                4'd7:  poll_word = 5'd7;  // frame ack / reserved
                4'd8:  poll_word = 5'd8;  // descriptor sequence / reserved
                4'd9:  poll_word = 5'd9;  // descriptor session / frame
                4'd10: poll_word = 5'd10; // descriptor bank / format
                4'd11: poll_word = 5'd11; // descriptor size / stride
                4'd12: poll_word = 5'd12; // FPGA heartbeat / reserved
                4'd13: poll_word = 5'd13; // HPS heartbeat / reserved
                4'd14: poll_word = 5'd14; // quiesce request / reserved
                default: poll_word = 5'd15; // quiesce ack / reserved
            endcase
        end
    endfunction

    initial begin
        if (ENTRY_COUNT < 2 ||
            (ENTRY_COUNT & (ENTRY_COUNT - 1)) != 0)
            $fatal(1,
                "H3D control ENTRY_COUNT must be a power of two >= 2");
        if (HEADER_WORDS64 != 16)
            $fatal(1, "H3D1 control header must contain 16 64-bit words");
        if (HPS_HEARTBEAT_TIMEOUT_CYCLES < 2)
            $fatal(1, "H3D HPS heartbeat timeout must be at least 2 clocks");
        if (DIAGNOSTIC_HOLD_CYCLES < 2)
            $fatal(1, "H3D diagnostic hold must be at least 2 clocks");
    end

    wire session_change_requested =
        requested_session != last_requested_session;
    wire presenting_command = ddram_read || ddram_write;
    wire accepted_read = ddram_command_accepted &&
        ((issued_command && issued_read) ||
         (!issued_command && ddram_read));
    wire accepted_write = ddram_command_accepted &&
        ((issued_command && issued_write) ||
         (!issued_command && ddram_write));
    wire accepted_known_command = accepted_read || accepted_write;
    wire poll_response_now =
        (state == POLL_WAIT && ddram_read_data_ready) ||
        (state == POLL_ISSUE && accepted_read &&
         ddram_read_data_ready);
    wire counter_response_now =
        (state == READ_COUNTER_WAIT && ddram_read_data_ready) ||
        (state == READ_COUNTER_ISSUE && accepted_read &&
         ddram_read_data_ready);
    wire ack_response_now =
        (state == READ_QUIESCE_ACK_WAIT && ddram_read_data_ready) ||
        (state == READ_QUIESCE_ACK_ISSUE && accepted_read &&
         ddram_read_data_ready);
    wire heartbeat_refresh_now =
        poll_response_now && current_poll_word == 5'd13 &&
        (!heartbeat_seen ||
         ddram_read_data[31:0] != last_hps_heartbeat);

    always_comb begin
        commit_word_address =
            BASE_WORD + 29'(HEADER_WORDS64) +
            (29'(commit_index) << 2) + 29'd3;
        current_poll_word = poll_word(poll_index);

        active = state != WAIT_SESSION && state != FAULT_HOLD;
        initialized =
            state == POLL_ISSUE || state == POLL_WAIT ||
            state == WRITE_FAULT || state == FAULT_HOLD;
        fault = fault_bits != 0;
        console_release =
            initialized && !fault && startup_complete && service_ready &&
            external_fault_bits == 0 &&
            active_session != 0 && !restart_pending &&
            !service_restart_pending &&
            !(requested_session != 0 && session_change_requested);

        ddram_read = 1'b0;
        ddram_write = 1'b0;
        ddram_burst_count = 8'd1;
        ddram_address = BASE_WORD;
        ddram_write_data = 64'd0;
        ddram_byte_enable = 8'hff;

        // A request is presented only until the registered arbiter queues it.
        case (state)
            READ_COUNTER_ISSUE: begin
                ddram_address = BASE_WORD + 29'd14;
                ddram_read = !issued_command && !ddram_busy;
            end
            WRITE_QUIESCE_REQUEST: begin
                ddram_address = BASE_WORD + 29'd14;
                ddram_write_data = {32'd0, active_session};
                ddram_write = !issued_command && !ddram_busy;
            end
            WRITE_QUIESCE_MAGIC: begin
                ddram_address = BASE_WORD;
                ddram_write_data = QUIESCE_HEADER_WORD;
                ddram_write = !issued_command && !ddram_busy;
            end
            READ_QUIESCE_ACK_ISSUE: begin
                ddram_address = BASE_WORD + 29'd15;
                ddram_read = !issued_command && !ddram_busy;
            end
            CLEAR_HEADER: begin
                ddram_address = BASE_WORD + 29'(header_word_index);
                ddram_write_data = 64'd0;
                ddram_write = !issued_command && !ddram_busy;
            end
            CLEAR_COMMITS: begin
                ddram_address = commit_word_address;
                ddram_write_data = 64'd0;
                ddram_write = !issued_command && !ddram_busy;
            end
            WRITE_CONFIG: begin
                ddram_address = BASE_WORD + 29'd1;
                ddram_write_data = {CONFIG_HIGH_32, active_session};
                ddram_write = !issued_command && !ddram_busy;
            end
            WRITE_MAGIC: begin
                ddram_address = BASE_WORD;
                ddram_write_data = VALID_HEADER_WORD;
                ddram_write = !issued_command && !ddram_busy;
            end
            POLL_ISSUE: begin
                ddram_address = BASE_WORD + 29'(current_poll_word);
                if (current_poll_word == 5'd12) begin
                    ddram_write_data = {
                        fpga_telemetry_value, fpga_heartbeat_value
                    };
                    ddram_write = !issued_command && !ddram_busy &&
                        !restart_pending && !service_restart_pending &&
                        !(requested_session != 0 &&
                          session_change_requested);
                end else begin
                    ddram_read = !issued_command && !ddram_busy &&
                        !restart_pending && !service_restart_pending &&
                        !(requested_session != 0 &&
                          session_change_requested);
                end
            end
            WRITE_FAULT: begin
                // Only the FPGA-owned low 32 bits are modified.  The HPS
                // fault word in the upper half must not be overwritten.
                ddram_address = BASE_WORD + 29'd4;
                ddram_write_data = {32'd0, fault_bits};
                ddram_byte_enable = 8'h0f;
                ddram_write = !issued_command && !ddram_busy;
            end
            default: begin end
        endcase
    end

    // Icarus emits false sensitivity warnings for constant part-selects in
    // always_comb.  This is the same combinational process written as @*.
    always @* begin
        validation_fault = 32'd0;
        validation_service_ready = service_ready;
        validation_restart_requested = 1'b0;

        case (current_poll_word)
            5'd0: begin
                if (ddram_read_data != VALID_HEADER_WORD)
                    validation_fault = FAULT_BAD_HEADER;
            end
            5'd1: begin
                if (ddram_read_data != {CONFIG_HIGH_32, active_session})
                    validation_fault = FAULT_BAD_SESSION;
            end
            5'd2, 5'd3, 5'd6, 5'd7, 5'd8: begin
                if (ddram_read_data[63:32] != 0)
                    validation_fault = FAULT_BAD_HEADER;
            end
            5'd4: begin
                if (ddram_read_data[63:32] != 0)
                    validation_fault =
                        FAULT_HPS | ddram_read_data[63:32];
                else if (ddram_read_data[31:0] != 0)
                    validation_fault = ddram_read_data[31:0];
            end
            5'd9, 5'd10, 5'd11: begin end
            // Heartbeat high halves are versioned diagnostic extensions:
            // word 12 is FPGA-owned telemetry and word 13 is an HPS-owned
            // one-shot freeze token. Neither is a sequence-counter reserve.
            5'd12, 5'd13: begin end
            5'd5: begin
                validation_service_ready =
                    ddram_read_data[31:0] == 32'd2 &&
                    ddram_read_data[63:32] == active_session;

                if (ddram_read_data[31:0] == 32'd4) begin
                    validation_restart_requested =
                        ddram_read_data[63:32] == 0 ||
                        ddram_read_data[63:32] == active_session;
                    if (ddram_read_data[63:32] != 0 &&
                        ddram_read_data[63:32] != active_session)
                        validation_fault = FAULT_BAD_SESSION;
                end else if (ddram_read_data[31:0] > 32'd4 ||
                    ddram_read_data[31:0] == 32'd3)
                    validation_fault = FAULT_SERVICE;
                else if (ddram_read_data[63:32] != 0 &&
                    ddram_read_data[63:32] != active_session)
                    validation_fault = FAULT_BAD_SESSION;
                else if (ddram_read_data[31:0] == 32'd2 &&
                    ddram_read_data[63:32] != active_session)
                    validation_fault = FAULT_BAD_SESSION;
            end
            5'd14, 5'd15: begin
                if (ddram_read_data != {32'd0, active_session})
                    validation_fault = FAULT_BAD_SESSION;
            end
            default: validation_fault = FAULT_BAD_HEADER;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= WAIT_SESSION;
            active_session <= 32'd0;
            last_requested_session <= 32'd0;
            fault_bits <= 32'd0;
            header_word_index <= 5'd1;
            commit_index <= '0;
            poll_index <= 4'd0;
            service_ready <= 1'b0;
            startup_complete <= 1'b0;
            heartbeat_seen <= 1'b0;
            last_hps_heartbeat <= 32'd0;
            heartbeat_stale_cycles <= '0;
            telemetry_divider <= '0;
            telemetry_index <= '0;
            last_diagnostic_token <= 32'd0;
            diagnostic_hold <= 1'b0;
            diagnostic_hold_cycles <= '0;
            issued_command <= 1'b0;
            issued_read <= 1'b0;
            issued_write <= 1'b0;
            epoch_command_armed <= 1'b0;
            restart_pending <= 1'b0;
            service_restart_pending <= 1'b0;
        end else begin
            // A manual hold is a bounded diagnostic lease, never a persistent
            // mode. This guarantees that a dead/crashed HPS cannot strand a
            // public user's game in debugger halt.
            if (diagnostic_hold) begin
                if (diagnostic_hold_cycles == 0)
                    diagnostic_hold <= 1'b0;
                else
                    diagnostic_hold_cycles <=
                        diagnostic_hold_cycles - 1'b1;
            end

            // Zero is an idle trigger value, not a request to tear down the
            // active session.  Remembering it lets the same nonzero external
            // token trigger again after a low interval.
            if (requested_session == 0)
                last_requested_session <= 32'd0;
            else if (session_change_requested) begin
                last_requested_session <= requested_session;
                restart_pending <= 1'b1;
            end

            // Remember the locally queued command.  A same-cycle physical
            // acceptance clears this again below.
            if (presenting_command) begin
                issued_command <= 1'b1;
                issued_read <= ddram_read;
                issued_write <= ddram_write;
                epoch_command_armed <= 1'b1;
            end
            if (ddram_command_accepted && accepted_known_command) begin
                issued_command <= 1'b0;
                issued_read <= 1'b0;
                issued_write <= 1'b0;
            end

            // Start only at an idle protocol boundary.  An already queued
            // arbiter command or accepted read response must drain first.
            if ((restart_pending || service_restart_pending ||
                (requested_session != 0 && session_change_requested)) &&
                !issued_command &&
                (state == WAIT_SESSION || state == POLL_ISSUE ||
                 state == FAULT_HOLD)) begin
                fault_bits <= 32'd0;
                service_ready <= 1'b0;
                startup_complete <= 1'b0;
                heartbeat_seen <= 1'b0;
                last_hps_heartbeat <= 32'd0;
                heartbeat_stale_cycles <= '0;
                last_diagnostic_token <= 32'd0;
                diagnostic_hold <= 1'b0;
                diagnostic_hold_cycles <= '0;
                header_word_index <= 5'd1;
                commit_index <= '0;
                poll_index <= 4'd0;
                restart_pending <= 1'b0;
                service_restart_pending <= 1'b0;
                issued_command <= 1'b0;
                issued_read <= 1'b0;
                issued_write <= 1'b0;
                state <= READ_COUNTER_ISSUE;
            end else if (counter_response_now) begin
                // Word 14 is FPGA-owned persistent DDR state.  Its previous
                // low word is the counter authority across resets and RBF
                // reloads.  Overwrite any malformed old high word when the
                // new request is published.
                if (ddram_read_data[31:0] == 32'hffffffff)
                    active_session <= 32'd1;
                else
                    active_session <= ddram_read_data[31:0] + 1'b1;
                state <= WRITE_QUIESCE_REQUEST;
            end else if (ack_response_now) begin
                if (ddram_read_data == {32'd0, active_session}) begin
                    // The exact ack is the only permission to overwrite any
                    // HPS-owned word or stale event state.
                    header_word_index <= 5'd1;
                    state <= CLEAR_HEADER;
                end else begin
                    state <= READ_QUIESCE_ACK_ISSUE;
                end
            end else if (poll_response_now) begin
                if (current_poll_word == 5'd5)
                    service_ready <= validation_service_ready;
                if (current_poll_word == 5'd13 &&
                    (!heartbeat_seen ||
                     ddram_read_data[31:0] != last_hps_heartbeat)) begin
                    heartbeat_seen <= 1'b1;
                    last_hps_heartbeat <= ddram_read_data[31:0];
                end
                if (current_poll_word == 5'd13 &&
                    ddram_read_data[63:32] != 0 &&
                    ddram_read_data[63:32] != last_diagnostic_token) begin
                    last_diagnostic_token <= ddram_read_data[63:32];
                    diagnostic_hold <= 1'b1;
                    diagnostic_hold_cycles <=
                        DIAGNOSTIC_HOLD_COUNTER_BITS'(
                            DIAGNOSTIC_HOLD_CYCLES - 1);
                end

                if (validation_fault != 0) begin
                    fault_bits <= fault_bits | validation_fault;
                    service_ready <= 1'b0;
                    startup_complete <= 1'b0;
                    state <= WRITE_FAULT;
                end else if (validation_restart_requested) begin
                    service_ready <= 1'b0;
                    startup_complete <= 1'b0;
                    service_restart_pending <= 1'b1;
                    state <= POLL_ISSUE;
                end else if (poll_index == LAST_POLL_INDEX) begin
                    poll_index <= 4'd0;
                    if (service_ready)
                        startup_complete <= 1'b1;
                    state <= POLL_ISSUE;
                end else begin
                    poll_index <= poll_index + 1'b1;
                    state <= POLL_ISSUE;
                end
            end else begin
                case (state)
                    WAIT_SESSION: begin
                        // External and service requests are handled above.
                    end
                    READ_COUNTER_ISSUE: begin
                        if (accepted_read)
                            state <= READ_COUNTER_WAIT;
                    end
                    READ_COUNTER_WAIT: begin
                        // Delayed data is handled by counter_response_now.
                    end
                    WRITE_QUIESCE_REQUEST: begin
                        if (accepted_write)
                            state <= WRITE_QUIESCE_MAGIC;
                    end
                    WRITE_QUIESCE_MAGIC: begin
                        if (accepted_write)
                            state <= READ_QUIESCE_ACK_ISSUE;
                    end
                    READ_QUIESCE_ACK_ISSUE: begin
                        if (accepted_read)
                            state <= READ_QUIESCE_ACK_WAIT;
                    end
                    READ_QUIESCE_ACK_WAIT: begin
                        // Delayed data is handled by ack_response_now.
                    end
                    CLEAR_HEADER: begin
                        if (accepted_write) begin
                            // Words 14 and 15 keep the exact request/ack token
                            // throughout the active H3D1 session.
                            if (header_word_index == 5'd13) begin
                                if (PACKET_MODE) begin
                                    // Cleared producer/ack counters and the
                                    // per-packet session tag make stale H3B
                                    // slot commits unreachable.
                                    state <= WRITE_CONFIG;
                                end else begin
                                    commit_index <= '0;
                                    state <= CLEAR_COMMITS;
                                end
                            end else begin
                                header_word_index <=
                                    header_word_index + 1'b1;
                            end
                        end
                    end
                    CLEAR_COMMITS: begin
                        if (accepted_write) begin
                            if (commit_index == LAST_COMMIT_INDEX) begin
                                state <= WRITE_CONFIG;
                            end else begin
                                commit_index <= commit_index + 1'b1;
                            end
                        end
                    end
                    WRITE_CONFIG: begin
                        if (accepted_write)
                            state <= WRITE_MAGIC;
                    end
                    WRITE_MAGIC: begin
                        if (accepted_write) begin
                            poll_index <= 4'd0;
                            state <= POLL_ISSUE;
                        end
                    end
                    POLL_ISSUE: begin
                        if (current_poll_word == 5'd12 && accepted_write) begin
                            telemetry_divider <= telemetry_divider + 1'b1;
                            // Normal gameplay keeps each tag visible long
                            // enough for the 10 Hz HPS flight recorder.  An
                            // explicitly requested bounded hold rotates the
                            // tags quickly so the manual burst collects the
                            // complete snapshot without increasing DDR
                            // traffic in either mode.
                            if (diagnostic_hold &&
                                &telemetry_divider[3:0]) begin
                                telemetry_divider <= '0;
                                telemetry_index <= telemetry_index + 1'b1;
                            end else if (!diagnostic_hold &&
                                &telemetry_divider) begin
                                telemetry_divider <= '0;
                                telemetry_index <= telemetry_index + 1'b1;
                            end
                            poll_index <= poll_index + 1'b1;
                            state <= POLL_ISSUE;
                        end else if (accepted_read)
                            state <= POLL_WAIT;
                    end
                    POLL_WAIT: begin
                        // A delayed response is handled by poll_response_now.
                    end
                    WRITE_FAULT: begin
                        if (accepted_write)
                            state <= FAULT_HOLD;
                    end
                    FAULT_HOLD: begin
                        // A new external or service request is handled above.
                    end
                    default: state <= WAIT_SESSION;
                endcase
            end

            // An acceptance with no remembered or currently presented
            // command is an ownership/protocol failure.  It is not safe to
            // guess which state should advance.
            if (ddram_command_accepted && epoch_command_armed &&
                !accepted_known_command) begin
                fault_bits <= fault_bits | FAULT_BAD_HEADER;
                service_ready <= 1'b0;
                startup_complete <= 1'b0;
                state <= WRITE_FAULT;
            end

            // Highest-priority fail-closed input.  It is sampled after normal
            // FSM work so no same-edge poll/session transition can overwrite
            // the sticky external fault or release the console.
            if (external_fault_bits != 0 &&
                state != WRITE_FAULT && state != FAULT_HOLD) begin
                fault_bits <= fault_bits | external_fault_bits;
                service_ready <= 1'b0;
                startup_complete <= 1'b0;
                state <= WRITE_FAULT;
            end

            // Once released, stale Ready state is insufficient: HPS must
            // continue advancing word 13.  A refresh on the expiry edge wins.
            if (!console_release || heartbeat_refresh_now) begin
                heartbeat_stale_cycles <= '0;
            end else if (heartbeat_stale_cycles <
                HEARTBEAT_COUNTER_BITS'(
                    HPS_HEARTBEAT_TIMEOUT_CYCLES - 1)) begin
                heartbeat_stale_cycles <= heartbeat_stale_cycles + 1'b1;
            end else if (state != WRITE_FAULT && state != FAULT_HOLD) begin
                fault_bits <= fault_bits | FAULT_SERVICE |
                    external_fault_bits;
                service_ready <= 1'b0;
                startup_complete <= 1'b0;
                state <= WRITE_FAULT;
            end
        end
    end
endmodule
