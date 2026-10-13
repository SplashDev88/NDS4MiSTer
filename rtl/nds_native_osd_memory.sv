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
    output reg [7:0] digital_q,
    input wire analog_read,
    input wire [12:0] analog_address,
    output reg [7:0] analog_q
);
    // The non-MENU core has 4096 addressable bitmap bytes. Bit12 must be
    // retained until validity is checked, so out-of-range SPI writes do not
    // alias the valid bitmap. Out-of-range reads are undefined, as before.
    (* ramstyle = "no_rw_check" *) reg [7:0] bitmap[0:4095];
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
        if (digital_read) digital_q <= bitmap[digital_address[11:0]];
        if (analog_read) analog_q <= bitmap[port_b_address];
        else if (take && !front[20]) bitmap[port_b_address] <= front[7:0];
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
