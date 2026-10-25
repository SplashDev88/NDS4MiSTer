// SPDX-License-Identifier: GPL-3.0-or-later
// Native NDS OSD: same-clock, two-reader bitmap shared by both rasters.
// NDS4MiSTer drives HPS_BUS[36] and CLK_VIDEO from the same60MHz clk_sys.
// Do not reuse this module across independent HPS/video clocks.
// Port A is dedicated to digital; port B alternates analog and writes.
module nds_native_osd_memory (
    input wire clk,
    input wire write_enable,
    input wire [12:0] write_address,
    input wire [7:0] write_data,
    output wire busy,
    input wire digital_read,
    input wire [12:0] digital_address,
    output wire [7:0] digital_q,
    output wire [7:0] digital_pair_q,
    input wire analog_read,
    input wire [12:0] analog_address,
    output wire [7:0] analog_q
);
    // The non-MENU core has 4096 addressable bitmap bytes. Bit12 must be
    // retained until validity is checked, so out-of-range SPI writes do not
    // alias the valid bitmap. Out-of-range reads are undefined, as before.
    // Even/odd columns use two byte-wide banks, retaining the same 4 KiB.
    // Each bank has the original true-dual-port read/write pattern, so
    // Quartus can infer M10Ks without unsupported partial-word writes.
    // Both columns arrive together without another video pipeline stage.
    (* ramstyle = "no_rw_check" *) reg [7:0] bitmap_even[0:2047];
    (* ramstyle = "no_rw_check" *) reg [7:0] bitmap_odd[0:2047];
    reg [7:0] digital_even, digital_odd, analog_even, analog_odd;
    reg digital_lane, analog_lane;
    assign digital_q = digital_lane ? digital_odd : digital_even;
    assign digital_pair_q = digital_lane ? digital_even : digital_odd;
    assign analog_q = analog_lane ? analog_odd : analog_even;
    reg [20:0] queued0,queued1,queued2,queued3;
    reg [1:0] wp=0,rp=0;
    reg [2:0] count=0;
    wire take = !analog_read && count != 0;
    wire accept = write_enable && (count != 4 || take);
    wire [20:0] front = rp[1] ? (rp[0] ? queued3 : queued2) : (rp[0] ? queued1 : queued0);
    wire [11:0] port_b_address = analog_read ? analog_address[11:0] : front[19:8];
    // Leave two entries for the accepted word and acknowledgement pipeline.
    assign busy = count >= 2;
    always @(posedge clk) begin
        if (digital_read) begin
            digital_even <= bitmap_even[digital_address[11:1]];
            digital_odd <= bitmap_odd[digital_address[11:1]];
            digital_lane <= digital_address[0];
        end
        if (analog_read) begin
            analog_even <= bitmap_even[port_b_address[11:1]];
            analog_odd <= bitmap_odd[port_b_address[11:1]];
            analog_lane <= port_b_address[0];
        end else if (take && !front[20]) begin
            if (port_b_address[0]) bitmap_odd[port_b_address[11:1]] <= front[7:0];
            else bitmap_even[port_b_address[11:1]] <= front[7:0];
        end
        if (accept) begin
            case(wp)
                0: queued0 <= {write_address,write_data};
                1: queued1 <= {write_address,write_data};
                2: queued2 <= {write_address,write_data};
                3: queued3 <= {write_address,write_data};
            endcase
            wp <= wp + 1'b1;
        end
        if (take) rp <= rp + 1'b1;
        case ({accept,take})
            2'b10: count <= count+1'b1;
            2'b01: count <= count-1'b1;
            default: ;
        endcase
    end
`ifndef SYNTHESIS
    always @(posedge clk)
        if(write_enable && !accept) $fatal(1,"OSD write FIFO overflow");
`endif
endmodule
