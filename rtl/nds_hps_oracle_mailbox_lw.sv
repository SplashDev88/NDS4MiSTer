// HPS oracle mailbox over the lightweight bridge.
//
// Drop-in alternative to nds_hps_oracle_mailbox: identical CPU-side interface,
// different transport. The DDR mailbox costs four DDR interactions per request
// (FPGA write burst, HPS poll, HPS write, FPGA poll) all contending with the
// video fetcher through the shared DDRAM arbiter. Profiling put ~24 us of the
// ~42 us per-request budget in that handshake -- more than half of all wall
// time -- against ~1.4 us for the bus access that is the actual work.
//
// Here the request lives in fabric registers the HPS reads directly at
// 0xFF200000. The HPS is the only master on this bridge, so it polls STATUS,
// reads the request, and writes the response; writing RESPONSE_FLAGS is the
// completion point and releases the stalled CPU.
//
// Register map, 32-bit words at 0xFF200000 + offset:
//   0x00 STATUS   r  {31:1 sequence, 0 pending}
//   0x04 ADDRESS  r  transaction address
//   0x08 WDATA    r  write payload
//   0x0c CONTROL  r  {31:4 unused, 3 cpu_is_arm9, 2:1 access, 0 read_not_write}
//   0x10 CYCLES   r  elapsed CPU cycles since the last flush
//   0x14 FENCE    r  posted-write sequence that must drain before servicing
//   0x18 RDATA    w  read result
//   0x1c FLAGS    w  {3 halt_arm7, 2 halt_arm9, 1 irq_arm7, 0 irq_arm9}
//                    -- writing this completes the transaction
//   0x20 PRODUCER r  newest safe posted-write sequence advertised by FPGA
//   0x24 CONSUMER rw newest posted-write sequence fully consumed by HPS
//   0x28 DOORBELL r  {28'h0, posted_pending, mailbox_pending, error, irq}
//   0x2c ABI      r  0x4e445332 ("NDS2")
//   0x30 SESSION  rw nonzero HPS ownership claim; does not arm transport
//   0x5c CAPS     r  {26'h0, verified_producer, time_irq_reverse, two_phase,
//                     epoch_commit, gx_posted, vram_posted}
//   0x60 ARM      rw write the same nonzero SESSION cookie after DDR init
//   0x64 FENCE_EPOCH r session epoch captured with the pending mailbox request
//   0x68 TIME_IRQ_CONSUMER r reverse-ring consumer sequence; zero unless the
//                            optional feature and current session are healthy
//
// Words 0x0d..0x16 are reserved for the r272 sound diagnostic overlay. Keep
// the transport ABI outside that passive read-only window.
//
// The interrupt is a level, not an event counter. Linux may coalesce IRQs, so
// userspace must drain work through PRODUCER, publish CONSUMER, then re-read
// DOORBELL until no work remains. A response FLAGS write completes only the
// blocking CPU request; it cannot acknowledge posted work.
module nds_hps_oracle_mailbox_lw #(
    // Cap bit 1 advertises the exact default-off GX posting scope selected by
    // the enclosing memory bridge. The production top leaves this at zero.
    parameter bit GX_POSTED_ENABLE = 0,
    // Cap bit 5 changes PRODUCER from the raw physical commit frontier to the
    // largest contiguous verified frontier. Keep this default-off until the
    // posted producer, verifier, and HPS consumer are integrated together.
    parameter bit VERIFIED_POSTED_PRODUCER_ENABLE = 0,
    // Cap bit 4 advertises a reverse time/IRQ wakeup source. Keep this
    // default-off so the existing NDS2 transport remains byte-identical until
    // the interrupt consumer is integrated deliberately.
    parameter bit TIME_IRQ_REVERSE_ENABLE = 0,
    // Capability bit 6 advertises the independent blocking ETW control
    // plane. Bit 5 remains the verified posted-producer contract; a safe ETW
    // responder requires both and must never reinterpret bit 5 alone.
    parameter bit BLOCKING_ETW_ENABLE = 0,
    // Capability bit 7 identifies the exact words 63..74 local-LCD queue.
    // Keep it independent from ETW so HPS can require the complete ABI and
    // fail closed before probing the queue identity.
    parameter bit LOCAL_LCD_ENABLE = 0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        request,
    input  logic        cpu_is_arm9,
    input  logic [31:0] elapsed_cycles,
    input  logic [31:0] fence_sequence,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,
    output logic        irq_arm9,
    output logic        irq_arm7,
    output logic        halt_arm9,
    output logic        halt_arm7,
    output logic        done,
    output logic [31:0] completed_fence_sequence,
    output logic [31:0] completed_fence_epoch,
    output logic [3:0]  debug_state,
    // Combined level IRQ for blocking mailbox and posted-write work.
    output logic        request_pending_irq,

    // A posted entry is advertised only after its commit marker has reached
    // DDR. The HPS acknowledgement is exported to the ring as an explicit
    // pulse/sequence pair; the ring must validate it independently too.
    input  logic        posted_commit,
    input  logic [31:0] posted_commit_sequence,
    input  logic        posted_commit_requires_verification,
    output logic        posted_commit_ready,
    output logic        posted_commit_accepted,
    input  logic        posted_verify,
    input  logic [31:0] posted_verify_sequence,
    output logic        posted_verify_ready,
    output logic        posted_verify_accepted,
    output logic [31:0] safe_posted_producer_sequence,
    input  logic        transport_fault,
    output logic        posted_ack,
    output logic [31:0] posted_ack_epoch,
    output logic [31:0] posted_ack_sequence,
    output logic        doorbell_protocol_error,
    output logic        transport_ready,
    output logic [31:0] active_session_epoch,
    output logic [31:0] active_session_capabilities,
    input  logic [31:0] time_irq_consumer_sequence,
    output logic [31:0] pending_source_id,

    // Register-file side of nds_hps_lw_slave.
    input  logic [18:0] reg_raddr,
    output logic [31:0] reg_rdata,
    input  logic [18:0] reg_waddr,
    input  logic [31:0] reg_wdata,
    input  logic [3:0]  reg_be,
    input  logic        reg_write
);
    typedef enum logic [3:0] {IDLE, PENDING, COMPLETE, WAIT_RELEASE} state_t;
    state_t state;

    logic [30:0] sequence_counter;
    logic [31:0] saved_address, saved_write_data, saved_cycles, saved_fence;
    logic [31:0] saved_fence_epoch;
    logic        saved_rnw, saved_cpu;
    logic [1:0]  saved_access;
    logic [31:0] response_data;
    logic [31:0] advertised_sequence;
    logic [31:0] acknowledged_sequence;
    logic        doorbell_irq;
    logic        doorbell_sequence_error;
    logic        register_protocol_error;
    logic        mailbox_pending;
    logic        posted_pending;
    logic        ack_write;
    logic [31:0] session_cookie;
    logic [31:0] armed_cookie;
    logic        rdata_write_legal;
    logic        flags_write_legal;
    logic        consumer_write_legal;
    logic        session_write_legal;
    logic        arm_write_legal;
    logic        register_write_legal;
    logic        verified_frontier_enable;
    logic        verified_frontier_advanced;
    logic [31:0] verified_frontier_sequence;
    logic        verified_frontier_protocol_error;
    logic        doorbell_posted_commit;
    logic [31:0] doorbell_posted_commit_sequence;

    // Word offsets within the slave's aperture.
    localparam logic [18:0] REG_STATUS  = 19'h0;
    localparam logic [18:0] REG_ADDRESS = 19'h1;
    localparam logic [18:0] REG_WDATA   = 19'h2;
    localparam logic [18:0] REG_CONTROL = 19'h3;
    localparam logic [18:0] REG_CYCLES  = 19'h4;
    localparam logic [18:0] REG_FENCE   = 19'h5;
    localparam logic [18:0] REG_RDATA   = 19'h6;
    localparam logic [18:0] REG_FLAGS   = 19'h7;
    localparam logic [18:0] REG_PRODUCER = 19'h8;
    localparam logic [18:0] REG_CONSUMER = 19'h9;
    localparam logic [18:0] REG_DOORBELL = 19'ha;
    localparam logic [18:0] REG_ABI      = 19'hb;
    localparam logic [18:0] REG_SESSION  = 19'hc;
    localparam logic [18:0] REG_CAPS     = 19'h17;
    localparam logic [18:0] REG_ARM      = 19'h18;
    localparam logic [18:0] REG_FENCE_EPOCH = 19'h19;
    localparam logic [18:0] REG_TIME_IRQ_CONSUMER = 19'h1a;
    localparam logic [31:0] LW_ABI_MAGIC = 32'h4e445332;
    localparam logic [31:0] LW_CAPABILITIES =
        32'h0000000d |
        (GX_POSTED_ENABLE ? 32'h00000002 : 32'h0) |
        (TIME_IRQ_REVERSE_ENABLE ? 32'h00000010 : 32'h0) |
        (VERIFIED_POSTED_PRODUCER_ENABLE ? 32'h00000020 : 32'h0) |
        (BLOCKING_ETW_ENABLE ? 32'h00000040 : 32'h0) |
        (LOCAL_LCD_ENABLE ? 32'h00000080 : 32'h0);

    assign debug_state = state;
    assign mailbox_pending = (state == PENDING);
    assign posted_pending =
        advertised_sequence != acknowledged_sequence;
    // Fail closed at the register boundary.  AXI writes are legal only for the
    // five writable words, in the protocol state in which each word has
    // meaning, and only while the current session is healthy.  In particular,
    // a sticky error cannot be "recovered" by a later ACK; reset plus a fresh
    // session is the only recovery boundary.
    assign rdata_write_legal = reg_write && reg_waddr == REG_RDATA &&
        reg_be == 4'hf && state == PENDING && !doorbell_protocol_error;
    assign flags_write_legal = reg_write && reg_waddr == REG_FLAGS &&
        reg_be == 4'hf && state == PENDING && !doorbell_protocol_error;
    assign consumer_write_legal = reg_write && reg_waddr == REG_CONSUMER &&
        reg_be == 4'hf && transport_ready &&
        !doorbell_protocol_error;
    assign session_write_legal = reg_write && reg_waddr == REG_SESSION &&
        reg_be == 4'hf && reg_wdata != 0 && state == IDLE &&
        !doorbell_protocol_error && advertised_sequence == 0 &&
        acknowledged_sequence == 0 && session_cookie == 0 &&
        armed_cookie == 0;
    assign arm_write_legal = reg_write && reg_waddr == REG_ARM &&
        reg_be == 4'hf && reg_wdata != 0 && state == IDLE &&
        !doorbell_protocol_error && advertised_sequence == 0 &&
        acknowledged_sequence == 0 && session_cookie != 0 &&
        armed_cookie == 0 && reg_wdata == session_cookie;
    assign register_write_legal = rdata_write_legal || flags_write_legal ||
        consumer_write_legal || session_write_legal || arm_write_legal;
    assign ack_write = consumer_write_legal;
    assign posted_ack_sequence = acknowledged_sequence;
    assign posted_ack_epoch = active_session_epoch;
    // Once either side detects a protocol fault, revoke admission
    // immediately. An already-active ring entry may finish its atomic
    // commit-last sequence, but no later CPU write can be accepted until a
    // full transport reset establishes a new session.
    assign transport_ready = session_cookie != 0 &&
                             armed_cookie == session_cookie &&
                             !doorbell_protocol_error;
    assign active_session_epoch = transport_ready ? session_cookie : 32'h0;
    assign active_session_capabilities =
        transport_ready ? LW_CAPABILITIES : 32'h0;
    assign safe_posted_producer_sequence =
        VERIFIED_POSTED_PRODUCER_ENABLE ?
        verified_frontier_sequence : advertised_sequence;
    // The reverse interrupt identifies exactly the serialized blocking source
    // visible in STATUS[31:1]. It is valid only while that source is pending;
    // completion, reset, or any protocol/transport fault withdraws it
    // immediately. Sequence zero is never advertised by the enabled feature.
    assign pending_source_id =
        TIME_IRQ_REVERSE_ENABLE && !reset && state == PENDING &&
        !doorbell_protocol_error ? {1'b0, sequence_counter} : 32'h0;
    // Reset invalidates both producer and consumer state. Holding the IRQ and
    // refusing posted admission until HPS installs a fresh nonzero session
    // cookie prevents stale userspace credit from crossing a core reset.
    assign request_pending_irq = doorbell_irq | !transport_ready;
    assign doorbell_protocol_error =
        doorbell_sequence_error | register_protocol_error | transport_fault |
        verified_frontier_protocol_error;

    // Runtime ownership for the verifier deliberately excludes its own sticky
    // error to avoid a combinational self-loop. Once that error is registered,
    // the frontier is already in its terminal fault state and transport_ready
    // is revoked through doorbell_protocol_error.
    assign verified_frontier_enable = session_cookie != 0 &&
        armed_cookie == session_cookie && !register_protocol_error &&
        !transport_fault && !doorbell_sequence_error;

    generate
        if (VERIFIED_POSTED_PRODUCER_ENABLE) begin : g_verified_producer
            logic [31:0] unused_last_physical_sequence;
            logic unused_verification_pending;
            logic [31:0] unused_pending_sequence;

            nds_verified_posted_producer_frontier #(
                .ENABLED(1'b1)
            ) verified_frontier (
                .clk,
                .reset,
                .enable(verified_frontier_enable),
                .physical_commit_valid(posted_commit),
                .physical_commit_sequence(posted_commit_sequence),
                .physical_commit_requires_verification(
                    posted_commit_requires_verification),
                .physical_commit_ready(posted_commit_ready),
                .physical_commit_accepted(posted_commit_accepted),
                .verify_valid(posted_verify),
                .verify_sequence(posted_verify_sequence),
                .verify_ready(posted_verify_ready),
                .verify_accepted(posted_verify_accepted),
                .advertised_sequence(verified_frontier_sequence),
                .frontier_advanced(verified_frontier_advanced),
                .last_physical_sequence(unused_last_physical_sequence),
                .verification_pending(unused_verification_pending),
                .pending_sequence(unused_pending_sequence),
                .protocol_error(verified_frontier_protocol_error)
            );

            // The legacy doorbell remains the ACK/IRQ owner, but it sees only
            // verified frontier advances. A special physical commit therefore
            // cannot become visible in PRODUCER before its matching proof.
            assign doorbell_posted_commit = verified_frontier_advanced;
            assign doorbell_posted_commit_sequence =
                verified_frontier_sequence;
        end else begin : g_legacy_producer
            // Preserve the existing byte-for-byte protocol behavior: raw
            // physical commits feed the doorbell directly and verification
            // metadata is completely inert when capability bit 5 is clear.
            assign posted_commit_ready = !reset;
            assign posted_commit_accepted = posted_commit && !reset;
            assign posted_verify_ready = 1'b0;
            assign posted_verify_accepted = 1'b0;
            assign verified_frontier_sequence = advertised_sequence;
            assign verified_frontier_advanced = 1'b0;
            assign verified_frontier_protocol_error = 1'b0;
            assign doorbell_posted_commit = posted_commit;
            assign doorbell_posted_commit_sequence = posted_commit_sequence;
        end
    endgenerate

    nds_hps_irq_doorbell work_doorbell (
        .clk(clk), .reset(reset),
        .mailbox_pending(mailbox_pending),
        .posted_commit(doorbell_posted_commit),
        .posted_commit_sequence(doorbell_posted_commit_sequence),
        .hps_ack(ack_write), .hps_ack_sequence(reg_wdata),
        .external_error(transport_fault | register_protocol_error |
                        verified_frontier_protocol_error),
        .irq(doorbell_irq),
        .advertised_sequence(advertised_sequence),
        .acknowledged_sequence(acknowledged_sequence),
        .ack_accepted(posted_ack),
        .protocol_error(doorbell_sequence_error)
    );

    // Combinational read. The sequence in STATUS lets the HPS tell a genuinely
    // new request apart from a repeat read of one it has already serviced.
    always_comb begin
        case (reg_raddr)
            REG_STATUS:  reg_rdata = {sequence_counter, state == PENDING};
            REG_ADDRESS: reg_rdata = saved_address;
            REG_WDATA:   reg_rdata = saved_write_data;
            REG_CONTROL: reg_rdata = {28'h0, saved_cpu, saved_access, saved_rnw};
            REG_CYCLES:  reg_rdata = saved_cycles;
            REG_FENCE:   reg_rdata = saved_fence;
            REG_PRODUCER: reg_rdata = advertised_sequence;
            REG_CONSUMER: reg_rdata = acknowledged_sequence;
            REG_DOORBELL: reg_rdata = {
                27'h0, !transport_ready, posted_pending, mailbox_pending,
                doorbell_protocol_error,
                request_pending_irq};
            REG_ABI:      reg_rdata = LW_ABI_MAGIC;
            REG_SESSION:  reg_rdata = session_cookie;
            REG_CAPS:     reg_rdata = LW_CAPABILITIES;
            REG_ARM:      reg_rdata = armed_cookie;
            REG_FENCE_EPOCH: reg_rdata = saved_fence_epoch;
            REG_TIME_IRQ_CONSUMER: reg_rdata =
                TIME_IRQ_REVERSE_ENABLE && !reset && transport_ready ?
                time_irq_consumer_sequence : 32'h0;
            default:     reg_rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            sequence_counter <= 31'h0;
            done <= 1'b0;
            read_data <= 32'h0;
            response_data <= 32'h0;
            irq_arm9 <= 1'b0; irq_arm7 <= 1'b0;
            halt_arm9 <= 1'b0; halt_arm7 <= 1'b0;
            completed_fence_sequence <= 32'h0;
            completed_fence_epoch <= 32'h0;
            saved_address <= 32'h0; saved_write_data <= 32'h0;
            saved_cycles <= 32'h0; saved_fence <= 32'h0;
            saved_fence_epoch <= 32'h0;
            saved_rnw <= 1'b0; saved_cpu <= 1'b0; saved_access <= 2'h0;
            register_protocol_error <= 1'b0;
            session_cookie <= 32'h0;
            armed_cookie <= 32'h0;
        end else begin
            done <= 1'b0;

            // Read-only, unmapped, partial-width, out-of-state, or post-fault
            // stores are all protocol violations.  Never silently accept an
            // ABI mismatch or let a malformed response change live payload.
            if (reg_write && !register_write_legal)
                register_protocol_error <= 1'b1;
            if (rdata_write_legal)
                response_data <= reg_wdata;
            if (session_write_legal)
                session_cookie <= reg_wdata;
            if (arm_write_legal)
                armed_cookie <= reg_wdata;

            case (state)
                IDLE: if (request && transport_ready) begin
                    // Source ID zero is reserved for "no pending source". An
                    // enabled reverse-wakeup transport therefore fails closed
                    // instead of wrapping the 31-bit STATUS sequence to zero.
                    // The default-off legacy transport retains its historical
                    // wrap behavior exactly.
                    if (TIME_IRQ_REVERSE_ENABLE &&
                        sequence_counter == 31'h7fffffff) begin
                        register_protocol_error <= 1'b1;
                    end else begin
                        sequence_counter <= sequence_counter + 1'b1;
                        saved_address <= address;
                        saved_write_data <= write_data;
                        saved_rnw <= read_not_write;
                        saved_access <= access;
                        saved_cpu <= cpu_is_arm9;
                        saved_cycles <= elapsed_cycles;
                        saved_fence <= fence_sequence;
                        saved_fence_epoch <= active_session_epoch;
                        state <= PENDING;
                    end
                end
                PENDING: if (flags_write_legal) begin
                    // The HPS has drained posted writes through saved_fence
                    // before publishing this response, so return that exact
                    // ordering point with the completion.
                    read_data <= (reg_write && reg_waddr == REG_RDATA)
                        ? reg_wdata : response_data;
                    irq_arm9  <= reg_wdata[0];
                    irq_arm7  <= reg_wdata[1];
                    halt_arm9 <= reg_wdata[2];
                    halt_arm7 <= reg_wdata[3];
                    completed_fence_sequence <= saved_fence;
                    completed_fence_epoch <= saved_fence_epoch;
                    done <= 1'b1;
                    state <= WAIT_RELEASE;
                end
                WAIT_RELEASE: if (!request) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
