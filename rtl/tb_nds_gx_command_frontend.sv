module tb_nds_gx_command_frontend;
    localparam integer QUEUE_DEPTH = 8;
    localparam integer MAX_EXPECTED = 8192;

    logic clk = 0;
    logic reset = 1;
    logic write_valid = 0;
    logic write_ready;
    logic cpu_is_arm9 = 1;
    logic [31:0] address = 0;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = 0;
    logic [31:0] frame = 0;
    logic [63:0] timestamp = 0;
    logic command_valid;
    logic command_ready = 1;
    logic [31:0] command_frame;
    logic [63:0] command_timestamp;
    logic [7:0] command_id;
    logic [31:0] command_parameter;
    logic [$clog2(QUEUE_DEPTH + 1)-1:0] queue_level;
    logic queue_empty;
    logic queue_full;
    logic packed_active;
    logic busy;
    logic protocol_error;

    logic [31:0] expected_frame [0:MAX_EXPECTED-1];
    logic [63:0] expected_timestamp [0:MAX_EXPECTED-1];
    logic [7:0] expected_command [0:MAX_EXPECTED-1];
    logic [31:0] expected_parameter [0:MAX_EXPECTED-1];
    integer expected_write = 0;
    integer expected_read = 0;

    logic [31:0] model_commands = 0;
    integer model_command_count = 0;
    integer model_parameters_remaining = 0;
    logic [31:0] model_trigger_frame = 0;
    logic [63:0] model_trigger_timestamp = 0;
    logic [31:0] model_trigger_parameter = 0;

    logic held_output = 0;
    logic [31:0] held_frame;
    logic [63:0] held_timestamp;
    logic [7:0] held_command;
    logic [31:0] held_parameter;
    logic random_backpressure = 0;
    logic [31:0] backpressure_lfsr = 32'h5a17c9e3;
    logic [31:0] random_state = 32'hc001d00d;
    integer accepted_writes = 0;
    integer output_commands = 0;

    always #5 clk = ~clk;

    nds_gx_command_frontend #(
        .QUEUE_DEPTH(QUEUE_DEPTH)
    ) dut (
        .*
    );

    function automatic integer reference_parameter_count(
        input logic [7:0] command
    );
        begin
            case (command)
                8'h10, 8'h12, 8'h13, 8'h14,
                8'h20, 8'h21, 8'h22,
                8'h24, 8'h25, 8'h26, 8'h27,
                8'h28, 8'h29, 8'h2a, 8'h2b,
                8'h30, 8'h31, 8'h32, 8'h33,
                8'h40, 8'h50, 8'h60, 8'h72:
                    reference_parameter_count = 1;
                8'h23, 8'h71:
                    reference_parameter_count = 2;
                8'h1b, 8'h1c, 8'h70:
                    reference_parameter_count = 3;
                8'h1a: reference_parameter_count = 9;
                8'h17, 8'h19: reference_parameter_count = 12;
                8'h16, 8'h18: reference_parameter_count = 16;
                8'h34: reference_parameter_count = 32;
                default: reference_parameter_count = 0;
            endcase
        end
    endfunction

    function automatic logic [31:0] random_command_word(
        input integer selector
    );
        begin
            case (selector % 12)
                0: random_command_word = 32'h00231210;
                1: random_command_word = 32'h00411511;
                2: random_command_word = 32'h00120000;
                3: random_command_word = 32'h00000000;
                4: random_command_word = 32'h00347023;
                5: random_command_word = 32'h721b5010;
                6: random_command_word = 32'h19181716;
                7: random_command_word = 32'h2b2a2928;
                8: random_command_word = 32'h33323130;
                9: random_command_word = 32'h00607170;
                10: random_command_word = 32'h00150041;
                default: random_command_word = 32'h14242240;
            endcase
        end
    endfunction

    task automatic expect_command(
        input logic [31:0] wanted_frame,
        input logic [63:0] wanted_timestamp,
        input logic [7:0] wanted_command,
        input logic [31:0] wanted_parameter
    );
        begin
            if (expected_write >= MAX_EXPECTED)
                $fatal(1, "expected command queue overflow");
            expected_frame[expected_write] = wanted_frame;
            expected_timestamp[expected_write] = wanted_timestamp;
            expected_command[expected_write] = wanted_command;
            expected_parameter[expected_write] = wanted_parameter;
            expected_write = expected_write + 1;
        end
    endtask

    task automatic model_advance_zero_commands;
        logic [7:0] current;
        begin
            while (model_command_count > 0 &&
                   model_parameters_remaining == 0) begin
                current = model_commands[7:0];
                if (current != 0 ||
                    (model_command_count == 4 &&
                     model_commands == 0))
                    expect_command(
                        model_trigger_frame,
                        model_trigger_timestamp,
                        current,
                        model_trigger_parameter);
                model_commands = model_commands >> 8;
                model_command_count = model_command_count - 1;
                if (model_command_count > 0)
                    model_parameters_remaining =
                        reference_parameter_count(
                            model_commands[7:0]);
            end
        end
    endtask

    task automatic model_accept_write(
        input logic selected_cpu,
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] bus_data,
        input logic [31:0] bus_frame,
        input logic [63:0] bus_timestamp
    );
        logic fifo_write;
        logic direct_write;
        logic [7:0] direct_command;
        begin
            fifo_write =
                selected_cpu && bus_access == 2'b10 &&
                bus_address[1:0] == 0 &&
                bus_address >= 32'h04000400 &&
                bus_address < 32'h04000440;
            direct_write =
                selected_cpu && bus_access == 2'b10 &&
                bus_address[1:0] == 0 &&
                bus_address >= 32'h04000440 &&
                bus_address < 32'h040005cc;
            if (direct_write) begin
                direct_command = bus_address[9:2];
                expect_command(
                    bus_frame, bus_timestamp,
                    direct_command, bus_data);
            end else if (fifo_write) begin
                if (model_command_count == 0) begin
                    model_commands = bus_data;
                    model_command_count = 4;
                    model_parameters_remaining =
                        reference_parameter_count(bus_data[7:0]);
                    model_trigger_frame = bus_frame;
                    model_trigger_timestamp = bus_timestamp;
                    model_trigger_parameter = bus_data;
                    model_advance_zero_commands();
                end else begin
                    if (model_parameters_remaining <= 0)
                        $fatal(1, "reference parser accepted a parameter in zero phase");
                    expect_command(
                        bus_frame, bus_timestamp,
                        model_commands[7:0], bus_data);
                    model_trigger_frame = bus_frame;
                    model_trigger_timestamp = bus_timestamp;
                    model_trigger_parameter = bus_data;
                    model_parameters_remaining =
                        model_parameters_remaining - 1;
                    if (model_parameters_remaining == 0) begin
                        model_commands = model_commands >> 8;
                        model_command_count =
                            model_command_count - 1;
                        if (model_command_count > 0)
                            model_parameters_remaining =
                                reference_parameter_count(
                                    model_commands[7:0]);
                        model_advance_zero_commands();
                    end
                end
            end
        end
    endtask

    task automatic send_write(
        input logic selected_cpu,
        input logic [31:0] bus_address,
        input logic [1:0] bus_access,
        input logic [31:0] bus_data,
        input logic [31:0] bus_frame,
        input logic [63:0] bus_timestamp
    );
        integer waited;
        begin
            model_accept_write(
                selected_cpu, bus_address, bus_access, bus_data,
                bus_frame, bus_timestamp);
            @(negedge clk);
            cpu_is_arm9 = selected_cpu;
            address = bus_address;
            access = bus_access;
            write_data = bus_data;
            frame = bus_frame;
            timestamp = bus_timestamp;
            write_valid = 1;
            waited = 0;
            while (!write_ready) begin
                @(posedge clk);
                waited = waited + 1;
                if (waited > 5000)
                    $fatal(1, "write handshake timeout");
                @(negedge clk);
            end
            @(posedge clk);
            accepted_writes = accepted_writes + 1;
            @(negedge clk);
            write_valid = 0;
        end
    endtask

    task automatic wait_for_drain;
        integer waited;
        begin
            waited = 0;
            while (expected_read != expected_write ||
                   command_valid || !queue_empty) begin
                @(posedge clk);
                waited = waited + 1;
                if (waited > 20000)
                    $fatal(1, "command drain timeout expected=%0d read=%0d",
                           expected_write, expected_read);
            end
        end
    endtask

    task automatic wait_for_packed_idle;
        integer waited;
        begin
            waited = 0;
            while (packed_active) begin
                @(posedge clk);
                waited = waited + 1;
                if (waited > 32)
                    $fatal(1, "packed parser did not return idle");
            end
        end
    endtask

    task automatic reset_test_state;
        begin
            @(negedge clk);
            reset = 1;
            write_valid = 0;
            command_ready = 1;
            random_backpressure = 0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 0;
            expected_write = 0;
            expected_read = 0;
            model_commands = 0;
            model_command_count = 0;
            model_parameters_remaining = 0;
            model_trigger_frame = 0;
            model_trigger_timestamp = 0;
            model_trigger_parameter = 0;
            held_output = 0;
        end
    endtask

    always @(negedge clk) begin
        if (random_backpressure) begin
            backpressure_lfsr =
                {backpressure_lfsr[30:0],
                 backpressure_lfsr[31] ^
                 backpressure_lfsr[21] ^
                 backpressure_lfsr[1] ^
                 backpressure_lfsr[0]};
            command_ready = backpressure_lfsr[0] |
                            backpressure_lfsr[4];
        end
    end

    always @(posedge clk) begin
        if (!reset) begin
            if (integer'(queue_level) > QUEUE_DEPTH)
                $fatal(1, "queue level exceeded depth");
            if (queue_empty != (queue_level == 0))
                $fatal(1, "queue_empty disagrees with level");
            if (queue_full !=
                (integer'(queue_level) == QUEUE_DEPTH))
                $fatal(1, "queue_full disagrees with level");

            if (held_output) begin
                if (!command_valid ||
                    command_frame !== held_frame ||
                    command_timestamp !== held_timestamp ||
                    command_id !== held_command ||
                    command_parameter !== held_parameter)
                    $fatal(1, "ready/valid payload changed under backpressure");
            end

            if (command_valid && command_ready) begin
                if (expected_read >= expected_write)
                    $fatal(1, "unexpected command %02x %08x",
                           command_id, command_parameter);
                if (command_frame !== expected_frame[expected_read] ||
                    command_timestamp !==
                        expected_timestamp[expected_read] ||
                    command_id !== expected_command[expected_read] ||
                    command_parameter !==
                        expected_parameter[expected_read])
                    $fatal(1,
                        "command mismatch at %0d got f=%0d t=%0d c=%02x p=%08x expected f=%0d t=%0d c=%02x p=%08x",
                        expected_read,
                        command_frame, command_timestamp,
                        command_id, command_parameter,
                        expected_frame[expected_read],
                        expected_timestamp[expected_read],
                        expected_command[expected_read],
                        expected_parameter[expected_read]);
                expected_read = expected_read + 1;
                output_commands = output_commands + 1;
            end

            held_output = command_valid && !command_ready;
            if (command_valid && !command_ready) begin
                held_frame = command_frame;
                held_timestamp = command_timestamp;
                held_command = command_id;
                held_parameter = command_parameter;
            end
        end
    end

    integer i;
    integer choice;
    logic [31:0] random_data;
    logic [31:0] random_address;
    logic random_cpu;
    logic [1:0] random_access;

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Invalid CPU, width, alignment, and address are consumed without
        // producing geometry entries.  Wrong-width ARM9 GX traffic raises
        // only the passive sticky diagnostic.
        send_write(0, 32'h04000440, 2'b10, 32'h11111111, 1, 64'h101);
        send_write(1, 32'h04000440, 2'b01, 32'h22222222, 2, 64'h102);
        send_write(1, 32'h04000442, 2'b10, 32'h33333333, 3, 64'h103);
        send_write(1, 32'h040003fc, 2'b10, 32'h44444444, 4, 64'h104);
        repeat (3) @(posedge clk);
        if (!protocol_error)
            $fatal(1, "invalid ARM9 GX access did not set protocol_error");
        if (expected_read != 0 || command_valid)
            $fatal(1, "invalid write produced a command");

        reset_test_state();
        if (protocol_error)
            $fatal(1, "reset did not clear protocol_error");

        // Packed commands 10/12/23 consume 1/1/2 parameters.  Padding zero
        // bytes are skipped exactly as GPU3D::WriteToGXFIFO does.
        send_write(1, 32'h04000400, 2'b10, 32'h00231210, 10, 64'h1000);
        send_write(1, 32'h04000400, 2'b10, 32'h10101010, 11, 64'h1001);
        send_write(1, 32'h04000404, 2'b10, 32'h12121212, 12, 64'h1002);
        send_write(1, 32'h04000408, 2'b10, 32'h23232301, 13, 64'h1003);
        send_write(1, 32'h0400040c, 2'b10, 32'h23232302, 14, 64'h1004);

        // Zero-parameter commands use the triggering command word as their
        // normalized dummy parameter.  An all-zero packet emits one NOP,
        // while leading zero padding in a nonzero packet emits no NOP.
        send_write(1, 32'h04000400, 2'b10, 32'h00411511, 20, 64'h2000);
        send_write(1, 32'h04000400, 2'b10, 32'h00000000, 21, 64'h2001);
        send_write(1, 32'h04000400, 2'b10, 32'h00120000, 22, 64'h2002);
        send_write(1, 32'h04000400, 2'b10, 32'habcdef01, 23, 64'h2003);

        // A direct command write is independent of a partially parsed packed
        // command packet.
        send_write(1, 32'h04000400, 2'b10, 32'h00000010, 30, 64'h3000);
        send_write(1, 32'h04000480, 2'b10, 32'h20202020, 31, 64'h3001);
        send_write(1, 32'h04000400, 2'b10, 32'h1010abcd, 32, 64'h3002);

        // Multiword commands exercise the largest and test-command counts.
        send_write(1, 32'h04000400, 2'b10, 32'h00003470, 40, 64'h4000);
        for (i = 0; i < 3; i = i + 1)
            send_write(1, 32'h04000400, 2'b10,
                       32'h70000000 + i, 41 + i,
                       64'h4001 + 64'(i));
        for (i = 0; i < 32; i = i + 1)
            send_write(1, 32'h04000400, 2'b10,
                       32'h34000000 + i, 50 + i,
                       64'h4100 + 64'(i));
        wait_for_drain();
        wait_for_packed_idle();
        if (packed_active)
            $fatal(1, "directed packed stream did not return idle");

        // Fill the output queue, hold a ninth direct write while full, and
        // verify simultaneous pop/push plus stable output backpressure.
        reset_test_state();
        command_ready = 0;
        for (i = 0; i < QUEUE_DEPTH; i = i + 1)
            send_write(1, 32'h04000440 + ((i % 8) * 4), 2'b10,
                       32'hb0000000 + i, 100 + i,
                       64'h5000 + 64'(i));
        repeat (2) @(posedge clk);
        if (!queue_full ||
            integer'(queue_level) != QUEUE_DEPTH || !busy)
            $fatal(1, "direct writes did not fill queue");

        model_accept_write(
            1, 32'h04000460, 2'b10, 32'hb0000008, 108, 64'h5008);
        @(negedge clk);
        cpu_is_arm9 = 1;
        address = 32'h04000460;
        access = 2'b10;
        write_data = 32'hb0000008;
        frame = 108;
        timestamp = 64'h5008;
        write_valid = 1;
        repeat (5) begin
            @(posedge clk);
            if (write_ready)
                $fatal(1, "full queue accepted write without a pop");
        end
        @(negedge clk);
        command_ready = 1;
        @(posedge clk);
        if (!write_ready)
            $fatal(1, "simultaneous pop did not release input ready");
        accepted_writes = accepted_writes + 1;
        @(negedge clk);
        write_valid = 0;
        command_ready = 0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        command_ready = 1;
        wait_for_drain();

        // Deterministic randomized traffic interleaves packed, direct, and
        // ignored writes while independently randomizing output readiness.
        reset_test_state();
        random_backpressure = 1;
        for (i = 0; i < 600; i = i + 1) begin
            random_state =
                random_state * 32'd1664525 + 32'd1013904223;
            choice = integer'(random_state[7:0]) % 10;
            random_data =
                random_state ^
                (32'h9e3779b9 * i);
            if (choice < 5) begin
                random_cpu = 1;
                random_access = 2'b10;
                random_address = 32'h04000400 +
                    ((random_state[11:10]) * 4);
                if (model_command_count == 0)
                    random_data = random_command_word(
                        integer'(random_state[19:12]));
            end else if (choice < 8) begin
                random_cpu = 1;
                random_access = 2'b10;
                random_address = 32'h04000440 +
                    ((integer'(random_state[7:0]) % 99) * 4);
            end else if (choice == 8) begin
                random_cpu = 0;
                random_access = 2'b10;
                random_address = 32'h04000400;
            end else begin
                random_cpu = 1;
                random_access = 2'b01;
                random_address = 32'h04000440;
            end
            send_write(
                random_cpu, random_address, random_access,
                random_data, 1000 + i, 64'h100000 + 64'(i));
        end
        @(negedge clk);
        random_backpressure = 0;
        command_ready = 1;
        wait_for_drain();

        if (expected_read != expected_write)
            $fatal(1, "not all expected commands were consumed");
        $display(
            "PASS: GX command frontend packed/direct parsing, exact parameter counts, backpressure, and randomized ordering");
        $display("accepted_writes=%0d output_commands=%0d randomized_operations=600",
                 accepted_writes, output_commands);
        $finish;
    end
endmodule
