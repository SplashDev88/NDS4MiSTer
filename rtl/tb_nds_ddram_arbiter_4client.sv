module tb_nds_ddram_arbiter_4client;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic cpu_rd = 0, cpu_we = 0;
    logic video_rd = 0, video_we = 0;
    logic sound_rd = 0, sound_we = 0;
    logic credit_rd = 0, credit_we = 0;
    logic [7:0] cpu_burstcnt = 1, video_burstcnt = 1;
    logic [7:0] sound_burstcnt = 1, credit_burstcnt = 1;
    logic [28:0] cpu_addr = 29'h01000001;
    logic [28:0] video_addr = 29'h02000002;
    logic [28:0] sound_addr = 29'h03000003;
    logic [28:0] credit_addr = 29'h04000004;
    logic [63:0] cpu_din = 64'h1111222233334444;
    logic [63:0] video_din = 64'h5555666677778888;
    logic [63:0] sound_din = 64'h9999aaaabbbbcccc;
    logic [63:0] credit_din = 64'hddddeeeeffff0000;
    logic [7:0] cpu_be = 8'h81, video_be = 8'h42;
    logic [7:0] sound_be = 8'h24, credit_be = 8'h18;

    logic cpu_busy, video_busy, sound_busy, credit_busy;
    logic [63:0] cpu_dout, video_dout, sound_dout, credit_dout;
    logic cpu_dout_ready, video_dout_ready;
    logic sound_dout_ready, credit_dout_ready;
    logic cpu_command_accepted, video_command_accepted;
    logic sound_command_accepted, credit_command_accepted;

    logic ddram_rd, ddram_we;
    logic [7:0] ddram_burstcnt, ddram_be;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din;
    logic ddram_busy = 1;
    logic [63:0] ddram_dout = 0;
    logic ddram_dout_ready = 0;
    logic epoch_quiescent;
    logic [31:0] debug_state;
    logic protocol_error;

    integer cpu_accepts = 0, video_accepts = 0;
    integer sound_accepts = 0, credit_accepts = 0;
    integer cpu_beats = 0, video_beats = 0;
    integer sound_beats = 0, credit_beats = 0;

    nds_ddram_arbiter_4client #(
        .RESET_QUIET_CYCLES(4)
    ) dut (
        .clk, .reset,
        .cpu_rd, .cpu_we, .cpu_burstcnt, .cpu_addr, .cpu_din, .cpu_be,
        .cpu_busy, .cpu_dout, .cpu_dout_ready, .cpu_command_accepted,
        .video_rd, .video_we, .video_burstcnt, .video_addr,
        .video_din, .video_be, .video_busy, .video_dout,
        .video_dout_ready, .video_command_accepted,
        .sound_rd, .sound_we, .sound_burstcnt, .sound_addr,
        .sound_din, .sound_be, .sound_busy, .sound_dout,
        .sound_dout_ready, .sound_command_accepted,
        .credit_rd, .credit_we, .credit_burstcnt, .credit_addr,
        .credit_din, .credit_be, .credit_busy, .credit_dout,
        .credit_dout_ready, .credit_command_accepted,
        .ddram_rd, .ddram_we, .ddram_burstcnt, .ddram_addr,
        .ddram_din, .ddram_be, .ddram_busy, .ddram_dout,
        .ddram_dout_ready, .epoch_quiescent, .debug_state,
        .protocol_error
    );

    always @(posedge clk) begin
        if (!reset) begin
            if ((cpu_command_accepted + video_command_accepted +
                 sound_command_accepted + credit_command_accepted) > 1)
                $fatal(1, "physical command accepted by multiple clients");
            if ((cpu_dout_ready + video_dout_ready +
                 sound_dout_ready + credit_dout_ready) > 1)
                $fatal(1, "read beat routed to multiple clients");
            if (cpu_command_accepted) cpu_accepts <= cpu_accepts + 1;
            if (video_command_accepted) video_accepts <= video_accepts + 1;
            if (sound_command_accepted) sound_accepts <= sound_accepts + 1;
            if (credit_command_accepted)
                credit_accepts <= credit_accepts + 1;
            if (cpu_dout_ready) cpu_beats <= cpu_beats + 1;
            if (video_dout_ready) video_beats <= video_beats + 1;
            if (sound_dout_ready) sound_beats <= sound_beats + 1;
            if (credit_dout_ready) credit_beats <= credit_beats + 1;
        end
    end

    task automatic require_no_routed_response;
        begin
            #1;
            if (cpu_dout_ready || video_dout_ready ||
                sound_dout_ready || credit_dout_ready)
                $fatal(1, "ownerless/reset response leaked to a client");
        end
    endtask

    initial begin
        repeat (800) @(posedge clk);
        $fatal(1,
            "timeout owner=%0d dwell=%0d command=%0d read=%0d beats=%0d quarantine=%0d",
            dut.grant_owner, dut.grant_dwell, dut.command_pending,
            dut.read_pending, dut.beats_remaining, dut.quarantine_active);
    end

    initial begin
        // Reset begins while the physical port is not quiet.  Neither this
        // response nor those immediately after reset may acquire a new owner.
        ddram_dout_ready = 1;
        repeat (3) begin
            @(posedge clk);
            require_no_routed_response();
        end
        @(negedge clk);
        reset = 0;
        repeat (2) begin
            @(posedge clk);
            require_no_routed_response();
            if (!dut.quarantine_active)
                $fatal(1, "quarantine ended while DDR was active");
        end
        // Raw waitrequest is legal idle-high and must not participate in the
        // response quarantine.  First accumulate only part of the required
        // quiet interval, then inject one stale response.  That response must
        // be discarded and restart the complete four-cycle silence window.
        @(negedge clk);
        ddram_dout_ready = 0;
        ddram_busy = 1;
        repeat (2) begin
            @(posedge clk);
            #1;
            require_no_routed_response();
            if (!dut.quarantine_active)
                $fatal(1,
                    "quarantine ignored the configured quiet interval");
        end
        if (dut.quiet_count !== 2)
            $fatal(1, "partial quiet interval count mismatch");

        @(negedge clk);
        ddram_dout = 64'h5154414c45524553;
        ddram_dout_ready = 1;
        @(posedge clk);
        #1;
        require_no_routed_response();
        if (!dut.quarantine_active || dut.quiet_count !== 0)
            $fatal(1,
                "stale response did not restart quarantine silence count");

        @(negedge clk);
        ddram_dout_ready = 0;
        repeat (3) begin
            @(posedge clk);
            #1;
            require_no_routed_response();
            if (!dut.quarantine_active)
                $fatal(1,
                    "quarantine exited before four response-free cycles");
            if (!ddram_busy)
                $fatal(1, "testbench dropped idle-high waitrequest");
        end
        @(posedge clk);
        #1;
        require_no_routed_response();
        if (dut.quarantine_active || !epoch_quiescent)
            $fatal(1,
                "idle-high waitrequest prevented quarantine completion");
        if (!ddram_busy)
            $fatal(1, "testbench dropped idle-high waitrequest");

        @(negedge clk);
        if (cpu_busy || !video_busy || !sound_busy || !credit_busy)
            $fatal(1, "reset did not expose the initial CPU grant");

        // Idle-high waitrequest: the CPU command must enter the local queue
        // and become visible on the physical port even though waitrequest was
        // already high.  Both controls are high to prove read-over-write
        // priority.  Burst response ownership must remain with CPU.
        ddram_busy = 1;
        cpu_burstcnt = 3;
        cpu_rd = 1;
        cpu_we = 1;
        @(posedge clk);
        @(negedge clk);
        cpu_rd = 0;
        cpu_we = 0;
        cpu_addr = 29'h1fffffff;
        cpu_din = 64'hbad0bad0bad0bad0;
        cpu_be = 8'h00;
        if (!ddram_rd || ddram_we ||
            ddram_addr !== 29'h01000001 || ddram_burstcnt !== 3 ||
            ddram_din !== 64'h1111222233334444 || ddram_be !== 8'h81)
            $fatal(1, "CPU command was not latched with read priority");
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!ddram_rd || ddram_we ||
                ddram_addr !== 29'h01000001 ||
                ddram_burstcnt !== 3 ||
                ddram_din !== 64'h1111222233334444 ||
                ddram_be !== 8'h81 || cpu_command_accepted)
                $fatal(1, "queued CPU command changed during waitrequest");
        end

        // The first beat lands on the physical acceptance edge.
        @(negedge clk);
        ddram_busy = 0;
        ddram_dout = 64'hc000000000000001;
        ddram_dout_ready = 1;
        #1;
        if (!cpu_command_accepted || video_command_accepted ||
            sound_command_accepted || credit_command_accepted)
            $fatal(1, "CPU physical acceptance ownership mismatch");
        if (!cpu_dout_ready || video_dout_ready ||
            sound_dout_ready || credit_dout_ready ||
            cpu_dout !== 64'hc000000000000001)
            $fatal(1, "CPU same-edge first beat was not routed");
        @(posedge clk);
        @(negedge clk);
        ddram_dout_ready = 0;
        ddram_busy = 1;

        // Two delayed trailing beats retain the original owner.
        repeat (2) @(posedge clk);
        @(negedge clk);
        ddram_dout = 64'hc000000000000002;
        ddram_dout_ready = 1;
        #1;
        if (!cpu_dout_ready || video_dout_ready ||
            sound_dout_ready || credit_dout_ready)
            $fatal(1, "CPU second beat ownership mismatch");
        @(posedge clk);
        @(negedge clk);
        ddram_dout_ready = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        ddram_dout = 64'hc000000000000003;
        ddram_dout_ready = 1;
        #1;
        if (!cpu_dout_ready || video_dout_ready ||
            sound_dout_ready || credit_dout_ready)
            $fatal(1, "CPU final beat ownership mismatch");
        @(posedge clk);
        @(negedge clk);
        ddram_dout_ready = 0;

        if (cpu_accepts != 1 || cpu_beats != 3 ||
            video_beats != 0 || sound_beats != 0 || credit_beats != 0)
            $fatal(1, "CPU command/beat counts are wrong");

        // A held video write stays a single transaction: the requester keeps
        // WE high through physical acceptance and lowers it afterward.
        wait (!video_busy);
        video_we = 1;
        @(posedge clk);
        @(negedge clk);
        if (!ddram_we || ddram_rd ||
            ddram_addr !== video_addr || ddram_din !== video_din ||
            ddram_be !== video_be)
            $fatal(1, "video write payload mismatch");
        repeat (2) begin
            @(posedge clk);
            #1;
            if (!ddram_we || video_command_accepted)
                $fatal(1, "video write did not remain queued");
        end
        @(negedge clk);
        ddram_busy = 0;
        #1;
        if (!video_command_accepted || cpu_command_accepted ||
            sound_command_accepted || credit_command_accepted)
            $fatal(1, "video physical acceptance mismatch");
        @(posedge clk);
        @(negedge clk);
        video_we = 0;
        ddram_busy = 1;

        // Sound exercises a one-beat, acceptance-edge response on client 2.
        wait (!sound_busy);
        sound_rd = 1;
        @(posedge clk);
        @(negedge clk);
        sound_rd = 0;
        if (!ddram_rd || ddram_addr !== sound_addr)
            $fatal(1, "sound read payload mismatch");
        ddram_busy = 0;
        ddram_dout = 64'h5000000000000001;
        ddram_dout_ready = 1;
        #1;
        if (!sound_command_accepted || !sound_dout_ready ||
            cpu_dout_ready || video_dout_ready || credit_dout_ready ||
            sound_dout !== 64'h5000000000000001)
            $fatal(1, "sound acceptance-edge response mismatch");
        @(posedge clk);
        @(negedge clk);
        ddram_dout_ready = 0;
        ddram_busy = 1;

        // A zero burst count is normalized to one at the physical interface.
        wait (!credit_busy);
        credit_burstcnt = 0;
        credit_we = 1;
        @(posedge clk);
        @(negedge clk);
        credit_we = 0;
        if (!ddram_we || ddram_burstcnt !== 1 ||
            ddram_addr !== credit_addr || ddram_din !== credit_din ||
            ddram_be !== credit_be)
            $fatal(1, "credit write or burst normalization mismatch");
        ddram_busy = 0;
        #1;
        if (!credit_command_accepted)
            $fatal(1, "credit write was not physically accepted");
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1;

        if (video_accepts != 1 || sound_accepts != 1 ||
            credit_accepts != 1 || sound_beats != 1)
            $fatal(1, "non-CPU command counts are wrong");

        // Reset with a read response outstanding.  The old owner's late beats
        // must be discarded throughout quarantine and must not become CPU
        // responses after the round-robin pointer restarts.
        wait (!cpu_busy);
        cpu_burstcnt = 2;
        cpu_rd = 1;
        @(posedge clk);
        @(negedge clk);
        cpu_rd = 0;
        ddram_busy = 0;
        @(posedge clk);
        @(negedge clk);
        if (!dut.read_pending)
            $fatal(1, "pre-reset read did not enter response state");
        reset = 1;
        ddram_dout = 64'hdeadbeefdeadbeef;
        ddram_dout_ready = 1;
        @(posedge clk);
        require_no_routed_response();
        @(negedge clk);
        reset = 0;
        ddram_busy = 1;
        repeat (2) begin
            @(posedge clk);
            require_no_routed_response();
        end
        @(negedge clk);
        ddram_dout_ready = 0;
        ddram_busy = 0;
        wait (!dut.quarantine_active);
        @(negedge clk);
        if (!epoch_quiescent)
            $fatal(1, "epoch did not become quiescent after reset quarantine");
        if (protocol_error)
            $fatal(1, "discarded reset response raised protocol_error");

        // Outside quarantine, an ownerless response is still never routed and
        // leaves sticky diagnostic evidence.
        ddram_dout_ready = 1;
        require_no_routed_response();
        @(posedge clk);
        @(negedge clk);
        ddram_dout_ready = 0;
        if (!protocol_error)
            $fatal(1, "ownerless response did not set protocol_error");
        if (epoch_quiescent)
            $fatal(1, "protocol error did not fail epoch closed");

        $display("PASS: four-client DDR arbiter exits reset quarantine with idle-high waitrequest, restarts silence on stale responses, and preserves stable commands/read ownership");
        $finish;
    end
endmodule
