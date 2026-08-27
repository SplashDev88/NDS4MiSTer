`timescale 1ns/1ps
`default_nettype none

module tb_nds_sound_lw_diagnostic_registers;
    logic [18:0] reg_raddr;
    logic [31:0] transport_rdata;
    logic [31:0] ownership_predicates;
    logic [7:0] supervisor_status;
    logic [7:0] fault_code;
    logic [3:0] sample_unsupported_reason;
    logic sample_unsupported_request;
    logic sample_unsupported_seen;
    logic sample_protocol_error;
    logic terminal_fault;
    logic output_controls_valid;
    logic candidate_healthy;
    logic infrastructure_healthy;
    logic fpga_audio_supported;
    logic fpga_audio_valid;
    logic fallback_required;
    logic supervisor_takeover;
    logic final_audio_takeover;
    logic signed [15:0] raw_audio_left;
    logic signed [15:0] raw_audio_right;
    logic signed [15:0] post_audio_left;
    logic signed [15:0] post_audio_right;
    logic signed [15:0] final_audio_left;
    logic signed [15:0] final_audio_right;
    logic [31:0] cause_word;
    logic [31:0] activity_word;
    logic [31:0] boot_generation;
    logic [31:0] shadow_active_epoch;
    logic [31:0] reg_rdata;

    nds_sound_lw_diagnostic_registers dut (.*);

    task automatic expect_read(
        input logic [18:0] address,
        input logic [31:0] expected,
        input string label
    );
        begin
            reg_raddr = address;
            #1;
            if (reg_rdata !== expected)
                $fatal(1, "%s: got %08x expected %08x",
                    label, reg_rdata, expected);
        end
    endtask

    initial begin
        transport_rdata = 32'ha5a55a5a;
        ownership_predicates = 32'h12345678;
        supervisor_status = 8'ha5;
        fault_code = 8'h3c;
        sample_unsupported_reason = 4'hd;
        sample_unsupported_request = 1'b1;
        sample_unsupported_seen = 1'b0;
        sample_protocol_error = 1'b1;
        terminal_fault = 1'b0;
        output_controls_valid = 1'b1;
        candidate_healthy = 1'b0;
        infrastructure_healthy = 1'b1;
        fpga_audio_supported = 1'b0;
        fpga_audio_valid = 1'b1;
        fallback_required = 1'b0;
        supervisor_takeover = 1'b1;
        final_audio_takeover = 1'b0;
        raw_audio_left = 16'sh8123;
        raw_audio_right = 16'sh4567;
        post_audio_left = 16'sh89ab;
        post_audio_right = 16'shcdef;
        final_audio_left = 16'sh1357;
        final_audio_right = 16'sh2468;
        cause_word = 32'h0102fefe;
        activity_word = 32'h10203040;
        boot_generation = 32'h11223344;
        shadow_active_epoch = 32'h55667788;

        expect_read(19'h000, 32'ha5a55a5a, "mailbox status forwarded");
        expect_read(19'h00c, 32'ha5a55a5a, "mailbox session forwarded");
        expect_read(19'h00d, 32'h41554431, "diagnostic magic");
        expect_read(19'h00e, 32'h12345678, "ownership predicates");
        expect_read(19'h00f, 32'ha53cdaaa, "detail flags");
        expect_read(19'h010, 32'h81234567, "raw audio");
        expect_read(19'h011, 32'h89abcdef, "post audio");
        expect_read(19'h012, 32'h13572468, "final audio");
        expect_read(19'h013, 32'h0102fefe, "cause");
        expect_read(19'h014, 32'h10203040, "activity");
        expect_read(19'h015, 32'h11223344, "boot generation");
        expect_read(19'h016, 32'h55667788, "sound epoch");
        expect_read(19'h017, 32'ha5a55a5a, "first unmapped word forwarded");
        expect_read(19'h7ffff, 32'ha5a55a5a, "last unmapped word forwarded");

        transport_rdata = 32'hdeadbeef;
        expect_read(19'h006, 32'hdeadbeef, "live mailbox data forwarded");
        expect_read(19'h00d, 32'h41554431, "diagnostic independent of transport");

        $display("PASS: passive LW audio diagnostics preserve mailbox reads and expose every ownership seam");
        $finish;
    end
endmodule

`default_nettype wire
