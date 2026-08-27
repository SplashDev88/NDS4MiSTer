module tb_nds_standalone_boot_ddr_sound_active;
    localparam logic [28:0] DESCRIPTOR_BASE = 29'h05800200;
    localparam logic [28:0] CPU_ADDRESS = 29'h01000010;
    localparam logic [28:0] VIDEO_ADDRESS = 29'h02000020;
    localparam logic [28:0] SOUND_ADDRESS = 29'h03000030;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic enable = 1'b0;
    logic sound_enable = 1'b1;
    always #5 clk = ~clk;

    logic boot_valid;
    logic boot_error;
    logic [31:0] boot_generation;
    logic [31:0] arm9_dtcm_irq_vector;
    logic [31:0] arm9_trace_trigger;
    logic [31:0] arm9_entry;
    logic [31:0] arm7_entry;
    logic [31:0] arm9_current_sp;
    logic [31:0] arm9_irq_sp;
    logic [31:0] arm9_saved_sp;
    logic [31:0] arm7_current_sp;
    logic [31:0] arm7_irq_sp;
    logic [31:0] arm7_saved_sp;
    logic [31:0] initial_cpsr;
    logic sound_mode_active;
    logic sound_mode_change_ignored;

    logic cpu_rd = 1'b0;
    logic cpu_we = 1'b0;
    logic [7:0] cpu_burstcnt = 8'd1;
    logic [28:0] cpu_addr = CPU_ADDRESS;
    logic [63:0] cpu_din = 64'h1111222233334444;
    logic [7:0] cpu_be = 8'hff;
    logic cpu_busy;
    logic [63:0] cpu_dout;
    logic cpu_dout_ready;
    logic cpu_command_accepted;

    logic video_rd = 1'b0;
    logic video_we = 1'b0;
    logic [7:0] video_burstcnt = 8'd1;
    logic [28:0] video_addr = VIDEO_ADDRESS;
    logic [63:0] video_din = 64'h5555666677778888;
    logic [7:0] video_be = 8'hff;
    logic video_busy;
    logic [63:0] video_dout;
    logic video_dout_ready;
    logic video_command_accepted;

    logic sound_rd = 1'b0;
    logic sound_we = 1'b0;
    logic [7:0] sound_burstcnt = 8'd1;
    logic [28:0] sound_addr = SOUND_ADDRESS;
    logic [63:0] sound_din = 64'h9999aaaabbbbcccc;
    logic [7:0] sound_be = 8'hff;
    logic sound_busy;
    logic [63:0] sound_dout;
    logic sound_dout_ready;
    logic sound_command_accepted;

    logic ddram_rd;
    logic ddram_we;
    logic [7:0] ddram_burstcnt;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din;
    logic [7:0] ddram_be;
    logic ddram_busy = 1'b0;
    logic [63:0] model_dout = 64'd0;
    logic model_ready = 1'b0;
    logic inject_ready = 1'b0;
    logic [63:0] inject_dout = 64'hdeaddeaddeaddead;
    wire [63:0] ddram_dout =
        inject_ready ? inject_dout : model_dout;
    wire ddram_dout_ready = inject_ready || model_ready;

    logic epoch_quiescent;
    logic [31:0] debug_arbiter_state;
    logic protocol_error;

    nds_standalone_boot_ddr_sound #(
        .SOUND_RESET_QUIET_CYCLES(3),
        .SOUND_STICKY_GRANT_LIMIT(8)
    ) dut (
        .clk,
        .reset,
        .enable,
        .sound_enable,
        .sound_mode_active,
        .sound_mode_change_ignored,
        .boot_valid,
        .boot_error,
        .boot_generation,
        .arm9_dtcm_irq_vector,
        .arm9_trace_trigger,
        .arm9_entry,
        .arm7_entry,
        .arm9_current_sp,
        .arm9_irq_sp,
        .arm9_saved_sp,
        .arm7_current_sp,
        .arm7_irq_sp,
        .arm7_saved_sp,
        .initial_cpsr,
        .cpu_rd,
        .cpu_we,
        .cpu_burstcnt,
        .cpu_addr,
        .cpu_din,
        .cpu_be,
        .cpu_busy,
        .cpu_dout,
        .cpu_dout_ready,
        .cpu_command_accepted,
        .video_rd,
        .video_we,
        .video_burstcnt,
        .video_addr,
        .video_din,
        .video_be,
        .video_busy,
        .video_dout,
        .video_dout_ready,
        .video_command_accepted,
        .sound_rd,
        .sound_we,
        .sound_burstcnt,
        .sound_addr,
        .sound_din,
        .sound_be,
        .sound_busy,
        .sound_dout,
        .sound_dout_ready,
        .sound_command_accepted,
        .ddram_rd,
        .ddram_we,
        .ddram_burstcnt,
        .ddram_addr,
        .ddram_din,
        .ddram_be,
        .ddram_busy,
        .ddram_dout,
        .ddram_dout_ready,
        .epoch_quiescent,
        .debug_arbiter_state,
        .protocol_error
    );

    logic [31:0] descriptor [0:15];
    integer response_beats = 0;
    integer response_index = 0;
    integer response_kind = 0;
    integer descriptor_commands = 0;
    integer client_commands = 0;
    integer cpu_accepts = 0;
    integer video_accepts = 0;
    integer sound_accepts = 0;
    integer cpu_responses = 0;
    integer video_responses = 0;
    integer sound_responses = 0;
    integer acceptance_mask = 0;
    integer preboot_descriptor_request_cycles = 0;
    integer preboot_video_physical_requests = 0;
    integer preboot_video_accepts = 0;

    // One-cycle-latency DDR model. Descriptor bursts use the known-good
    // production descriptor; client reads return address-tagged values.
    always @(posedge clk) begin
        if (reset) begin
            model_ready <= 1'b0;
            response_beats <= 0;
            response_index <= 0;
            response_kind <= 0;
        end else begin
            model_ready <= 1'b0;
            if (response_beats > 0) begin
                case (response_kind)
                    1: model_dout <= {
                        descriptor[response_index * 2 + 1],
                        descriptor[response_index * 2]
                    };
                    2: model_dout <= {
                        descriptor[3], descriptor[2]
                    };
                    3: model_dout <= 64'hc0c0c0c0c0c0c0c0;
                    4: model_dout <= 64'hb0b0b0b0b0b0b0b0;
                    5: model_dout <= 64'ha0a0a0a0a0a0a0a0;
                    default: model_dout <= 64'd0;
                endcase
                model_ready <= 1'b1;
                response_beats <= response_beats - 1;
                response_index <= response_index + 1;
            end else if (ddram_rd && !ddram_busy &&
                         !inject_ready) begin
                response_index <= 0;
                case (ddram_addr)
                    DESCRIPTOR_BASE: begin
                        response_kind <= 1;
                        response_beats <= 8;
                        descriptor_commands <=
                            descriptor_commands + 1;
                    end
                    DESCRIPTOR_BASE + 1'b1: begin
                        response_kind <= 2;
                        response_beats <= 1;
                        descriptor_commands <=
                            descriptor_commands + 1;
                    end
                    CPU_ADDRESS: begin
                        response_kind <= 3;
                        response_beats <= 1;
                        client_commands <= client_commands + 1;
                        acceptance_mask <= acceptance_mask | 1;
                    end
                    VIDEO_ADDRESS: begin
                        response_kind <= 4;
                        response_beats <= 1;
                        client_commands <= client_commands + 1;
                        acceptance_mask <= acceptance_mask | 2;
                    end
                    SOUND_ADDRESS: begin
                        response_kind <= 5;
                        response_beats <= 1;
                        client_commands <= client_commands + 1;
                        acceptance_mask <= acceptance_mask | 4;
                    end
                    default:
                        $fatal(1, "unexpected physical read address %h",
                            ddram_addr);
                endcase
            end
        end
    end

    always @(posedge clk) begin
        if (!reset) begin
            if ((^{video_busy, sound_busy, ddram_we,
                   ddram_din, ddram_be}) === 1'bx)
                $fatal(1, "active sound DDR control exposed X state");
            if (cpu_command_accepted)
                cpu_accepts <= cpu_accepts + 1;
            if (video_command_accepted)
                video_accepts <= video_accepts + 1;
            if (sound_command_accepted)
                sound_accepts <= sound_accepts + 1;
            if (!boot_valid) begin
                if (ddram_rd && ddram_addr == DESCRIPTOR_BASE)
                    preboot_descriptor_request_cycles <=
                        preboot_descriptor_request_cycles + 1;
                if ((ddram_rd || ddram_we) &&
                    ddram_addr == VIDEO_ADDRESS)
                    preboot_video_physical_requests <=
                        preboot_video_physical_requests + 1;
                if (video_command_accepted)
                    preboot_video_accepts <= preboot_video_accepts + 1;
                if ((ddram_rd || ddram_we) &&
                    ddram_addr != DESCRIPTOR_BASE &&
                    ddram_addr != DESCRIPTOR_BASE + 1'b1)
                    $fatal(1,
                        "non-descriptor physical request escaped before boot addr=%h rd=%0d we=%0d",
                        ddram_addr, ddram_rd, ddram_we);
                if (video_command_accepted)
                    $fatal(1,
                        "video command was accepted before descriptor boot");
            end
            if (cpu_dout_ready) begin
                cpu_responses <= cpu_responses + 1;
                if (cpu_dout !== 64'hc0c0c0c0c0c0c0c0)
                    $fatal(1, "CPU received another client's data");
            end
            if (video_dout_ready) begin
                video_responses <= video_responses + 1;
                if (video_dout !== 64'hb0b0b0b0b0b0b0b0)
                    $fatal(1, "video received another client's data");
            end
            if (sound_dout_ready) begin
                sound_responses <= sound_responses + 1;
                if (sound_dout !== 64'ha0a0a0a0a0a0a0a0)
                    $fatal(1, "sound received another client's data");
            end
            if (epoch_quiescent &&
                dut.sound_path_arbiter.grant_owner == 2'd3)
                $fatal(1, "disabled credit client received a grant");
            if (dut.active_credit_command_accepted ||
                dut.active_credit_dout_ready ||
                !dut.active_credit_busy)
                $fatal(1, "disabled credit client became active");
        end
    end

    initial begin : timeout_guard
        repeat (2000) @(posedge clk);
        $fatal(1,
            "timeout boot=%0d desc=%0d clients=%0d mask=%0h debug=%h",
            boot_valid, descriptor_commands, client_commands,
            acceptance_mask, debug_arbiter_state);
    end

    logic [28:0] held_addr;
    logic [7:0] held_burst;
    integer quiet_edge;
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

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        enable = 1'b1;
        cpu_rd = 1'b1;
        // Keep a real video request asserted throughout descriptor boot.  The
        // active sound path must suppress it until the CRC-checked descriptor
        // and generation recheck have both completed.
        video_rd = 1'b1;
        // MiSTer's idle Avalon waitrequest may remain high until RD/WE is
        // presented.  Response-free quarantine must therefore not wait for
        // raw ddram_busy to fall.
        ddram_busy = 1'b1;
        inject_ready = 1'b1;

        // A stale pre-reset response restarts the quiet interval and cannot
        // be routed to descriptor, CPU, video, or sound.
        @(posedge clk);
        #1;
        if (epoch_quiescent || cpu_dout_ready ||
            video_dout_ready || sound_dout_ready || protocol_error)
            $fatal(1, "stale response escaped reset quarantine");
        @(negedge clk);
        inject_ready = 1'b0;
        for (quiet_edge = 0; quiet_edge < 2;
             quiet_edge = quiet_edge + 1) begin
            @(posedge clk);
            #1;
            if (epoch_quiescent)
                $fatal(1, "quarantine ended before three quiet edges");
        end
        @(posedge clk);
        #1;
        if (!epoch_quiescent)
            $fatal(1, "quarantine did not end after three quiet edges");
        if (!ddram_busy)
            $fatal(1, "raw DDR busy was not held through quarantine");
        if (!cpu_busy || cpu_command_accepted)
            $fatal(1, "CPU acquired DDR before descriptor acceptance");

        // The descriptor reader owns client zero before boot.  Once
        // quarantine opens, its physical request must be presented and held
        // stable even though raw waitrequest is still high.
        wait (ddram_rd);
        #1;
        if (ddram_addr != DESCRIPTOR_BASE || ddram_burstcnt != 8'd8 ||
            ddram_we)
            $fatal(1,
                "first post-quarantine request was not descriptor burst");
        held_addr = ddram_addr;
        held_burst = ddram_burstcnt;
        repeat (4) begin
            @(posedge clk);
            #1;
            if (!ddram_busy || !ddram_rd ||
                ddram_addr != held_addr ||
                ddram_burstcnt != held_burst)
                $fatal(1,
                    "descriptor request was not held under raw DDR busy");
            if (descriptor_commands != 0 || video_command_accepted ||
                cpu_command_accepted || sound_command_accepted)
                $fatal(1,
                    "pre-boot command accepted while raw DDR busy");
        end
        @(negedge clk);
        cpu_rd = 1'b0;
        ddram_busy = 1'b0;

        wait (boot_valid);
        #1;
        if (boot_error || boot_generation != 1 ||
            arm9_dtcm_irq_vector != 32'h01ffd5ec ||
            arm9_trace_trigger != 32'h02064eb4 ||
            arm9_entry != 32'h02004800 ||
            arm7_entry != 32'h02380000 ||
            arm9_current_sp != 32'h03002f7c ||
            arm9_irq_sp != 32'h03003f80 ||
            arm9_saved_sp != 32'h03003fc0 ||
            arm7_current_sp != 32'h0380fd80 ||
            arm7_irq_sp != 32'h0380ff80 ||
            arm7_saved_sp != 32'h0380ffc0 ||
            initial_cpsr != 32'h000000d3 ||
            descriptor_commands != 2)
            $fatal(1, "sound path lost atomic descriptor ownership");
        if (preboot_descriptor_request_cycles < 4)
            $fatal(1,
                "descriptor request was not observed held before acceptance");
        if (preboot_video_physical_requests != 0 ||
            preboot_video_accepts != 0 || video_accepts != 0)
            $fatal(1,
                "video escaped descriptor-first gate physical=%0d preboot_accept=%0d total_accept=%0d",
                preboot_video_physical_requests,
                preboot_video_accepts, video_accepts);
        if (!sound_mode_active || sound_mode_change_ignored)
            $fatal(1, "reset-latched sound mode was not retained");

        // Present all three clients together. Hold physical waitrequest high
        // after one client queues to prove its payload remains stable.
        @(negedge clk);
        cpu_rd = 1'b1;
        sound_rd = 1'b1;
        ddram_busy = 1'b1;
        wait (ddram_rd);
        held_addr = ddram_addr;
        held_burst = ddram_burstcnt;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!ddram_rd || ddram_addr != held_addr ||
                ddram_burstcnt != held_burst)
                $fatal(1, "queued client payload changed under stall");
        end
        @(negedge clk);
        ddram_busy = 1'b0;

        fork
            begin
                wait (cpu_command_accepted);
                @(negedge clk);
                cpu_rd = 1'b0;
            end
            begin
                wait (video_command_accepted);
                @(negedge clk);
                video_rd = 1'b0;
            end
            begin
                wait (sound_command_accepted);
                @(negedge clk);
                sound_rd = 1'b0;
            end
        join

        wait (cpu_responses == 1 &&
              video_responses == 1 &&
              sound_responses == 1);
        #1;
        if (cpu_accepts != 1 || video_accepts != 1 ||
            sound_accepts != 1 || client_commands != 3 ||
            acceptance_mask != 7)
            $fatal(1,
                "CPU/video/sound fairness failed accepts=%0d/%0d/%0d commands=%0d mask=%0h",
                cpu_accepts, video_accepts, sound_accepts,
                client_commands, acceptance_mask);

        // Start a new epoch with the descriptor disabled. Another stale beat
        // is discarded during quarantine, but the same ownerless beat after
        // quiescence must fail the epoch closed.
        @(negedge clk);
        enable = 1'b0;
        reset = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        inject_ready = 1'b1;
        @(posedge clk);
        #1;
        if (epoch_quiescent || protocol_error || cpu_dout_ready ||
            video_dout_ready || sound_dout_ready)
            $fatal(1, "second-epoch stale response escaped quarantine");
        @(negedge clk);
        inject_ready = 1'b0;
        wait (epoch_quiescent);
        @(negedge clk);
        inject_ready = 1'b1;
        @(posedge clk);
        #1;
        if (!protocol_error || epoch_quiescent ||
            cpu_dout_ready || video_dout_ready || sound_dout_ready)
            $fatal(1,
                "ownerless response did not fail epoch readiness closed");
        @(negedge clk);
        inject_ready = 1'b0;

        $display(
            "PASS: response-only quarantine, held descriptor-first boot, pre-boot video blocking, post-boot CPU/video/sound progress, disabled credit, and fail-closed epoch");
        $finish;
    end
endmodule
