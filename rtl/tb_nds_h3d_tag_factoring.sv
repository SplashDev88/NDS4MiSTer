`timescale 1ps/1ps
// Exercise the actual production match wires against the original unfactored
// predicate. Four distinct 32-bit values cover every three-way equality
// partition; independent session/frame partitions and eligibility bits are
// exhausted. No clocks run: this test concerns only combinational predicates.
module tb_nds_h3d_tag_factoring;
    logic [31:0] session_value, merge_value;
    nds_h3d_plane_reader dut(
        .ddr_clk(1'b0), .ddr_reset(1'b0),
        .pixel_clk(1'b0), .pixel_reset(1'b0),
        .pixel_session(session_value), .merge_frame(merge_value),
        .merge_y(8'd17), .scanline_tick(1'b0), .line_start(1'b0));
    function automatic [31:0] value(input integer n);
        case (n & 3)
            0: value=32'h00000000;
            1: value=32'h80000000;
            2: value=32'hffffffff;
            3: value=32'h7fff0001;
        endcase
    endfunction
    integer sessions, frames, flags, bank, checks=0;
    logic expected_current, expected_hit;
    logic [2:0] actual_current, actual_hit;
    always_comb begin
        actual_current={dut.bank2_tag_current,dut.bank1_tag_current,dut.bank0_tag_current};
        actual_hit={dut.line_start_hit2,dut.line_start_hit1,dut.line_start_hit0};
    end
    initial begin
        for (sessions=0;sessions<64;sessions=sessions+1)
        for (frames=0;frames<64;frames=frames+1)
        for (flags=0;flags<64;flags=flags+1) begin
            session_value=value(sessions>>2);
            dut.pixel_descriptor_session=value(sessions>>4);
            dut.pixel_descriptor_frame=value(frames>>2);
            merge_value=value(frames>>4);
            dut.pixel_descriptor_sequence=32'h80123456;
            dut.pixel_descriptor_bank=flags[5];
            dut.pixel_descriptor_valid=flags[1];
            for (bank=0;bank<3;bank=bank+1) begin
                dut.bank_available_pixel[bank]=flags[0];
                dut.bank_tag_session_pixel[bank]=value(sessions+bank);
                dut.bank_tag_frame_pixel[bank]=value(frames+bank);
                dut.bank_tag_sequence_pixel[bank]=flags[2] ? 32'h80123456 : 32'h00123456;
                dut.bank_tag_source_pixel[bank]=flags[3];
                dut.bank_tag_y_pixel[bank]=flags[4] ? 8'd17 : 8'd18;
            end
            #1;
            for (bank=0;bank<3;bank=bank+1) begin
                expected_current=dut.bank_available_pixel[bank] && dut.pixel_descriptor_valid &&
                    dut.bank_tag_sequence_pixel[bank]==dut.pixel_descriptor_sequence &&
                    dut.bank_tag_session_pixel[bank]==session_value &&
                    dut.bank_tag_session_pixel[bank]==dut.pixel_descriptor_session &&
                    dut.bank_tag_frame_pixel[bank]==dut.pixel_descriptor_frame &&
                    dut.bank_tag_source_pixel[bank]==dut.pixel_descriptor_bank;
                expected_hit=expected_current &&
                    dut.bank_tag_frame_pixel[bank]==merge_value &&
                    dut.bank_tag_y_pixel[bank]==8'd17;
                if (actual_current[bank] !== expected_current || actual_hit[bank] !== expected_hit)
                    $fatal(1,"tag factoring differs from original: sessions=%0d frames=%0d flags=%0d bank=%0d",sessions,frames,flags,bank);
                checks=checks+1;
            end
        end
        $display("PASS: production tag factoring equals original predicates (%0d bank cases)",checks);
        $finish;
    end
endmodule
