module tb_nds_ddram_arbiter_4client_random;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic cpu_rd = 0, cpu_we = 0;
    logic video_rd = 0, video_we = 0;
    logic sound_rd = 0, sound_we = 0;
    logic credit_rd = 0, credit_we = 0;
    logic [7:0] cpu_burstcnt = 2, video_burstcnt = 1;
    logic [7:0] sound_burstcnt = 4, credit_burstcnt = 1;
    logic [28:0] cpu_addr = 29'h01000100;
    logic [28:0] video_addr = 29'h02000200;
    logic [28:0] sound_addr = 29'h03000300;
    logic [28:0] credit_addr = 29'h04000400;
    logic [63:0] cpu_din = 64'h1010101010101010;
    logic [63:0] video_din = 64'h2020202020202020;
    logic [63:0] sound_din = 64'h3030303030303030;
    logic [63:0] credit_din = 64'h4040404040404040;
    logic [7:0] cpu_be = 8'h11, video_be = 8'h22;
    logic [7:0] sound_be = 8'h44, credit_be = 8'h88;

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
    logic ddram_busy = 0;
    logic [63:0] ddram_dout = 0;
    logic ddram_dout_ready = 0;
    logic epoch_quiescent;
    logic [31:0] debug_state;
    logic protocol_error;

    integer accepted [0:3];
    integer returned [0:3];
    integer age [0:3];
    integer tx, expected_owner, stall_cycles, delay_cycles;
    integer beat, total_beats, remaining_beats;
    integer i;
    logic [31:0] prng = 32'h6d2b79f5;
    logic same_edge;
    logic stress_active = 0;
    logic [63:0] expected_data;

    nds_ddram_arbiter_4client dut (
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

    task automatic advance_prng;
        begin
            prng = {prng[30:0],
                    prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
        end
    endtask

    task automatic require_accept_owner(input integer owner);
        begin
            case (owner)
                0: if (!cpu_command_accepted ||
                       video_command_accepted || sound_command_accepted ||
                       credit_command_accepted)
                    $fatal(1, "expected CPU acceptance");
                1: if (!video_command_accepted ||
                       cpu_command_accepted || sound_command_accepted ||
                       credit_command_accepted)
                    $fatal(1, "expected video acceptance");
                2: if (!sound_command_accepted ||
                       cpu_command_accepted || video_command_accepted ||
                       credit_command_accepted)
                    $fatal(1, "expected sound acceptance");
                3: if (!credit_command_accepted ||
                       cpu_command_accepted || video_command_accepted ||
                       sound_command_accepted)
                    $fatal(1, "expected credit acceptance");
            endcase
        end
    endtask

    task automatic require_response_owner(
        input integer owner,
        input logic [63:0] data
    );
        begin
            case (owner)
                0: if (!cpu_dout_ready || video_dout_ready ||
                       sound_dout_ready || credit_dout_ready ||
                       cpu_dout !== data)
                    $fatal(1, "CPU response routing/data mismatch");
                1: if (!video_dout_ready || cpu_dout_ready ||
                       sound_dout_ready || credit_dout_ready ||
                       video_dout !== data)
                    $fatal(1, "video response routing/data mismatch");
                2: if (!sound_dout_ready || cpu_dout_ready ||
                       video_dout_ready || credit_dout_ready ||
                       sound_dout !== data)
                    $fatal(1, "sound response routing/data mismatch");
                3: if (!credit_dout_ready || cpu_dout_ready ||
                       video_dout_ready || sound_dout_ready ||
                       credit_dout !== data)
                    $fatal(1, "credit response routing/data mismatch");
            endcase
        end
    endtask

    task automatic require_payload(input integer owner);
        begin
            case (owner)
                0: begin
                    if (!ddram_rd || ddram_we || ddram_burstcnt !== 2 ||
                        ddram_addr !== cpu_addr || ddram_din !== cpu_din ||
                        ddram_be !== cpu_be)
                        $fatal(1, "CPU read-priority payload changed");
                end
                1: begin
                    if (!ddram_we || ddram_rd || ddram_burstcnt !== 1 ||
                        ddram_addr !== video_addr ||
                        ddram_din !== video_din || ddram_be !== video_be)
                        $fatal(1, "video write payload changed");
                end
                2: begin
                    if (!ddram_rd || ddram_we || ddram_burstcnt !== 4 ||
                        ddram_addr !== sound_addr ||
                        ddram_din !== sound_din || ddram_be !== sound_be)
                        $fatal(1, "sound read payload changed");
                end
                3: begin
                    if (!ddram_we || ddram_rd || ddram_burstcnt !== 1 ||
                        ddram_addr !== credit_addr ||
                        ddram_din !== credit_din || ddram_be !== credit_be)
                        $fatal(1, "credit write payload changed");
                end
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 4; i = i + 1) begin
                accepted[i] <= 0;
                returned[i] <= 0;
                age[i] <= 0;
            end
        end else begin
            if ((cpu_command_accepted + video_command_accepted +
                 sound_command_accepted + credit_command_accepted) > 1)
                $fatal(1, "multiple simultaneous physical acceptances");
            if ((cpu_dout_ready + video_dout_ready +
                 sound_dout_ready + credit_dout_ready) > 1)
                $fatal(1, "multiple response owners");
            if (cpu_command_accepted) accepted[0] <= accepted[0] + 1;
            if (video_command_accepted) accepted[1] <= accepted[1] + 1;
            if (sound_command_accepted) accepted[2] <= accepted[2] + 1;
            if (credit_command_accepted) accepted[3] <= accepted[3] + 1;
            if (cpu_dout_ready) returned[0] <= returned[0] + 1;
            if (video_dout_ready) returned[1] <= returned[1] + 1;
            if (sound_dout_ready) returned[2] <= returned[2] + 1;
            if (credit_dout_ready) returned[3] <= returned[3] + 1;

            if (stress_active) begin
                for (i = 0; i < 4; i = i + 1) begin
                    age[i] <= age[i] + 1;
                    if (age[i] > 160)
                        $fatal(1,
                            "bounded fairness violated for client %0d age=%0d",
                            i, age[i]);
                end
                if (cpu_command_accepted) age[0] <= 0;
                if (video_command_accepted) age[1] <= 0;
                if (sound_command_accepted) age[2] <= 0;
                if (credit_command_accepted) age[3] <= 0;
            end
            if (protocol_error)
                $fatal(1, "unexpected ownerless response during stress");
        end
    end

    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "random/fairness stress timeout");
    end

    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            accepted[i] = 0;
            returned[i] = 0;
            age[i] = 0;
        end
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        wait (!dut.quarantine_active);
        @(negedge clk);

        // All four clients remain asserted for the full run.  This is both a
        // simultaneous-request test and the strongest starvation case.  CPU
        // also keeps RD and WE high to exercise read priority every turn.
        cpu_rd = 1;
        cpu_we = 1;
        video_we = 1;
        sound_rd = 1;
        credit_we = 1;
        ddram_busy = 1;
        stress_active = 1;

        for (tx = 0; tx < 80; tx = tx + 1) begin
            expected_owner = tx & 3;

            // Wait for the selected held request to reach the physical port.
            while (!ddram_rd && !ddram_we)
                @(negedge clk);
            require_payload(expected_owner);

            // Pseudorandom bounded waitrequest.  Payload must be completely
            // stable on every stalled edge.
            advance_prng();
            stall_cycles = prng[2:0] % 5;
            repeat (stall_cycles) begin
                ddram_busy = 1;
                @(posedge clk);
                #1;
                require_payload(expected_owner);
                if (cpu_command_accepted || video_command_accepted ||
                    sound_command_accepted || credit_command_accepted)
                    $fatal(1, "acceptance pulsed while waitrequest high");
                @(negedge clk);
            end

            total_beats = (expected_owner == 0) ? 2 :
                          (expected_owner == 2) ? 4 : 0;
            advance_prng();
            same_edge = total_beats != 0 && prng[0];
            ddram_busy = 0;
            if (same_edge) begin
                expected_data =
                    64'ha500000000000000 |
                    (expected_owner << 24) | (tx << 8);
                ddram_dout = expected_data;
                ddram_dout_ready = 1;
                #1;
                require_response_owner(expected_owner, expected_data);
            end
            #1;
            require_accept_owner(expected_owner);
            @(posedge clk);
            @(negedge clk);
            ddram_busy = 1;
            ddram_dout_ready = 0;

            remaining_beats = total_beats - (same_edge ? 1 : 0);
            for (beat = total_beats - remaining_beats;
                 beat < total_beats; beat = beat + 1) begin
                advance_prng();
                delay_cycles = prng[2:1] % 4;
                repeat (delay_cycles) begin
                    @(posedge clk);
                    #1;
                    if (cpu_dout_ready || video_dout_ready ||
                        sound_dout_ready || credit_dout_ready)
                        $fatal(1, "response ready appeared during delay");
                    @(negedge clk);
                end
                expected_data =
                    64'ha500000000000000 |
                    (expected_owner << 24) | (tx << 8) | beat;
                ddram_dout = expected_data;
                ddram_dout_ready = 1;
                #1;
                require_response_owner(expected_owner, expected_data);
                @(posedge clk);
                @(negedge clk);
                ddram_dout_ready = 0;
            end
        end

        stress_active = 0;
        cpu_rd = 0;
        cpu_we = 0;
        video_we = 0;
        sound_rd = 0;
        credit_we = 0;
        repeat (3) @(posedge clk);

        for (i = 0; i < 4; i = i + 1)
            if (accepted[i] != 20)
                $fatal(1,
                    "round-robin count client %0d got %0d expected 20",
                    i, accepted[i]);
        if (returned[0] != 40 || returned[1] != 0 ||
            returned[2] != 80 || returned[3] != 0)
            $fatal(1,
                "burst totals wrong cpu=%0d video=%0d sound=%0d credit=%0d",
                returned[0], returned[1], returned[2], returned[3]);

        $display("PASS: four-client DDR arbiter randomized stalls/responses preserve exact 0-1-2-3 round robin for 80 sustained mixed transactions");
        $finish;
    end
endmodule
