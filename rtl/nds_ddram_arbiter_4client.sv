// Four-client arbiter for the single MiSTer DDRAM port.  The product H3D
// fabric wraps this block while legacy and focused test configurations also
// instantiate it directly.  Client roles retain their historical names:
//   cpu    - CPU/main-memory and boot-descriptor traffic
//   video  - published-frame reads
//   sound  - FPGA sound sample reads
//   credit - HPS-consumed-credit reverse-ring traffic
//
// Each client follows the existing local contract: it may present a command
// when its busy output is low.  The command is copied into a one-entry queue,
// which then holds the physical Avalon payload stable until waitrequest
// (ddram_busy) is low.  command_accepted reports physical, not local-queue,
// acceptance.
module nds_ddram_arbiter_4client #(
    // After reset, require this many consecutive response-free DDR cycles
    // before exposing a client grant.  Response beats seen during quarantine
    // are discarded, so a response belonging to the pre-reset owner cannot be
    // delivered to a post-reset owner.  Raw waitrequest is deliberately not
    // part of this test: MiSTer's legal idle state may hold it high until
    // RD/WE is presented.  The surrounding menu-mediated deployment must
    // still drain the old image before reconfiguration; no new-image counter
    // can prove an untagged f2sdram response will never arrive later.
    parameter integer RESET_QUIET_CYCLES = 4,
    // A registered client cannot advertise a pending command until its busy
    // input is low.  Blindly walking all four grants therefore spends two
    // clocks on every inactive client.  Keep a recently productive grant for
    // a bounded number of transactions when no *other* client is already
    // asserting a request.  The periodic forced probe preserves progress for
    // strict registered clients that only raise RD/WE after seeing busy low.
    //
    // Zero selects the original unconditional 0-1-2-3 rotation and exists so
    // the simulator throughput gate can measure the old policy exactly.
    parameter integer STICKY_GRANT_LIMIT = 8,
    // Direct mailbox completion does not need the reverse-credit DDR client.
    // A compile-time mask lets that client be removed from the grant rotation
    // without fabricating requests or spending forced-probe slots on it.
    // Client zero (CPU/boot) is mandatory.  The all-ones default preserves the
    // byte-for-byte scheduling contract of every pre-existing test/candidate.
    parameter logic [3:0] CLIENT_ENABLE_MASK = 4'b1111,
    // The raster cannot wait.  Video reads feed a two-line store that the
    // display drains at a fixed rate, so a stall longer than one line time
    // blanks pixels, while every other client only loses throughput.  Video
    // demands roughly 8% of DDR duty (256 beats per 51.2 us line), so letting
    // it jump the round robin costs the other clients little.  The grant is
    // still handed back after each completed video transaction.  The optional
    // fair-credit policy below also preserves the place of any owner skipped
    // by that jump, preventing a sustained video/peer pair from becoming a
    // lock.
    parameter bit VIDEO_PRIORITY_GRANT = 0,
    // The original priority hint prevents video from granting itself, but a
    // permanently visible video request can still alternate with the first
    // round-robin peer and starve the other two clients.  Opting into a fair
    // credit remembers the normal round-robin owner whenever video jumps it,
    // then resumes that owner immediately after the injected video command.
    // Keep the default disabled so existing candidate bitstreams retain their
    // exact scheduling until they opt in.
    parameter bit VIDEO_PRIORITY_FAIR_CREDIT = 0
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        cpu_rd,
    input  logic        cpu_we,
    input  logic [7:0]  cpu_burstcnt,
    input  logic [28:0] cpu_addr,
    input  logic [63:0] cpu_din,
    input  logic [7:0]  cpu_be,
    output logic        cpu_busy,
    output logic [63:0] cpu_dout,
    output logic        cpu_dout_ready,
    output logic        cpu_command_accepted,

    input  logic        video_rd,
    input  logic        video_we,
    input  logic [7:0]  video_burstcnt,
    input  logic [28:0] video_addr,
    input  logic [63:0] video_din,
    input  logic [7:0]  video_be,
    output logic        video_busy,
    output logic [63:0] video_dout,
    output logic        video_dout_ready,
    output logic        video_command_accepted,

    input  logic        sound_rd,
    input  logic        sound_we,
    input  logic [7:0]  sound_burstcnt,
    input  logic [28:0] sound_addr,
    input  logic [63:0] sound_din,
    input  logic [7:0]  sound_be,
    output logic        sound_busy,
    output logic [63:0] sound_dout,
    output logic        sound_dout_ready,
    output logic        sound_command_accepted,

    input  logic        credit_rd,
    input  logic        credit_we,
    input  logic [7:0]  credit_burstcnt,
    input  logic [28:0] credit_addr,
    input  logic [63:0] credit_din,
    input  logic [7:0]  credit_be,
    output logic        credit_busy,
    output logic [63:0] credit_dout,
    output logic        credit_dout_ready,
    output logic        credit_command_accepted,

    output logic        ddram_rd,
    output logic        ddram_we,
    output logic [7:0]  ddram_burstcnt,
    output logic [28:0] ddram_addr,
    output logic [63:0] ddram_din,
    output logic [7:0]  ddram_be,
    input  logic        ddram_busy,
    input  logic [63:0] ddram_dout,
    input  logic        ddram_dout_ready,

    // Goes high only after the reset response quarantine has observed its
    // complete quiet interval.  It remains high for the active DDR epoch and
    // drops on reset or an ownerless-response protocol failure.
    output logic        epoch_quiescent,
    output logic [31:0] debug_state,

    // Sticky evidence of an ownerless response outside reset quarantine.
    // Such a response is discarded and never routed to a client.
    output logic        protocol_error
);
    localparam integer QUIET_TARGET =
        RESET_QUIET_CYCLES < 1 ? 1 : RESET_QUIET_CYCLES;
    localparam logic [7:0] QUIET_LIMIT = 8'(QUIET_TARGET - 1);
    localparam integer STICKY_TARGET =
        STICKY_GRANT_LIMIT > 255 ? 255 : STICKY_GRANT_LIMIT;
    localparam logic [7:0] STICKY_LIMIT = 8'(STICKY_TARGET);

    initial begin
        if (RESET_QUIET_CYCLES < 1 || RESET_QUIET_CYCLES > 256)
            $fatal(1,
                "RESET_QUIET_CYCLES must be in the range 1..256");
        if (!CLIENT_ENABLE_MASK[0])
            $fatal(1,
                "four-client DDR arbiter requires CPU/boot client zero");
    end

    logic [1:0] grant_owner;
    logic       grant_dwell;
    logic [7:0] sticky_count;
    logic       video_priority_resume_valid;
    logic [1:0] video_priority_resume_owner;

    logic       command_pending;
    logic [1:0] command_owner;
    logic       command_read;
    logic       command_write;
    logic [7:0] command_burst;
    logic [28:0] command_addr;
    logic [63:0] command_din;
    logic [7:0] command_be;

    logic       read_pending;
    logic [1:0] read_owner;
    logic [7:0] beats_remaining;

    // Avalon burst writes are a command plus a stream of accepted data
    // beats.  The legacy Nitro DDR client uses that contract for every
    // 256-pixel framebuffer line.  Keep the owner locked across the complete
    // stream.  The first beat is accepted from the registered command queue;
    // every continuation beat is then passed directly from the locked owner.
    // This is required by MiSTer's f2sdram safe terminator: once a burst write
    // starts, a ready physical cycle counts as a data beat even if WE were to
    // disappear.  Re-queuing each beat would therefore create fatal phantom
    // beats whenever waitrequest remains low.  Each client-side
    // command_accepted pulse consumes exactly one source beat, and arbitration
    // resumes only after the final beat.
    logic       write_stream_pending;
    logic [1:0] write_stream_owner;
    logic [7:0] write_beats_remaining;
    logic [7:0] write_stream_burst;
    logic [28:0] write_stream_addr;

    logic       quarantine_active;
    logic [7:0] quiet_count;

    logic       granted_rd;
    logic       granted_we;
    logic [7:0] granted_burst;
    logic [28:0] granted_addr;
    logic [63:0] granted_din;
    logic [7:0] granted_be;

    logic       stream_rd;
    logic       stream_we;
    logic [7:0] stream_burst;
    logic [28:0] stream_addr;
    logic [63:0] stream_din;
    logic [7:0] stream_be;

    wire granted_request = granted_rd || granted_we;
    wire accepting_queued_command =
        command_pending && !ddram_busy && !reset && !quarantine_active;
    wire accepting_stream_beat =
        write_stream_pending && stream_we && !ddram_busy &&
        !reset && !quarantine_active;
    wire accepting_read_command =
        accepting_queued_command && command_read;
    wire response_has_owner = read_pending || accepting_read_command;
    wire [3:0] request_vector = {
        credit_rd || credit_we,
        sound_rd || sound_we,
        video_rd || video_we,
        cpu_rd || cpu_we
    } & CLIENT_ENABLE_MASK;

    function automatic logic [1:0] next_enabled_owner(
        input logic [1:0] current_owner
    );
        logic [1:0] candidate;
        logic [1:0] chosen_owner;
        logic found;
        integer offset;
        begin
            chosen_owner = current_owner;
            found = 1'b0;
            for (offset = 1; offset <= 4; offset = offset + 1) begin
                candidate = current_owner + offset[1:0];
                if (!found && CLIENT_ENABLE_MASK[candidate]) begin
                    chosen_owner = candidate;
                    found = 1'b1;
                end
            end
            next_enabled_owner = chosen_owner;
        end
    endfunction

    // Prefer an already-visible waiting peer in round-robin order.  If no
    // peer is visible, retain the productive owner for a bounded run.  Once
    // the bound is reached, expose the next grant for the full registered
    // two-cycle dwell so even a client that gates its request with busy must
    // eventually be discovered.
    function automatic logic [12:0] next_grant_state(
        input logic [1:0] completed_owner,
        input logic [3:0] requests,
        input logic [7:0] completed_sticky_count,
        input logic completed_video_priority_resume_valid,
        input logic [1:0] completed_video_priority_resume_owner
    );
        logic [1:0] candidate;
        logic [1:0] normal_owner;
        logic [7:0] normal_sticky_count;
        logic [1:0] chosen_owner;
        logic [7:0] chosen_sticky_count;
        logic chosen_video_priority_resume_valid;
        logic [1:0] chosen_video_priority_resume_owner;
        logic found_peer;
        integer offset;
        begin
            normal_owner = next_enabled_owner(completed_owner);
            normal_sticky_count = 8'd0;
            found_peer = 1'b0;
            if (STICKY_GRANT_LIMIT > 0) begin
                for (offset = 1; offset <= 3; offset = offset + 1) begin
                    candidate = completed_owner + offset[1:0];
                    if (!found_peer &&
                        CLIENT_ENABLE_MASK[candidate] &&
                        requests[candidate]) begin
                        normal_owner = candidate;
                        found_peer = 1'b1;
                    end
                end

                if (!found_peer) begin
                    if ((completed_sticky_count + 8'd1) <
                        STICKY_LIMIT) begin
                        normal_owner = completed_owner;
                        normal_sticky_count =
                            completed_sticky_count + 1'b1;
                    end
                end
            end

            chosen_owner = normal_owner;
            chosen_sticky_count = normal_sticky_count;
            chosen_video_priority_resume_valid =
                completed_video_priority_resume_valid;
            chosen_video_priority_resume_owner =
                completed_video_priority_resume_owner;

            if (VIDEO_PRIORITY_FAIR_CREDIT &&
                completed_owner == 2'd1 &&
                completed_video_priority_resume_valid) begin
                // The priority-injected plane transaction has completed.
                // Resume the owner it jumped even if that strict registered
                // client cannot advertise a request until its busy drops.
                chosen_owner = completed_video_priority_resume_owner;
                chosen_sticky_count = 8'd0;
                chosen_video_priority_resume_valid = 1'b0;
            end else if (VIDEO_PRIORITY_GRANT &&
                CLIENT_ENABLE_MASK[2'd1] &&
                requests[2'd1] &&
                completed_owner != 2'd1) begin
                if (!VIDEO_PRIORITY_FAIR_CREDIT) begin
                    chosen_owner = 2'd1;
                    chosen_sticky_count = 8'd0;
                end else if (normal_owner != 2'd1) begin
                    // Inject plane before the normal owner and retain that
                    // skipped owner's place in the round robin as a credit.
                    chosen_owner = 2'd1;
                    chosen_sticky_count = 8'd0;
                    chosen_video_priority_resume_valid = 1'b1;
                    chosen_video_priority_resume_owner = normal_owner;
                end
            end
            next_grant_state = {
                chosen_video_priority_resume_valid,
                chosen_video_priority_resume_owner,
                chosen_sticky_count,
                chosen_owner
            };
        end
    endfunction

    always_comb begin
        granted_rd = 1'b0;
        granted_we = 1'b0;
        granted_burst = 8'd1;
        granted_addr = 29'd0;
        granted_din = 64'd0;
        granted_be = 8'hff;
        if (CLIENT_ENABLE_MASK[grant_owner]) begin
            case (grant_owner)
                2'd0: begin
                    granted_rd = cpu_rd;
                    granted_we = cpu_we;
                    granted_burst = cpu_burstcnt;
                    granted_addr = cpu_addr;
                    granted_din = cpu_din;
                    granted_be = cpu_be;
                end
                2'd1: begin
                    granted_rd = video_rd;
                    granted_we = video_we;
                    granted_burst = video_burstcnt;
                    granted_addr = video_addr;
                    granted_din = video_din;
                    granted_be = video_be;
                end
                2'd2: begin
                    granted_rd = sound_rd;
                    granted_we = sound_we;
                    granted_burst = sound_burstcnt;
                    granted_addr = sound_addr;
                    granted_din = sound_din;
                    granted_be = sound_be;
                end
                default: begin
                    granted_rd = credit_rd;
                    granted_we = credit_we;
                    granted_burst = credit_burstcnt;
                    granted_addr = credit_addr;
                    granted_din = credit_din;
                    granted_be = credit_be;
                end
            endcase
        end
    end

    // A burst-write continuation is not a new Avalon command.  Select the
    // locked owner's live, held beat independently of the rotating grant.
    // The client sees the physical waitrequest directly while this stream is
    // active, so it advances its payload on exactly the same edge that the
    // physical port accepts it.
    always_comb begin
        stream_rd = 1'b0;
        stream_we = 1'b0;
        stream_burst = 8'd1;
        stream_addr = 29'd0;
        stream_din = 64'd0;
        stream_be = 8'hff;
        case (write_stream_owner)
            2'd0: begin
                stream_rd = cpu_rd;
                stream_we = cpu_we;
                stream_burst = cpu_burstcnt;
                stream_addr = cpu_addr;
                stream_din = cpu_din;
                stream_be = cpu_be;
            end
            2'd1: begin
                stream_rd = video_rd;
                stream_we = video_we;
                stream_burst = video_burstcnt;
                stream_addr = video_addr;
                stream_din = video_din;
                stream_be = video_be;
            end
            2'd2: begin
                stream_rd = sound_rd;
                stream_we = sound_we;
                stream_burst = sound_burstcnt;
                stream_addr = sound_addr;
                stream_din = sound_din;
                stream_be = sound_be;
            end
            default: begin
                stream_rd = credit_rd;
                stream_we = credit_we;
                stream_burst = credit_burstcnt;
                stream_addr = credit_addr;
                stream_din = credit_din;
                stream_be = credit_be;
            end
        endcase
    end

    always_comb begin
        // All clients are blocked while a command or its read response is in
        // flight.  While idle, exactly one grant is exposed.  The two-cycle
        // idle dwell lets the registered clients used elsewhere in this core
        // observe busy low and present their request on the following edge.
        cpu_busy = 1'b1;
        video_busy = 1'b1;
        sound_busy = 1'b1;
        credit_busy = 1'b1;
        if (!reset && !quarantine_active) begin
            if (write_stream_pending) begin
                // The stream owner advances precisely with the physical
                // Avalon sink.  Every other client remains blocked.
                case (write_stream_owner)
                    2'd0: cpu_busy = ddram_busy;
                    2'd1: video_busy = ddram_busy;
                    2'd2: sound_busy = ddram_busy;
                    default: credit_busy = ddram_busy;
                endcase
            end else if (!command_pending && !read_pending) begin
                case (grant_owner)
                    2'd0: cpu_busy = 1'b0;
                    2'd1: video_busy = 1'b0;
                    2'd2: sound_busy = 1'b0;
                    default: credit_busy = 1'b0;
                endcase
            end
        end

        // The initial command is registered.  A locked burst continuation is
        // live from the owner, whose busy input is the physical waitrequest;
        // the source contract therefore holds its payload throughout stalls.
        ddram_rd = command_pending && command_read &&
                   !reset && !quarantine_active;
        if (write_stream_pending && !reset && !quarantine_active) begin
            ddram_we = stream_we;
            ddram_burstcnt = write_stream_burst;
            ddram_addr = write_stream_addr;
            ddram_din = stream_din;
            ddram_be = stream_be;
        end else begin
            ddram_we = command_pending && command_write &&
                       !reset && !quarantine_active;
            ddram_burstcnt = command_burst;
            ddram_addr = command_addr;
            ddram_din = command_din;
            ddram_be = command_be;
        end

        cpu_dout = ddram_dout;
        video_dout = ddram_dout;
        sound_dout = ddram_dout;
        credit_dout = ddram_dout;

        cpu_dout_ready = ddram_dout_ready && !reset &&
            !quarantine_active && response_has_owner &&
            ((read_pending && read_owner == 2'd0) ||
             (accepting_read_command && command_owner == 2'd0));
        video_dout_ready = ddram_dout_ready && !reset &&
            !quarantine_active && response_has_owner &&
            ((read_pending && read_owner == 2'd1) ||
             (accepting_read_command && command_owner == 2'd1));
        sound_dout_ready = ddram_dout_ready && !reset &&
            !quarantine_active && response_has_owner &&
            ((read_pending && read_owner == 2'd2) ||
             (accepting_read_command && command_owner == 2'd2));
        credit_dout_ready = ddram_dout_ready && !reset &&
            !quarantine_active && response_has_owner &&
            ((read_pending && read_owner == 2'd3) ||
             (accepting_read_command && command_owner == 2'd3));

        cpu_command_accepted =
            (accepting_queued_command && command_owner == 2'd0) ||
            (accepting_stream_beat && write_stream_owner == 2'd0);
        video_command_accepted =
            (accepting_queued_command && command_owner == 2'd1) ||
            (accepting_stream_beat && write_stream_owner == 2'd1);
        sound_command_accepted =
            (accepting_queued_command && command_owner == 2'd2) ||
            (accepting_stream_beat && write_stream_owner == 2'd2);
        credit_command_accepted =
            (accepting_queued_command && command_owner == 2'd3) ||
            (accepting_stream_beat && write_stream_owner == 2'd3);
        epoch_quiescent =
            !reset && !quarantine_active && !protocol_error;
        debug_state = {
            quarantine_active,
            read_pending,
            command_owner,
            command_pending,
            grant_dwell,
            grant_owner,
            sticky_count,
            beats_remaining,
            quiet_count
        };
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            grant_owner <= 2'd0;
            grant_dwell <= 1'b1;
            sticky_count <= 8'd0;
            video_priority_resume_valid <= 1'b0;
            video_priority_resume_owner <= 2'd0;
            command_pending <= 1'b0;
            command_owner <= 2'd0;
            command_read <= 1'b0;
            command_write <= 1'b0;
            command_burst <= 8'd1;
            command_addr <= 29'd0;
            command_din <= 64'd0;
            command_be <= 8'hff;
            read_pending <= 1'b0;
            read_owner <= 2'd0;
            beats_remaining <= 8'd0;
            write_stream_pending <= 1'b0;
            write_stream_owner <= 2'd0;
            write_beats_remaining <= 8'd0;
            write_stream_burst <= 8'd1;
            write_stream_addr <= 29'd0;
            quarantine_active <= 1'b1;
            quiet_count <= 8'd0;
            protocol_error <= 1'b0;
        end else if (quarantine_active) begin
            // Keep all ownership empty and discard any old response beats.
            command_pending <= 1'b0;
            read_pending <= 1'b0;
            beats_remaining <= 8'd0;
            write_stream_pending <= 1'b0;
            write_beats_remaining <= 8'd0;
            grant_owner <= 2'd0;
            grant_dwell <= 1'b1;
            sticky_count <= 8'd0;
            video_priority_resume_valid <= 1'b0;
            video_priority_resume_owner <= 2'd0;
            if (ddram_dout_ready) begin
                quiet_count <= 8'd0;
            end else if (quiet_count >= QUIET_LIMIT) begin
                quarantine_active <= 1'b0;
                quiet_count <= 8'd0;
            end else begin
                quiet_count <= quiet_count + 1'b1;
            end
        end else begin
            if (ddram_dout_ready && !response_has_owner)
                protocol_error <= 1'b1;

            if (write_stream_pending &&
                (stream_rd || !stream_we ||
                 (stream_burst == 0 ? 8'd1 : stream_burst) !=
                    write_stream_burst ||
                 stream_addr != write_stream_addr))
                protocol_error <= 1'b1;

            if (command_pending) begin
                if (!ddram_busy) begin
                    command_pending <= 1'b0;
                    if (command_read) begin
                        read_owner <= command_owner;
                        if (ddram_dout_ready) begin
                            // The first read beat may be returned on the same
                            // edge that accepts the command.
                            if (command_burst <= 1) begin
                                read_pending <= 1'b0;
                                beats_remaining <= 8'd0;
                                {video_priority_resume_valid,
                                 video_priority_resume_owner,
                                 sticky_count, grant_owner} <=
                                    next_grant_state(
                                        command_owner,
                                        request_vector,
                                        sticky_count,
                                        video_priority_resume_valid,
                                        video_priority_resume_owner);
                                grant_dwell <= 1'b1;
                            end else begin
                                read_pending <= 1'b1;
                                beats_remaining <= command_burst - 1'b1;
                            end
                        end else begin
                            read_pending <= 1'b1;
                            beats_remaining <= command_burst;
                        end
                    end else if (command_burst > 1) begin
                        write_stream_pending <= 1'b1;
                        write_stream_owner <= command_owner;
                        write_beats_remaining <= command_burst - 1'b1;
                        write_stream_burst <= command_burst;
                        write_stream_addr <= command_addr;
                        grant_owner <= command_owner;
                        grant_dwell <= 1'b0;
                    end else begin
                        // Read has priority if a client asserted both controls;
                        // command_write was latched only when granted_rd=0.
                        {video_priority_resume_valid,
                         video_priority_resume_owner,
                         sticky_count, grant_owner} <=
                            next_grant_state(
                                command_owner,
                                request_vector,
                                sticky_count,
                                video_priority_resume_valid,
                                video_priority_resume_owner);
                        grant_dwell <= 1'b1;
                    end
                end
            end else if (write_stream_pending) begin
                if (accepting_stream_beat) begin
                    if (write_beats_remaining <= 1) begin
                        write_stream_pending <= 1'b0;
                        write_beats_remaining <= 8'd0;
                        {video_priority_resume_valid,
                         video_priority_resume_owner,
                         sticky_count, grant_owner} <=
                            next_grant_state(
                                write_stream_owner,
                                request_vector,
                                sticky_count,
                                video_priority_resume_valid,
                                video_priority_resume_owner);
                        grant_dwell <= 1'b1;
                    end else begin
                        write_beats_remaining <=
                            write_beats_remaining - 1'b1;
                        grant_owner <= write_stream_owner;
                        grant_dwell <= 1'b0;
                    end
                end
            end else if (read_pending) begin
                if (ddram_dout_ready) begin
                    if (beats_remaining <= 1) begin
                        read_pending <= 1'b0;
                        beats_remaining <= 8'd0;
                        {video_priority_resume_valid,
                         video_priority_resume_owner,
                         sticky_count, grant_owner} <=
                            next_grant_state(
                                read_owner,
                                request_vector,
                                sticky_count,
                                video_priority_resume_valid,
                                video_priority_resume_owner);
                        grant_dwell <= 1'b1;
                    end else begin
                        beats_remaining <= beats_remaining - 1'b1;
                    end
                end
            end else if (granted_request) begin
                command_pending <= 1'b1;
                command_owner <= grant_owner;
                command_read <= granted_rd;
                command_write <= granted_we && !granted_rd;
                command_burst <=
                    granted_burst == 0 ? 8'd1 : granted_burst;
                command_addr <= granted_addr;
                command_din <= granted_din;
                command_be <= granted_be;
                grant_dwell <= 1'b0;
            end else if (grant_dwell) begin
                grant_dwell <= 1'b0;
            end else begin
                if (VIDEO_PRIORITY_FAIR_CREDIT &&
                    video_priority_resume_valid &&
                    grant_owner == 2'd1) begin
                    // The injected plane requester vanished before the local
                    // handoff.  Resume the exact owner that was skipped.
                    grant_owner <= video_priority_resume_owner;
                    video_priority_resume_valid <= 1'b0;
                end else begin
                    grant_owner <= next_enabled_owner(grant_owner);
                end
                grant_dwell <= 1'b1;
                sticky_count <= 8'd0;
            end
        end
    end
endmodule
