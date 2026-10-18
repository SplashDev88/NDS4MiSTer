-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS system-control registers shared between the two CPUs (M4):
--
--   EXMEMCNT  0x04000204 (ARM9, r/w 16 bit): GBA-slot timings [6:0], GBA-slot
--             rights [7], NDS-card rights [11], main-memory mode [14],
--             main-memory priority [15]. Bit 13 reads as 1.
--   EXMEMSTAT 0x04000204 (ARM7): [6:0] are the ARM7's own private timing
--             copy (r/w); [15:7] mirror the ARM9 register read-only.
--   WRAMCNT   0x04000247 (ARM9, r/w 8 bit, [1:0] used) - shared-WRAM mapping,
--             wired straight to nds_wram.
--   WRAMSTAT  0x04000241 (ARM7, read-only view of WRAMCNT).
--   VRAMCNT_A..I 0x240..0x246 / 0x248..0x249 (ARM9, r/w bytes) -
--             bank mapping, wired straight to nds_vram/nds_vram_map
--             (vramcnt(8k+7 downto 8k) = bank k, A = 0). Reads return the
--             bank's implemented bits; reserved bits read as zero.
--   VRAMSTAT  0x04000240 (ARM7, read-only): bit0/1 = bank C/D mapped as
--             ARM7 WRAM (MST=2).
--   POWCNT1   0x04000304 (ARM9, r/w, stored bits masked 0x820F) - 2D/3D
--             engine power + LCD swap (bit 15: '1' = engine A on top).
--   POSTFLG   0x04000300 (both CPUs, independent): bit 0 sticky-set until
--             reset; ARM9 side also has r/w bit 1.
--   HALTCNT   0x04000301 (ARM7, write-only): value 0x80/0xC0 halts the
--             ARM7 until IE & IF != 0. Sleep additionally holds the console
--             until an enabled ARM7 interrupt wakes it.
--
-- Register semantics per GBATEK / melonDS.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_syscnt is
   generic (EXPERIMENTAL_CHECKPOINT : boolean := false);
   port
   (
      clk          : in  std_logic;
      reset        : in  std_logic;
      cold_boot    : in  std_logic := '0';

      bus9         : in  proc_bus_gb_type;
      wired_out9   : out std_logic_vector(31 downto 0);
      wired_done9  : out std_logic;

      bus7         : in  proc_bus_gb_type;
      wired_out7   : out std_logic_vector(31 downto 0);
      wired_done7  : out std_logic;

      -- 1-cycle pulse after a direct boot: firmware-left state
      -- (WRAMCNT=3, POSTFLG=1, POWCNT1=0x820F)
      preset_direct : in std_logic := '0';

      wramcnt      : out std_logic_vector(1 downto 0);
      vramcnt      : out std_logic_vector(71 downto 0);
      pow_2da      : out std_logic;   -- POWCNT1.1: 2D engine A power
      pow_2db      : out std_logic;   -- POWCNT1.9: 2D engine B power
      pow_swap     : out std_logic;   -- POWCNT1.15: engine A on top screen
      exmem_gba7   : out std_logic;   -- GBA slot belongs to ARM7
      exmem_card7  : out std_logic;   -- NDS card belongs to ARM7
      exmem_prio7  : out std_logic;   -- main-memory priority to ARM7
      halt7        : out std_logic := '0'; -- 1-cycle pulse: HALTCNT halt
      wake7        : in  std_logic := '0'; -- IE & IF, independent of IME
      console_sleep : out std_logic := '0';
      -- Four ordered words. Bus/loader producers must be held independently.
      checkpoint_idle : out std_logic := '0';
      checkpoint_address : in unsigned(2 downto 0) := (others => '0');
      checkpoint_data : out std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_valid : out std_logic := '0';
      checkpoint_restore : in std_logic := '0';
      checkpoint_write : in std_logic := '0';
      checkpoint_write_data : in std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_restore_ready : out std_logic := '0';
      checkpoint_restore_error : out std_logic := '0'
   );
end entity;

architecture arch of nds_syscnt is

   constant ADR_EXMEM : std_logic_vector(27 downto 0) := x"0000204";
   constant ADR_WRAM  : std_logic_vector(27 downto 0) := x"0000240"; -- 0x241/0x247 word base is 0x240/0x244
   constant ADR_WRAM9 : std_logic_vector(27 downto 0) := x"0000244";
   constant ADR_VRAMHI : std_logic_vector(27 downto 0) := x"0000248";
   constant ADR_POWCNT : std_logic_vector(27 downto 0) := x"0000304";
   constant ADR_POSTFLG : std_logic_vector(27 downto 0) := x"0000300";

   signal exmem9    : std_logic_vector(15 downto 0) := x"6580"; -- post-BIOS-ish default
   signal exmem7lo  : std_logic_vector(6 downto 0)  := (others => '0');
   signal r_wramcnt : std_logic_vector(1 downto 0)  := "00";
   signal r_vramcnt : std_logic_vector(71 downto 0) := (others => '0');
   signal r_powcnt  : std_logic_vector(15 downto 0) := (others => '0');
   signal postflg7  : std_logic := '0';
   signal postflg9  : std_logic_vector(1 downto 0) := "00";

   signal exmem9_rd, exmem7_rd : std_logic_vector(15 downto 0);
   signal vramstat  : std_logic_vector(1 downto 0);
   signal vramcnt_rd : std_logic_vector(71 downto 0);
   signal restore_active, restore_write_valid : std_logic;
   signal restore_count : unsigned(2 downto 0) := (others => '0');
   signal restore_error : std_logic := '0';

   function valid_word(a : unsigned(2 downto 0); d : std_logic_vector(31 downto 0)) return boolean is
   begin
      case to_integer(a) is
         when 0 => return d(31 downto 29) = "000";
         when 1 | 2 => return true;
         when 3 => return d(31 downto 24) = x"00" and (d(23 downto 8) and x"7DF0") = x"0000";
         when others => return false;
      end case;
   end function;

begin

   checkpoint_idle <= '1' when reset = '0' and bus9.ena = '0' and bus7.ena = '0' and
      preset_direct = '0' and halt7 = '0' and not (console_sleep = '1' and wake7 = '1') else '0';
   restore_active <= '1' when EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0';
   restore_write_valid <= '1' when restore_active = '1' and restore_error = '0' and checkpoint_write = '1' and
      bus9.ena = '0' and bus7.ena = '0' and preset_direct = '0' and restore_count < 4 and
      checkpoint_address = restore_count and valid_word(checkpoint_address, checkpoint_write_data) else '0';
   checkpoint_restore_error <= restore_error when EXPERIMENTAL_CHECKPOINT else '0';
   checkpoint_restore_ready <= '1' when restore_active = '1' and restore_error = '0' and restore_count = 4 and
      bus9.ena = '0' and bus7.ena = '0' and preset_direct = '0' and checkpoint_write = '0' else '0';

   process(clk)
   begin
      if rising_edge(clk) then
         if not EXPERIMENTAL_CHECKPOINT or checkpoint_restore = '0' then
            restore_count <= (others => '0'); restore_error <= '0';
         elsif reset = '0' or bus9.ena = '1' or bus7.ena = '1' or preset_direct = '1' then
            restore_error <= '1';
         elsif checkpoint_write = '1' then
            if restore_write_valid = '1' then restore_count <= restore_count + 1;
            else restore_error <= '1'; end if;
         end if;
      end if;
   end process;

   process(all)
   begin
      checkpoint_data <= (others => '0'); checkpoint_valid <= '0';
      if EXPERIMENTAL_CHECKPOINT and checkpoint_address < 4 and
         ((checkpoint_idle = '1' and checkpoint_restore = '0') or checkpoint_restore_ready = '1') then
         checkpoint_valid <= '1';
         case to_integer(checkpoint_address) is
            when 0 => checkpoint_data(28 downto 0) <= console_sleep & postflg9 & postflg7 & r_wramcnt & exmem7lo & exmem9;
            when 1 => checkpoint_data <= r_vramcnt(31 downto 0);
            when 2 => checkpoint_data <= r_vramcnt(63 downto 32);
            when 3 => checkpoint_data(23 downto 0) <= r_powcnt & r_vramcnt(71 downto 64);
            when others => null;
         end case;
      end if;
   end process;

   exmem9_rd <= exmem9(15 downto 14) & '1' & exmem9(12 downto 0);
   exmem7_rd <= exmem9(15 downto 14) & '1' & exmem9(12 downto 7) & exmem7lo;

   -- Games save a bank's VRAMCNT, map it to LCDC for a texture upload,
   -- then restore the saved byte (King Kong). Match melonDS's per-bank
   -- masks while retaining the existing mapping outputs and write timing.
   vramcnt_rd <= r_vramcnt and x"83839F9F879F9F9B9B";
   wired_out9 <= x"0000" & exmem9_rd when (bus9.Adr = ADR_EXMEM) else
                 vramcnt_rd(31 downto 0) when (bus9.Adr = ADR_WRAM) else
                 "000000" & r_wramcnt & vramcnt_rd(55 downto 32) when (bus9.Adr = ADR_WRAM9) else -- 0x247 = byte 3
                 x"0000" & vramcnt_rd(71 downto 56) when (bus9.Adr = ADR_VRAMHI) else
                 x"0000" & r_powcnt when (bus9.Adr = ADR_POWCNT) else
                 x"000000" & "000000" & postflg9 when (bus9.Adr = ADR_POSTFLG) else
                 (others => '0');
   wired_done9 <= '1' when (bus9.Adr = ADR_EXMEM or bus9.Adr = ADR_WRAM9 or
                            bus9.Adr = ADR_WRAM or bus9.Adr = ADR_VRAMHI or
                            bus9.Adr = ADR_POWCNT or bus9.Adr = ADR_POSTFLG) else '0';

   -- VRAMSTAT: bank C/D mapped as ARM7 WRAM (enabled, MST=2)
   vramstat(0) <= '1' when (r_vramcnt(23 downto 16) and x"87") = x"82" else '0';
   vramstat(1) <= '1' when (r_vramcnt(31 downto 24) and x"87") = x"82" else '0';

   wired_out7 <= x"0000" & exmem7_rd when (bus7.Adr = ADR_EXMEM) else
                 x"0000" & "000000" & r_wramcnt & "000000" & vramstat when (bus7.Adr = ADR_WRAM) else
                 x"000000" & "0000000" & postflg7 when (bus7.Adr = ADR_POSTFLG) else
                 (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_EXMEM or bus7.Adr = ADR_WRAM or
                            bus7.Adr = ADR_POSTFLG) else '0';

   wramcnt     <= r_wramcnt;
   vramcnt     <= r_vramcnt;
   pow_2da     <= r_powcnt(1);
   pow_2db     <= r_powcnt(9);
   pow_swap    <= r_powcnt(15);
   exmem_gba7  <= exmem9(7);
   exmem_card7 <= exmem9(11);
   exmem_prio7 <= exmem9(15);

   process (clk)
   begin
      if rising_edge(clk) then
         halt7 <= '0';
         if restore_active = '1' then
            -- Do not reapply cold/direct-boot defaults between loaded words.
            -- Preserve raw VRAM bank bytes, including masked readback bits.
            if restore_write_valid = '1' then
               case to_integer(checkpoint_address) is
                  when 0 =>
                     exmem9 <= checkpoint_write_data(15 downto 0); exmem7lo <= checkpoint_write_data(22 downto 16);
                     r_wramcnt <= checkpoint_write_data(24 downto 23); postflg7 <= checkpoint_write_data(25);
                     postflg9 <= checkpoint_write_data(27 downto 26); console_sleep <= checkpoint_write_data(28);
                  when 1 => r_vramcnt(31 downto 0) <= checkpoint_write_data;
                  when 2 => r_vramcnt(63 downto 32) <= checkpoint_write_data;
                  when 3 => r_vramcnt(71 downto 64) <= checkpoint_write_data(7 downto 0); r_powcnt <= checkpoint_write_data(23 downto 8);
                  when others => null;
               end case;
            end if;
         elsif (reset = '1') then
            console_sleep <= '0';
            if cold_boot = '1' then exmem9 <= x"6000";
            else exmem9 <= x"6580"; end if;
            exmem7lo  <= (others => '0');
            r_wramcnt <= "00";
            r_vramcnt <= (others => '0');
            r_powcnt  <= (others => '0');
            postflg7  <= '0';
            postflg9  <= "00";
         else
            if wake7 = '1' then console_sleep <= '0'; end if;
            if (preset_direct = '1') then
               r_wramcnt <= "11";
               postflg7  <= '1';
               postflg9  <= "01";
               r_powcnt  <= x"820F";
            end if;
            if (bus9.ena = '1' and bus9.rnw = '0') then
               if (bus9.Adr = ADR_EXMEM) then
                  if (bus9.bEna(0) = '1') then exmem9(7 downto 0)  <= bus9.Din(7 downto 0);  end if;
                  if (bus9.bEna(1) = '1') then exmem9(15 downto 8) <= bus9.Din(15 downto 8); end if;
               elsif (bus9.Adr = ADR_WRAM) then
                  -- VRAMCNT_A..D, bytes 0x240..0x243
                  for i in 0 to 3 loop
                     if (bus9.bEna(i) = '1') then
                        r_vramcnt(i*8 + 7 downto i*8) <= bus9.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
               elsif (bus9.Adr = ADR_WRAM9) then
                  -- VRAMCNT_E..G, bytes 0x244..0x246; WRAMCNT byte 0x247
                  for i in 0 to 2 loop
                     if (bus9.bEna(i) = '1') then
                        r_vramcnt(32 + i*8 + 7 downto 32 + i*8) <= bus9.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
                  if (bus9.bEna(3) = '1') then
                     r_wramcnt <= bus9.Din(25 downto 24);        -- byte 0x247
                  end if;
               elsif (bus9.Adr = ADR_POWCNT) then
                  if (bus9.bEna(0) = '1') then r_powcnt(7 downto 0)  <= bus9.Din(7 downto 0)  and x"0F"; end if;
                  if (bus9.bEna(1) = '1') then r_powcnt(15 downto 8) <= bus9.Din(15 downto 8) and x"82"; end if;
               elsif (bus9.Adr = ADR_POSTFLG) then
                  if (bus9.bEna(0) = '1') then
                     postflg9(0) <= postflg9(0) or bus9.Din(0);
                     postflg9(1) <= bus9.Din(1);
                  end if;
               elsif (bus9.Adr = ADR_VRAMHI) then
                  -- VRAMCNT_H..I, bytes 0x248..0x249
                  for i in 0 to 1 loop
                     if (bus9.bEna(i) = '1') then
                        r_vramcnt(56 + i*8 + 7 downto 56 + i*8) <= bus9.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
               end if;
            end if;
            if (bus7.ena = '1' and bus7.rnw = '0' and bus7.Adr = ADR_EXMEM) then
               if (bus7.bEna(0) = '1') then
                  exmem7lo <= bus7.Din(6 downto 0);
               end if;
            end if;
            if (bus7.ena = '1' and bus7.rnw = '0' and bus7.Adr = ADR_POSTFLG) then
               if (bus7.bEna(0) = '1') then
                  postflg7 <= postflg7 or bus7.Din(0);
               end if;
               if (bus7.bEna(1) = '1' and bus7.Din(15) = '1') then
                  halt7 <= '1';        -- HALTCNT 0x80 halt / 0xC0 sleep
                  if bus7.Din(14) = '1' and wake7 = '0' then
                     console_sleep <= '1';
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;

end architecture;
