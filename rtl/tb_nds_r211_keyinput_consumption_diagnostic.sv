`timescale 1ns/1ps
`default_nettype none

module tb_nds_r211_keyinput_consumption_diagnostic;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic mailbox_request = 1'b0;
    logic [31:0] mailbox_address = 32'd0;
    logic mailbox_read_not_write = 1'b0;
    logic [1:0] mailbox_access = 2'd0;
    logic mailbox_cpu_arm9 = 1'b0;
    logic [31:0] mailbox_fence_sequence = 32'd0;
    logic mailbox_done = 1'b0;
    logic [31:0] mailbox_completed_fence_sequence = 32'd0;
    logic [31:0] cpu9_rdata = 32'd0;
    logic cpu9_done = 1'b0;
    logic cpu9_cycles_valid = 1'b0;
    logic [31:0] cpu9_debug_pc_raw = 32'd0;
    logic [11:0] joystick = 12'd0;

    logic target_active;
    logic mailbox_completion_seen;
    logic cpu_completion_seen;
    logic first_retire_seen;
    logic later_retire_seen;
    logic observer_fault_seen;
    logic witness_complete;
    logic [7:0] target_request_count;
    logic [7:0] mailbox_completion_count;
    logic [7:0] cpu_completion_count;
    logic [7:0] retirement_event_count;
    logic [7:0] abandoned_witness_count;
    logic [7:0] witness_retire_count;
    logic [11:0] request_joystick;
    logic [31:0] request_pc;
    logic [31:0] request_fence_sequence;
    logic [31:0] completion_fence_sequence;
    logic [31:0] mailbox_response;
    logic [31:0] cpu_response;
    logic [31:0] first_retire_pc;
    logic [31:0] later_retire_pc;
    logic [31:0] diagnostic_payload;
    logic completed_valid;
    logic [31:0] completed_payload;
    logic [31:0] completed_first_retire_pc;
    logic [31:0] completed_later_retire_pc;
    logic [1:0] diagnostic_phase;
    logic [7:0] diagnostic_marker;
    logic [31:0] diagnostic_snapshot;
    logic diagnostic_snapshot_strobe;
    logic [31:0] diagnostic_word;

    logic serializer_probe_complete = 1'b0;
    logic [31:0] serializer_probe_payload = 32'd0;
    logic [11:0] serializer_probe_joystick = 12'd0;
    logic [1:0] serializer_probe_phase;
    logic [7:0] serializer_probe_marker;
    logic [31:0] serializer_probe_snapshot;
    logic serializer_probe_snapshot_strobe;
    logic [31:0] serializer_probe_word;

    integer iteration;
    integer phase_index;

    always #5 clk = ~clk;

    nds_r211_keyinput_consumption_diagnostic #(
        .LATER_RETIRE_COUNT(4),
        .PHASE_DIVIDER_WIDTH(1)
    ) dut (
        .*
    );

    nds_r211_keyinput_consumption_serializer #(
        .PHASE_DIVIDER_WIDTH(1)
    ) serializer_probe (
        .clk,
        .reset,
        .witness_complete(serializer_probe_complete),
        .live_payload(serializer_probe_payload),
        .joystick(serializer_probe_joystick),
        .diagnostic_phase(serializer_probe_phase),
        .diagnostic_marker(serializer_probe_marker),
        .diagnostic_snapshot(serializer_probe_snapshot),
        .diagnostic_snapshot_strobe(serializer_probe_snapshot_strobe),
        .diagnostic_word(serializer_probe_word)
    );

    task automatic require (
        input logic condition,
        input string message
    );
        begin
            if (condition !== 1'b1)
                $fatal(1, "%s", message);
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic reset_dut;
        begin
            reset = 1'b1;
            mailbox_request = 1'b0;
            mailbox_address = 32'd0;
            mailbox_read_not_write = 1'b0;
            mailbox_access = 2'd0;
            mailbox_cpu_arm9 = 1'b0;
            mailbox_fence_sequence = 32'd0;
            mailbox_done = 1'b0;
            mailbox_completed_fence_sequence = 32'd0;
            cpu9_rdata = 32'd0;
            cpu9_done = 1'b0;
            cpu9_cycles_valid = 1'b0;
            cpu9_debug_pc_raw = 32'd0;
            joystick = 12'd0;
            serializer_probe_complete = 1'b0;
            serializer_probe_payload = 32'd0;
            serializer_probe_joystick = 12'd0;
            tick();
            tick();
            reset = 1'b0;
            tick();
        end
    endtask

    task automatic request_cycle (
        input logic [31:0] address,
        input logic read_not_write,
        input logic [1:0] access,
        input logic cpu_arm9,
        input logic [11:0] physical_joystick,
        input logic [31:0] pc
    );
        begin
            mailbox_fence_sequence =
                mailbox_fence_sequence + 1'b1;
            mailbox_address = address;
            mailbox_read_not_write = read_not_write;
            mailbox_access = access;
            mailbox_cpu_arm9 = cpu_arm9;
            joystick = physical_joystick;
            cpu9_debug_pc_raw = pc;
            mailbox_request = 1'b1;
            tick();
            mailbox_request = 1'b0;
            tick();
        end
    endtask

    task automatic mailbox_completion (
        input logic [31:0] value
    );
        begin
            cpu9_rdata = value;
            mailbox_completed_fence_sequence =
                request_fence_sequence;
            mailbox_done = 1'b1;
            tick();
            mailbox_done = 1'b0;
            tick();
        end
    endtask

    task automatic cpu_completion (
        input logic [31:0] value
    );
        begin
            cpu9_rdata = value;
            mailbox_completed_fence_sequence =
                request_fence_sequence;
            cpu9_done = 1'b1;
            tick();
            cpu9_done = 1'b0;
            tick();
        end
    endtask

    task automatic combined_completion (
        input logic [31:0] value
    );
        begin
            cpu9_rdata = value;
            mailbox_completed_fence_sequence =
                request_fence_sequence;
            mailbox_done = 1'b1;
            cpu9_done = 1'b1;
            tick();
            mailbox_done = 1'b0;
            cpu9_done = 1'b0;
            tick();
        end
    endtask

    task automatic combined_completion_fence (
        input logic [31:0] value,
        input logic [31:0] completed_fence
    );
        begin
            cpu9_rdata = value;
            mailbox_completed_fence_sequence = completed_fence;
            mailbox_done = 1'b1;
            cpu9_done = 1'b1;
            tick();
            mailbox_done = 1'b0;
            cpu9_done = 1'b0;
            tick();
        end
    endtask

    task automatic retire (
        input logic [31:0] pc
    );
        begin
            cpu9_debug_pc_raw = pc;
            cpu9_cycles_valid = 1'b1;
            tick();
            cpu9_cycles_valid = 1'b0;
            tick();
        end
    endtask

    task automatic wait_snapshot;
        integer clocks;
        begin
            tick();
            clocks = 1;
            while (!diagnostic_snapshot_strobe && clocks < 40) begin
                tick();
                clocks = clocks + 1;
            end
            require(diagnostic_snapshot_strobe,
                "atomic diagnostic snapshot timed out");
        end
    endtask

    task automatic wait_phase(input logic [1:0] wanted_phase);
        integer clocks;
        begin
            clocks = 0;
            while (diagnostic_phase != wanted_phase && clocks < 20) begin
                tick();
                clocks = clocks + 1;
            end
            require(diagnostic_phase == wanted_phase,
                "diagnostic phase timed out");
        end
    endtask

    task automatic check_atomic_rotation (
        input logic [7:0] wanted_marker,
        input logic [31:0] wanted_snapshot
    );
        logic [7:0] wanted_byte;
        begin
            require(diagnostic_marker == wanted_marker,
                "atomic marker mismatch");
            require(diagnostic_snapshot == wanted_snapshot,
                "atomic payload mismatch");
            for (phase_index = 0; phase_index < 4;
                 phase_index = phase_index + 1) begin
                wait_phase(phase_index[1:0]);
                joystick = 12'h120 + phase_index[11:0];
                #1;
                case (phase_index)
                    0: wanted_byte = wanted_snapshot[7:0];
                    1: wanted_byte = wanted_snapshot[15:8];
                    2: wanted_byte = wanted_snapshot[23:16];
                    default: wanted_byte = wanted_snapshot[31:24];
                endcase
                require(diagnostic_word[31:24] == wanted_marker,
                    "marker changed within atomic rotation");
                require(diagnostic_word[23] == 1'b0 &&
                        diagnostic_word[20] == 1'b0,
                    "reserved framing bits changed");
                require(diagnostic_word[22:21] == phase_index[1:0],
                    "serialized phase mismatch");
                require(diagnostic_word[19:12] == wanted_byte,
                    "serialized payload byte mismatch");
                require(diagnostic_word[11:0] == joystick,
                    "live physical joystick bits were not preserved");
                require(diagnostic_snapshot == wanted_snapshot,
                    "snapshot tore within one rotation");
                if (phase_index != 3) begin
                    tick();
                    wait_phase(phase_index[1:0] + 2'd1);
                end
            end
        end
    endtask

    initial begin
        reset_dut();
        joystick = 12'ha5a;
        #1;
        require(!target_active && !witness_complete &&
                target_request_count == 0 &&
                mailbox_completion_count == 0 &&
                cpu_completion_count == 0 &&
                retirement_event_count == 0 &&
                diagnostic_marker == 8'hf0 &&
                diagnostic_word[11:0] == joystick,
            "reset did not clear observer or preserve joystick");

        // Near misses must never arm the observer.
        request_cycle(32'h0400_0132, 1'b1, 2'd1, 1'b1,
                      12'h001, 32'h0204_4664);
        request_cycle(32'h0400_0130, 1'b0, 2'd1, 1'b1,
                      12'h002, 32'h0204_4664);
        request_cycle(32'h0400_0130, 1'b1, 2'd2, 1'b1,
                      12'h004, 32'h0204_4664);
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b0,
                      12'h008, 32'h0204_4664);
        require(!target_active && target_request_count == 0,
            "nearby transaction armed KEYINPUT observer");

        // Mailbox publication without the same-edge CPU completion is not
        // architectural consumption and permanently fails this reset epoch.
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                      12'h000, 32'h0204_4664);
        require(target_active && target_request_count == 1 &&
                request_pc == 32'h0204_4664 &&
                request_joystick == 12'h000 &&
                request_fence_sequence == mailbox_fence_sequence,
            "released KEYINPUT request was not captured");
        mailbox_completion(32'h0000_03ff);
        require(mailbox_completion_seen &&
                !cpu_completion_seen &&
                mailbox_response == 32'h0000_03ff &&
                diagnostic_payload[15:0] == 16'h03ff &&
                observer_fault_seen &&
                !witness_complete &&
                !completed_valid,
            "mailbox-only response did not fail closed");
        retire(32'h0204_4668);
        require(!first_retire_seen && witness_retire_count == 0,
            "pre-consumption retirement was attributed to KEYINPUT");
        wait_snapshot();
        require(diagnostic_marker == 8'hf0 &&
                diagnostic_snapshot == 32'd0,
            "completion-without-consumption did not fail closed");

        // A valid witness requires the exact same completion edge and fence.
        reset_dut();
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                      12'h000, 32'h0204_4664);
        combined_completion(32'h0000_03ff);
        require(mailbox_completion_seen &&
                cpu_completion_seen &&
                mailbox_response == 32'h0000_03ff &&
                cpu_response == 32'h0000_03ff &&
                completion_fence_sequence == request_fence_sequence &&
                !observer_fault_seen,
            "same-edge released completion did not bind exact fence/data");
        retire(32'h0204_4668);
        retire(32'h0204_466c);
        retire(32'h0204_4670);
        require(first_retire_seen && !later_retire_seen &&
                first_retire_pc == 32'h0204_4668 &&
                witness_retire_count == 3 &&
                !witness_complete,
            "first retirement or later-retirement threshold is wrong");
        retire(32'h0201_009c);
        require(later_retire_seen &&
                later_retire_pc == 32'h0201_009c &&
                witness_retire_count == 4 &&
                witness_complete &&
                diagnostic_payload == 32'hff04_03ff &&
                completed_valid &&
                completed_payload == 32'hff04_03ff &&
                completed_first_retire_pc == 32'h0204_4668 &&
                completed_later_retire_pc == 32'h0201_009c,
            "released KEYINPUT complete witness is wrong");
        wait_snapshot();
        check_atomic_rotation(8'hf1, 32'hff04_03ff);

        // A newer incomplete request must not tear the last complete sparse
        // publication. Physical A is bit 4 and returns active-low 0x03FE.
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                      12'h010, 32'h0204_4664);
        require(target_request_count == 2 && completed_valid &&
                completed_payload == 32'hff04_03ff &&
                completed_first_retire_pc == 32'h0204_4668 &&
                completed_later_retire_pc == 32'h0201_009c &&
                request_joystick == 12'h010 &&
                !mailbox_completion_seen &&
                !cpu_completion_seen &&
                !witness_complete,
            "incomplete pressed request tore frozen complete witness");
        wait_snapshot();
        check_atomic_rotation(8'hf1, 32'hff04_03ff);

        combined_completion(32'h0000_03fe);
        retire(32'h0204_4668);
        retire(32'h0204_466c);
        retire(32'h0204_4670);
        retire(32'h0201_05fc);
        require(mailbox_completion_count == 2 &&
                cpu_completion_count == 2 &&
                mailbox_response == 32'h0000_03fe &&
                cpu_response == 32'h0000_03fe &&
                first_retire_pc == 32'h0204_4668 &&
                later_retire_pc == 32'h0201_05fc &&
                witness_complete &&
                diagnostic_payload == 32'hff04_03fe &&
                completed_valid &&
                completed_payload == 32'hff04_03fe &&
                completed_first_retire_pc == 32'h0204_4668 &&
                completed_later_retire_pc == 32'h0201_05fc,
            "pressed KEYINPUT witness is wrong");
        wait_snapshot();
        check_atomic_rotation(8'hf1, 32'hff04_03fe);

        // A newer unrelated request invalidates an in-flight KEYINPUT target.
        // Its response can never be misattributed, even when both done
        // indications and enough retirement pulses follow.
        reset_dut();
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                      12'h010, 32'h0204_4664);
        request_cycle(32'h0400_0100, 1'b1, 2'd2, 1'b1,
                      12'h010, 32'h0204_4670);
        combined_completion_fence(
            32'hdead_beef, mailbox_fence_sequence);
        retire(32'h0204_4674);
        retire(32'h0204_4678);
        retire(32'h0204_467c);
        retire(32'h0204_4680);
        require(observer_fault_seen && !target_active &&
                !witness_complete && !completed_valid &&
                mailbox_completion_count == 0 &&
                cpu_completion_count == 0 &&
                mailbox_response == 32'd0 &&
                cpu_response == 32'd0,
            "interposed transaction completed KEYINPUT witness");

        // A simultaneous completion with the wrong fence is also unrelated.
        reset_dut();
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                      12'h010, 32'h0204_4664);
        combined_completion_fence(
            32'h0000_03fe, request_fence_sequence + 1'b1);
        retire(32'h0204_4668);
        retire(32'h0204_466c);
        retire(32'h0204_4670);
        retire(32'h0201_05fc);
        require(observer_fault_seen &&
                completion_fence_sequence != request_fence_sequence &&
                !witness_complete && !completed_valid,
            "wrong-fence completion produced complete witness");

        // CPU-only completion is the opposite ordering fault.
        reset_dut();
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                      12'h010, 32'h0204_4664);
        cpu_completion(32'h0000_03fe);
        require(!mailbox_completion_seen && cpu_completion_seen &&
                observer_fault_seen && !completed_valid,
            "CPU-only completion did not fail closed");

        // Once the exact target completion pair is bound, later mailbox
        // traffic is normal CPU progress and must not steal or invalidate
        // the response while the observer counts subsequent retirements.
        reset_dut();
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                      12'h010, 32'h0204_4664);
        combined_completion(32'h0000_03fe);
        retire(32'h0204_4668);
        request_cycle(32'h0400_0100, 1'b1, 2'd2, 1'b1,
                      12'h010, 32'h0204_466c);
        combined_completion_fence(
            32'hdead_beef, mailbox_fence_sequence);
        retire(32'h0204_466c);
        retire(32'h0204_4670);
        retire(32'h0201_05fc);
        require(!observer_fault_seen &&
                mailbox_response == 32'h0000_03fe &&
                cpu_response == 32'h0000_03fe &&
                completion_fence_sequence ==
                    request_fence_sequence &&
                mailbox_completion_count == 1 &&
                cpu_completion_count == 1 &&
                completed_valid &&
                completed_payload == 32'hff04_03fe &&
                completed_first_retire_pc == 32'h0204_4668 &&
                completed_later_retire_pc == 32'h0201_05fc,
            "post-completion mailbox traffic stole bound KEYINPUT witness");

        // All aggregate event counters saturate instead of wrapping.
        reset_dut();
        for (iteration = 0; iteration < 260; iteration = iteration + 1) begin
            request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                          12'h010, 32'h0204_4664);
            combined_completion(32'h0000_03fe);
            retire(32'h0204_4668);
            retire(32'h0204_466c);
            retire(32'h0204_4670);
            retire(32'h0201_05fc);
        end
        require(target_request_count == 8'hff &&
                mailbox_completion_count == 8'hff &&
                cpu_completion_count == 8'hff &&
                retirement_event_count == 8'hff,
            "aggregate event counter wrapped instead of saturating");

        // Replacing incomplete witnesses also uses a saturating counter.
        reset_dut();
        for (iteration = 0; iteration < 260; iteration = iteration + 1)
            request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                          12'h000, 32'h0204_4664);
        require(abandoned_witness_count == 8'hff &&
                target_request_count == 8'hff &&
                !witness_complete,
            "abandoned witness counter wrapped or claimed completion");

`ifndef VERILATOR
        // Four-state simulation must fail closed on an unknown returned value.
        reset_dut();
        request_cycle(32'h0400_0130, 1'b1, 2'd1, 1'b1,
                      12'h010, 32'h0204_4664);
        cpu9_rdata = 32'hxxxx_xxxx;
        mailbox_completed_fence_sequence =
            request_fence_sequence;
        mailbox_done = 1'b1;
        cpu9_done = 1'b1;
        tick();
        mailbox_done = 1'b0;
        cpu9_done = 1'b0;
        cpu9_rdata = 32'd0;
        retire(32'h0204_4668);
        retire(32'h0204_466c);
        retire(32'h0204_4670);
        retire(32'h0201_05fc);
        require(observer_fault_seen && !witness_complete &&
                !completed_valid &&
                diagnostic_payload[0] == 1'b0,
            "unknown response did not fail closed");
        wait_snapshot();
        require(diagnostic_marker == 8'hf0,
            "unknown response emitted complete F1 marker");

        // The serializer is independently fail closed: even a claimed
        // complete witness cannot emit F1 around an unknown payload.
        reset_dut();
        serializer_probe_complete = 1'b1;
        serializer_probe_payload = 32'hxxxx_xxxx;
        serializer_probe_joystick = 12'h010;
        iteration = 0;
        while (!serializer_probe_snapshot_strobe &&
               iteration < 40) begin
            tick();
            iteration = iteration + 1;
        end
        require(serializer_probe_snapshot_strobe &&
                serializer_probe_marker == 8'hf0 &&
                serializer_probe_snapshot == 32'd0,
            "unknown serializer payload emitted complete F1 marker");
`endif

        $display("PASS: r211 KEYINPUT observer distinguishes mailbox publication, CPU consumption, and later ARM9 retirement with atomic F0/F1 transport");
        $finish;
    end
endmodule

`default_nettype wire
