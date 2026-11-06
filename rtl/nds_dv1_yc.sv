// SPDX-License-Identifier: GPL-3.0-or-later
// Encode the independently selected DV1 picture, after its OSD. The analog
// encoder remains dedicated to the analog picture. No framebuffer is added.
module nds_dv1_yc (
    input clk,
    input native_dv1, crt_target, crt_raster, split_active, yc_enable, cvbs,
    input pal_enable,
    input [39:0] phase_inc,
    input [16:0] burst_range,
    input [23:0] rgb, analog_yc,
    input hs, vs, cs, de,
    input analog_hs, analog_vs, analog_cs,
    output [23:0] data_out,
    output hs_out, vs_out, cs_out,
    output independent_yc
);
    wire [23:0] digital_yc;
    wire digital_hs, digital_vs, digital_cs;
    // The first experiment adds separate Y/C only. The active adapter mixes
    // composite externally. Preserve the pre-existing shared CVBS path.
    assign independent_yc = native_dv1 && crt_target && crt_raster &&
                            split_active && yc_enable && !cvbs;
    yc_out digital_encoder (
        .clk(clk), .PAL_EN(pal_enable), .CVBS(1'b0),
        .PHASE_INC(phase_inc), .COLORBURST_RANGE(burst_range),
        .din(rgb), .hsync(hs), .vsync(vs), .csync(cs), .de(de),
        .dout(digital_yc), .hsync_o(digital_hs), .vsync_o(digital_vs),
        .csync_o(digital_cs), .de_o()
    );
    assign {data_out, hs_out, vs_out, cs_out} = independent_yc
        ? {digital_yc, digital_hs, digital_vs, digital_cs}
        : (!split_active && yc_enable)
        ? {analog_yc, analog_hs, analog_vs, analog_cs}
        : {rgb, hs, vs, cs};
endmodule
