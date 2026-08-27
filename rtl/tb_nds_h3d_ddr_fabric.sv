module tb_nds_h3d_ddr_fabric;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic legacy_read = 1'b0;
    logic legacy_write = 1'b0;
    logic [7:0] legacy_burst_count = 8'd1;
    logic [28:0] legacy_address = 29'h01000000;
    logic [63:0] legacy_write_data = 64'h1010101010101010;
    logic [7:0] legacy_byte_enable = 8'h81;
    logic legacy_busy;
    logic legacy_command_accepted;
    logic [63:0] legacy_read_data;
    logic legacy_read_data_ready;

    logic plane_read = 1'b0;
    logic plane_write = 1'b0;
    logic [7:0] plane_burst_count = 8'd1;
    logic [28:0] plane_address = 29'h02000000;
    logic [63:0] plane_write_data = 64'h2020202020202020;
    logic [7:0] plane_byte_enable = 8'h42;
    logic plane_busy;
    logic plane_command_accepted;
    logic [63:0] plane_read_data;
    logic plane_read_data_ready;

    logic event_read = 1'b0;
    logic event_write = 1'b0;
    logic [7:0] event_burst_count = 8'd1;
    logic [28:0] event_address = 29'h03000000;
    logic [63:0] event_write_data = 64'h3030303030303030;
    logic [7:0] event_byte_enable = 8'h24;
    logic event_busy;
    logic event_command_accepted;
    logic [63:0] event_read_data;
    logic event_read_data_ready;

    logic control_read = 1'b0;
    logic control_write = 1'b0;
    logic [7:0] control_burst_count = 8'd1;
    logic [28:0] control_address = 29'h04000000;
    logic [63:0] control_write_data = 64'h4040404040404040;
    logic [7:0] control_byte_enable = 8'h18;
    logic control_busy;
    logic control_command_accepted;
    logic [63:0] control_read_data;
    logic control_read_data_ready;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy = 1'b1;
    logic [63:0] ddram_read_data = 64'd0;
    logic ddram_read_data_ready = 1'b0;
    logic epoch_quiescent;
    logic protocol_error;
    logic [31:0] debug_state;

    integer accepted_order [0:31];
    integer accepted_count = 0;
    integer legacy_count = 0;
    integer plane_count = 0;
    integer event_count = 0;
    integer control_count = 0;
    integer plane_beats = 0;
    integer event_beats = 0;
    integer legacy_beats = 0;
    integer control_beats = 0;

    nds_h3d_ddr_fabric #(
        .RESET_QUIET_CYCLES(4),
        .STICKY_GRANT_LIMIT(3)
    ) dut (
        .clk,
        .reset,
        .legacy_read,
        .legacy_write,
        .legacy_burst_count,
        .legacy_address,
        .legacy_write_data,
        .legacy_byte_enable,
        .legacy_busy,
        .legacy_command_accepted,
        .legacy_read_data,
        .legacy_read_data_ready,
        .plane_read,
        .plane_write,
        .plane_burst_count,
        .plane_address,
        .plane_write_data,
        .plane_byte_enable,
        .plane_busy,
        .plane_command_accepted,
        .plane_read_data,
        .plane_read_data_ready,
        .event_read,
        .event_write,
        .event_burst_count,
        .event_address,
        .event_write_data,
        .event_byte_enable,
        .event_busy,
        .event_command_accepted,
        .event_read_data,
        .event_read_data_ready,
        .control_read,
        .control_write,
        .control_burst_count,
        .control_address,
        .control_write_data,
        .control_byte_enable,
        .control_busy,
        .control_command_accepted,
        .control_read_data,
        .control_read_data_ready,
        .ddram_read,
        .ddram_write,
        .ddram_burst_count,
        .ddram_address,
        .ddram_write_data,
        .ddram_byte_enable,
        .ddram_busy,
        .ddram_read_data,
        .ddram_read_data_ready,
        .epoch_quiescent,
        .protocol_error,
        .debug_state
    );

    task automatic require_no_routed_beat;
        begin
            #1;
            if (legacy_read_data_ready || plane_read_data_ready ||
                event_read_data_ready || control_read_data_ready)
                $fatal(1, "ownerless/reset response reached a client");
            if (legacy_read_data !== ddram_read_data ||
                plane_read_data !== ddram_read_data ||
                event_read_data !== ddram_read_data ||
                control_read_data !== ddram_read_data)
                $fatal(1, "fabric read-data fanout mapping mismatch");
        end
    endtask

    task automatic require_only_legacy_beat(
        input logic [63:0] expected
    );
        begin
            #1;
            if (!legacy_read_data_ready || plane_read_data_ready ||
                event_read_data_ready || control_read_data_ready ||
                legacy_read_data !== expected)
                $fatal(1, "legacy burst beat ownership/data mismatch");
            legacy_beats = legacy_beats + 1;
        end
    endtask

    task automatic require_only_event_beat(
        input logic [63:0] expected
    );
        begin
            #1;
            if (legacy_read_data_ready || plane_read_data_ready ||
                !event_read_data_ready || control_read_data_ready ||
                event_read_data !== expected)
                $fatal(1, "event burst beat ownership/data mismatch");
            event_beats = event_beats + 1;
        end
    endtask

    task automatic require_only_plane_beat(
        input logic [63:0] expected
    );
        begin
            #1;
            if (legacy_read_data_ready || !plane_read_data_ready ||
                event_read_data_ready || control_read_data_ready ||
                plane_read_data !== expected)
                $fatal(1, "plane read beat ownership/data mismatch");
            plane_beats = plane_beats + 1;
        end
    endtask

    task automatic require_only_control_beat(
        input logic [63:0] expected
    );
        begin
            #1;
            if (legacy_read_data_ready || plane_read_data_ready ||
                event_read_data_ready || !control_read_data_ready ||
                control_read_data !== expected)
                $fatal(1, "control read beat ownership/data mismatch");
            control_beats = control_beats + 1;
        end
    endtask

    task automatic wait_for_epoch;
        integer watchdog;
        begin
            watchdog = 0;
            while (!epoch_quiescent) begin
                @(posedge clk);
                #1;
                watchdog = watchdog + 1;
                if (watchdog > 32)
                    $fatal(1, "DDR reset quarantine did not finish");
            end
        end
    endtask

    // Structural safety checks remain active through every directed phase.
    always @(posedge clk) begin
        if (!reset) begin
            if ((legacy_command_accepted + plane_command_accepted +
                 event_command_accepted + control_command_accepted) > 1)
                $fatal(1, "one physical command accepted for many clients");
            if ((legacy_read_data_ready + plane_read_data_ready +
                 event_read_data_ready + control_read_data_ready) > 1)
                $fatal(1, "one physical response routed to many clients");
            if ((legacy_command_accepted || plane_command_accepted ||
                 event_command_accepted || control_command_accepted) &&
                (!(ddram_read || ddram_write) || ddram_busy))
                $fatal(1, "client acceptance was not physical acceptance");
        end
    end

    initial begin
        repeat (3000) @(posedge clk);
        $fatal(1,
            "timeout debug=%08x physical=%0d%0d busy=%0d epoch=%0d",
            debug_state, ddram_read, ddram_write, ddram_busy,
            epoch_quiescent);
    end

    initial begin : directed_test
        integer i;
        integer owner;
        integer legacy_remaining;
        integer plane_remaining;
        integer event_remaining;
        integer control_remaining;
        integer previous_owner;
        integer delayed_cycles;
        integer burst_write_index;
        logic saved_read;
        logic saved_write;
        logic [7:0] saved_burst;
        logic [28:0] saved_address;
        logic [63:0] saved_data;
        logic [7:0] saved_be;

        // A response active across reset/deassertion must restart the complete
        // quiet interval and must never be given the reset/default owner.
        ddram_busy = 1'b1;
        ddram_read_data = 64'hdeaddeaddeaddead;
        ddram_read_data_ready = 1'b1;
        repeat (3) begin
            @(posedge clk);
            require_no_routed_beat();
        end
        @(negedge clk);
        reset = 1'b0;
        repeat (2) begin
            @(posedge clk);
            require_no_routed_beat();
            if (epoch_quiescent)
                $fatal(1, "epoch opened while stale DDR response was active");
        end
        @(negedge clk);
        ddram_read_data_ready = 1'b0;
        wait_for_epoch();
        if (protocol_error)
            $fatal(1, "reset quarantine raised protocol_error");
        if (legacy_busy || !plane_busy || !event_busy || !control_busy)
            $fatal(1, "reset/default grant was not legacy client zero");

        // The real legacy framebuffer issues one Avalon write command with
        // burst_count=128 and then changes only its data beat after each
        // accepted transfer.  MiSTer's safe terminator counts EVERY ready
        // cycle after the first write as a burst beat; it does not re-check
        // WE.  Hold physical busy low for the entire transfer and prove that
        // all 128 beats are physically continuous, with no WE gap and no H3D
        // interleave.  This is the exact condition that a per-beat requeue
        // incorrectly masked by inserting artificial waitrequest cycles.
        @(negedge clk);
        legacy_burst_count = 8'd128;
        legacy_address = 29'h017e0000;
        legacy_write_data = 64'h5a00000000000000;
        legacy_byte_enable = 8'hff;
        plane_write = 1'b1;
        event_write = 1'b1;
        control_write = 1'b1;
        legacy_write = 1'b1;
        wait (ddram_write);
        saved_data = ddram_write_data;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!ddram_write || ddram_read ||
                ddram_burst_count !== 8'd128 ||
                ddram_address !== 29'h017e0000 ||
                ddram_write_data !== saved_data ||
                ddram_byte_enable !== 8'hff ||
                legacy_command_accepted)
                $fatal(1,
                    "legacy first burst beat changed while stalled");
        end

        @(negedge clk);
        ddram_busy = 1'b0;
        for (burst_write_index = 0; burst_write_index < 128;
             burst_write_index = burst_write_index + 1) begin
            #1;
            if (!ddram_write || ddram_read ||
                ddram_burst_count !== 8'd128 ||
                ddram_address !== 29'h017e0000 ||
                ddram_write_data !==
                    (64'h5a00000000000000 + 64'(burst_write_index)) ||
                ddram_byte_enable !== 8'hff)
                $fatal(1,
                    "legacy continuous burst payload/gap at beat %0d",
                    burst_write_index);
            @(posedge clk);
            if (!legacy_command_accepted || plane_command_accepted ||
                event_command_accepted || control_command_accepted)
                $fatal(1,
                    "H3D client interleaved legacy burst beat %0d",
                    burst_write_index);
            #1;
            if (burst_write_index == 127) begin
                legacy_write = 1'b0;
                plane_write = 1'b0;
                event_write = 1'b0;
                control_write = 1'b0;
                ddram_busy = 1'b1;
            end else begin
                legacy_write_data = 64'h5a00000000000000 +
                    64'(burst_write_index) + 64'd1;
            end
        end

        if (protocol_error)
            $fatal(1, "valid legacy burst write raised protocol_error");

        // Client zero owns reset/default grant.  Its three-beat read command
        // is held stable through delayed physical acceptance, then receives a
        // same-edge first beat and two arbitrarily delayed trailing beats.
        wait (!legacy_busy);
        @(negedge clk);
        legacy_burst_count = 8'd3;
        legacy_address = 29'h01123456;
        legacy_read = 1'b1;
        @(posedge clk);
        @(negedge clk);
        legacy_read = 1'b0;
        if (!ddram_read || ddram_write ||
            ddram_burst_count !== 8'd3 ||
            ddram_address !== 29'h01123456)
            $fatal(1, "legacy read did not reach the physical queue");
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!ddram_read || ddram_write ||
                ddram_burst_count !== 8'd3 ||
                ddram_address !== 29'h01123456 ||
                legacy_command_accepted)
                $fatal(1, "legacy physical command changed while stalled");
        end
        @(negedge clk);
        ddram_busy = 1'b0;
        ddram_read_data = 64'h1100000000000001;
        ddram_read_data_ready = 1'b1;
        #1;
        if (!legacy_command_accepted || plane_command_accepted ||
            event_command_accepted || control_command_accepted)
            $fatal(1, "legacy physical acceptance mapping mismatch");
        require_only_legacy_beat(64'h1100000000000001);
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1'b1;
        ddram_read_data_ready = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        ddram_read_data = 64'h1100000000000002;
        ddram_read_data_ready = 1'b1;
        require_only_legacy_beat(64'h1100000000000002);
        @(posedge clk);
        @(negedge clk);
        ddram_read_data_ready = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        ddram_read_data = 64'h1100000000000003;
        ddram_read_data_ready = 1'b1;
        require_only_legacy_beat(64'h1100000000000003);
        @(posedge clk);
        @(negedge clk);
        ddram_read_data_ready = 1'b0;
        if (legacy_beats != 3)
            $fatal(1, "legacy burst lost or duplicated a response beat");

        // Saturate all four request inputs.  Delayed acceptance proves the
        // registered physical payload, while the acceptance order proves:
        //   L,P,E,P,C,P,L,...
        // Plane may jump a visible peer, but that skipped peer owns a resume
        // credit immediately after the injected plane command.
        legacy_remaining = 3;
        plane_remaining = 5;
        event_remaining = 2;
        control_remaining = 2;
        previous_owner = -1;
        @(negedge clk);
        legacy_burst_count = 8'd1;
        plane_burst_count = 8'd1;
        event_burst_count = 8'd1;
        control_burst_count = 8'd1;
        legacy_address = 29'h01000010;
        plane_address = 29'h02000010;
        event_address = 29'h03000010;
        control_address = 29'h04000010;
        legacy_write = 1'b1;
        plane_write = 1'b1;
        event_write = 1'b1;
        control_write = 1'b1;

        while ((legacy_remaining + plane_remaining + event_remaining +
                control_remaining) != 0) begin
            wait (ddram_write || ddram_read);
            #1;
            if (!ddram_write || ddram_read)
                $fatal(1, "saturated write phase emitted a read");
            saved_read = ddram_read;
            saved_write = ddram_write;
            saved_burst = ddram_burst_count;
            saved_address = ddram_address;
            saved_data = ddram_write_data;
            saved_be = ddram_byte_enable;
            delayed_cycles = (accepted_count % 3) + 1;
            repeat (delayed_cycles) begin
                @(posedge clk);
                #1;
                if (ddram_read !== saved_read ||
                    ddram_write !== saved_write ||
                    ddram_burst_count !== saved_burst ||
                    ddram_address !== saved_address ||
                    ddram_write_data !== saved_data ||
                    ddram_byte_enable !== saved_be)
                    $fatal(1,
                        "physical payload changed during delayed acceptance");
            end
            @(negedge clk);
            ddram_busy = 1'b0;
            #1;
            case ({control_command_accepted,
                   event_command_accepted,
                   plane_command_accepted,
                   legacy_command_accepted})
                4'b0001: owner = 0;
                4'b0010: owner = 1;
                4'b0100: owner = 2;
                4'b1000: owner = 3;
                default: $fatal(1,
                    "saturated request had invalid acceptance vector");
            endcase
            if (ddram_address[28:24] !== 5'(owner + 1))
                $fatal(1, "client payload/acceptance owner mapping mismatch");
            if (owner == 1 && previous_owner == 1 &&
                (legacy_remaining + event_remaining +
                 control_remaining) != 0)
                $fatal(1, "plane priority became an unbounded lock");
            accepted_order[accepted_count] = owner;
            accepted_count = accepted_count + 1;
            previous_owner = owner;
            case (owner)
                0: legacy_count = legacy_count + 1;
                1: plane_count = plane_count + 1;
                2: event_count = event_count + 1;
                default: control_count = control_count + 1;
            endcase
            @(posedge clk);
            @(negedge clk);
            ddram_busy = 1'b1;
            case (owner)
                0: begin
                    legacy_remaining = legacy_remaining - 1;
                    if (legacy_remaining == 0)
                        legacy_write = 1'b0;
                    else begin
                        legacy_address = legacy_address + 1'b1;
                        legacy_write_data = legacy_write_data + 1'b1;
                    end
                end
                1: begin
                    plane_remaining = plane_remaining - 1;
                    if (plane_remaining == 0)
                        plane_write = 1'b0;
                    else begin
                        plane_address = plane_address + 1'b1;
                        plane_write_data = plane_write_data + 1'b1;
                    end
                end
                2: begin
                    event_remaining = event_remaining - 1;
                    if (event_remaining == 0)
                        event_write = 1'b0;
                    else begin
                        event_address = event_address + 1'b1;
                        event_write_data = event_write_data + 1'b1;
                    end
                end
                default: begin
                    control_remaining = control_remaining - 1;
                    if (control_remaining == 0)
                        control_write = 1'b0;
                    else begin
                        control_address = control_address + 1'b1;
                        control_write_data = control_write_data + 1'b1;
                    end
                end
            endcase
        end

        if (accepted_count != 12 || legacy_count != 3 ||
            plane_count != 5 || event_count != 2 || control_count != 2)
            $fatal(1, "contention phase did not serve every client exactly");
        if (accepted_order[0] != 0 || accepted_order[1] != 1 ||
            accepted_order[2] != 2 || accepted_order[3] != 1 ||
            accepted_order[4] != 3 || accepted_order[5] != 1)
            $fatal(1,
                "plane priority or peer round-robin prefix changed: %0d %0d %0d %0d %0d %0d",
                accepted_order[0], accepted_order[1], accepted_order[2],
                accepted_order[3], accepted_order[4], accepted_order[5]);

        // Route a delayed four-beat read through event client two.  This also
        // proves that the wrapper did not accidentally preserve the old
        // sound/credit role names at its public boundary.
        wait (!event_busy);
        @(negedge clk);
        event_burst_count = 8'd4;
        event_address = 29'h03123456;
        event_read = 1'b1;
        @(posedge clk);
        @(negedge clk);
        event_read = 1'b0;
        if (!ddram_read || ddram_burst_count !== 8'd4 ||
            ddram_address !== 29'h03123456)
            $fatal(1, "event burst command mapping mismatch");
        repeat (2) @(posedge clk);
        @(negedge clk);
        ddram_busy = 1'b0;
        #1;
        if (!event_command_accepted || legacy_command_accepted ||
            plane_command_accepted || control_command_accepted)
            $fatal(1, "event physical acceptance mapping mismatch");
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1'b1;
        for (i = 0; i < 4; i = i + 1) begin
            repeat ((i % 2) + 1) @(posedge clk);
            @(negedge clk);
            ddram_read_data = 64'he300000000000000 + 64'(i);
            ddram_read_data_ready = 1'b1;
            require_only_event_beat(
                64'he300000000000000 + 64'(i));
            @(posedge clk);
            @(negedge clk);
            ddram_read_data_ready = 1'b0;
        end
        if (event_beats != 4)
            $fatal(1, "event burst lost or duplicated a response beat");

        // Exercise the remaining two public response ports explicitly: plane
        // gets an acceptance-edge response and control gets a delayed one.
        wait (!plane_busy);
        @(negedge clk);
        plane_burst_count = 8'd1;
        plane_address = 29'h02123456;
        plane_read = 1'b1;
        @(posedge clk);
        @(negedge clk);
        plane_read = 1'b0;
        if (!ddram_read || ddram_address !== 29'h02123456)
            $fatal(1, "plane one-beat read command mapping mismatch");
        ddram_busy = 1'b0;
        ddram_read_data = 64'h2200000000000001;
        ddram_read_data_ready = 1'b1;
        #1;
        if (!plane_command_accepted)
            $fatal(1, "plane read was not physically accepted");
        require_only_plane_beat(64'h2200000000000001);
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1'b1;
        ddram_read_data_ready = 1'b0;

        wait (!control_busy);
        @(negedge clk);
        control_burst_count = 8'd1;
        control_address = 29'h04112233;
        control_read = 1'b1;
        @(posedge clk);
        @(negedge clk);
        control_read = 1'b0;
        if (!ddram_read || ddram_address !== 29'h04112233)
            $fatal(1, "control one-beat read command mapping mismatch");
        ddram_busy = 1'b0;
        #1;
        if (!control_command_accepted)
            $fatal(1, "control read was not physically accepted");
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        ddram_read_data = 64'h4400000000000001;
        ddram_read_data_ready = 1'b1;
        require_only_control_beat(64'h4400000000000001);
        @(posedge clk);
        @(negedge clk);
        ddram_read_data_ready = 1'b0;
        if (plane_beats != 1 || control_beats != 1)
            $fatal(1, "plane/control response was lost or duplicated");

        // Reset first with a command sitting in the physical waitrequest
        // queue.  It must disappear without an acceptance pulse.
        wait (!control_busy);
        @(negedge clk);
        control_burst_count = 8'd2;
        control_address = 29'h04123456;
        control_read = 1'b1;
        @(posedge clk);
        @(negedge clk);
        control_read = 1'b0;
        if (!ddram_read || ddram_address !== 29'h04123456)
            $fatal(1, "queued control read was not visible");
        reset = 1'b1;
        #1;
        if (ddram_read || ddram_write || control_command_accepted)
            $fatal(1, "reset did not cancel the queued physical command");
        ddram_read_data = 64'hbad1000000000001;
        ddram_read_data_ready = 1'b1;
        @(posedge clk);
        require_no_routed_beat();
        @(negedge clk);
        reset = 1'b0;
        repeat (2) begin
            @(posedge clk);
            require_no_routed_beat();
        end
        @(negedge clk);
        ddram_read_data_ready = 1'b0;
        wait_for_epoch();
        if (protocol_error)
            $fatal(1, "queued-command reset raised protocol_error");

        // Reset again with an accepted read waiting for three response beats.
        // Late beats must be discarded and restart reset quarantine.
        wait (!event_busy);
        @(negedge clk);
        event_burst_count = 8'd3;
        event_address = 29'h0300abcd;
        event_read = 1'b1;
        @(posedge clk);
        @(negedge clk);
        event_read = 1'b0;
        ddram_busy = 1'b0;
        #1;
        if (!event_command_accepted)
            $fatal(1, "pre-reset event read was not accepted");
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1'b1;
        reset = 1'b1;
        ddram_read_data = 64'hbad2000000000001;
        ddram_read_data_ready = 1'b1;
        repeat (2) begin
            @(posedge clk);
            require_no_routed_beat();
        end
        @(negedge clk);
        reset = 1'b0;
        @(posedge clk);
        require_no_routed_beat();
        @(negedge clk);
        ddram_read_data_ready = 1'b0;
        wait_for_epoch();
        if (protocol_error)
            $fatal(1, "inflight-read reset raised protocol_error");

        $display(
            "PASS: H3D DDR fabric preserved delayed physical acceptance, legacy/event burst ownership, bounded plane priority, all-client fairness, and queued/inflight reset quarantine (%0d writes)",
            accepted_count);
        $finish;
    end
endmodule
