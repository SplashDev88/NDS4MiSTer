// SPDX-License-Identifier: GPL-3.0-or-later
// Compact cartridge game-code -> save-device lookup.
//
// The public melonDS ROMList is the oracle.  SaveMemType 1 (512-byte tiny
// EEPROM) is the default; the table stores explicit no-save entries and types
// 2..7, so all regular EEPROM/FRAM-compatible and flash cartridges fit in ROM.
// A linear walk costs at most 4096 clocks during the much longer boot loader
// pass and avoids a large parallel comparator tree in the 98%-full ALM fabric.
module nds_nitro_save_profile #(
    parameter integer ENTRY_COUNT = 4057
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] game_code,
    output logic        busy,
    output logic        valid,
    output logic [3:0]  save_type
);
    (* ramstyle = "M10K" *) logic [35:0] profile_rom [0:4095];
    logic [11:0] index;
    logic [35:0] entry;
    logic [31:0] target;
    logic publish_pending;

    // Keep this a literal for Quartus 17.0: its mixed VHDL/SystemVerilog
    // elaborator rejects a string parameter passed through a VHDL component.
    initial $readmemh("nds_save_profiles.hex", profile_rom);

    always_ff @(posedge clk) begin
        entry <= profile_rom[index];

        if (reset) begin
            index <= '0;
            target <= '0;
            busy <= 1'b0;
            valid <= 1'b0;
            save_type <= 4'd0;
            publish_pending <= 1'b0;
        end else if (start) begin
            index <= '0;
            target <= game_code;
            busy <= 1'b1;
            valid <= 1'b0;
            save_type <= 4'd1;
            publish_pending <= 1'b0;
        end else if (publish_pending) begin
            // save_type crosses to clk_video as a bundled payload.  Publish
            // valid only after the payload has been stable for a complete
            // clk1x cycle so the destination's equal-depth synchronizers can
            // never observe valid with the previous cartridge's type.
            publish_pending <= 1'b0;
            valid <= 1'b1;
        end else if (busy) begin
            if (entry[35:4] == target && entry[3:0] <= 4'd7) begin
                save_type <= entry[3:0];
                busy <= 1'b0;
                publish_pending <= 1'b1;
            // entry is the synchronous ROM result from the prior index cycle;
            // wait one extra count so the final populated row is compared.
            end else if (index == ENTRY_COUNT) begin
                // Codes absent from the compact table use tiny EEPROM, which
                // is melonDS's most common nonzero save profile.  The two local
                // homebrew test codes are explicitly no-save.
                if (target == 32'h4553424b || target == 32'h23232323)
                    save_type <= 4'd0;
                else
                    save_type <= 4'd1;
                busy <= 1'b0;
                publish_pending <= 1'b1;
            end else begin
                index <= index + 1'b1;
            end
        end
    end
endmodule
