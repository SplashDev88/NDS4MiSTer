module nds_cpu_memory_system #(
    parameter logic [28:0] MAIN_RAM_BASE_WORD = 29'h05820000,
    parameter logic [28:0] SHARED_WRAM_BASE_WORD = 29'h05802000,
    parameter logic [28:0] ARM7_WRAM_BASE_WORD = 29'h05804000,
    parameter logic [28:0] ORACLE_BASE_WORD = 29'h05800000,
    parameter logic [28:0] POSTED_RING_BASE_WORD = 29'h05806000,
    parameter integer ORACLE_POLL_DELAY_CYCLES = 64,
    // Diagnostic-only: the first corrupt post-IRQ ARM9 write observed on
    // hardware targets 0x0400009f and carries a fetched opcode as data.
    // Substitute the issuing PC in that already-invalid write payload so the
    // HPS flight log can identify its exact producer.
    parameter bit ARM9_BAD_WRITE_PC_TELEMETRY = 0,
    // Diagnostic-only: FPGA-local ARM7 RAM/BIOS traffic never reaches the
    // oracle, so an external ARM7 write outside the 0x04xxxxxx I/O aperture
    // is already invalid. Replace only that invalid payload with the issuing
    // PC to identify the first address-runaway instruction without changing
    // production timing cadence or any valid transaction.
    parameter bit ARM7_INVALID_WRITE_PC_TELEMETRY = 0,
    // Diagnostic-only: legitimate DIV/SQRT programming is short. After a
    // sustained run of completed ARM9 writes across 0x04000280..0x040002bf,
    // latch the PC that began the run and substitute it into later writes in
    // that already-corrupt run. Repeating the latched tag makes the evidence
    // observable after the mandatory safe-load verification gate.
    parameter bit ARM9_MATH_RUNAWAY_PC_TELEMETRY = 0,
    parameter integer ARM9_MATH_RUNAWAY_THRESHOLD = 256,
    // Diagnostic-only: while ARM9 is parked in the post-boot polling loop,
    // publish the live DTCM IRQ vector and guard state in timing telemetry.
    // The legacy parameter name is retained so archived diagnostic tops and
    // mixed-language compile stubs remain source-compatible.
    parameter bit ARM9_POLL_ADDRESS_TELEMETRY = 0,
    // Diagnostic-only: shadow the SDK IRQ handler-table word at DTCM+0x3c0
    // and export it on alternating ARM9 timing buckets. HPS cannot directly
    // inspect FPGA-local TCM BRAM, so this captures the hardware-only state
    // without redirecting the CPU's architectural read or write.
    parameter bit ARM9_DTCM_HANDLER_TELEMETRY = 0,
    // Production batching keeps timing-only mailbox traffic low while both
    // CPUs execute from FPGA-local memory.
    parameter integer TIME_FLUSH_CYCLES = 8192,
    // clk_sys is 60 MHz while the DS scheduler runs at roughly 33.5 MHz.
    // Batch a little under 1 ms of idle DS time per mailbox transaction.
    // This keeps halted CPUs wakeable without flooding the HPS responder.
    parameter integer HALT_POLL_CLOCKS = 60000,
    parameter integer HALT_ADVANCE_CYCLES = 32768,
    // Posted writes do not themselves return IRQ/HALT state to FPGA. A
    // zero-cycle fenced mailbox refresh at this cadence prevents a sustained
    // VRAM stream from starving VBlank while retaining nearly all batching.
    parameter integer POSTED_IRQ_REFRESH_WRITES = 256,
    // Simulator-first functional candidate. When explicitly enabled, route
    // only aligned ARM9 word writes in the exact geometry command aperture
    // through the same ordered/fenced ring as the proven VRAM halfword page.
    // Reads, ARM7 accesses, narrow/unaligned writes, and neighboring I/O stay
    // on the authoritative mailbox path. Production must remain default-off
    // until hardware differential validation proves identical GX behavior.
    parameter bit GX_POSTED_ENABLE = 0,
    // Simulator-first migration aid. When enabled, passively normalize
    // external ARM9 GX writes beside the authoritative HPS mailbox path.
    // The shadow has no connection to CPU completion, read data, IRQ/HALT,
    // pause, DDR routing, or GXSTAT. Keep disabled in production until its
    // command stream has been validated against the HPS model.
    parameter bit GX_COMMAND_SHADOW_ENABLE = 0,
    parameter integer GX_COMMAND_SHADOW_QUEUE_DEPTH = 16,
    // Simulator-first functional candidate. When explicitly enabled, keep
    // ARM9 DIV/SQRT MMIO in FPGA and consume the same emulated-cycle credits
    // that already drive the HPS model. ARM7 accesses and undefined holes in
    // the surrounding aperture remain on the authoritative oracle path.
    parameter bit ARM9_MATH_LOCAL_ENABLE = 0,
    // Route the oracle mailbox over the HPS lightweight bridge instead of the
    // DDR mailbox. Transport only: the request/response protocol, ordering
    // fence and IRQ/HALT semantics are identical. Default off so the DDR path
    // stays the production default until hardware proves the bridge.
    parameter bit LW_MAILBOX_ENABLE = 0
)(
    input  logic        clk,
    input  logic        reset,
    // The CPU/TCM reset may remain asserted while the one-shot FPGA-audio
    // supervisor waits for a boot descriptor.  The HPS must still be able to
    // establish a fresh LW transport session before publishing that
    // descriptor, so the transport has its own reset domain.  Existing users
    // tie this to reset; the MiSTer top ties it to the pre-supervisor reset.
    input  logic        transport_reset,
    input  logic        request,
    input  logic        cpu_is_arm9,
    input  logic [7:0]  arm9_cycles,
    input  logic        arm9_cycles_valid,
    input  logic [7:0]  arm7_cycles,
    input  logic        arm7_cycles_valid,
    input  logic [31:0] arm9_debug_pc,
    input  logic [31:0] arm7_debug_pc,
    input  logic [31:0] request_debug_pc,
    input  logic [31:0] arm9_dtcm_region,
    input  logic        arm9_dtcm_enable,
    input  logic        arm9_dtcm_seed_valid,
    input  logic [31:0] arm9_dtcm_irq_vector,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,
    output logic        done,
    output logic        irq_arm9,
    output logic        irq_arm7,
    output logic        halt_arm9,
    output logic        halt_arm7,
    output logic        cpu_pause,
    // Diagnostic observation points. These are passive copies of the
    // production request path so hardware can localize a lost transaction
    // without changing arbitration or completion timing.
    output logic        debug_oracle_request,
    output logic        debug_mailbox_request,
    output logic        debug_mailbox_done,
    output logic [3:0]  debug_mailbox_state,
    // Lightweight-bridge register file. Driven by nds_hps_lw_slave in the top
    // level; inert when LW_MAILBOX_ENABLE is 0.
    input  logic [18:0] lw_reg_raddr,
    output logic [31:0] lw_reg_rdata,
    input  logic [18:0] lw_reg_waddr,
    input  logic [31:0] lw_reg_wdata,
    input  logic [3:0]  lw_reg_be,
    input  logic        lw_reg_write,
    output logic        lw_request_pending_irq,
    output logic [1:0]  debug_tick_state,

    // Read-only production observation seam for the default-off sound
    // shadow.  These ports are exact copies of the values presented to the
    // real mailbox and posted-write ring; none feeds either transport back.
`ifdef NDS_SOUND_OBSERVATION_EXPORTS
    output logic        sound_mailbox_explicit_launch,
    output logic        sound_mailbox_request,
    output logic [3:0]  sound_mailbox_debug_state,
    output logic        sound_mailbox_cpu_arm9,
    output logic [31:0] sound_mailbox_elapsed_cycles,
    output logic [31:0] sound_mailbox_fence_sequence,
    output logic [31:0] sound_mailbox_address,
    output logic        sound_mailbox_read_not_write,
    output logic [1:0]  sound_mailbox_access,
    output logic [31:0] sound_mailbox_write_data,
    output logic        sound_mailbox_done,
    output logic [31:0] sound_mailbox_completed_fence_sequence,
    output logic        sound_posted_request,
    output logic        sound_posted_active,
    output logic        sound_posted_accepted,
    output logic        sound_posted_sequence_exhausted,
    output logic [31:0] sound_posted_producer_sequence,
    output logic        sound_posted_cpu_arm9,
    output logic [31:0] sound_posted_elapsed_cycles,
    output logic [1:0]  sound_live_wramcnt,
`endif

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
    logic local_ddr_hit;
    logic oracle_request, oracle_rnw, oracle_done, mailbox_done;
    logic [31:0] router_read_data;
    logic mailbox_irq_arm9;
    logic [31:0] oracle_address, oracle_write_data, oracle_read_data;
    logic [1:0] oracle_access;
    logic main_rd, main_we, oracle_rd, oracle_we, posted_rd, posted_we;
    logic [7:0] main_burst, main_be, oracle_burst, oracle_be;
    logic [7:0] posted_burst, posted_be;
    logic [28:0] main_addr, oracle_ddr_addr, posted_addr;
    logic [63:0] main_din, oracle_din, posted_din;
    logic posted_accepted, posted_active, posted_ddr_active, posted_done;
    logic posted_sequence_exhausted;
    logic posted_consumer_protocol_error;
    logic [31:0] posted_producer_sequence;
    logic lw_posted_ack;
    logic [31:0] lw_posted_ack_epoch;
    logic [31:0] lw_posted_ack_sequence;
    logic lw_doorbell_protocol_error;
    logic lw_transport_ready;
    logic [31:0] lw_active_session_epoch;
    logic [31:0] lw_active_session_capabilities;
    logic posted_consumer_ack;
    logic [31:0] posted_consumer_ack_epoch;
    logic [31:0] posted_consumer_ack_sequence;
    // Archived/default DDR projects predate the separate transport-reset
    // port and leave it unconnected.  Preserve their exact reset semantics;
    // only an explicitly enabled LW build may consume the separate input.
    wire effective_transport_reset =
        LW_MAILBOX_ENABLE ? transport_reset : reset;
    logic ddram_owner_pending;
    logic ddram_pending_owner_posted;
    logic [31:0] mailbox_completed_fence;
    logic [31:0] mailbox_completed_fence_epoch;
    logic [31:0] accumulated9, accumulated7;
    logic oracle_was_requested;
    typedef enum logic [1:0] {TICK_IDLE,TICK_ACTIVE,TICK_RELEASE} tick_state_t;
    tick_state_t tick_state;
    logic tick_cpu;
    logic [31:0] tick_cycles;
    logic last_time_tick_cpu;
    logic last_halt_tick_cpu;
    logic [1:0] wramcnt;
    logic pending_wramcnt_write;
    logic [1:0] pending_wramcnt_value;
    logic [31:0] arm9_live_irq_vector;
    logic arm9_dtcm_vector_active;
    logic arm9_dtcm_vector_done;
    logic router_done;
    logic arm9_vector_mismatch_seen;
    logic arm9_vector_restore_seen;
    logic [31:0] arm9_dtcm_handler_shadow;
    logic arm9_dtcm_handler_write_seen;
    logic arm9_dtcm_handler_telemetry_phase;
    logic [15:0] arm9_math_write_count;
    logic [31:0] arm9_math_run_first_pc;
    logic arm9_math_runaway_seen;
    // r222 diagnostic-only: the runaway begins at a PC the CPU reached by an
    // ordinary branch, and every instruction it then executes lives in ITCM
    // and never reaches this oracle seam. Retain the last few oracle-visible
    // ARM9 PCs so the tagged payload can rotate out the path into the branch
    // instead of repeating its destination.
    localparam integer ARM9_MATH_HISTORY_DEPTH = 8;
    logic [31:0] arm9_math_pc_history [0:ARM9_MATH_HISTORY_DEPTH-1];
    logic [2:0] arm9_math_history_read;
    // IME and IE are CPU-owned, side-effect-free registers. Keep a coherent
    // read cache per CPU after an authoritative HPS completion. Writes still
    // reach HPS and update/invalidate the shadow only after completion, so the
    // peripheral model remains the sole owner while tight SDK save/restore
    // loops avoid a second mailbox round trip for the following read.
    logic [31:0] ime_cache [0:1];
    logic [31:0] ie_cache [0:1];
    logic ime_cache_valid [0:1];
    logic ie_cache_valid [0:1];
    logic local_read_active;
    logic local_read_done;
    logic [31:0] local_read_data;
    logic arm9_math_selected;
    logic arm9_math_done;
    logic [31:0] arm9_math_read_data;
    logic [15:0] wifi_bb_cnt;
    logic [15:0] wifi_bb_write;
    logic [7:0] wifi_bb_regs [0:255];
    logic [255:0] wifi_bb_written;
    logic gx_shadow_write_ready;
    logic gx_shadow_command_valid;
    logic [31:0] gx_shadow_command_frame;
    logic [63:0] gx_shadow_command_timestamp;
    logic [7:0] gx_shadow_command_id;
    logic [31:0] gx_shadow_command_parameter;
    logic [$clog2(GX_COMMAND_SHADOW_QUEUE_DEPTH + 1)-1:0]
        gx_shadow_queue_level;
    logic gx_shadow_queue_empty;
    logic gx_shadow_queue_full;
    logic gx_shadow_packed_active;
    logic gx_shadow_busy;
    logic gx_shadow_protocol_error;
    integer halt_poll_count;
    integer posted_since_irq_refresh;
    function automatic logic wifi_bb_read_only(input logic [7:0] index);
        begin
            wifi_bb_read_only =
                index == 8'h00 ||
                (index >= 8'h0d && index <= 8'h12) ||
                (index >= 8'h16 && index <= 8'h1a) ||
                index == 8'h27 || index == 8'h4d ||
                (index >= 8'h5d && index <= 8'h61) ||
                index == 8'h64 || index == 8'h66 ||
                index >= 8'h69;
        end
    endfunction
    function automatic logic [7:0] wifi_bb_reset_value(
        input logic [7:0] index
    );
        begin
            case (index)
                8'h00: wifi_bb_reset_value = 8'h6d;
                8'h5d: wifi_bb_reset_value = 8'h01;
                8'h64: wifi_bb_reset_value = 8'hff;
                default: wifi_bb_reset_value = 8'h00;
            endcase
        end
    endfunction
    wire oracle_start = oracle_request && !oracle_was_requested;
    // Declare this before the diagnostic telemetry expression that observes
    // it so strict host simulators do not create an implicit one-bit net.
    wire arm9_irq_vector_ready = arm9_dtcm_seed_valid &&
        (arm9_vector_restore_seen ||
         arm9_live_irq_vector == arm9_dtcm_irq_vector);
    // The software responder's wall-clock latency must not become emulated
    // dual-CPU skew. Keep both CPUs paused for an unresolved I/O request or
    // timing-flush mailbox cycle; the DDR/mailbox state machines continue.
    assign cpu_pause = oracle_request || tick_state != TICK_IDLE;
    wire [31:0] request_elapsed_cycles = cpu_is_arm9
        ? accumulated9 + (arm9_cycles_valid ? arm9_cycles : 0)
        : accumulated7 + (arm7_cycles_valid ? arm7_cycles : 0);

    generate
        if (GX_COMMAND_SHADOW_ENABLE) begin : gx_command_shadow
            // oracle_start is a single pulse for each external CPU request.
            // Observe the router's authoritative request fields, not the live
            // CPU address bus, and drain immediately so this transport shadow
            // can never apply backpressure to the production mailbox.
            nds_gx_command_frontend #(
                .QUEUE_DEPTH(GX_COMMAND_SHADOW_QUEUE_DEPTH)
            ) frontend (
                .clk(clk),
                .reset(reset),
                .write_valid(oracle_start && !oracle_rnw),
                .write_ready(gx_shadow_write_ready),
                .cpu_is_arm9(cpu_is_arm9),
                .address(oracle_address),
                .access(oracle_access),
                .write_data(oracle_write_data),
                .frame(32'd0),
                .timestamp({32'd0, request_elapsed_cycles}),
                .command_valid(gx_shadow_command_valid),
                .command_ready(1'b1),
                .command_frame(gx_shadow_command_frame),
                .command_timestamp(gx_shadow_command_timestamp),
                .command_id(gx_shadow_command_id),
                .command_parameter(gx_shadow_command_parameter),
                .queue_level(gx_shadow_queue_level),
                .queue_empty(gx_shadow_queue_empty),
                .queue_full(gx_shadow_queue_full),
                .packed_active(gx_shadow_packed_active),
                .busy(gx_shadow_busy),
                .protocol_error(gx_shadow_protocol_error)
            );
        end else begin : gx_command_shadow_disabled
            assign gx_shadow_write_ready = 1'b1;
            assign gx_shadow_command_valid = 1'b0;
            assign gx_shadow_command_frame = 32'd0;
            assign gx_shadow_command_timestamp = 64'd0;
            assign gx_shadow_command_id = 8'd0;
            assign gx_shadow_command_parameter = 32'd0;
            assign gx_shadow_queue_level = '0;
            assign gx_shadow_queue_empty = 1'b1;
            assign gx_shadow_queue_full = 1'b0;
            assign gx_shadow_packed_active = 1'b0;
            assign gx_shadow_busy = 1'b0;
            assign gx_shadow_protocol_error = 1'b0;
        end
    endgenerate

    wire tick_owns_ddr = tick_state != TICK_IDLE;
    wire mailbox_request = tick_state == TICK_ACTIVE ? 1'b1 :
                           tick_state == TICK_RELEASE ? 1'b0 : oracle_request;
    assign debug_oracle_request = oracle_request;
    assign debug_mailbox_request = mailbox_request;
    assign debug_mailbox_done = mailbox_done;
    assign debug_tick_state = tick_state;
    wire mailbox_cpu = tick_state == TICK_ACTIVE ? tick_cpu : cpu_is_arm9;
    wire [31:0] mailbox_cycles =
        tick_state == TICK_ACTIVE ? tick_cycles : request_elapsed_cycles;
    // A read has no write payload, so reuse that otherwise ignored mailbox
    // word as non-invasive hardware telemetry. This lets the HPS observer
    // correlate every external read with the selected CPU's live PC while
    // preserving real CPU write data byte-for-byte.
    wire arm9_bad_write_telemetry =
        ARM9_BAD_WRITE_PC_TELEMETRY && cpu_is_arm9 && !oracle_rnw &&
        oracle_address == 32'h0400009f;
    wire arm7_invalid_write_telemetry =
        ARM7_INVALID_WRITE_PC_TELEMETRY && !cpu_is_arm9 && !oracle_rnw &&
        oracle_address[31:24] != 8'h04;
    wire arm9_math_write =
        cpu_is_arm9 && !oracle_rnw &&
        oracle_address >= 32'h04000280 &&
        oracle_address <= 32'h040002bf;
    wire arm9_math_runaway_telemetry =
        ARM9_MATH_RUNAWAY_PC_TELEMETRY && arm9_math_runaway_seen &&
        arm9_math_write;
    wire [31:0] mailbox_write_or_pc =
        oracle_rnw ? request_debug_pc :
        arm9_bad_write_telemetry ? arm9_debug_pc :
        arm7_invalid_write_telemetry ? arm7_debug_pc :
        arm9_math_runaway_telemetry ?
            arm9_math_pc_history[arm9_math_history_read] :
        oracle_write_data;
    // Timing-only requests otherwise carry an unused payload. Publish the
    // selected CPU's live PC there so fully local execution remains
    // observable without forcing any CPU memory transaction through HPS.
    wire [31:0] arm9_irq_guard_telemetry =
        arm9_debug_pc[3] ? arm9_live_irq_vector :
        {24'ha90000, 3'b000,
         arm9_live_irq_vector == arm9_dtcm_irq_vector,
         arm9_vector_restore_seen, arm9_vector_mismatch_seen,
         arm9_irq_vector_ready, mailbox_irq_arm9};
    wire [31:0] timing_debug_pc =
        tick_cpu && ARM9_DTCM_HANDLER_TELEMETRY &&
            arm9_dtcm_handler_write_seen &&
            arm9_dtcm_handler_telemetry_phase
            ? arm9_dtcm_handler_shadow ^ 32'h60000000 :
        tick_cpu && ARM9_POLL_ADDRESS_TELEMETRY &&
            arm9_debug_pc >= 32'h0207cca0 &&
            arm9_debug_pc <= 32'h0207ccb8 ? arm9_irq_guard_telemetry :
        tick_cpu ? arm9_debug_pc : arm7_debug_pc;
    wire [31:0] mailbox_address =
        tick_state == TICK_ACTIVE ? 32'hffffffff : oracle_address;
    wire mailbox_read_not_write =
        tick_state == TICK_ACTIVE ? 1'b1 : oracle_rnw;
    wire [1:0] mailbox_access =
        tick_state == TICK_ACTIVE ? 2'b10 : oracle_access;
    wire [31:0] mailbox_actual_write_data =
        tick_state == TICK_ACTIVE ? timing_debug_pc : mailbox_write_or_pc;

`ifdef NDS_SOUND_OBSERVATION_EXPORTS
    // The mailbox accepts a request only in state zero (IDLE).  This exact
    // edge-qualified launch pulse lets an observer capture the same live
    // metadata that the mailbox registers, including diagnostic payload
    // substitution when one of those legacy parameters is explicitly used.
    assign sound_mailbox_explicit_launch =
        mailbox_request && debug_mailbox_state == 4'd0;
    assign sound_mailbox_request = mailbox_request;
    assign sound_mailbox_debug_state = debug_mailbox_state;
    assign sound_mailbox_cpu_arm9 = mailbox_cpu;
    assign sound_mailbox_elapsed_cycles = mailbox_cycles;
    assign sound_mailbox_fence_sequence = posted_producer_sequence;
    assign sound_mailbox_address = mailbox_address;
    assign sound_mailbox_read_not_write = mailbox_read_not_write;
    assign sound_mailbox_access = mailbox_access;
    assign sound_mailbox_write_data = mailbox_actual_write_data;
    assign sound_mailbox_done = mailbox_done;
    assign sound_mailbox_completed_fence_sequence =
        mailbox_completed_fence;
    assign sound_live_wramcnt = wramcnt;
`endif
    wire completed_local_request =
        request && done && !oracle_request;
    // The hardware profile of the first playable menu found that every
    // access to this exact VRAM page was an ARM9 halfword write.
    wire posted_vram_halfword_hit =
        request && cpu_is_arm9 && !read_not_write &&
        access == 2'b01 && address[31:12] == 20'h0600c;
    // The optional first functional GX batching candidate is deliberately
    // narrower than the full 0x04000400..0x040006ff 3D register region. The
    // measured NSMB workload uses aligned command-port words only through
    // 0x040005c8. Its exact-timestamp 600-frame replay observed max FIFO=0,
    // pipe=4, stall queue=0, and no state transitions, removing a workload-
    // specific FIFO hazard but not proving the generic feature safe. GXSTAT
    // and every read therefore remain ordered by the mailbox fence.
    wire posted_gx_word_hit =
        GX_POSTED_ENABLE && request && cpu_is_arm9 && !read_not_write &&
        access == 2'b10 && address[1:0] == 2'b00 &&
        address >= 32'h04000400 && address <= 32'h040005c8;
    wire ordered_posted_write_hit =
        posted_vram_halfword_hit || posted_gx_word_hit;
`ifdef NDS_SOUND_OBSERVATION_EXPORTS
    assign sound_posted_request = ordered_posted_write_hit;
    assign sound_posted_active = posted_active;
    assign sound_posted_accepted = posted_accepted;
    assign sound_posted_sequence_exhausted =
        posted_sequence_exhausted;
    assign sound_posted_producer_sequence =
        posted_producer_sequence;
    assign sound_posted_cpu_arm9 = cpu_is_arm9;
    assign sound_posted_elapsed_cycles = request_elapsed_cycles;
`endif
    wire arm9_dtcm_vector_access = request && cpu_is_arm9 &&
        arm9_dtcm_enable &&
        address[31:2] ==
            ({arm9_dtcm_region[31:12], 12'h000} + 32'h00003ffc) >> 2;
    // Local TCM asserts done with a registered pulse on the same edge that
    // accepts the request. A parent always_ff block cannot observe that pulse
    // until the following edge, by which time the bridge may have released
    // request. Track the stable live write request here; repeated assignments
    // while it is held are idempotent and mirror the TCM's accepted payload.
    wire arm9_dtcm_vector_write = arm9_dtcm_vector_access &&
        !read_not_write;
    wire arm9_dtcm_handler_access = request && cpu_is_arm9 &&
        arm9_dtcm_enable &&
        address[31:2] ==
            ({arm9_dtcm_region[31:12], 12'h000} + 32'h000003c0) >> 2;
    wire arm9_dtcm_handler_write = arm9_dtcm_handler_access &&
        !read_not_write;
    wire ime_cache_hit = request && read_not_write &&
        address[31:2] == 30'h01000082 && ime_cache_valid[cpu_is_arm9];
    wire ie_cache_hit = request && read_not_write &&
        address[31:2] == 30'h01000084 && ie_cache_valid[cpu_is_arm9];
    // The DS baseband port is a self-contained 256-byte register file.
    // Mirror melonDS's complete BBCnt/BBWrite/BBRead transaction semantics so
    // the long firmware readback test can execute locally without replacing
    // any dynamic WiFi MAC, RF, IRQ, or timing behavior.
    wire wifi_bb_port_hit = request && !cpu_is_arm9 &&
        access == 2'b01 &&
        (address == 32'h04808158 || address == 32'h0480815a ||
         (read_not_write &&
          (address == 32'h0480815c || address == 32'h0480815e)));
    wire wifi_bb_read_hit = wifi_bb_port_hit && read_not_write;
    wire wifi_bb_write_hit = wifi_bb_port_hit && !read_not_write;
    wire local_read_hit =
        ime_cache_hit || ie_cache_hit || wifi_bb_port_hit;
    wire arm9_math_hit = ARM9_MATH_LOCAL_ENABLE && request &&
        cpu_is_arm9 && arm9_math_selected;
    wire [31:0] selected_irq_cache =
        ime_cache_hit ? ime_cache[cpu_is_arm9] : ie_cache[cpu_is_arm9];
    wire [31:0] formatted_irq_cache =
        access == 2'b00 ? {24'h0,
            address[1:0] == 2'd0 ? selected_irq_cache[7:0] :
            address[1:0] == 2'd1 ? selected_irq_cache[15:8] :
            address[1:0] == 2'd2 ? selected_irq_cache[23:16] :
                                   selected_irq_cache[31:24]} :
        access == 2'b01 ? {16'h0,
            address[1] ? selected_irq_cache[31:16] :
                         selected_irq_cache[15:0]} :
        selected_irq_cache;
    // The direct-boot copy temporarily destroys the seeded vector. Guard
    // that one unsafe interval, but once software has restored the expected
    // dispatcher, permanently open delivery. Games legitimately replace the
    // DTCM vector later; continuing to compare against the boot descriptor
    // would suppress every DMA/VBlank IRQ after such a runtime update.
    // Direct-boot startup copies an image across all 16 KiB of DTCM before
    // installing the SDK IRQ dispatcher in its final word.  Peripheral time
    // can advance on HPS while that copy is in progress, so suppress only the
    // otherwise-fatal interrupt window in which BIOS LDR PC,[DTCM+3ffc] would
    // branch to copied data.  Software regains IRQ delivery as soon as its
    // expected vector is live.
    assign irq_arm9 = mailbox_irq_arm9 && arm9_irq_vector_ready;
    // The final DTCM word is architectural IRQ-vector state. Hardware proved
    // that the generic single-port TCM can retain the earlier startup-copy
    // word even after the CPU-side accepted-write tracker has advanced.
    // Handle this one word as a dedicated register transaction instead of
    // merely shadowing the BRAM read-data mux. Keeping the transaction active
    // through the completion edge also makes both done and data independent
    // of the next address launched by gba_cpu on that same edge.
    assign read_data = arm9_dtcm_vector_active
        ? arm9_live_irq_vector :
        arm9_math_hit ? arm9_math_read_data :
        local_read_active ? local_read_data : router_read_data;
    assign done = arm9_dtcm_vector_active
        ? arm9_dtcm_vector_done :
        arm9_math_hit ? arm9_math_done :
        local_read_active ? local_read_done :
        posted_active ? posted_done : router_done;

    generate
    if (ARM9_MATH_LOCAL_ENABLE) begin : g_arm9_math_local
        nds_arm9_math_unit arm9_math (
            .clk(clk),
            .reset(reset),
            .cycle_advance(arm9_cycles),
            .cycle_advance_valid(arm9_cycles_valid),
            .request(request && cpu_is_arm9),
            .address(address),
            .read_not_write(read_not_write),
            .access(access),
            .write_data(write_data),
            .selected(arm9_math_selected),
            .read_data(arm9_math_read_data),
            .done(arm9_math_done),
            .div_busy(),
            .sqrt_busy()
        );
    end else begin : g_no_arm9_math_local
        assign arm9_math_selected = 1'b0;
        assign arm9_math_read_data = 32'd0;
        assign arm9_math_done = 1'b0;
    end
    endgenerate

    wire arm9_dtcm_local_hit = cpu_is_arm9 && arm9_dtcm_enable &&
        address >= {arm9_dtcm_region[31:12], 12'h000} &&
        address < ({arm9_dtcm_region[31:12], 12'h000} + 32'h00004000);
    assign local_ddr_hit = address[31:24] == 8'h02 ||
        (address[31:24] == 8'h03 &&
         ((!cpu_is_arm9) || wramcnt != 2'd3)) ||
        (!cpu_is_arm9 && address < 32'h00004000) ||
        (cpu_is_arm9 && address < 32'h02000000) ||
        arm9_dtcm_local_hit;
    assign ddram_read = tick_owns_ddr ? oracle_rd :
        posted_ddr_active ? posted_rd :
        local_ddr_hit ? main_rd : oracle_rd;
    assign ddram_write = tick_owns_ddr ? oracle_we :
        posted_ddr_active ? posted_we :
        local_ddr_hit ? main_we : oracle_we;
    assign ddram_burst_count = tick_owns_ddr ? oracle_burst :
        posted_ddr_active ? posted_burst :
        local_ddr_hit ? main_burst : oracle_burst;
    assign ddram_address = tick_owns_ddr ? oracle_ddr_addr :
        posted_ddr_active ? posted_addr :
        local_ddr_hit ? main_addr : oracle_ddr_addr;
    assign ddram_write_data = tick_owns_ddr ? oracle_din :
        posted_ddr_active ? posted_din :
        local_ddr_hit ? main_din : oracle_din;
    assign ddram_byte_enable = tick_owns_ddr ? oracle_be :
        posted_ddr_active ? posted_be :
        local_ddr_hit ? main_be : oracle_be;
    // The outer shared-DDR arbiter decouples client queue admission from
    // physical Avalon acceptance. The CPU-side mux may select a newer source
    // while an older command remains queued, so tag the sub-owner at the
    // admission edge. A later acceptance pulse must retire only that owner.
    wire ddram_current_owner_posted =
        posted_ddr_active && !tick_owns_ddr;
    wire ddram_client_command = ddram_read || ddram_write;
    wire ddram_client_admitted =
        ddram_client_command && !ddram_busy;
    wire posted_ddram_command_accepted =
        ddram_command_accepted &&
        ((ddram_owner_pending && ddram_pending_owner_posted) ||
         (!ddram_owner_pending && ddram_client_admitted &&
          ddram_current_owner_posted));

    always_ff @(posedge clk) begin
        if (reset) begin
            ddram_owner_pending <= 1'b0;
            ddram_pending_owner_posted <= 1'b0;
        end else begin
            if (ddram_command_accepted)
                ddram_owner_pending <= 1'b0;
            if (ddram_client_admitted && !ddram_command_accepted) begin
                ddram_owner_pending <= 1'b1;
                ddram_pending_owner_posted <=
                    ddram_current_owner_posted;
            end
        end
    end
    assign oracle_done = mailbox_done && tick_state == TICK_IDLE;

    nds_cpu_memory_router #(
        .MAIN_RAM_BASE_WORD(MAIN_RAM_BASE_WORD),
        .SHARED_WRAM_BASE_WORD(SHARED_WRAM_BASE_WORD),
        .ARM7_WRAM_BASE_WORD(ARM7_WRAM_BASE_WORD)
    ) router (
        .clk(clk), .reset(reset),
        .request(request && !arm9_dtcm_vector_access &&
                 !arm9_dtcm_vector_active && !arm9_math_hit &&
                 !local_read_hit &&
                 !local_read_active && !ordered_posted_write_hit &&
                 !posted_active),
        .cpu_is_arm9(cpu_is_arm9), .wramcnt(wramcnt),
        .arm9_dtcm_region(arm9_dtcm_region),
        .arm9_dtcm_enable(arm9_dtcm_enable),
        .arm9_dtcm_seed_valid, .arm9_dtcm_irq_vector, .address(address),
        .read_not_write(read_not_write), .access(access), .write_data(write_data),
        .read_data(router_read_data), .done(router_done),
        .oracle_request(oracle_request), .oracle_address(oracle_address),
        .oracle_read_not_write(oracle_rnw), .oracle_access(oracle_access),
        .oracle_write_data(oracle_write_data), .oracle_read_data(oracle_read_data),
        .oracle_done(oracle_done),
        .ddram_read(main_rd), .ddram_write(main_we), .ddram_burst_count(main_burst),
        .ddram_address(main_addr), .ddram_write_data(main_din),
        .ddram_byte_enable(main_be),
        .ddram_busy(ddram_busy || !local_ddr_hit || tick_owns_ddr ||
                    posted_ddr_active),
        .ddram_read_data(ddram_read_data),
        .ddram_read_data_ready(ddram_read_data_ready && local_ddr_hit &&
                               !tick_owns_ddr && !posted_ddr_active)
    );

    assign posted_consumer_ack = mailbox_done || lw_posted_ack;
    assign posted_consumer_ack_sequence =
        mailbox_done && lw_posted_ack
            ? (mailbox_completed_fence >= lw_posted_ack_sequence
                ? mailbox_completed_fence : lw_posted_ack_sequence)
            : (mailbox_done
                ? mailbox_completed_fence : lw_posted_ack_sequence);
    assign posted_consumer_ack_epoch =
        mailbox_done && lw_posted_ack
            ? (mailbox_completed_fence >= lw_posted_ack_sequence
                ? mailbox_completed_fence_epoch : lw_posted_ack_epoch)
            : (mailbox_done
                ? mailbox_completed_fence_epoch : lw_posted_ack_epoch);

    nds_hps_posted_write_ring #(
        .BASE_WORD(POSTED_RING_BASE_WORD),
        .REQUIRE_EPOCH_SESSION(LW_MAILBOX_ENABLE)
    ) posted_write_ring (
        .clk(clk), .reset(effective_transport_reset),
        .request(ordered_posted_write_hit && lw_transport_ready),
        .cpu_is_arm9(cpu_is_arm9),
        .elapsed_cycles(request_elapsed_cycles),
        .address(address), .access(access), .write_data(write_data),
        .session_epoch(lw_active_session_epoch),
        .session_capabilities(lw_active_session_capabilities),
        .consumer_ack(posted_consumer_ack),
        .consumer_ack_epoch(posted_consumer_ack_epoch),
        .consumer_ack_sequence(posted_consumer_ack_sequence),
        .accepted(posted_accepted), .active(posted_active),
        .ddram_active(posted_ddr_active),
        .done(posted_done),
        .producer_sequence(posted_producer_sequence),
        .sequence_exhausted(posted_sequence_exhausted),
        .consumer_protocol_error(posted_consumer_protocol_error),
        .ddram_read(posted_rd), .ddram_write(posted_we),
        .ddram_burst_count(posted_burst), .ddram_address(posted_addr),
        .ddram_write_data(posted_din), .ddram_byte_enable(posted_be),
        .ddram_busy(ddram_busy || tick_owns_ddr),
        .ddram_command_accepted(posted_ddram_command_accepted),
        .ddram_read_data(ddram_read_data),
        .ddram_read_data_ready(ddram_read_data_ready &&
                               posted_ddr_active && !tick_owns_ddr)
    );

    // Transport selection. The DDR mailbox costs four DDR interactions per
    // request and contends with the video fetcher through the shared arbiter;
    // profiling put ~24 us of the ~42 us per-request budget in that handshake.
    // The lightweight-bridge transport moves the same protocol into fabric
    // registers the HPS reads directly at 0xFF200000. Only the transport
    // changes -- emulation timing semantics are untouched either way.
    generate
    if (LW_MAILBOX_ENABLE) begin : g_lw_oracle
        assign oracle_rd = 1'b0;
        assign oracle_we = 1'b0;
        assign oracle_burst = 8'd1;
        assign oracle_ddr_addr = ORACLE_BASE_WORD;
        assign oracle_din = 64'h0;
        assign oracle_be = 8'h0;
        nds_hps_oracle_mailbox_lw #(
            .GX_POSTED_ENABLE(GX_POSTED_ENABLE)
        ) oracle_lw (
            .clk(clk), .reset(effective_transport_reset),
            // A missing/stale HPS session must stall blocking traffic just as
            // it stalls posted traffic.  Otherwise an early CPU request could
            // occupy PENDING before HPS is allowed to install SESSION, making
            // startup recovery circular.
            .request(mailbox_request && lw_transport_ready),
            .cpu_is_arm9(mailbox_cpu),
            .elapsed_cycles(mailbox_cycles),
            .fence_sequence(posted_producer_sequence),
            .address(mailbox_address),
            .read_not_write(mailbox_read_not_write),
            .access(mailbox_access),
            .write_data(mailbox_actual_write_data),
            .read_data(oracle_read_data),
            .irq_arm9(mailbox_irq_arm9), .irq_arm7(irq_arm7),
            .halt_arm9(halt_arm9), .halt_arm7(halt_arm7),
            .done(mailbox_done),
            .completed_fence_sequence(mailbox_completed_fence),
            .completed_fence_epoch(mailbox_completed_fence_epoch),
            .debug_state(debug_mailbox_state),
            .request_pending_irq(lw_request_pending_irq),
            // Advertise only the commit pulse, never the earlier admission
            // pulse. This guarantees HPS cannot be notified before the
            // entry's sequence marker is physically accepted by DDR.
            .posted_commit(posted_done),
            .posted_commit_sequence(posted_producer_sequence),
            .transport_fault(posted_sequence_exhausted |
                             posted_consumer_protocol_error),
            .posted_ack(lw_posted_ack),
            .posted_ack_epoch(lw_posted_ack_epoch),
            .posted_ack_sequence(lw_posted_ack_sequence),
            .doorbell_protocol_error(lw_doorbell_protocol_error),
            .transport_ready(lw_transport_ready),
            .active_session_epoch(lw_active_session_epoch),
            .active_session_capabilities(
                lw_active_session_capabilities),
            .reg_raddr(lw_reg_raddr), .reg_rdata(lw_reg_rdata),
            .reg_waddr(lw_reg_waddr), .reg_wdata(lw_reg_wdata),
            .reg_be(lw_reg_be), .reg_write(lw_reg_write));
    end else begin : g_ddr_oracle
    assign lw_reg_rdata = 32'h0;
    assign lw_request_pending_irq = 1'b0;
    assign lw_posted_ack = 1'b0;
    assign lw_posted_ack_epoch = 32'h0;
    assign lw_posted_ack_sequence = 32'h0;
    assign lw_doorbell_protocol_error = 1'b0;
    assign lw_transport_ready = 1'b1;
    assign lw_active_session_epoch = 32'h0;
    assign lw_active_session_capabilities = 32'h0;
    assign mailbox_completed_fence_epoch = 32'h0;
    nds_hps_oracle_mailbox #(
        .BASE_WORD(ORACLE_BASE_WORD), .POLL_DELAY_CYCLES(ORACLE_POLL_DELAY_CYCLES)
    ) oracle (
        .clk(clk), .reset(reset), .request(mailbox_request),
        .cpu_is_arm9(mailbox_cpu),
        .fence_sequence(posted_producer_sequence),
        .address(mailbox_address),
        .elapsed_cycles(mailbox_cycles),
        .read_not_write(mailbox_read_not_write),
        .access(mailbox_access),
        .write_data(mailbox_actual_write_data),
        .read_data(oracle_read_data),
        .irq_arm9(mailbox_irq_arm9), .irq_arm7(irq_arm7),
        .halt_arm9(halt_arm9), .halt_arm7(halt_arm7), .done(mailbox_done),
        .completed_fence_sequence(mailbox_completed_fence),
        .debug_state(debug_mailbox_state),
        .ddram_read(oracle_rd), .ddram_write(oracle_we),
        .ddram_burst_count(oracle_burst), .ddram_address(oracle_ddr_addr),
        .ddram_write_data(oracle_din), .ddram_byte_enable(oracle_be),
        // A timing tick has explicit priority in the DDR source mux above.
        // A posted write may become DDR-active on the same completion edge
        // that starts that tick; treating the parked posted client as busy
        // here would make it wait for the tick while the tick waits for it.
        // Ignore lower-priority local clients only while the tick owns the
        // mux. They remain held by their own tick_owns_ddr busy gates and
        // resume after TICK_RELEASE.
        .ddram_busy(ddram_busy ||
                    ((posted_ddr_active || local_ddr_hit) &&
                     !tick_owns_ddr)),
        .ddram_read_data(ddram_read_data),
        .ddram_read_data_ready(ddram_read_data_ready &&
            (tick_owns_ddr || !local_ddr_hit))
    );
    end
    endgenerate

    always_ff @(posedge clk) begin
        if (reset) begin
            accumulated9 <= 0;
            accumulated7 <= 0;
            oracle_was_requested <= 0;
            tick_state <= TICK_IDLE;
            tick_cpu <= 0;
            tick_cycles <= 0;
            last_time_tick_cpu <= 0;
            last_halt_tick_cpu <= 0;
            halt_poll_count <= 0;
            posted_since_irq_refresh <= 0;
            wramcnt <= 2'd3;
            pending_wramcnt_write <= 0;
            pending_wramcnt_value <= 2'd3;
            arm9_vector_mismatch_seen <= 0;
            arm9_vector_restore_seen <= 0;
            arm9_dtcm_handler_shadow <= 0;
            arm9_dtcm_handler_write_seen <= 0;
            arm9_dtcm_handler_telemetry_phase <= 0;
            arm9_math_write_count <= 0;
            arm9_math_run_first_pc <= 0;
            arm9_math_runaway_seen <= 0;
            arm9_math_history_read <= 0;
            for (int unsigned i = 0; i < ARM9_MATH_HISTORY_DEPTH; i++)
                arm9_math_pc_history[i] <= 0;
            arm9_dtcm_vector_active <= 0;
            arm9_dtcm_vector_done <= 0;
            local_read_active <= 0;
            local_read_done <= 0;
            local_read_data <= 0;
            wifi_bb_cnt <= 0;
            wifi_bb_write <= 0;
            wifi_bb_written <= 0;
            ime_cache[0] <= 0;
            ime_cache[1] <= 0;
            ie_cache[0] <= 0;
            ie_cache[1] <= 0;
            ime_cache_valid[0] <= 0;
            ime_cache_valid[1] <= 0;
            ie_cache_valid[0] <= 0;
            ie_cache_valid[1] <= 0;
            if (arm9_dtcm_seed_valid)
                arm9_live_irq_vector <= arm9_dtcm_irq_vector;
        end else begin
            arm9_dtcm_vector_done <= 0;
            local_read_done <= 0;
            if (!arm9_dtcm_vector_active && arm9_dtcm_vector_access) begin
                arm9_dtcm_vector_active <= 1;
                arm9_dtcm_vector_done <= 1;
            end else if (arm9_dtcm_vector_active && !request) begin
                arm9_dtcm_vector_active <= 0;
            end
            if (!local_read_active && local_read_hit) begin
                local_read_active <= 1;
                local_read_done <= 1;
                if (wifi_bb_read_hit) begin
                    case (address[2:0])
                        3'h0: local_read_data <= {16'h0, wifi_bb_cnt};
                        3'h2: local_read_data <= {16'h0, wifi_bb_write};
                        3'h4: local_read_data <=
                            wifi_bb_cnt[15:12] == 4'h6
                                ? {24'h0,
                                   wifi_bb_written[wifi_bb_cnt[7:0]]
                                       ? wifi_bb_regs[wifi_bb_cnt[7:0]]
                                       : wifi_bb_reset_value(
                                           wifi_bb_cnt[7:0])}
                                : 32'h00000000;
                        default: local_read_data <= 32'h00000000;
                    endcase
                end else begin
                    local_read_data <= formatted_irq_cache;
                end
                if (wifi_bb_write_hit) begin
                    if (address == 32'h0480815a) begin
                        wifi_bb_write <= write_data[15:0];
                    end else begin
                        wifi_bb_cnt <= write_data[15:0];
                        if (write_data[15:12] == 4'h5 &&
                            !wifi_bb_read_only(write_data[7:0])) begin
                            wifi_bb_regs[write_data[7:0]] <=
                                wifi_bb_write[7:0];
                            wifi_bb_written[write_data[7:0]] <= 1;
                        end
                    end
                end
            end else if (local_read_active && !request) begin
                local_read_active <= 0;
            end
            if (!arm9_vector_restore_seen) begin
                if (arm9_live_irq_vector != arm9_dtcm_irq_vector)
                    arm9_vector_mismatch_seen <= 1;
                else if (arm9_vector_mismatch_seen)
                    arm9_vector_restore_seen <= 1;
            end
            if (arm9_dtcm_vector_write) begin
                case (access)
                    2'b00: begin
                        case (address[1:0])
                            2'd0: arm9_live_irq_vector[7:0] <= write_data[7:0];
                            2'd1: arm9_live_irq_vector[15:8] <= write_data[7:0];
                            2'd2: arm9_live_irq_vector[23:16] <= write_data[7:0];
                            2'd3: arm9_live_irq_vector[31:24] <= write_data[7:0];
                        endcase
                    end
                    2'b01: if (address[1])
                        arm9_live_irq_vector[31:16] <= write_data[15:0];
                    else
                        arm9_live_irq_vector[15:0] <= write_data[15:0];
                    default: arm9_live_irq_vector <= write_data;
                endcase
            end
            if (arm9_dtcm_handler_write) begin
                arm9_dtcm_handler_write_seen <= 1;
                case (access)
                    2'b00: begin
                        case (address[1:0])
                            2'd0: arm9_dtcm_handler_shadow[7:0] <=
                                write_data[7:0];
                            2'd1: arm9_dtcm_handler_shadow[15:8] <=
                                write_data[7:0];
                            2'd2: arm9_dtcm_handler_shadow[23:16] <=
                                write_data[7:0];
                            2'd3: arm9_dtcm_handler_shadow[31:24] <=
                                write_data[7:0];
                        endcase
                    end
                    2'b01: if (address[1])
                        arm9_dtcm_handler_shadow[31:16] <=
                            write_data[15:0];
                    else
                        arm9_dtcm_handler_shadow[15:0] <=
                            write_data[15:0];
                    default: arm9_dtcm_handler_shadow <= write_data;
                endcase
            end
            if (mailbox_done && tick_state == TICK_ACTIVE && tick_cpu &&
                ARM9_DTCM_HANDLER_TELEMETRY)
                arm9_dtcm_handler_telemetry_phase <=
                    !arm9_dtcm_handler_telemetry_phase;
            // Count only completed CPU transactions. Timing-only mailbox
            // cycles do not break an otherwise continuous math-register run.
            // Preserve the first PC so later tagged payloads identify where
            // the runaway began, not merely where it happened to be sampled.
            if (mailbox_done && tick_state == TICK_IDLE &&
                ARM9_MATH_RUNAWAY_PC_TELEMETRY &&
                !arm9_math_runaway_seen) begin
                if (arm9_math_write) begin
                    if (arm9_math_write_count == 0)
                        arm9_math_run_first_pc <= arm9_debug_pc;
                    if (ARM9_MATH_RUNAWAY_THRESHOLD <= 1 ||
                        arm9_math_write_count >=
                            ARM9_MATH_RUNAWAY_THRESHOLD - 1) begin
                        arm9_math_runaway_seen <= 1;
                    end else begin
                        arm9_math_write_count <=
                            arm9_math_write_count + 1'b1;
                    end
                end else begin
                    arm9_math_write_count <= 0;
                    arm9_math_run_first_pc <= 0;
                end
            end
            // Shift every completed oracle-visible ARM9 PC through the
            // pre-runaway window while the run has not yet been declared.
            // Entry 0 holds the most recent PC once the window freezes.
            if (mailbox_done && tick_state == TICK_IDLE &&
                ARM9_MATH_RUNAWAY_PC_TELEMETRY &&
                !arm9_math_runaway_seen && cpu_is_arm9 &&
                !arm9_math_write) begin
                arm9_math_pc_history[0] <= arm9_debug_pc;
                for (int unsigned i = 1; i < ARM9_MATH_HISTORY_DEPTH; i++)
                    arm9_math_pc_history[i] <= arm9_math_pc_history[i-1];
            end
            // Once frozen, advance one entry per tagged write so a bounded
            // request trace reads the whole window out of the runaway itself.
            if (mailbox_done && tick_state == TICK_IDLE &&
                arm9_math_runaway_telemetry)
                arm9_math_history_read <=
                    (arm9_math_history_read == ARM9_MATH_HISTORY_DEPTH-1) ?
                        3'd0 : arm9_math_history_read + 3'd1;
            oracle_was_requested <= oracle_request;
            if (arm9_cycles_valid)
                accumulated9 <= accumulated9 + arm9_cycles;
            if (arm7_cycles_valid)
                accumulated7 <= accumulated7 + arm7_cycles;
            if (oracle_start) begin
                if (cpu_is_arm9) accumulated9 <= 0;
                else accumulated7 <= 0;
                pending_wramcnt_write <= 0;
                if (!read_not_write) begin
                    if (address == 32'h04000247 && access == 2'b00) begin
                        pending_wramcnt_write <= 1;
                        pending_wramcnt_value <= write_data[1:0];
                    end else if (address == 32'h04000246 &&
                                 access == 2'b01) begin
                        pending_wramcnt_write <= 1;
                        pending_wramcnt_value <= write_data[9:8];
                    end else if (address == 32'h04000244 &&
                                 access == 2'b10) begin
                        pending_wramcnt_write <= 1;
                        pending_wramcnt_value <= write_data[25:24];
                    end
                end
            end
            // The queued entry contains all execution time through the
            // accepted write. Reset only that CPU's bucket after admission;
            // the other FPGA CPU continues accumulating independently.
            if (posted_accepted) begin
                if (cpu_is_arm9)
                    accumulated9 <= 0;
                else
                    accumulated7 <= 0;
            end
            if (mailbox_done) begin
                posted_since_irq_refresh <= 0;
            end else if (posted_done &&
                         posted_since_irq_refresh <
                             POSTED_IRQ_REFRESH_WRITES) begin
                posted_since_irq_refresh <= posted_since_irq_refresh + 1;
            end
            // Mirror the backend's WRAMCNT write only after the oracle has
            // accepted it, keeping FPGA and HPS ownership views atomic.
            if (mailbox_done && tick_state == TICK_IDLE &&
                pending_wramcnt_write) begin
                wramcnt <= pending_wramcnt_value;
                pending_wramcnt_write <= 0;
            end
            // Cache only after the HPS model has completed the transaction.
            // IME is architecturally one bit, so every access establishes its
            // complete readback value. IE requires a word read/write to seed
            // the cache; narrower writes merge only into an existing shadow.
            if (mailbox_done && tick_state == TICK_IDLE &&
                oracle_address[31:2] == 30'h01000082) begin
                if (oracle_rnw) begin
                    ime_cache[cpu_is_arm9] <=
                        {31'h0, oracle_read_data[0]};
                    ime_cache_valid[cpu_is_arm9] <= 1;
                end else begin
                    ime_cache[cpu_is_arm9] <=
                        {31'h0, oracle_write_data[0]};
                    ime_cache_valid[cpu_is_arm9] <= 1;
                end
            end
            if (mailbox_done && tick_state == TICK_IDLE &&
                oracle_address[31:2] == 30'h01000084) begin
                if (oracle_rnw && oracle_access == 2'b10) begin
                    ie_cache[cpu_is_arm9] <= oracle_read_data;
                    ie_cache_valid[cpu_is_arm9] <= 1;
                end else if (!oracle_rnw) begin
                    case (oracle_access)
                        2'b00: if (ie_cache_valid[cpu_is_arm9])
                            case (oracle_address[1:0])
                                2'd0: ie_cache[cpu_is_arm9][7:0] <=
                                    oracle_write_data[7:0];
                                2'd1: ie_cache[cpu_is_arm9][15:8] <=
                                    oracle_write_data[7:0];
                                2'd2: ie_cache[cpu_is_arm9][23:16] <=
                                    oracle_write_data[7:0];
                                2'd3: ie_cache[cpu_is_arm9][31:24] <=
                                    oracle_write_data[7:0];
                            endcase
                        2'b01: if (ie_cache_valid[cpu_is_arm9])
                            if (oracle_address[1])
                                ie_cache[cpu_is_arm9][31:16] <=
                                    oracle_write_data[15:0];
                            else
                                ie_cache[cpu_is_arm9][15:0] <=
                                    oracle_write_data[15:0];
                        default: begin
                            ie_cache[cpu_is_arm9] <= oracle_write_data;
                            ie_cache_valid[cpu_is_arm9] <= 1;
                        end
                    endcase
                end
            end
            case (tick_state)
                // Never steal DDR from a live CPU transaction. Between local
                // transactions, however, flush a full execution-time bucket
                // before treating new cycle reports as mere activity. Without
                // this ordering, a CPU running entirely from local DDR can
                // postpone peripheral/video/audio time for hundreds of
                // millions of cycles.
                TICK_IDLE: if (posted_done &&
                               posted_since_irq_refresh >=
                                   POSTED_IRQ_REFRESH_WRITES - 1) begin
                    // All elapsed cycles are already carried by ring entries.
                    // Fence those entries and refresh only IRQ/HALT outputs.
                    tick_cpu <= 1;
                    tick_cycles <= 0;
                    halt_poll_count <= 0;
                    tick_state <= TICK_ACTIVE;
                end else if (completed_local_request &&
                               (accumulated9 >= TIME_FLUSH_CYCLES ||
                                accumulated7 >= TIME_FLUSH_CYCLES)) begin
                    // Both FPGA CPUs can accumulate execution credit faster
                    // than one HPS timing mailbox round trip. Fixed ARM9
                    // priority then drains ARM9 forever, starving ARM7; the
                    // backend advances shared DMA/video/audio time only to
                    // the timestamp reached by both CPUs. Alternate whenever
                    // both buckets are ready so neither timestamp can freeze.
                    if (accumulated9 >= TIME_FLUSH_CYCLES &&
                        (accumulated7 < TIME_FLUSH_CYCLES ||
                         !last_time_tick_cpu)) begin
                        tick_cpu <= 1;
                        last_time_tick_cpu <= 1;
                        tick_cycles <= TIME_FLUSH_CYCLES;
                        accumulated9 <= accumulated9 - TIME_FLUSH_CYCLES +
                            (arm9_cycles_valid ? arm9_cycles : 0);
                    end else begin
                        tick_cpu <= 0;
                        last_time_tick_cpu <= 0;
                        tick_cycles <= TIME_FLUSH_CYCLES;
                        accumulated7 <= accumulated7 - TIME_FLUSH_CYCLES +
                            (arm7_cycles_valid ? arm7_cycles : 0);
                    end
                    halt_poll_count <= 0;
                    tick_state <= TICK_ACTIVE;
                end else if (request || oracle_request) begin
                    halt_poll_count <= 0;
                end else begin
                    if (accumulated9 >= TIME_FLUSH_CYCLES &&
                        (accumulated7 < TIME_FLUSH_CYCLES ||
                         !last_time_tick_cpu)) begin
                        tick_cpu <= 1;
                        last_time_tick_cpu <= 1;
                        tick_cycles <= TIME_FLUSH_CYCLES;
                        accumulated9 <= accumulated9 - TIME_FLUSH_CYCLES +
                            (arm9_cycles_valid ? arm9_cycles : 0);
                        halt_poll_count <= 0;
                        tick_state <= TICK_ACTIVE;
                    end else if (accumulated7 >= TIME_FLUSH_CYCLES) begin
                        tick_cpu <= 0;
                        last_time_tick_cpu <= 0;
                        tick_cycles <= TIME_FLUSH_CYCLES;
                        accumulated7 <= accumulated7 - TIME_FLUSH_CYCLES +
                            (arm7_cycles_valid ? arm7_cycles : 0);
                        halt_poll_count <= 0;
                        tick_state <= TICK_ACTIVE;
                    end else begin
                        if (arm9_cycles_valid || arm7_cycles_valid) begin
                            halt_poll_count <= 0;
                        end else if (halt_poll_count >= HALT_POLL_CLOCKS - 1) begin
                            if (halt_arm9 && halt_arm7)
                                tick_cpu <= !last_halt_tick_cpu;
                            else if (halt_arm9 || halt_arm7)
                                tick_cpu <= halt_arm9;
                            else
                                tick_cpu <= !last_halt_tick_cpu;
                            if (halt_arm9 && halt_arm7)
                                last_halt_tick_cpu <= !last_halt_tick_cpu;
                            else if (halt_arm9 || halt_arm7)
                                last_halt_tick_cpu <= halt_arm9;
                            else
                                last_halt_tick_cpu <= !last_halt_tick_cpu;
                            tick_cycles <= HALT_ADVANCE_CYCLES;
                            halt_poll_count <= 0;
                            tick_state <= TICK_ACTIVE;
                        end else begin
                            halt_poll_count <= halt_poll_count + 1;
                        end
                    end
                end
                TICK_ACTIVE: if (mailbox_done)
                    tick_state <= TICK_RELEASE;
                TICK_RELEASE: tick_state <= TICK_IDLE;
                default: tick_state <= TICK_IDLE;
            endcase
        end
    end
endmodule
