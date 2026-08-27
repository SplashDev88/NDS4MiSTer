`timescale 1ns/1ps
`default_nettype none

module tb_nds_standalone_boot_ddr_credit_active;
    localparam logic [28:0] DESCRIPTOR_BASE = 29'h05800200;
    localparam logic [28:0] CPU_ADDRESS = 29'h01000010;
    localparam logic [28:0] VIDEO_ADDRESS = 29'h02000020;
    localparam logic [28:0] SOUND_ADDRESS = 29'h03000030;
    localparam logic [28:0] CREDIT_ADDRESS = 29'h04000040;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic enable = 1'b1;
    logic sound_enable = 1'b0;
    always #5 clk = ~clk;

    logic sound_mode_active;
    logic sound_mode_change_ignored;
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

    logic credit_rd = 1'b0;
    logic credit_we = 1'b0;
    logic [7:0] credit_burstcnt = 8'd1;
    logic [28:0] credit_addr = CREDIT_ADDRESS;
    logic [63:0] credit_din = 64'hddddeeeeffff0000;
    logic [7:0] credit_be = 8'hff;
    logic credit_busy;
    logic [63:0] credit_dout;
    logic credit_dout_ready;
    logic credit_command_accepted;

    logic ddram_rd;
    logic ddram_we;
    logic [7:0] ddram_burstcnt;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din;
    logic [7:0] ddram_be;
    logic ddram_busy = 1'b0;
    logic [63:0] ddram_dout = 64'd0;
    logic ddram_dout_ready = 1'b0;
    logic epoch_quiescent;
    logic [31:0] debug_arbiter_state;
    logic protocol_error;

    nds_standalone_boot_ddr_sound #(
        .SOUND_RESET_QUIET_CYCLES(3),
        .SOUND_STICKY_GRANT_LIMIT(4),
        .ENABLE_CREDIT_CLIENT(1'b1)
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
        .credit_rd,
        .credit_we,
        .credit_burstcnt,
        .credit_addr,
        .credit_din,
        .credit_be,
        .credit_busy,
        .credit_dout,
        .credit_dout_ready,
        .credit_command_accepted,
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
    integer response_kind = 0;
    integer response_beats = 0;
    integer response_index = 0;
    integer response_delay = 0;
    integer descriptor_commands = 0;
    integer client_commands = 0;
    integer cpu_accepts = 0;
    integer video_accepts = 0;
    integer sound_accepts = 0;
    integer credit_accepts = 0;
    integer cpu_responses = 0;
    integer video_responses = 0;
    integer sound_responses = 0;
    integer credit_responses = 0;
    integer cycle_count = 0;
    integer cpu_accept_cycle = 0;
    integer video_accept_cycle = 0;
    integer sound_accept_cycle = 0;
    integer credit_accept_cycle = 0;
    logic expect_sound_disabled = 1'b1;

    // Delayed physical DDR model. Every client receives a distinct payload,
    // making stale or mis-owned response routing immediately observable.
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        ddram_dout_ready <= 1'b0;
        if (reset) begin
            response_kind <= 0;
            response_beats <= 0;
            response_index <= 0;
            response_delay <= 0;
        end else begin
            if (response_beats != 0) begin
                if (response_delay != 0) begin
                    response_delay <= response_delay - 1;
                end else begin
                    case (response_kind)
                        1: ddram_dout <= {
                            descriptor[response_index * 2 + 1],
                            descriptor[response_index * 2]};
                        2: ddram_dout <= {descriptor[3], descriptor[2]};
                        3: ddram_dout <= 64'hc0c0c0c0c0c0c0c0;
                        4: ddram_dout <= 64'hb0b0b0b0b0b0b0b0;
                        5: ddram_dout <= 64'ha0a0a0a0a0a0a0a0;
                        6: ddram_dout <= 64'hd0d0d0d0d0d0d0d0;
                        default: $fatal(1, "unknown delayed response owner");
                    endcase
                    ddram_dout_ready <= 1'b1;
                    response_index <= response_index + 1;
                    response_beats <= response_beats - 1;
                    response_delay <= 1;
                end
            end

            if (ddram_rd && !ddram_busy) begin
                if (response_beats != 0)
                    $fatal(1, "overlapping physical read ownership");
                response_index <= 0;
                response_delay <= 3;
                case (ddram_addr)
                    DESCRIPTOR_BASE: begin
                        if (ddram_burstcnt != 8)
                            $fatal(1, "descriptor burst length changed");
                        response_kind <= 1;
                        response_beats <= 8;
                        descriptor_commands <= descriptor_commands + 1;
                    end
                    DESCRIPTOR_BASE + 1: begin
                        response_kind <= 2;
                        response_beats <= 1;
                        descriptor_commands <= descriptor_commands + 1;
                    end
                    CPU_ADDRESS: begin
                        response_kind <= 3;
                        response_beats <= 1;
                        client_commands <= client_commands + 1;
                    end
                    VIDEO_ADDRESS: begin
                        response_kind <= 4;
                        response_beats <= 1;
                        client_commands <= client_commands + 1;
                    end
                    SOUND_ADDRESS: begin
                        response_kind <= 5;
                        response_beats <= 1;
                        client_commands <= client_commands + 1;
                    end
                    CREDIT_ADDRESS: begin
                        response_kind <= 6;
                        response_beats <= 1;
                        client_commands <= client_commands + 1;
                    end
                    default:
                        $fatal(1, "unexpected physical read %h", ddram_addr);
                endcase
            end
        end
    end

    always @(posedge clk) begin
        integer ready_count;
        if (!reset) begin
            if (dut.sound_path_arbiter.CLIENT_ENABLE_MASK !== 4'b1111)
                $fatal(1, "enabled credit build did not use 1111 mask");
            if ((^{cpu_busy, video_busy, sound_busy, credit_busy,
                   ddram_rd, ddram_we, ddram_addr}) === 1'bx)
                $fatal(1, "enabled credit composition exposed X state");

            if (cpu_command_accepted) begin
                cpu_accepts <= cpu_accepts + 1;
                cpu_accept_cycle <= cycle_count;
            end
            if (video_command_accepted) begin
                video_accepts <= video_accepts + 1;
                video_accept_cycle <= cycle_count;
            end
            if (sound_command_accepted) begin
                sound_accepts <= sound_accepts + 1;
                sound_accept_cycle <= cycle_count;
            end
            if (credit_command_accepted) begin
                credit_accepts <= credit_accepts + 1;
                credit_accept_cycle <= cycle_count;
            end

            ready_count = cpu_dout_ready + video_dout_ready +
                          sound_dout_ready + credit_dout_ready;
            if (ready_count > 1)
                $fatal(1, "one DDR response reached multiple clients");
            if (cpu_dout_ready) begin
                cpu_responses <= cpu_responses + 1;
                if (cpu_dout != 64'hc0c0c0c0c0c0c0c0 ||
                    cycle_count - cpu_accept_cycle < 3)
                    $fatal(1, "CPU response ownership/delay mismatch");
            end
            if (video_dout_ready) begin
                video_responses <= video_responses + 1;
                if (video_dout != 64'hb0b0b0b0b0b0b0b0 ||
                    cycle_count - video_accept_cycle < 3)
                    $fatal(1, "video response ownership/delay mismatch");
            end
            if (sound_dout_ready) begin
                sound_responses <= sound_responses + 1;
                if (sound_dout != 64'ha0a0a0a0a0a0a0a0 ||
                    cycle_count - sound_accept_cycle < 3)
                    $fatal(1, "sound response ownership/delay mismatch");
            end
            if (credit_dout_ready) begin
                credit_responses <= credit_responses + 1;
                if (credit_dout != 64'hd0d0d0d0d0d0d0d0 ||
                    cycle_count - credit_accept_cycle < 3)
                    $fatal(1, "credit response ownership/delay mismatch");
            end

            if (expect_sound_disabled &&
                (!sound_busy || sound_command_accepted ||
                 sound_dout_ready || sound_dout != 0))
                $fatal(1, "sound coupled into credit-only active path");
            if (!boot_valid &&
                (cpu_command_accepted || video_command_accepted ||
                 sound_command_accepted))
                $fatal(1, "functional client escaped descriptor-first gate");
        end
    end

    task automatic wait_for_boot;
        integer timeout;
        begin
            timeout = 0;
            while (!boot_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 5000)
                    $fatal(1, "credit active-path boot timeout");
            end
            #1;
            if (boot_error || !epoch_quiescent ||
                boot_generation != 1 || protocol_error)
                $fatal(1, "credit active-path descriptor boot failed");
        end
    endtask

    task automatic run_preboot_credit;
        integer timeout;
        begin
            // Reproduce the hardware startup contract: the HPS withholds the
            // boot descriptor until the ETW credit transport acknowledges its
            // own DDR descriptor. Only that credit client may progress here.
            @(negedge clk);
            cpu_rd = 1'b1;
            video_rd = 1'b1;
            sound_rd = 1'b1;
            credit_rd = 1'b1;

            timeout = 0;
            while (!credit_command_accepted) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 500)
                    $fatal(1, "preboot credit command was deadlocked");
            end
            @(negedge clk);
            credit_rd = 1'b0;

            timeout = 0;
            while (credit_responses != 1) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 500)
                    $fatal(1, "preboot credit response was deadlocked");
            end
            if (boot_valid || cpu_accepts != 0 || video_accepts != 0 ||
                sound_accepts != 0 || credit_accepts != 1)
                $fatal(1, "preboot credit isolation contract failed");

            @(negedge clk);
            cpu_rd = 1'b0;
            video_rd = 1'b0;
            sound_rd = 1'b0;
        end
    endtask

    task automatic reset_epoch(input logic next_sound_enable);
        begin
            @(negedge clk);
            cpu_rd = 1'b0;
            video_rd = 1'b0;
            sound_rd = 1'b0;
            credit_rd = 1'b0;
            ddram_busy = 1'b0;
            sound_enable = next_sound_enable;
            reset = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
            wait_for_boot();
        end
    endtask

    task automatic run_clients(input logic include_sound);
        integer start_cpu_responses;
        integer start_video_responses;
        integer start_sound_responses;
        integer start_credit_responses;
        integer timeout;
        logic [28:0] held_address;
        begin
            start_cpu_responses = cpu_responses;
            start_video_responses = video_responses;
            start_sound_responses = sound_responses;
            start_credit_responses = credit_responses;
            @(negedge clk);
            cpu_rd = 1'b1;
            video_rd = 1'b1;
            sound_rd = 1'b1;
            credit_rd = 1'b1;
            ddram_busy = 1'b1;

            // Queue one granted command, then hold the physical port blocked.
            // All other clients remain backpressured behind its delayed reply.
            wait (ddram_rd);
            held_address = ddram_addr;
            repeat (4) begin
                @(posedge clk);
                #1;
                if (!ddram_rd || ddram_addr != held_address ||
                    !ddram_busy)
                    $fatal(1, "queued four-client payload changed under stall");
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
                    wait (credit_command_accepted);
                    @(negedge clk);
                    credit_rd = 1'b0;
                end
                begin
                    if (include_sound) begin
                        wait (sound_command_accepted);
                        @(negedge clk);
                        sound_rd = 1'b0;
                    end
                end
            join

            timeout = 0;
            while (cpu_responses != start_cpu_responses + 1 ||
                   video_responses != start_video_responses + 1 ||
                   credit_responses != start_credit_responses + 1 ||
                   (include_sound &&
                    sound_responses != start_sound_responses + 1)) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 500)
                    $fatal(1, "four-client response progress timeout");
            end
            if (!include_sound) begin
                repeat (12) @(posedge clk);
                if (sound_accepts != 0 ||
                    sound_responses != start_sound_responses)
                    $fatal(1, "sound request escaped credit-only mode");
                @(negedge clk);
                sound_rd = 1'b0;
            end
        end
    endtask

    initial begin
        descriptor[0] = 32'h4253444e;
        descriptor[1] = 32'd3;
        descriptor[2] = 32'd0;
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

        // Credit selects the active path while sound remains reset-latched
        // off. Runtime sound changes are recorded but cannot change ownership.
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        run_preboot_credit();
        descriptor[2] = 32'd1;
        wait_for_boot();
        if (sound_mode_active || sound_mode_change_ignored ||
            !dut.legacy_reset || dut.active_reset)
            $fatal(1, "credit did not select sound-independent active path");
        @(negedge clk);
        sound_enable = 1'b1;
        @(posedge clk);
        #1;
        if (sound_mode_active || !sound_mode_change_ignored)
            $fatal(1, "runtime sound toggle changed reset-latched mode");
        run_clients(1'b0);
        if (cpu_accepts != 1 || video_accepts != 1 ||
            credit_accepts != 2 || sound_accepts != 0)
            $fatal(1, "credit-only client acceptance mismatch");

        // Reset is the only sound-mode boundary. Credit remains the same
        // fourth client while sound joins independently in the next epoch.
        expect_sound_disabled = 1'b0;
        reset_epoch(1'b1);
        if (!sound_mode_active || sound_mode_change_ignored)
            $fatal(1, "reset did not latch sound on");
        @(negedge clk);
        sound_enable = 1'b0;
        @(posedge clk);
        #1;
        if (!sound_mode_active || !sound_mode_change_ignored)
            $fatal(1, "runtime sound-off toggle changed active ownership");
        run_clients(1'b1);
        if (cpu_accepts != 2 || video_accepts != 2 ||
            credit_accepts != 3 || sound_accepts != 1 ||
            cpu_responses != 2 || video_responses != 2 ||
            credit_responses != 3 || sound_responses != 1 ||
            client_commands != 8 || protocol_error)
            $fatal(1, "enabled four-client ownership/count mismatch");

        $display("PASS: preboot credit bootstrap and postboot CPU/video/sound/credit ownership preserve 1111 arbitration");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "enabled credit DDR composition timeout debug=%h",
               debug_arbiter_state);
    end
endmodule

`default_nettype wire
