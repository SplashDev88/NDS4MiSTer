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
   generic(EXPERIMENTAL_CHECKPOINT : boolean := false);
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
      dbg_if     : out std_logic_vector(31 downto 0) := (others => '0');
      -- Observation only. Sources/bus masters must be held separately.
      checkpoint_idle : out std_logic := '0';
      -- Fixed-point component image: word 0 IME, 1 IE, 2 IF. The common
      -- owner must hold all source/bus masters throughout capture. Restore
      -- only under reset; every word is required before ready can assert.
      checkpoint_address : in unsigned(1 downto 0) := (others => '0');
      checkpoint_data : out std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_valid : out std_logic := '0';
      checkpoint_restore : in std_logic := '0';
      checkpoint_write : in std_logic := '0';
      checkpoint_write_data : in std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_restore_ready : out std_logic := '0';
      checkpoint_restore_error : out std_logic := '0'
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
   signal register_bus : proc_bus_gb_type;
   signal restore_loaded : std_logic_vector(2 downto 0) := "000";
   signal restore_error : std_logic := '0';
   signal restore_active, restore_write_valid : std_logic;
   signal expected_unhalt, expected_irq : std_logic;

begin

   -- A held level source (notably GX) need not go low: it is settled once
   -- its bits are already in IF and the registered CPU outputs agree with
   -- IME/IE/IF. Requiring irq_in=0 would reject valid boundaries forever.
   -- Conversely a just-written IE/IME can leave one cycle of output work
   -- even with no source pulse or bus request currently asserted.
   expected_unhalt <= '1' when (IRPFLags and REG_IE) /= x"00000000" else '0';
   expected_irq <= expected_unhalt and REG_IME(0);
   process(all) begin
      checkpoint_idle <= '0';
      if reset = '0' and gb_bus.rst = '0' and gb_bus.ena = '0' and
         IF_written = '0' and (irq_in and not IRPFLags) = x"00000000" and
         cpu_unhalt = expected_unhalt and cpu_irq = expected_irq then
         checkpoint_idle <= '1';
      end if;
   end process;

   restore_active <= '1' when EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0';
   restore_write_valid <= '1' when restore_active = '1' and restore_error = '0' and
      checkpoint_write = '1' and checkpoint_address < 3 and
      (checkpoint_address /= 0 or checkpoint_write_data(31 downto 1) = (31 downto 1 => '0')) else '0';

   -- Reuse the existing live IE/IME registers, rather than adding full shadow
   -- banks. During restore the ordinary bus reset must not erase earlier
   -- writes on every edge; IF is loaded directly below, never via W1C.
   process(all) begin
      register_bus <= gb_bus;
      if restore_active = '1' then
         register_bus.rst <= '0'; register_bus.rnw <= '0';
         register_bus.acc <= ACCESS_32BIT; register_bus.bEna <= "1111";
         register_bus.Din <= checkpoint_write_data; register_bus.ena <= '0';
         register_bus.Adr <= std_logic_vector(to_unsigned(16#208#, register_bus.Adr'length));
         if checkpoint_address = 1 then
            register_bus.Adr <= std_logic_vector(to_unsigned(16#210#, register_bus.Adr'length));
         end if;
         if checkpoint_address < 2 then register_bus.ena <= restore_write_valid; end if;
      end if;
   end process;

   process(clk) begin
      if rising_edge(clk) then
         if not EXPERIMENTAL_CHECKPOINT or checkpoint_restore = '0' then
            restore_loaded <= "000"; restore_error <= '0';
         elsif reset = '0' then
            restore_error <= '1';
         elsif checkpoint_write = '1' then
            if restore_write_valid = '1' then
               restore_loaded(to_integer(checkpoint_address)) <= '1';
            else restore_error <= '1'; end if;
         end if;
      end if;
   end process;
   checkpoint_restore_error <= restore_error when EXPERIMENTAL_CHECKPOINT else '0';
   checkpoint_restore_ready <= '1' when restore_active = '1' and restore_loaded = "111" and
      restore_error = '0' and checkpoint_write = '0' and
      cpu_unhalt = expected_unhalt and cpu_irq = expected_irq else '0';
   process(all) begin
      checkpoint_data <= (others => '0'); checkpoint_valid <= '0';
      if EXPERIMENTAL_CHECKPOINT and checkpoint_address < 3 and
         ((checkpoint_idle = '1' and checkpoint_restore = '0') or checkpoint_restore_ready = '1') then
         checkpoint_valid <= '1';
         case to_integer(checkpoint_address) is
            when 0 => checkpoint_data <= (31 downto 1 => '0') & REG_IME;
            when 1 => checkpoint_data <= REG_IE;
            when 2 => checkpoint_data <= IRPFLags;
            when others => null;
         end case;
      end if;
   end process;

   dbg_ime <= (31 downto 1 => '0') & REG_IME;
   dbg_ie  <= REG_IE;
   dbg_if  <= IRPFLags;

   iIME : entity work.eProcReg_gba generic map (NDS_IME)
      port map (clk, register_bus, reg_wired_or(0), reg_wired_done(0), REG_IME, REG_IME);

   iIE  : entity work.eProcReg_gba generic map (NDS_IE)
      port map (clk, register_bus, reg_wired_or(1), reg_wired_done(1), REG_IE, REG_IE);

   iIF  : entity work.eProcReg_gba generic map (NDS_IF)
      port map (clk, register_bus, reg_wired_or(2), reg_wired_done(2), IRPFLags, open,
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
            if restore_active = '1' then
               if restore_write_valid = '1' and checkpoint_address = 2 then
                  IRPFLags <= checkpoint_write_data;
               end if;
               -- At the supported fixed point these outputs are redundant
               -- with IME/IE/IF. Reconstruct them before reset is released,
               -- so the first resumed CPU edge observes the original IRQ.
               cpu_irq <= expected_irq; cpu_unhalt <= expected_unhalt;
            else
               IRPFLags   <= (others => '0');
               cpu_irq    <= '0';
               cpu_unhalt <= '0';
            end if;
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
