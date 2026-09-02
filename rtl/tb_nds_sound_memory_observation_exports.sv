`timescale 1ns/1ps
`default_nettype none

// Focused host-simulator model of the ownership portion of the VHDL
// nds_dual_cpu_bus.  The memory system below is the real production RTL; this
// shim only holds each selected CPU request until its real completion.
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
    logic owner_active;
    logic owner_arm9;

    assign arm9_rdata = ext_rdata;
    assign arm7_rdata = ext_rdata;
    assign arm9_done = owner_active && owner_arm9 && ext_done;
    assign arm7_done = owner_active && !owner_arm9 && ext_done;
    assign ext_ena = owner_active;
    assign ext_cpu_is_arm9 = owner_arm9;

    always_ff @(posedge clk) begin
        if (reset) begin
            owner_active <= 1'b0;
            owner_arm9 <= 1'b0;
            ext_addr <= 32'd0;
            ext_rnw <= 1'b1;
            ext_acc <= 2'd0;
            ext_wdata <= 32'd0;
            ext_debug_pc <= 32'd0;
        end else if (!owner_active) begin
            if (arm9_ena) begin
                owner_active <= 1'b1;
                owner_arm9 <= 1'b1;
                ext_addr <= arm9_addr;
                ext_rnw <= arm9_rnw;
                ext_acc <= arm9_acc;
                ext_wdata <= arm9_wdata;
                ext_debug_pc <= arm9_debug_pc;
            end else if (arm7_ena) begin
                owner_active <= 1'b1;
                owner_arm9 <= 1'b0;
                ext_addr <= arm7_addr;
                ext_rnw <= arm7_rnw;
                ext_acc <= arm7_acc;
                ext_wdata <= arm7_wdata;
                ext_debug_pc <= arm7_debug_pc;
            end
        end else if (ext_done) begin
            owner_active <= 1'b0;
        end
    end
endmodule

module tb_nds_sound_memory_observation_exports;
    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7 = 29'h001a0000;
    localparam logic [28:0] ORACLE = 29'h00200000;
    // The bridge intentionally exposes the production ring base rather than
    // a test override, so observe the real default here.
    localparam logic [28:0] POSTED = 29'h05806000;
    localparam integer TIME_FLUSH = 64;

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic [7:0] arm9_cycles = 8'd0;
    logic arm9_cycles_valid = 1'b0;
    logic [7:0] arm7_cycles = 8'd0;
    logic arm7_cycles_valid = 1'b0;
    logic [31:0] arm9_debug_pc = 32'h02001234;
    logic [31:0] arm7_debug_pc = 32'h037f8120;

    logic [31:0] arm9_addr = 32'd0;
    logic arm9_rnw = 1'b1;
    logic arm9_ena = 1'b0;
    logic [1:0] arm9_acc = 2'b10;
    logic [31:0] arm9_wdata = 32'd0;
    logic [31:0] arm9_rdata;
    logic arm9_done;
    logic arm9_irq;
    logic arm9_halt;

    logic [31:0] arm7_addr = 32'd0;
    logic arm7_rnw = 1'b1;
    logic arm7_ena = 1'b0;
    logic [1:0] arm7_acc = 2'b10;
    logic [31:0] arm7_wdata = 32'd0;
    logic [31:0] arm7_rdata;
    logic arm7_done;
    logic arm7_irq;
    logic arm7_halt;
    logic cpu_pause;

    logic debug_ext_ena;
    logic debug_ext_cpu_is_arm9;
    logic [31:0] debug_ext_address;
    logic debug_ext_done;
    logic debug_oracle_request;
    logic debug_mailbox_request;
    logic debug_mailbox_done;
    logic [3:0] debug_mailbox_state;
    logic [1:0] debug_tick_state;

    logic sound_mailbox_explicit_launch;
    logic sound_mailbox_request;
    logic [3:0] sound_mailbox_debug_state;
    logic sound_mailbox_cpu_arm9;
    logic [31:0] sound_mailbox_elapsed_cycles;
    logic [31:0] sound_mailbox_fence_sequence;
    logic [31:0] sound_mailbox_address;
    logic sound_mailbox_read_not_write;
    logic [1:0] sound_mailbox_access;
    logic [31:0] sound_mailbox_write_data;
    logic sound_mailbox_done;
    logic [31:0] sound_mailbox_completed_fence_sequence;
    logic sound_posted_request;
    logic sound_posted_active;
    logic sound_posted_accepted;
    logic sound_posted_sequence_exhausted;
    logic [31:0] sound_posted_producer_sequence;
    logic sound_posted_cpu_arm9;
    logic [31:0] sound_posted_elapsed_cycles;
    logic [1:0] sound_live_wramcnt;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy = 1'b0;
    logic ddram_command_accepted;
    logic [63:0] ddram_read_data = 64'd0;
    logic ddram_read_data_ready = 1'b0;

    logic [63:0] mailbox_words [0:4];
    logic [63:0] posted [0:31];
    logic second_response_pending = 1'b0;
    integer mailbox_launch_count = 0;
    integer mailbox_done_count = 0;
    integer posted_launch_count = 0;
    integer posted_accept_count = 0;
    integer index;

    assign ddram_command_accepted =
        (ddram_read || ddram_write) && !ddram_busy;

    nds_dual_cpu_memory_bridge #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7),
        .ORACLE_BASE_WORD(ORACLE),
        .ORACLE_POLL_DELAY_CYCLES(1),
        .TIME_FLUSH_CYCLES(TIME_FLUSH)
    ) dut (
        .clk,
        .reset,
        .transport_reset(reset),
        .arm9_cycles,
        .arm9_cycles_valid,
        .arm7_cycles,
        .arm7_cycles_valid,
        .arm9_debug_pc,
        .arm7_debug_pc,
        .arm9_dtcm_region(32'h0300000a),
        .arm9_dtcm_enable(1'b1),
        .arm9_dtcm_seed_valid(1'b1),
        .arm9_dtcm_irq_vector(32'h01ffd5ec),
        .arm9_addr,
        .arm9_rnw,
        .arm9_ena,
        .arm9_acc,
        .arm9_wdata,
        .arm9_rdata,
        .arm9_done,
        .arm9_irq,
        .arm9_halt,
        .arm7_addr,
        .arm7_rnw,
        .arm7_ena,
        .arm7_acc,
        .arm7_wdata,
        .arm7_rdata,
        .arm7_done,
        .arm7_irq,
        .arm7_halt,
        .cpu_pause,
        .debug_ext_ena,
        .debug_ext_cpu_is_arm9,
        .debug_ext_address,
        .debug_ext_done,
        .debug_oracle_request,
        .debug_mailbox_request,
        .debug_mailbox_done,
        .debug_mailbox_state,
        .debug_tick_state,
        .sound_mailbox_explicit_launch,
        .sound_mailbox_request,
        .sound_mailbox_debug_state,
        .sound_mailbox_cpu_arm9,
        .sound_mailbox_elapsed_cycles,
        .sound_mailbox_fence_sequence,
        .sound_mailbox_address,
        .sound_mailbox_read_not_write,
        .sound_mailbox_access,
        .sound_mailbox_write_data,
        .sound_mailbox_done,
        .sound_mailbox_completed_fence_sequence,
        .sound_posted_request,
        .sound_posted_active,
        .sound_posted_accepted,
        .sound_posted_sequence_exhausted,
        .sound_posted_producer_sequence,
        .sound_posted_cpu_arm9,
        .sound_posted_elapsed_cycles,
        .sound_live_wramcnt,
        .ddram_read,
        .ddram_write,
        .ddram_burst_count,
        .ddram_address,
        .ddram_write_data,
        .ddram_byte_enable,
        .ddram_busy,
        .ddram_read_data,
        .ddram_read_data_ready,
        .ddram_command_accepted
    );

    // Minimal HPS-visible DDR responder.  It accepts every command
    // immediately, stores the real mailbox/ring beats, and returns one
    // matching two-beat mailbox response.
    always_ff @(posedge clk) begin
        ddram_read_data_ready <= 1'b0;
        if (ddram_write &&
            ddram_address >= ORACLE && ddram_address <= ORACLE + 4)
            mailbox_words[ddram_address - ORACLE] <= ddram_write_data;
        if (ddram_write &&
            ddram_address >= POSTED && ddram_address < POSTED + 32)
            posted[ddram_address - POSTED] <= ddram_write_data;

        if (ddram_read && ddram_address == ORACLE + 3) begin
            ddram_read_data_ready <= 1'b1;
            ddram_read_data <= {
                mailbox_words[0][63:32], 32'hfeedc0de
            };
            second_response_pending <= 1'b1;
        end else if (second_response_pending) begin
            ddram_read_data_ready <= 1'b1;
            ddram_read_data <= 64'h0000000000000000;
            second_response_pending <= 1'b0;
        end
    end

    // These equalities cover every cycle, not only the directed samples, and
    // prove that the bridge exports are transparent copies of the real
    // memory-system observation points.
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (sound_mailbox_request !== debug_mailbox_request ||
                sound_mailbox_done !== debug_mailbox_done ||
                sound_mailbox_debug_state !== debug_mailbox_state)
                $fatal(1, "bridge mailbox observation was not transparent");
            if (sound_mailbox_explicit_launch) begin
                mailbox_launch_count <= mailbox_launch_count + 1;
                if (!sound_mailbox_request ||
                    sound_mailbox_debug_state != 4'd0)
                    $fatal(1, "mailbox launch was not the IDLE request edge");
            end
            if (sound_mailbox_done)
                mailbox_done_count <= mailbox_done_count + 1;
            if (sound_posted_request && !sound_posted_active)
                posted_launch_count <= posted_launch_count + 1;
            if (sound_posted_accepted)
                posted_accept_count <= posted_accept_count + 1;
        end
    end

    task automatic add_arm9_cycles(input logic [7:0] cycles);
        begin
            @(negedge clk);
            arm9_cycles = cycles;
            arm9_cycles_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            arm9_cycles_valid = 1'b0;
            arm9_cycles = 8'd0;
        end
    endtask

    task automatic add_arm7_cycles(input logic [7:0] cycles);
        begin
            @(negedge clk);
            arm7_cycles = cycles;
            arm7_cycles_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            arm7_cycles_valid = 1'b0;
            arm7_cycles = 8'd0;
        end
    endtask

    initial begin : timeout_guard
        repeat (2500) @(posedge clk);
        $fatal(1,
            "timeout mailbox_launch=%0d done=%0d posted_launch=%0d accept=%0d",
            mailbox_launch_count, mailbox_done_count,
            posted_launch_count, posted_accept_count);
    end

    initial begin : directed_test
        for (index = 0; index < 5; index = index + 1)
            mailbox_words[index] = 64'd0;
        for (index = 0; index < 32; index = index + 1)
            posted[index] = 64'd0;

        repeat (4) @(posedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (sound_live_wramcnt != 2'd3 ||
            sound_mailbox_request || sound_posted_active ||
            sound_posted_sequence_exhausted)
            $fatal(1, "reset observation state was not passive");

        // A pure timing tick must expose the exact synthetic mailbox payload,
        // selected CPU, elapsed cycles, empty posted fence, and completion.
        add_arm9_cycles(TIME_FLUSH);
        wait (sound_mailbox_explicit_launch);
        #1;
        if (!sound_mailbox_request ||
            sound_mailbox_debug_state != 4'd0 ||
            !sound_mailbox_cpu_arm9 ||
            sound_mailbox_elapsed_cycles != TIME_FLUSH ||
            sound_mailbox_fence_sequence != 32'd0 ||
            sound_mailbox_address != 32'hffffffff ||
            !sound_mailbox_read_not_write ||
            sound_mailbox_access != 2'b10 ||
            sound_mailbox_write_data != arm9_debug_pc)
            $fatal(1,
                "timing launch metadata cpu=%b cycles=%h fence=%h addr=%h rnw=%b acc=%b data=%h",
                sound_mailbox_cpu_arm9,
                sound_mailbox_elapsed_cycles,
                sound_mailbox_fence_sequence,
                sound_mailbox_address,
                sound_mailbox_read_not_write,
                sound_mailbox_access,
                sound_mailbox_write_data);
        wait (sound_mailbox_done);
        #1;
        if (sound_mailbox_completed_fence_sequence != 32'd0)
            $fatal(1, "timing completion fence was not zero");
        wait (!sound_mailbox_request);
        wait (sound_mailbox_debug_state == 4'd0);
        wait (!cpu_pause);

        // Launch one real posted write between the timing tick and the sound
        // write.  The observer must retain the launch CPU/cycle metadata
        // while acceptance still reports the old producer frontier.
        add_arm9_cycles(8'd13);
        @(negedge clk);
        arm9_addr = 32'h0600c000;
        arm9_rnw = 1'b0;
        arm9_acc = 2'b01;
        arm9_wdata = 32'h00001234;
        arm9_ena = 1'b1;
        wait (sound_posted_request && !sound_posted_active);
        #1;
        if (!sound_posted_cpu_arm9 ||
            sound_posted_elapsed_cycles != 32'd13 ||
            sound_posted_producer_sequence != 32'd0 ||
            cpu_pause)
            $fatal(1,
                "posted launch metadata cpu=%b cycles=%h frontier=%h pause=%b",
                sound_posted_cpu_arm9,
                sound_posted_elapsed_cycles,
                sound_posted_producer_sequence,
                cpu_pause);
        wait (sound_posted_accepted);
        #1;
        if (!sound_posted_active ||
            sound_posted_producer_sequence != 32'd0 ||
            sound_posted_sequence_exhausted)
            $fatal(1, "posted acceptance/frontier mismatch");
        wait (arm9_done);
        #1;
        if (sound_posted_producer_sequence != 32'd1)
            $fatal(1, "posted producer frontier did not commit");
        @(negedge clk);
        arm9_ena = 1'b0;
        wait (!arm9_done);
        wait (!sound_posted_active);
        if (posted[8] != 64'h000012340600c000 ||
            posted[9] != 64'h0000000a0000000d ||
            posted[10] != 64'h0000000000000001)
            $fatal(1, "real posted ring payload was altered %h %h %h",
                posted[8], posted[9], posted[10]);

        // The following ARM7 sound-register write must carry the posted
        // frontier as its mailbox fence.  All metadata is sampled from the
        // actual mailbox launch wires, including the unmodified write payload.
        add_arm7_cycles(8'd27);
        @(negedge clk);
        arm7_addr = 32'h04000400;
        arm7_rnw = 1'b0;
        arm7_acc = 2'b10;
        arm7_wdata = 32'h81234567;
        arm7_ena = 1'b1;
        wait (sound_mailbox_explicit_launch);
        #1;
        if (sound_mailbox_cpu_arm9 ||
            sound_mailbox_elapsed_cycles != 32'd27 ||
            sound_mailbox_fence_sequence != 32'd1 ||
            sound_mailbox_address != 32'h04000400 ||
            sound_mailbox_read_not_write ||
            sound_mailbox_access != 2'b10 ||
            sound_mailbox_write_data != 32'h81234567)
            $fatal(1,
                "ARM7 sound launch metadata cpu=%b cycles=%h fence=%h addr=%h rnw=%b acc=%b data=%h",
                sound_mailbox_cpu_arm9,
                sound_mailbox_elapsed_cycles,
                sound_mailbox_fence_sequence,
                sound_mailbox_address,
                sound_mailbox_read_not_write,
                sound_mailbox_access,
                sound_mailbox_write_data);
        wait (sound_mailbox_done);
        #1;
        if (sound_mailbox_completed_fence_sequence != 32'd1)
            $fatal(1, "sound completion lost the posted fence");
        wait (arm7_done);
        @(negedge clk);
        arm7_ena = 1'b0;
        wait (!arm7_done);
        wait (!sound_mailbox_request);
        wait (sound_mailbox_debug_state == 4'd0);

        // WRAMCNT is exported from the acknowledged internal mirror, not the
        // live CPU write bus.  It must remain at mode 3 throughout launch and
        // change only after the real mailbox completion is consumed.
        @(negedge clk);
        arm9_addr = 32'h04000247;
        arm9_rnw = 1'b0;
        arm9_acc = 2'b00;
        arm9_wdata = 32'h00000002;
        arm9_ena = 1'b1;
        wait (sound_mailbox_explicit_launch);
        #1;
        if (!sound_mailbox_cpu_arm9 ||
            sound_mailbox_address != 32'h04000247 ||
            sound_mailbox_access != 2'b00 ||
            sound_mailbox_write_data != 32'h00000002 ||
            sound_mailbox_fence_sequence != 32'd1 ||
            sound_live_wramcnt != 2'd3)
            $fatal(1, "WRAMCNT launch observation mismatch");
        wait (sound_mailbox_done);
        #1;
        if (sound_live_wramcnt != 2'd3 ||
            sound_mailbox_completed_fence_sequence != 32'd1)
            $fatal(1, "WRAMCNT changed before completion was consumed");
        @(posedge clk);
        #1;
        if (sound_live_wramcnt != 2'd2)
            $fatal(1, "acknowledged WRAMCNT mirror did not update");
        @(negedge clk);
        arm9_ena = 1'b0;
        wait (!arm9_done);
        wait (!sound_mailbox_request);
        wait (sound_mailbox_debug_state == 4'd0);
        repeat (3) @(posedge clk);

        if (mailbox_launch_count != 3 ||
            mailbox_done_count != 3 ||
            posted_launch_count != 1 ||
            posted_accept_count != 1 ||
            sound_posted_sequence_exhausted)
            $fatal(1,
                "observation event counts launch=%0d done=%0d posted=%0d accepted=%0d exhausted=%b",
                mailbox_launch_count,
                mailbox_done_count,
                posted_launch_count,
                posted_accept_count,
                sound_posted_sequence_exhausted);

        $display(
            "PASS: real memory-system sound exports preserve exact timing, mailbox, posted-fence, and acknowledged WRAMCNT events");
        $finish;
    end
endmodule

`default_nettype wire
