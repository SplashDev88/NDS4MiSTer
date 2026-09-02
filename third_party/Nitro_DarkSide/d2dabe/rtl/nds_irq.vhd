-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS interrupt controller (one instance per CPU).
-- IME 0x208 / IE 0x210 / IF 0x214, all 32-bit (vs GBA's 16-bit pair packed at
-- 0x200). Follows the gba_top IF-accumulate idiom: irq_in pulses OR into the
-- flags, a write to IF clears the acknowledged bits (write-1-to-clear),
-- cpu_irq is delivered registered when IME(0) and (IE and IF) /= 0.
-- Source bit meanings differ per CPU (see docs/NDS_HARDWARE.md interrupt
-- table); this module is bit-agnostic.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;

package pReg_nds_irq is
   -- IME is a one-bit register.  Bits 31:1 read as zero and ignore writes.
   constant NDS_IME : regmap_type := (16#000208#, 0, 0, 1, 0, readwrite);
   constant NDS_IE  : regmap_type := (16#000210#, 31, 0, 1, 0, readwrite);
   constant NDS_IF  : regmap_type := (16#000214#, 31, 0, 1, 0, readonly);
end package;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;
use work.pReg_nds_irq.all;

entity nds_irq is
   port
   (
      clk        : in  std_logic;
      ce         : in  std_logic;
      reset      : in  std_logic;

      gb_bus     : in  proc_bus_gb_type;
      wired_out  : out std_logic_vector(31 downto 0);
      wired_done : out std_logic;

      irq_in     : in  std_logic_vector(31 downto 0);  -- one-cycle pulses
      cpu_irq    : out std_logic := '0';
      cpu_unhalt : out std_logic := '0';

      -- Temporary live-hardware diagnostic taps. These expose state only;
      -- they do not participate in interrupt delivery.
      dbg_ime    : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_ie     : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_if     : out std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_irq is

   signal REG_IME     : std_logic_vector(0 downto 0);
   signal REG_IE      : std_logic_vector(31 downto 0);
   signal IF_written  : std_logic;
   signal IF_writeval : std_logic_vector(31 downto 0);

   signal IRPFLags    : std_logic_vector(31 downto 0) := (others => '0');

   type t_reg_wired_or is array (0 to 2) of std_logic_vector(31 downto 0);
   signal reg_wired_or   : t_reg_wired_or;
   signal reg_wired_done : std_logic_vector(0 to 2);

begin

   dbg_ime <= (31 downto 1 => '0') & REG_IME;
   dbg_ie  <= REG_IE;
   dbg_if  <= IRPFLags;

   iIME : entity work.eProcReg_gba generic map (NDS_IME)
      port map (clk, gb_bus, reg_wired_or(0), reg_wired_done(0), REG_IME, REG_IME);

   iIE  : entity work.eProcReg_gba generic map (NDS_IE)
      port map (clk, gb_bus, reg_wired_or(1), reg_wired_done(1), REG_IE, REG_IE);

   iIF  : entity work.eProcReg_gba generic map (NDS_IF)
      port map (clk, gb_bus, reg_wired_or(2), reg_wired_done(2), IRPFLags, open,
                open, IF_writeval, IF_written);

   process (all)
      variable wired_or : std_logic_vector(31 downto 0);
   begin
      wired_or := (others => '0');
      for i in 0 to 2 loop
         wired_or := wired_or or reg_wired_or(i);
      end loop;
      wired_out <= wired_or;
   end process;
   wired_done <= reg_wired_done(0) or reg_wired_done(1) or reg_wired_done(2);

   process (clk)
      variable flags : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            IRPFLags   <= (others => '0');
            cpu_irq    <= '0';
            cpu_unhalt <= '0';
         elsif (ce = '1') then
            -- ack first, then accumulate: a source firing in the same cycle
            -- as its acknowledge must win (hardware behavior)
            flags := IRPFLags;
            if (IF_written = '1') then
               flags := flags and (not IF_writeval);
            end if;
            flags := flags or irq_in;
            IRPFLags <= flags;

            cpu_unhalt <= '0';
            cpu_irq    <= '0';
            if ((flags and REG_IE) /= x"00000000") then
               cpu_unhalt <= '1';
               if (REG_IME(0) = '1') then
                  cpu_irq <= '1';
               end if;
            end if;
         end if;
      end if;
   end process;

end architecture;
