// SPDX-License-Identifier: GPL-3.0-or-later
// Compact cartridge game-code -> save-device lookup.
//
// The public melonDS ROMList is the oracle. SaveMemType 1 (512-byte tiny
// EEPROM) is the default; the table stores explicit no-save entries and types
// 2..7. A 35-bit prefix payload identifies one short bucket in a 20-bit low-code
// ROM. It is held in a 36-bit array because $readmemh treats each nine-digit hex
// token as 36 bits; bit 35 is a generated zero pad. This avoids 512 misleading
// Quartus truncation warnings without changing the two-M10K physical shape. The
// largest generated bucket is 72 entries, so the exact two-level walk is both
// smaller and faster than the former 4096x36 linear table.
module nds_nitro_save_profile #(
    parameter integer PREFIX_COUNT = 368
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] game_code,
    output logic        busy,
    output logic        valid,
    output logic [3:0]  save_type
);
    (* ramstyle = "M10K" *) logic [35:0] prefix_rom [0:511];
    (* ramstyle = "M10K" *) logic [19:0] entry_rom [0:4095];
    logic [8:0] prefix_index;
    logic [35:0] prefix_entry;
    logic [11:0] entry_index;
    logic [19:0] entry;
    logic [6:0] bucket_remaining;
    logic [31:0] target;
    logic publish_pending;

    typedef enum logic [2:0] {
        IDLE,
        PREFIX_FETCH,
        PREFIX_CHECK,
        ENTRY_FETCH,
        ENTRY_CHECK
    } lookup_state_t;
    lookup_state_t state;

    // Keep this a literal for Quartus 17.0: its mixed VHDL/SystemVerilog
    // elaborator rejects a string parameter passed through a VHDL component.
    initial begin
        $readmemh("nds_save_profile_prefix.hex", prefix_rom);
        $readmemh("nds_save_profile_entries.hex", entry_rom);
    end

    always_ff @(posedge clk) begin
        prefix_entry <= prefix_rom[prefix_index];
        entry <= entry_rom[entry_index];

        if (reset) begin
            prefix_index <= '0;
            entry_index <= '0;
            bucket_remaining <= '0;
            target <= '0;
            busy <= 1'b0;
            valid <= 1'b0;
            save_type <= 4'd0;
            publish_pending <= 1'b0;
            state <= IDLE;
        end else if (start) begin
            prefix_index <= '0;
            entry_index <= '0;
            bucket_remaining <= '0;
            target <= game_code;
            busy <= 1'b1;
            valid <= 1'b0;
            save_type <= 4'd1;
            publish_pending <= 1'b0;
            state <= PREFIX_FETCH;
        end else if (publish_pending) begin
            // save_type crosses to clk_video as a bundled payload.  Publish
            // valid only after the payload has been stable for a complete
            // clk1x cycle so the destination's equal-depth synchronizers can
            // never observe valid with the previous cartridge's type.
            publish_pending <= 1'b0;
            valid <= 1'b1;
        end else if (busy) begin
            case (state)
                PREFIX_FETCH: state <= PREFIX_CHECK;

                PREFIX_CHECK: begin
                    // prefix_entry[35] is the zero pad of the nine-digit hex
                    // representation. The exact 35-bit payload remains [34:0].
                    if (prefix_entry[34:19] == target[31:16]) begin
                        entry_index <= prefix_entry[18:7];
                        bucket_remaining <= prefix_entry[6:0];
                        state <= ENTRY_FETCH;
                    end else if (prefix_index == PREFIX_COUNT - 1) begin
                        if (target == 32'h4553424b || target == 32'h23232323)
                            save_type <= 4'd0;
                        else
                            save_type <= 4'd1;
                        busy <= 1'b0;
                        publish_pending <= 1'b1;
                        state <= IDLE;
                    end else begin
                        prefix_index <= prefix_index + 1'b1;
                        state <= PREFIX_FETCH;
                    end
                end

                ENTRY_FETCH: state <= ENTRY_CHECK;

                ENTRY_CHECK: begin
                    if (entry[19:4] == target[15:0] && entry[3:0] <= 4'd7) begin
                        save_type <= entry[3:0];
                        busy <= 1'b0;
                        publish_pending <= 1'b1;
                        state <= IDLE;
                    end else if (bucket_remaining <= 1) begin
                        if (target == 32'h4553424b || target == 32'h23232323)
                            save_type <= 4'd0;
                        else
                            save_type <= 4'd1;
                        busy <= 1'b0;
                        publish_pending <= 1'b1;
                        state <= IDLE;
                    end else begin
                        entry_index <= entry_index + 1'b1;
                        bucket_remaining <= bucket_remaining - 1'b1;
                        state <= ENTRY_FETCH;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
