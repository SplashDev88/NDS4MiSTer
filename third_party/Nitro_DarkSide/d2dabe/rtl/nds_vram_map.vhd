-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS VRAM bank mapping decoder
-- Pure combinational: VRAMCNT_A..I + a CPU address in the 0x06xxxxxx region
-- -> which of the 9 banks hit, and the offset inside each bank.
--
-- Ground truth: NitroSDK gx_vramcnt.c MST tables + GBATEK "DS Video Memory Control".
-- See docs/NDS_HARDWARE.md for the full table this implements.
--
-- Scope notes (phase 1):
--  * Texture / texture-palette / extended-palette MST modes have NO CPU mapping;
--    those banks simply do not hit here (renderer-side ports come later).
--  * Region mirroring is decoded coarsely: each window is matched at its canonical
--    location inside the 2MB regions selected by addr(23:21). TODO: full mirrors.
--  * Multiple banks may hit the same address (hardware ORs reads, writes go to all);
--    callers get the full hit vector and must implement that semantic.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package pnds_vram_map is
   type t_vram_offs is array (0 to 8) of unsigned(16 downto 0); -- max bank = 128KB
   constant BANK_A : integer := 0;
   constant BANK_B : integer := 1;
   constant BANK_C : integer := 2;
   constant BANK_D : integer := 3;
   constant BANK_E : integer := 4;
   constant BANK_F : integer := 5;
   constant BANK_G : integer := 6;
   constant BANK_H : integer := 7;
   constant BANK_I : integer := 8;
end package;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pnds_vram_map.all;

entity nds_vram_map is
   port
   (
      -- raw VRAMCNT bytes, A..I packed low-to-high: bank N = vramcnt(N*8+7 downto N*8)
      -- byte layout: bit7 = enable, bits 4:3 = OFS, bits 2:0 = MST (2 bits on A/B/H/I)
      vramcnt  : in  std_logic_vector(71 downto 0);
      -- address inside the VRAM region: bits 23:0 of a 0x06xxxxxx access
      addr     : in  unsigned(23 downto 0);
      is_arm7  : in  std_logic;
      hit      : out std_logic_vector(8 downto 0);
      offs     : out t_vram_offs
   );
end entity;

architecture arch of nds_vram_map is

   type t_cnt_fields is record
      ena : std_logic;
      mst : unsigned(2 downto 0);
      ofs : unsigned(1 downto 0);
   end record;
   type t_cnt_arr is array (0 to 8) of t_cnt_fields;
   signal cnt : t_cnt_arr;

   -- region select from addr(23:21): 2MB granules of 0x06000000..
   constant REG_MAINBG  : unsigned(2 downto 0) := "000"; -- 0x000000
   constant REG_SUBBG   : unsigned(2 downto 0) := "001"; -- 0x200000
   constant REG_MAINOBJ : unsigned(2 downto 0) := "010"; -- 0x400000
   constant REG_SUBOBJ  : unsigned(2 downto 0) := "011"; -- 0x600000
   signal region  : unsigned(2 downto 0);
   signal is_lcdc : std_logic;                           -- addr >= 0x800000

begin

   gsplit : for i in 0 to 8 generate
      cnt(i).ena <= vramcnt(i*8 + 7);
      cnt(i).ofs <= unsigned(vramcnt(i*8 + 4 downto i*8 + 3));
      -- A/B/H/I have a 2-bit MST field; mask bit2 so garbage writes decode like hardware
      cnt(i).mst <= unsigned('0' & vramcnt(i*8 + 1 downto i*8)) when (i = BANK_A or i = BANK_B or i = BANK_H or i = BANK_I) else
                    unsigned(vramcnt(i*8 + 2 downto i*8));
   end generate;

   region  <= addr(23 downto 21);
   is_lcdc <= addr(23);

   process (all)
      variable v_hit  : std_logic_vector(8 downto 0);
      variable v_offs : t_vram_offs;
   begin
      v_hit  := (others => '0');
      v_offs := (others => (others => '0'));

      -- ===================== banks A..D (128 KB) =====================
      for i in BANK_A to BANK_D loop
         if (cnt(i).ena = '1') then
            case to_integer(cnt(i).mst) is
               when 0 =>   -- LCDC: 0x800000 + i*0x20000
                  if (is_arm7 = '0' and is_lcdc = '1' and addr(22 downto 17) = to_unsigned(i, 6)) then
                     v_hit(i)  := '1';
                     v_offs(i) := addr(16 downto 0);
                  end if;
               when 1 =>   -- main BG: 0x000000 + OFS*0x20000
                  if (is_arm7 = '0' and region = REG_MAINBG and addr(18 downto 17) = cnt(i).ofs) then
                     v_hit(i)  := '1';
                     v_offs(i) := addr(16 downto 0);
                  end if;
               when 2 =>
                  if (i = BANK_A or i = BANK_B) then
                     -- main OBJ: 0x400000 + OFS.0*0x20000
                     if (is_arm7 = '0' and region = REG_MAINOBJ and addr(18) = '0' and addr(17) = cnt(i).ofs(0)) then
                        v_hit(i)  := '1';
                        v_offs(i) := addr(16 downto 0);
                     end if;
                  else
                     -- C/D: mapped into ARM7 space at 0x000000 + OFS.0*0x20000
                     if (is_arm7 = '1' and region = REG_MAINBG and addr(18) = '0' and addr(17) = cnt(i).ofs(0)) then
                        v_hit(i)  := '1';
                        v_offs(i) := addr(16 downto 0);
                     end if;
                  end if;
               when 3 => null;  -- texture slot: renderer-only, no CPU mapping
               when 4 =>
                  if (i = BANK_C) then
                     -- sub BG: 0x200000 (full 128 KB)
                     if (is_arm7 = '0' and region = REG_SUBBG and addr(20 downto 17) = "0000") then
                        v_hit(i)  := '1';
                        v_offs(i) := addr(16 downto 0);
                     end if;
                  elsif (i = BANK_D) then
                     -- sub OBJ: 0x600000
                     if (is_arm7 = '0' and region = REG_SUBOBJ and addr(20 downto 17) = "0000") then
                        v_hit(i)  := '1';
                        v_offs(i) := addr(16 downto 0);
                     end if;
                  end if;
               when others => null;
            end case;
         end if;
      end loop;

      -- ===================== bank E (64 KB) =====================
      if (cnt(BANK_E).ena = '1' and is_arm7 = '0') then
         case to_integer(cnt(BANK_E).mst) is
            when 0 =>   -- LCDC 0x880000
               if (is_lcdc = '1' and addr(22 downto 16) = "0001000") then
                  v_hit(BANK_E)  := '1';
                  v_offs(BANK_E) := '0' & addr(15 downto 0);
               end if;
            when 1 =>   -- main BG 0x000000
               if (region = REG_MAINBG and addr(18 downto 16) = "000") then
                  v_hit(BANK_E)  := '1';
                  v_offs(BANK_E) := '0' & addr(15 downto 0);
               end if;
            when 2 =>   -- main OBJ 0x400000
               if (region = REG_MAINOBJ and addr(18 downto 16) = "000") then
                  v_hit(BANK_E)  := '1';
                  v_offs(BANK_E) := '0' & addr(15 downto 0);
               end if;
            when others => null;  -- 3: tex palette, 4: BG ext palette — no CPU mapping
         end case;
      end if;

      -- ===================== banks F/G (16 KB) =====================
      -- BG/OBJ base inside window: (OFS.0)*0x4000 + (OFS.1)*0x10000
      for i in BANK_F to BANK_G loop
         if (cnt(i).ena = '1' and is_arm7 = '0') then
            case to_integer(cnt(i).mst) is
               when 0 =>   -- LCDC: F=0x890000, G=0x894000
                  if (is_lcdc = '1' and addr(22 downto 14) = to_unsigned(16#24# + (i - BANK_F), 9)) then
                     v_hit(i)  := '1';
                     v_offs(i) := "000" & addr(13 downto 0);
                  end if;
               when 1 =>   -- main BG
                  if (region = REG_MAINBG and addr(18 downto 17) = "00" and
                      addr(16) = cnt(i).ofs(1) and addr(15) = '0' and addr(14) = cnt(i).ofs(0)) then
                     v_hit(i)  := '1';
                     v_offs(i) := "000" & addr(13 downto 0);
                  end if;
               when 2 =>   -- main OBJ
                  if (region = REG_MAINOBJ and addr(18 downto 17) = "00" and
                      addr(16) = cnt(i).ofs(1) and addr(15) = '0' and addr(14) = cnt(i).ofs(0)) then
                     v_hit(i)  := '1';
                     v_offs(i) := "000" & addr(13 downto 0);
                  end if;
               when others => null;  -- 3/4/5: tex pal / BG ext pal / OBJ ext pal
            end case;
         end if;
      end loop;

      -- ===================== bank H (32 KB) =====================
      if (cnt(BANK_H).ena = '1' and is_arm7 = '0') then
         case to_integer(cnt(BANK_H).mst) is
            when 0 =>   -- LCDC 0x898000
               if (is_lcdc = '1' and addr(22 downto 15) = "00010011") then
                  v_hit(BANK_H)  := '1';
                  v_offs(BANK_H) := "00" & addr(14 downto 0);
               end if;
            when 1 =>   -- sub BG 0x200000
               if (region = REG_SUBBG and addr(20 downto 15) = "000000") then
                  v_hit(BANK_H)  := '1';
                  v_offs(BANK_H) := "00" & addr(14 downto 0);
               end if;
            when others => null;  -- 2: sub BG ext palette
         end case;
      end if;

      -- ===================== bank I (16 KB) =====================
      if (cnt(BANK_I).ena = '1' and is_arm7 = '0') then
         case to_integer(cnt(BANK_I).mst) is
            when 0 =>   -- LCDC 0x8A0000
               if (is_lcdc = '1' and addr(22 downto 14) = to_unsigned(16#28#, 9)) then
                  v_hit(BANK_I)  := '1';
                  v_offs(BANK_I) := "000" & addr(13 downto 0);
               end if;
            when 1 =>   -- sub BG 0x208000
               if (region = REG_SUBBG and addr(20 downto 14) = "0000010") then
                  v_hit(BANK_I)  := '1';
                  v_offs(BANK_I) := "000" & addr(13 downto 0);
               end if;
            when 2 =>   -- sub OBJ 0x600000
               if (region = REG_SUBOBJ and addr(20 downto 14) = "0000000") then
                  v_hit(BANK_I)  := '1';
                  v_offs(BANK_I) := "000" & addr(13 downto 0);
               end if;
            when others => null;  -- 3: sub OBJ ext palette
         end case;
      end if;

      hit  <= v_hit;
      offs <= v_offs;
   end process;

end architecture;
