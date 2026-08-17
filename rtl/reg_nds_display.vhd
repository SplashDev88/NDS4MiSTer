-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS 2D engine A register map (0x04000000..0x0400005F), pReg_gba_display
-- pattern. Engine B is the same layout at +0x1000 (instantiated with an
-- address offset when it arrives). Field semantics per GBATEK.
-- DISPSTAT/VCOUNT (0x004/0x006) belong to the timing module, POWCNT/master
-- brightness to compose - not here.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;

package pReg_nds_display is

   -- DISPCNT, 32 bit
   constant DISPCNT_BG_Mode              : regmap_type := (16#000#,   2,      0,        1,        0,   readwrite); -- BG mode 0-6
   constant DISPCNT_BG0_3D               : regmap_type := (16#000#,   3,      3,        1,        0,   readwrite); -- BG0 is the 3D layer (engine A)
   constant DISPCNT_Tile_OBJ_1D          : regmap_type := (16#000#,   4,      4,        1,        0,   readwrite); -- tile OBJ mapping 1D
   constant DISPCNT_Bitmap_OBJ_2D_Wide   : regmap_type := (16#000#,   5,      5,        1,        0,   readwrite); -- bitmap OBJ 2D: 256-wide
   constant DISPCNT_Bitmap_OBJ_1D        : regmap_type := (16#000#,   6,      6,        1,        0,   readwrite); -- bitmap OBJ mapping 1D
   constant DISPCNT_Forced_Blank         : regmap_type := (16#000#,   7,      7,        1,        0,   readwrite);
   constant DISPCNT_Screen_Display_BG0   : regmap_type := (16#000#,   8,      8,        1,        0,   readwrite);
   constant DISPCNT_Screen_Display_BG1   : regmap_type := (16#000#,   9,      9,        1,        0,   readwrite);
   constant DISPCNT_Screen_Display_BG2   : regmap_type := (16#000#,  10,     10,        1,        0,   readwrite);
   constant DISPCNT_Screen_Display_BG3   : regmap_type := (16#000#,  11,     11,        1,        0,   readwrite);
   constant DISPCNT_Screen_Display_OBJ   : regmap_type := (16#000#,  12,     12,        1,        0,   readwrite);
   constant DISPCNT_Window_0_Display     : regmap_type := (16#000#,  13,     13,        1,        0,   readwrite);
   constant DISPCNT_Window_1_Display     : regmap_type := (16#000#,  14,     14,        1,        0,   readwrite);
   constant DISPCNT_OBJ_Wnd_Display      : regmap_type := (16#000#,  15,     15,        1,        0,   readwrite);
   constant DISPCNT_Display_Mode         : regmap_type := (16#000#,  17,     16,        1,        0,   readwrite); -- 0 off, 1 graphics, 2 vram, 3 mainram
   constant DISPCNT_VRAM_Block           : regmap_type := (16#000#,  19,     18,        1,        0,   readwrite); -- display mode 2 source
   constant DISPCNT_Tile_OBJ_Boundary    : regmap_type := (16#000#,  21,     20,        1,        0,   readwrite); -- 1D tile OBJ boundary 32<<n
   constant DISPCNT_Bitmap_OBJ_Boundary  : regmap_type := (16#000#,  22,     22,        1,        0,   readwrite); -- 1D bitmap OBJ boundary 128<<n (A only)
   -- NDS bit 23 = "OBJ Processing during H-Blank" (GBATEK), the DS relocation
   -- of the GBA's bit 5 "H-Blank Interval Free" read from the OBJ's side:
   -- SET = OBJ gets the HBlank interval (1210 cycles), CLEAR = 954. The
   -- drawer's hblankfree port keeps the donor meaning and nds_gpu2d inverts
   -- this bit before driving it.
   constant DISPCNT_OBJ_HBlank_Proc      : regmap_type := (16#000#,  23,     23,        1,        0,   readwrite);
   constant DISPCNT_Char_Base            : regmap_type := (16#000#,  26,     24,        1,        0,   readwrite); -- 64 KB units (A only)
   constant DISPCNT_Screen_Base          : regmap_type := (16#000#,  29,     27,        1,        0,   readwrite); -- 64 KB units (A only)
   constant DISPCNT_BG_ExtPal            : regmap_type := (16#000#,  30,     30,        1,        0,   readwrite);
   constant DISPCNT_OBJ_ExtPal           : regmap_type := (16#000#,  31,     31,        1,        0,   readwrite);

   -- DISPSTAT (0x004) / VCOUNT (0x006) — owned by nds_gpu_timing, one
   -- register set per CPU (ARM9 and ARM7 each have their own DISPSTAT and
   -- can each write VCOUNT; the flags/VCOUNT values are shared). The
   -- V-count match value is 9 bits: bits 15:8 are the low byte, bit 7 the
   -- MSB (GBATEK: LYC 0..262). Bit 6 is unused, reads 0.
   constant DISPSTAT_V_Blank_flag        : regmap_type := (16#004#,   0,      0,        1,        0,   readonly);  -- set lines 192..261 (not 262)
   constant DISPSTAT_H_Blank_flag        : regmap_type := (16#004#,   1,      1,        1,        0,   readonly);  -- set from dot 256+48lead each line
   constant DISPSTAT_V_Counter_flag      : regmap_type := (16#004#,   2,      2,        1,        0,   readonly);
   constant DISPSTAT_V_Blank_IRQ_Enable  : regmap_type := (16#004#,   3,      3,        1,        0,   readwrite);
   constant DISPSTAT_H_Blank_IRQ_Enable  : regmap_type := (16#004#,   4,      4,        1,        0,   readwrite);
   constant DISPSTAT_V_Counter_IRQ_Enable: regmap_type := (16#004#,   5,      5,        1,        0,   readwrite);
   constant DISPSTAT_V_Count_Setting_MSB : regmap_type := (16#004#,   7,      7,        1,        0,   readwrite); -- bit 8 of the 9-bit match
   constant DISPSTAT_V_Count_Setting     : regmap_type := (16#004#,  15,      8,        1,        0,   readwrite); -- bits 7:0 of the match
   constant VCOUNT                       : regmap_type := (16#004#,  31,     16,        1,        0,   readwrite); -- reads 9-bit line; writes land at next scanline

   -- BGxCNT
   constant BG0CNT_Priority              : regmap_type := (16#008#,   1,      0,        1,        0,   readwrite);
   constant BG0CNT_Char_Base             : regmap_type := (16#008#,   5,      2,        1,        0,   readwrite); -- 16 KB units
   constant BG0CNT_Mosaic                : regmap_type := (16#008#,   6,      6,        1,        0,   readwrite);
   constant BG0CNT_HiColor               : regmap_type := (16#008#,   7,      7,        1,        0,   readwrite);
   constant BG0CNT_Screen_Base           : regmap_type := (16#008#,  12,      8,        1,        0,   readwrite); -- 2 KB units
   constant BG0CNT_ExtPal_Slot           : regmap_type := (16#008#,  13,     13,        1,        0,   readwrite); -- BG0: slot 0/2
   constant BG0CNT_Screen_Size           : regmap_type := (16#008#,  15,     14,        1,        0,   readwrite);

   constant BG1CNT_Priority              : regmap_type := (16#008#,  17,     16,        1,        0,   readwrite);
   constant BG1CNT_Char_Base             : regmap_type := (16#008#,  21,     18,        1,        0,   readwrite);
   constant BG1CNT_Mosaic                : regmap_type := (16#008#,  22,     22,        1,        0,   readwrite);
   constant BG1CNT_HiColor               : regmap_type := (16#008#,  23,     23,        1,        0,   readwrite);
   constant BG1CNT_Screen_Base           : regmap_type := (16#008#,  28,     24,        1,        0,   readwrite);
   constant BG1CNT_ExtPal_Slot           : regmap_type := (16#008#,  29,     29,        1,        0,   readwrite); -- BG1: slot 1/3
   constant BG1CNT_Screen_Size           : regmap_type := (16#008#,  31,     30,        1,        0,   readwrite);

   constant BG2CNT_Priority              : regmap_type := (16#00C#,   1,      0,        1,        0,   readwrite);
   constant BG2CNT_Char_Base             : regmap_type := (16#00C#,   5,      2,        1,        0,   readwrite);
   constant BG2CNT_Mosaic                : regmap_type := (16#00C#,   6,      6,        1,        0,   readwrite);
   constant BG2CNT_HiColor               : regmap_type := (16#00C#,   7,      7,        1,        0,   readwrite);
   constant BG2CNT_Screen_Base           : regmap_type := (16#00C#,  12,      8,        1,        0,   readwrite);
   constant BG2CNT_Wrap                  : regmap_type := (16#00C#,  13,     13,        1,        0,   readwrite);
   constant BG2CNT_Screen_Size           : regmap_type := (16#00C#,  15,     14,        1,        0,   readwrite);

   constant BG3CNT_Priority              : regmap_type := (16#00C#,  17,     16,        1,        0,   readwrite);
   constant BG3CNT_Char_Base             : regmap_type := (16#00C#,  21,     18,        1,        0,   readwrite);
   constant BG3CNT_Mosaic                : regmap_type := (16#00C#,  22,     22,        1,        0,   readwrite);
   constant BG3CNT_HiColor               : regmap_type := (16#00C#,  23,     23,        1,        0,   readwrite);
   constant BG3CNT_Screen_Base           : regmap_type := (16#00C#,  28,     24,        1,        0,   readwrite);
   constant BG3CNT_Wrap                  : regmap_type := (16#00C#,  29,     29,        1,        0,   readwrite);
   constant BG3CNT_Screen_Size           : regmap_type := (16#00C#,  31,     30,        1,        0,   readwrite);

   -- scrolls (write-only on hardware; readwrite here, CPU reads return 0
   -- via the unmapped-read path once membus masks them - same as GBA core)
   constant BG0HOFS                      : regmap_type := (16#010#,   8,      0,        1,        0,   writeonly);
   constant BG0VOFS                      : regmap_type := (16#010#,  24,     16,        1,        0,   writeonly);
   constant BG1HOFS                      : regmap_type := (16#014#,   8,      0,        1,        0,   writeonly);
   constant BG1VOFS                      : regmap_type := (16#014#,  24,     16,        1,        0,   writeonly);
   constant BG2HOFS                      : regmap_type := (16#018#,   8,      0,        1,        0,   writeonly);
   constant BG2VOFS                      : regmap_type := (16#018#,  24,     16,        1,        0,   writeonly);
   constant BG3HOFS                      : regmap_type := (16#01C#,   8,      0,        1,        0,   writeonly);
   constant BG3VOFS                      : regmap_type := (16#01C#,  24,     16,        1,        0,   writeonly);

   -- affine parameters
   constant BG2RotScaleParDX             : regmap_type := (16#020#,  15,      0,        1,        0,   writeonly);
   constant BG2RotScaleParDMX            : regmap_type := (16#020#,  31,     16,        1,        0,   writeonly);
   constant BG2RotScaleParDY             : regmap_type := (16#024#,  15,      0,        1,        0,   writeonly);
   constant BG2RotScaleParDMY            : regmap_type := (16#024#,  31,     16,        1,        0,   writeonly);
   constant BG2RefX                      : regmap_type := (16#028#,  27,      0,        1,        0,   writeonly);
   constant BG2RefY                      : regmap_type := (16#02C#,  27,      0,        1,        0,   writeonly);

   constant BG3RotScaleParDX             : regmap_type := (16#030#,  15,      0,        1,        0,   writeonly);
   constant BG3RotScaleParDMX            : regmap_type := (16#030#,  31,     16,        1,        0,   writeonly);
   constant BG3RotScaleParDY             : regmap_type := (16#034#,  15,      0,        1,        0,   writeonly);
   constant BG3RotScaleParDMY            : regmap_type := (16#034#,  31,     16,        1,        0,   writeonly);
   constant BG3RefX                      : regmap_type := (16#038#,  27,      0,        1,        0,   writeonly);
   constant BG3RefY                      : regmap_type := (16#03C#,  27,      0,        1,        0,   writeonly);

   -- windows
   constant WIN0H_X2                     : regmap_type := (16#040#,   7,      0,        1,        0,   writeonly);
   constant WIN0H_X1                     : regmap_type := (16#040#,  15,      8,        1,        0,   writeonly);
   constant WIN1H_X2                     : regmap_type := (16#040#,  23,     16,        1,        0,   writeonly);
   constant WIN1H_X1                     : regmap_type := (16#040#,  31,     24,        1,        0,   writeonly);
   constant WIN0V_Y2                     : regmap_type := (16#044#,   7,      0,        1,        0,   writeonly);
   constant WIN0V_Y1                     : regmap_type := (16#044#,  15,      8,        1,        0,   writeonly);
   constant WIN1V_Y2                     : regmap_type := (16#044#,  23,     16,        1,        0,   writeonly);
   constant WIN1V_Y1                     : regmap_type := (16#044#,  31,     24,        1,        0,   writeonly);

   constant WININ_Win0_Enables           : regmap_type := (16#048#,   5,      0,        1,        0,   readwrite); -- BG0-3, OBJ, effects
   constant WININ_Win1_Enables           : regmap_type := (16#048#,  13,      8,        1,        0,   readwrite);
   constant WINOUT_Enables               : regmap_type := (16#048#,  21,     16,        1,        0,   readwrite);
   constant WINOUT_Objwnd_Enables        : regmap_type := (16#048#,  29,     24,        1,        0,   readwrite);

   constant MOSAIC_BG_H                  : regmap_type := (16#04C#,   3,      0,        1,        0,   writeonly);
   constant MOSAIC_BG_V                  : regmap_type := (16#04C#,   7,      4,        1,        0,   writeonly);
   constant MOSAIC_OBJ_H                 : regmap_type := (16#04C#,  11,      8,        1,        0,   writeonly);
   constant MOSAIC_OBJ_V                 : regmap_type := (16#04C#,  15,     12,        1,        0,   writeonly);

   -- color special effects
   constant BLDCNT_1st_Target            : regmap_type := (16#050#,   5,      0,        1,        0,   readwrite); -- BG0-3, OBJ, BD
   constant BLDCNT_Effect                : regmap_type := (16#050#,   7,      6,        1,        0,   readwrite);
   constant BLDCNT_2nd_Target            : regmap_type := (16#050#,  13,      8,        1,        0,   readwrite);
   constant BLDALPHA_EVA                 : regmap_type := (16#050#,  20,     16,        1,        0,   readwrite);
   constant BLDALPHA_EVB                 : regmap_type := (16#050#,  28,     24,        1,        0,   readwrite);
   constant BLDY                         : regmap_type := (16#054#,   4,      0,        1,        0,   writeonly);

   -- 0x6C - MASTER_BRIGHT (applied after compose, in 18-bit space)
   constant MASTER_BRIGHT_Factor         : regmap_type := (16#06C#,   4,      0,        1,        0,   readwrite);
   constant MASTER_BRIGHT_Mode           : regmap_type := (16#06C#,  15,     14,        1,        0,   readwrite); -- 0 off, 1 up, 2 down

end package;
