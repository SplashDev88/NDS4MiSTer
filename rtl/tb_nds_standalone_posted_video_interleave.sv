// Host-simulator model of the request/ownership portion of the VHDL
// nds_dual_cpu_bus. The IPCSYNC fast path is intentionally omitted because
// this test issues only main-RAM and VRAM requests. Keeping this model in the
// testbench lets Icarus and Verilator exercise the production mixed-language
// bridge boundary, including a CPU request launched while ext_done is high.
module nds_dual_cpu_bus (
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] arm9_addr,
    input  logic        arm9_rnw,
    input  logic        arm9_ena,
    input  logic [1:0]  arm9_acc,
    input  logic [31:0] arm9_wdata,
    input  logic [31:0] arm9_debug_pc,
    output logic [31:0] arm9_rdata,
    output logic        arm9_done,
    input  logic [31:0] arm7_addr,
    input  logic        arm7_rnw,
    input  logic        arm7_ena,
    input  logic [1:0]  arm7_acc,
    input  logic [31:0] arm7_wdata,
    input  logic [31:0] arm7_debug_pc,
    output logic [31:0] arm7_rdata,
    output logic        arm7_done,
    output logic [31:0] ext_addr,
    output logic        ext_rnw,
    output logic        ext_ena,
    output logic [1:0]  ext_acc,
    output logic [31:0] ext_wdata,
    output logic        ext_cpu_is_arm9,
    output logic [31:0] ext_debug_pc,
    input  logic [31:0] ext_rdata,
    input  logic        ext_done
);
    typedef enum logic [1:0] {IDLE, GRANT_ARM9, GRANT_ARM7} grant_t;
    grant_t grant;
    logic last_grant_arm9;
    logic pending9, pending7;
    logic [31:0] pending9_addr, pending7_addr;
    logic pending9_rnw, pending7_rnw;
    logic [1:0] pending9_acc, pending7_acc;
    logic [31:0] pending9_wdata, pending7_wdata;
    logic [31:0] pending9_debug_pc, pending7_debug_pc;

    assign arm9_rdata = ext_rdata;
    assign arm7_rdata = ext_rdata;
    assign arm9_done = grant == GRANT_ARM9 && ext_done;
    assign arm7_done = grant == GRANT_ARM7 && ext_done;
    assign ext_ena = grant != IDLE;
    assign ext_cpu_is_arm9 = grant == GRANT_ARM9;

    always_ff @(posedge clk) begin
        if (reset) begin
            grant <= IDLE;
            last_grant_arm9 <= 1'b0;
            pending9 <= 1'b0;
            pending7 <= 1'b0;
            ext_addr <= 32'd0;
            ext_rnw <= 1'b1;
            ext_acc <= 2'd0;
            ext_wdata <= 32'd0;
            ext_debug_pc <= 32'd0;
        end else begin
            // This is the completion-edge capture rule from the VHDL bus.
            if (arm9_ena && (grant != GRANT_ARM9 || ext_done) &&
                !pending9) begin
                pending9 <= 1'b1;
                pending9_addr <= arm9_addr;
                pending9_rnw <= arm9_rnw;
                pending9_acc <= arm9_acc;
                pending9_wdata <= arm9_wdata;
                pending9_debug_pc <= arm9_debug_pc;
            end
            if (arm7_ena && (grant != GRANT_ARM7 || ext_done) &&
                !pending7) begin
                pending7 <= 1'b1;
                pending7_addr <= arm7_addr;
                pending7_rnw <= arm7_rnw;
                pending7_acc <= arm7_acc;
                pending7_wdata <= arm7_wdata;
                pending7_debug_pc <= arm7_debug_pc;
            end

            case (grant)
                IDLE: begin
                    if (pending9 && pending7) begin
                        if (last_grant_arm9) begin
                            ext_addr <= pending7_addr;
                            ext_rnw <= pending7_rnw;
                            ext_acc <= pending7_acc;
                            ext_wdata <= pending7_wdata;
                            ext_debug_pc <= pending7_debug_pc;
                            pending7 <= 1'b0;
                            grant <= GRANT_ARM7;
                        end else begin
                            ext_addr <= pending9_addr;
                            ext_rnw <= pending9_rnw;
                            ext_acc <= pending9_acc;
                            ext_wdata <= pending9_wdata;
                            ext_debug_pc <= pending9_debug_pc;
                            pending9 <= 1'b0;
                            grant <= GRANT_ARM9;
                        end
                    end else if (pending9) begin
                        ext_addr <= pending9_addr;
                        ext_rnw <= pending9_rnw;
                        ext_acc <= pending9_acc;
                        ext_wdata <= pending9_wdata;
                        ext_debug_pc <= pending9_debug_pc;
                        pending9 <= 1'b0;
                        grant <= GRANT_ARM9;
                    end else if (pending7) begin
                        ext_addr <= pending7_addr;
                        ext_rnw <= pending7_rnw;
                        ext_acc <= pending7_acc;
                        ext_wdata <= pending7_wdata;
                        ext_debug_pc <= pending7_debug_pc;
                        pending7 <= 1'b0;
                        grant <= GRANT_ARM7;
                    end
                end
                GRANT_ARM9: if (ext_done) begin
                    grant <= IDLE;
                    last_grant_arm9 <= 1'b1;
                end
                GRANT_ARM7: if (ext_done) begin
                    grant <= IDLE;
                    last_grant_arm9 <= 1'b0;
                end
                default: grant <= IDLE;
            endcase
        end
    end
endmodule

module tb_nds_standalone_posted_video_interleave;
    localparam logic [28:0] ORACLE = 29'h05800000;
    localparam logic [28:0] MAIN = 29'h05820000;
    localparam logic [28:0] POSTED = 29'h05806000;
    localparam logic [28:0] VIDEO = 29'h05880000;
    localparam logic [2:0] RESP_NONE = 3'd0;
    localparam logic [2:0] RESP_DESCRIPTOR = 3'd1;
    localparam logic [2:0] RESP_RECHECK = 3'd2;
    localparam logic [2:0] RESP_VIDEO = 3'd3;
    localparam logic [2:0] RESP_MAILBOX = 3'd4;

    logic clk = 0;
    logic reset = 1;
    logic enable = 0;
    always #5 clk = ~clk;

    logic boot_valid, boot_error;
    logic [31:0] boot_generation, dtcm_vector, trace_trigger;
    logic [31:0] arm9_entry, arm7_entry;
    logic [31:0] arm9_sp, arm9_irq_sp, arm9_saved_sp;
    logic [31:0] arm7_sp, arm7_irq_sp, arm7_saved_sp, initial_cpsr;
    logic core_reset;

    logic [31:0] arm9_addr = 0;
    logic arm9_rnw = 0;
    logic arm9_ena = 0;
    logic [1:0] arm9_acc = 2'b10;
    logic [31:0] arm9_wdata = 0;
    logic [31:0] arm9_rdata;
    logic arm9_done;
    logic [31:0] arm7_rdata;
    logic arm7_done;
    logic cpu_pause;
    logic debug_mailbox_request, debug_mailbox_done;

    logic cpu_read, cpu_write;
    logic [7:0] cpu_burst, cpu_be;
    logic [28:0] cpu_address;
    logic [63:0] cpu_write_data, cpu_read_data;
    logic cpu_busy, cpu_read_ready, cpu_command_accepted;

    logic video_read = 0;
    logic video_busy, video_read_ready, video_command_accepted;
    logic [63:0] video_read_data;

    logic physical_read, physical_write;
    logic [7:0] physical_burst, physical_be;
    logic [28:0] physical_address;
    logic [63:0] physical_write_data;
    logic physical_busy;
    logic [63:0] physical_read_data;
    logic physical_read_ready;
    logic [17:0] arbiter_debug;

    logic idle_high_waitrequest = 0;
    logic force_waitrequest = 0;
    logic [31:0] descriptor [0:15];
    logic [2:0] response_kind = RESP_NONE;
    integer response_remaining = 0;
    integer response_index = 0;
    integer response_delay = 0;
    integer mailbox_response_variant = 0;
    logic [31:0] published_mailbox_sequence = 0;
    integer local_write_accepts = 0;
    integer posted_write_accepts = 0;
    integer mailbox_write_accepts = 0;
    integer mailbox_read_accepts = 0;
    integer mailbox_response_beats = 0;
    integer video_read_accepts = 0;
    integer video_response_beats = 0;
    logic [28:0] accepted_posted_address [0:11];

    wire physical_command = physical_read || physical_write;
    wire physical_accept = physical_command && !physical_busy;
    wire video_acceptance_edge =
        physical_accept && physical_read && physical_address == VIDEO;
    wire mailbox_acceptance_edge =
        physical_accept && physical_read &&
        physical_address == ORACLE + 29'd3;
    wire queued_response_ready =
        response_remaining > 0 && response_delay == 0;

    // During descriptor boot the always-ready mode keeps the setup focused
    // on the post-handoff production path. Thereafter this is MiSTer's legal
    // idle-high waitrequest convention: waitrequest drops only after RD/WE is
    // presented. force_waitrequest creates an older queued CPU command.
    always_comb begin
        if (force_waitrequest)
            physical_busy = 1'b1;
        else if (idle_high_waitrequest)
            physical_busy = !physical_command;
        else
            physical_busy = 1'b0;
    end

    // Video returns beat zero on its command-acceptance edge. Mailbox mode
    // zero does the same; modes one and two exercise post-accept back-to-back
    // and delayed/gapped response pairs. Descriptor responses begin one
    // cycle after acceptance.
    always_comb begin
        physical_read_ready = 1'b0;
        physical_read_data = 64'd0;
        if (video_acceptance_edge) begin
            physical_read_ready = 1'b1;
            physical_read_data = 64'hb000000000000000;
        end else if (mailbox_acceptance_edge &&
                     mailbox_response_variant == 0) begin
            physical_read_ready = 1'b1;
            physical_read_data = {
                published_mailbox_sequence, 32'h13579bdf
            };
        end else if (queued_response_ready) begin
            physical_read_ready = 1'b1;
            case (response_kind)
                RESP_DESCRIPTOR: physical_read_data = {
                    descriptor[response_index*2+1],
                    descriptor[response_index*2]
                };
                RESP_RECHECK: physical_read_data = {
                    descriptor[3], descriptor[2]
                };
                RESP_VIDEO: physical_read_data =
                    64'hb000000000000000 | response_index;
                RESP_MAILBOX: physical_read_data =
                    response_index == 0
                        ? {published_mailbox_sequence, 32'h13579bdf}
                        : 64'h0000000000000000;
                default: physical_read_data = 64'd0;
            endcase
        end
    end

    assign core_reset = reset || !boot_valid;

    nds_dual_cpu_memory_bridge #(
        .ORACLE_POLL_DELAY_CYCLES(1),
        .TIME_FLUSH_CYCLES(8192)
    ) bridge (
        .clk, .reset(core_reset), .transport_reset(core_reset),
        .arm9_cycles(8'd0), .arm9_cycles_valid(1'b0),
        .arm7_cycles(8'd0), .arm7_cycles_valid(1'b0),
        .arm9_debug_pc(32'h02001000),
        .arm7_debug_pc(32'h037f8000),
        .arm9_dtcm_region(32'h0300000a),
        .arm9_dtcm_enable(1'b1),
        .arm9_dtcm_seed_valid(boot_valid),
        .arm9_dtcm_irq_vector(dtcm_vector),
        .arm9_addr, .arm9_rnw, .arm9_ena, .arm9_acc, .arm9_wdata,
        .arm9_rdata, .arm9_done, .arm9_irq(), .arm9_halt(),
        .arm7_addr(32'd0), .arm7_rnw(1'b1), .arm7_ena(1'b0),
        .arm7_acc(2'b10), .arm7_wdata(32'd0),
        .arm7_rdata, .arm7_done, .arm7_irq(), .arm7_halt(),
        .cpu_pause, .debug_ext_ena(), .debug_ext_cpu_is_arm9(),
        .debug_ext_address(), .debug_oracle_request(),
        .debug_mailbox_request, .debug_mailbox_done,
        .ddram_read(cpu_read), .ddram_write(cpu_write),
        .ddram_burst_count(cpu_burst), .ddram_address(cpu_address),
        .ddram_write_data(cpu_write_data), .ddram_byte_enable(cpu_be),
        .ddram_busy(cpu_busy), .ddram_read_data(cpu_read_data),
        .ddram_read_data_ready(cpu_read_ready),
        .ddram_command_accepted(cpu_command_accepted)
    );
    nds_standalone_boot_ddr shared (
        .clk, .reset, .enable, .boot_valid, .boot_error,
        .boot_generation, .arm9_dtcm_irq_vector(dtcm_vector),
        .arm9_trace_trigger(trace_trigger),
        .arm9_entry, .arm7_entry,
        .arm9_current_sp(arm9_sp), .arm9_irq_sp, .arm9_saved_sp,
        .arm7_current_sp(arm7_sp), .arm7_irq_sp, .arm7_saved_sp,
        .initial_cpsr,
        .cpu_rd(cpu_read), .cpu_we(cpu_write),
        .cpu_burstcnt(cpu_burst), .cpu_addr(cpu_address),
        .cpu_din(cpu_write_data), .cpu_be,
        .cpu_busy, .cpu_dout(cpu_read_data),
        .cpu_dout_ready(cpu_read_ready),
        .cpu_command_accepted,
        .video_rd(video_read), .video_we(1'b0),
        .video_burstcnt(8'd8), .video_addr(VIDEO),
        .video_din(64'd0), .video_be(8'hff),
        .video_busy, .video_dout(video_read_data),
        .video_dout_ready(video_read_ready),
        .video_command_accepted,
`ifndef ARCHIVED_R192
        .debug_arbiter_state(arbiter_debug),
`endif
        .ddram_rd(physical_read), .ddram_we(physical_write),
        .ddram_burstcnt(physical_burst),
        .ddram_addr(physical_address),
        .ddram_din(physical_write_data), .ddram_be(physical_be),
        .ddram_busy(physical_busy),
        .ddram_dout(physical_read_data),
        .ddram_dout_ready(physical_read_ready)
    );

    always_ff @(posedge clk) begin
        if (reset) begin
            response_kind <= RESP_NONE;
            response_remaining <= 0;
            response_index <= 0;
            response_delay <= 0;
            published_mailbox_sequence <= 0;
            local_write_accepts <= 0;
            posted_write_accepts <= 0;
            mailbox_write_accepts <= 0;
            mailbox_read_accepts <= 0;
            mailbox_response_beats <= 0;
            video_read_accepts <= 0;
            video_response_beats <= 0;
        end else begin
            if (response_remaining > 0) begin
                if (response_delay > 0) begin
                    response_delay <= response_delay - 1;
                end else if (response_kind == RESP_MAILBOX &&
                             mailbox_response_variant == 2 &&
                             response_index == 0 &&
                             response_remaining == 2) begin
                    // Leave a visible low-ready gap between the two beats.
                    response_remaining <= 1;
                    response_index <= 1;
                    response_delay <= 2;
                end else begin
                    response_remaining <= response_remaining - 1;
                    response_index <= response_index + 1;
                    if (response_remaining == 1)
                        response_kind <= RESP_NONE;
                end
            end
            if (physical_accept && physical_read) begin
                if (physical_address == 29'h05800200) begin
                    response_kind <= RESP_DESCRIPTOR;
                    response_remaining <= 8;
                    response_index <= 0;
                    response_delay <= 0;
                end else if (physical_address == 29'h05800201) begin
                    response_kind <= RESP_RECHECK;
                    response_remaining <= 1;
                    response_index <= 0;
                    response_delay <= 0;
                end else if (physical_address == VIDEO) begin
                    response_kind <= RESP_VIDEO;
                    response_remaining <= physical_burst - 1;
                    response_index <= 1;
                    response_delay <= 0;
                    video_read_accepts <= video_read_accepts + 1;
                end else if (physical_address == ORACLE + 29'd3) begin
                    if (physical_burst != 2)
                        $fatal(1, "mailbox poll was not a two-beat read");
                    if (published_mailbox_sequence !=
                        bridge.memory.g_ddr_oracle.oracle.request_sequence)
                        $fatal(1,
                            "HPS response generation mismatch published=%h requested=%h",
                            published_mailbox_sequence,
                            bridge.memory.g_ddr_oracle.oracle.request_sequence);
                    response_kind <= RESP_MAILBOX;
                    response_remaining <=
                        mailbox_response_variant == 0 ? 1 : 2;
                    response_index <=
                        mailbox_response_variant == 0 ? 1 : 0;
                    response_delay <=
                        mailbox_response_variant == 2 ? 2 : 0;
                    mailbox_read_accepts <= mailbox_read_accepts + 1;
                end else begin
                    $fatal(1, "unexpected physical read %h/%0d",
                           physical_address, physical_burst);
                end
            end
            if (physical_accept && physical_write) begin
                if (physical_address >= MAIN &&
                    physical_address < MAIN + 29'd16) begin
                    local_write_accepts <= local_write_accepts + 1;
                end else if (physical_address >= POSTED + 29'd8 &&
                             physical_address < POSTED + 29'd20) begin
                    if (physical_address !=
                        POSTED + 29'd8 + posted_write_accepts)
                        $fatal(1,
                            "posted write skipped/duplicated expected=%h got=%h",
                            POSTED + 29'd8 + posted_write_accepts,
                            physical_address);
                    accepted_posted_address[posted_write_accepts] <=
                        physical_address;
                    posted_write_accepts <= posted_write_accepts + 1;
                end else if (physical_address >= ORACLE &&
                             physical_address <= ORACLE + 29'd4) begin
                    case (mailbox_write_accepts % 4)
                        0: if (physical_address != ORACLE + 29'd1 ||
                               physical_write_data[31:0] != 32'hffffffff)
                            $fatal(1,
                                "timing transaction beat mismatch %h/%h",
                                physical_address, physical_write_data);
                        1: if (physical_address != ORACLE + 29'd2 ||
                               physical_write_data !=
                                   64'h000000000000000d)
                            $fatal(1,
                                "timing control beat mismatch %h/%h",
                                physical_address, physical_write_data);
                        2: if (physical_address != ORACLE + 29'd4 ||
                               physical_write_data[63:32] !=
                                   bridge.memory.posted_write_ring.
                                       producer_sequence)
                            $fatal(1,
                                "timing fence beat mismatch %h/%h producer=%h",
                                physical_address, physical_write_data,
                                bridge.memory.posted_write_ring.
                                    producer_sequence);
                        3: begin
                            if (physical_address != ORACLE ||
                                physical_write_data[31:0] != 32'h4f53444e)
                                $fatal(1,
                                    "timing header mismatch %h/%h",
                                    physical_address,
                                    physical_write_data);
                            published_mailbox_sequence <=
                                physical_write_data[63:32];
                        end
                    endcase
                    mailbox_write_accepts <= mailbox_write_accepts + 1;
                end else begin
                    $fatal(1, "unexpected physical write %h",
                           physical_address);
                end
            end
            if (mailbox_acceptance_edge &&
                mailbox_response_variant == 0)
                mailbox_response_beats <= mailbox_response_beats + 1;
            if (queued_response_ready &&
                response_kind == RESP_MAILBOX)
                mailbox_response_beats <= mailbox_response_beats + 1;
            if (video_read_ready)
                video_response_beats <= video_response_beats + 1;
        end
    end

    task automatic launch_arm9_write(
        input logic [31:0] target,
        input logic [1:0] width,
        input logic [31:0] value
    );
        begin
            wait (!cpu_pause && !arm9_done);
            @(negedge clk);
            arm9_addr = target;
            arm9_rnw = 0;
            arm9_acc = width;
            arm9_wdata = value;
            arm9_ena = 1;
            @(posedge clk);
            @(negedge clk);
            arm9_ena = 0;
            wait (arm9_done);
            #1;
        end
    endtask

    task automatic queue_arm9_write_on_completion(
        input logic [31:0] target,
        input logic [1:0] width,
        input logic [31:0] value
    );
        begin
            if (!arm9_done)
                $fatal(1,
                    "completion-edge request was not staged while done high");
            // Match gba_cpu's legal same-edge handoff: present the next
            // posted write while the previous request's done pulse is still
            // high. The bus captures it on that completion edge even though
            // the terminal posted-write IRQ refresh starts simultaneously.
            @(negedge clk);
            arm9_addr = target;
            arm9_rnw = 0;
            arm9_acc = width;
            arm9_wdata = value;
            arm9_ena = 1;
            @(posedge clk);
            @(negedge clk);
            arm9_ena = 0;
        end
    endtask

    task automatic complete_refresh(
        input integer variant,
        input integer expected_sequence
    );
        integer writes_before;
        integer reads_before;
        integer responses_before;
        integer video_reads_before;
        integer video_beats_before;
        begin
            mailbox_response_variant = variant;
            // Put the production counter at its terminal value for this
            // posted-done pulse. This is equivalent to a threshold of one
            // while retaining the exact production bridge instance.
            force bridge.memory.posted_since_irq_refresh = 255;
            wait (bridge.memory.tick_state == 1);
            release bridge.memory.posted_since_irq_refresh;
            #1;
            if (!cpu_pause || !debug_mailbox_request)
                $fatal(1,
                    "refresh did not pause CPU/start mailbox variant=%0d",
                    variant);
            writes_before = mailbox_write_accepts;
            reads_before = mailbox_read_accepts;
            responses_before = mailbox_response_beats;
            video_reads_before = video_read_accepts;
            video_beats_before = video_response_beats;

            // Put a real B read into the arbiter while the timing-only A
            // mailbox is publishing. The mailbox must resume afterward.
            @(negedge clk);
            video_read = 1;
            wait (video_command_accepted);
            @(negedge clk);
            video_read = 0;

            wait (debug_mailbox_done);
            #1;
            if (bridge.memory.tick_state != 1)
                $fatal(1,
                    "tick left ACTIVE before observing mailbox done");
            if (mailbox_write_accepts - writes_before != 4 ||
                mailbox_read_accepts - reads_before != 1 ||
                mailbox_response_beats - responses_before != 2)
                $fatal(1,
                    "mailbox shape mismatch variant=%0d writes=%0d reads=%0d responses=%0d",
                    variant,
                    mailbox_write_accepts - writes_before,
                    mailbox_read_accepts - reads_before,
                    mailbox_response_beats - responses_before);
            if (video_read_accepts - video_reads_before != 1 ||
                video_response_beats - video_beats_before != 8)
                $fatal(1,
                    "video contention mismatch variant=%0d reads=%0d beats=%0d",
                    variant,
                    video_read_accepts - video_reads_before,
                    video_response_beats - video_beats_before);
            if (bridge.memory.mailbox_completed_fence !=
                expected_sequence)
                $fatal(1,
                    "refresh completed wrong fence expected=%0d got=%h",
                    expected_sequence,
                    bridge.memory.mailbox_completed_fence);

            @(posedge clk);
            #1;
            if (bridge.memory.tick_state != 2 || !cpu_pause)
                $fatal(1,
                    "tick did not enter paused RELEASE variant=%0d state=%0d pause=%0d",
                    variant, bridge.memory.tick_state, cpu_pause);
            @(posedge clk);
            #1;
            if (bridge.memory.tick_state != 0 || cpu_pause ||
                debug_mailbox_request)
                $fatal(1,
                    "tick did not return IDLE variant=%0d state=%0d pause=%0d request=%0d",
                    variant, bridge.memory.tick_state, cpu_pause,
                    debug_mailbox_request);
        end
    endtask

    initial begin : timeout_guard
        repeat (4000) @(posedge clk);
        $fatal(1,
            "timeout boot=%0d local=%0d posted=%0d mb_wr=%0d mb_rd=%0d mb_rsp=%0d vreads=%0d vbeats=%0d arm9done=%0d pause=%0d tick=%0d mailbox=%0d ring_state=%0d producer=%0d owner_pending=%0d owner_posted=%0d arb=%05h sel_b=%0d dwell=%0d cmd_pending=%0d cmd_owner_b=%0d read_pending=%0d read_owner_b=%0d remaining=%0d phy_rd=%0d phy_we=%0d phy_busy=%0d phy_ready=%0d",
            boot_valid, local_write_accepts, posted_write_accepts,
            mailbox_write_accepts, mailbox_read_accepts,
            mailbox_response_beats, video_read_accepts,
            video_response_beats, arm9_done, cpu_pause,
            bridge.memory.tick_state,
            bridge.memory.g_ddr_oracle.oracle.state,
            bridge.memory.posted_write_ring.state,
            bridge.memory.posted_write_ring.producer_sequence,
            bridge.memory.ddram_owner_pending,
            bridge.memory.ddram_pending_owner_posted,
            arbiter_debug,
            shared.arbiter.selected_b, shared.arbiter.grant_dwell,
            shared.arbiter.command_pending,
            shared.arbiter.command_owner_b,
            shared.arbiter.read_pending,
            shared.arbiter.read_owner_b,
            shared.arbiter.beats_remaining,
            physical_read, physical_write, physical_busy,
            physical_read_ready);
    end

    initial begin
        descriptor[0] = 32'h4253444e;
        descriptor[1] = 32'd3;
        descriptor[2] = 32'd1;
        descriptor[3] = 32'h01ffd5ec;
        descriptor[4] = 32'h00400000;
        descriptor[5] = 32'h02064eb4;
        descriptor[6] = 32'h02004800;
        descriptor[7] = 32'h02380000;
        descriptor[8] = 32'h03002f7c;
        descriptor[9] = 32'h03003f80;
        descriptor[10] = 32'h03003fc0;
        descriptor[11] = 32'h0380fd80;
        descriptor[12] = 32'h0380ff80;
        descriptor[13] = 32'h0380ffc0;
        descriptor[14] = 32'h000000d3;
        descriptor[15] = 32'h3ac5bac9;

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        enable = 1;
        wait (boot_valid);
        if (boot_error || dtcm_vector != 32'h01ffd5ec)
            $fatal(1, "descriptor did not survive standalone handoff");

        // Begin the production protocol only from an empty A grant. The
        // older r192 arbiter can therefore queue the local command first;
        // its failure occurs only after that command rotates to idle B.
        wait (!shared.arbiter.selected_b &&
              !shared.arbiter.command_pending &&
              !shared.arbiter.read_pending);
        @(negedge clk);
        idle_high_waitrequest = 1;
        force_waitrequest = 1;

        // Launch a local main-RAM write through the bridge. It completes to
        // the CPU when admitted to the outer queue, while physical DDR is
        // deliberately stalled.
        arm9_addr = 32'h02000000;
        arm9_rnw = 0;
        arm9_acc = 2'b10;
        arm9_wdata = 32'h11223344;
        arm9_ena = 1;
        @(posedge clk);
        @(negedge clk);
        arm9_ena = 0;
        wait (arm9_done);
        if (!bridge.memory.ddram_owner_pending ||
            bridge.memory.ddram_pending_owner_posted)
            $fatal(1, "older local DDR command lost its sub-owner tag");

        // gba_cpu may pulse its next request while done is still high. Drive
        // the posted VRAM write on that exact bridge completion window.
        @(negedge clk);
        arm9_addr = 32'h0600c000;
        arm9_acc = 2'b01;
        arm9_wdata = 32'h000055aa;
        arm9_ena = 1;
        @(posedge clk);
        @(negedge clk);
        arm9_ena = 0;
        wait (bridge.memory.posted_write_ring.state == 4);

        // Accept the older local write while the posted request is already
        // live. Its acceptance must not advance the posted ring.
        force_waitrequest = 0;
        wait (local_write_accepts == 1);
        #1;
        if (bridge.memory.posted_write_ring.state != 4 ||
            bridge.memory.posted_write_ring.producer_sequence != 0)
            $fatal(1, "older local acceptance retired the posted owner");

        // Let the first two posted beats land, then occupy B with a real
        // eight-beat read. Beat zero returns on the command-acceptance edge.
        wait (posted_write_accepts == 2);
        @(negedge clk);
        video_read = 1;
        wait (video_command_accepted);
        @(negedge clk);
        video_read = 0;
        wait (video_response_beats == 8);

        // B completion must rotate back to the held A commit. The bridge
        // then returns done for the posted CPU request.
        wait (arm9_done);
        #1;
        if (posted_write_accepts != 3 ||
            accepted_posted_address[0] != POSTED + 8 ||
            accepted_posted_address[1] != POSTED + 9 ||
            accepted_posted_address[2] != POSTED + 10)
            $fatal(1, "posted beats skipped or duplicated around B");
        if (video_read_accepts != 1 || video_response_beats != 8)
            $fatal(1, "video burst acceptance/response count changed");
        if (bridge.memory.posted_write_ring.producer_sequence != 1)
            $fatal(1, "posted commit did not advance producer");

        // Stage the next posted write on the exact completion edge that
        // starts the zero-cycle IRQ refresh. It reaches the ring's DDR-active
        // state while the tick mailbox is publishing. The tick owns the mux,
        // so the mailbox must complete first and the parked posted write must
        // then resume without either client blocking the other.
        force bridge.memory.posted_since_irq_refresh = 255;
        queue_arm9_write_on_completion(
            32'h0600c002, 2'b01, 32'h000066bb);
        complete_refresh(0, 1);
        wait (arm9_done);
        #1;
        if (bridge.memory.posted_write_ring.producer_sequence != 2 ||
            posted_write_accepts != 6)
            $fatal(1,
                "completion-edge posted write did not resume after refresh");

        // Exercise the remaining legal two-beat return shapes while a B
        // video burst contends for the same outer DDR port.
        complete_refresh(1, 2);

        launch_arm9_write(32'h0600c004, 2'b01, 32'h000077cc);
        if (bridge.memory.posted_write_ring.producer_sequence != 3 ||
            posted_write_accepts != 9)
            $fatal(1, "CPU did not continue to third posted commit");
        complete_refresh(2, 3);

        // Start one more delayed mailbox response and reset while its two
        // response beats are outstanding. All queued owner/read state must
        // clear, the descriptor must reload, and a new CPU transfer must
        // complete without a stale response or stuck pause.
        mailbox_response_variant = 2;
        launch_arm9_write(32'h0600c006, 2'b01, 32'h000088dd);
        force bridge.memory.posted_since_irq_refresh = 255;
        wait (bridge.memory.tick_state == 1);
        release bridge.memory.posted_since_irq_refresh;
        wait (response_kind == RESP_MAILBOX &&
              response_remaining == 2 && response_delay > 0);
        @(negedge clk);
        idle_high_waitrequest = 0;
        force_waitrequest = 0;
        video_read = 0;
        reset = 1;
        repeat (3) @(posedge clk);
        #1;
        if (boot_valid || bridge.memory.tick_state != 0 ||
            shared.arbiter.command_pending ||
            shared.arbiter.read_pending)
            $fatal(1,
                "runtime reset retained boot/tick/DDR owner state");
        @(negedge clk);
        reset = 0;
        wait (boot_valid);
        wait (!shared.arbiter.selected_b &&
              !shared.arbiter.command_pending &&
              !shared.arbiter.read_pending);
        idle_high_waitrequest = 1;
        launch_arm9_write(32'h02000008, 2'b10, 32'ha5a55a5a);
        wait (local_write_accepts == 1);
        #1;
        if (cpu_pause || debug_mailbox_request ||
            bridge.memory.tick_state != 0)
            $fatal(1,
                "CPU did not recover after reset-overlap pause=%0d request=%0d tick=%0d",
                cpu_pause, debug_mailbox_request,
                bridge.memory.tick_state);

        $display("PASS: bridge/posted/video path completes all mailbox response timings, releases CPU pause, and recovers from response-overlap reset");
        $finish;
    end
endmodule
