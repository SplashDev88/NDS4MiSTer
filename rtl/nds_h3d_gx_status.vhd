-- SPDX-License-Identifier: GPL-3.0-or-later
-- Minimal synchronous ARM9 3D-status owner for the first hybrid-3D beta.
--
-- The packet frontend owns a real 256-entry normalized geometry-command FIFO.
-- This block exposes that local level rather than DDR mailbox occupancy:
--
--   bits 16..24 = level, bit 25 = level <= 127, bit 26 = level == 0
--
-- IRQ mode bits 31..30 are locally writable and irq_gxfifo is a true level:
-- mode 1 asserts for below-half, mode 2 asserts for empty, modes 0/3 do not.
-- Clearing ARM9 IF while the condition remains true therefore reasserts on
-- the next IRQ-controller evaluation, as hardware does.
--
-- Matrix stack/test busy, geometry busy, stack pointers, polygon/vertex
-- counts, and test/matrix result registers are not fabricated here. GXSTAT
-- returns zero for those fields. Addresses 0x04000604 and above remain
-- unclaimed and therefore read zero through the product's existing NDS open-
-- IO behavior. Workloads needing synchronous result-register semantics are a
-- later phase and must not infer them from packet-transport state.
--
-- DISP3DCNT at 0x04000060 is a CPU-visible read/modify/write register even
-- though its renderer-side writes are also transported to the HPS. Retain the
-- writable bits locally so software does not read open-bus zero and
-- accidentally clear texture enable. Bits 13..12 are hardware status/W1C;
-- this beta does not fabricate those status sources and therefore reads them
-- as zero.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_h3d_gx_status is
   port
   (
      clk            : in  std_logic;
      reset          : in  std_logic;
      service_ready  : in  std_logic;
      fifo_level     : in  std_logic_vector(8 downto 0) := (others => '0');

      gb_bus         : in  proc_bus_gb_type;
      wired_out      : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done     : out std_logic := '0';

      -- Level outputs. service_ready gates DMA startup, while the IRQ level is
      -- architectural and remains derived solely from the programmed mode.
      trig_gx        : out std_logic := '0';
      irq_gxfifo     : out std_logic := '0'
   );
end entity;

architecture arch of nds_h3d_gx_status is
   constant ADR_DISP3DCNT : std_logic_vector(27 downto 0) := x"0000060";
   constant ADR_GXSTAT : std_logic_vector(27 downto 0) := x"0000600";

   signal irq_mode    : std_logic_vector(1 downto 0) := "00";
   signal disp3dcnt   : std_logic_vector(14 downto 0) := (others => '0');
   signal gxstat_word : std_logic_vector(31 downto 0);
   signal fifo_below_half : std_logic;
   signal fifo_empty      : std_logic;
begin
   fifo_below_half <= '1' when unsigned(fifo_level) <= to_unsigned(127, 9)
                      else '0';
   fifo_empty <= '1' when unsigned(fifo_level) = to_unsigned(0, 9) else '0';

   process (all)
   begin
      gxstat_word <= (others => '0');
      gxstat_word(24 downto 16) <= fifo_level;
      gxstat_word(25) <= fifo_below_half;
      gxstat_word(26) <= fifo_empty;
      gxstat_word(31 downto 30) <= irq_mode;
   end process;

   wired_out  <= x"0000" & '0' & disp3dcnt
                    when gb_bus.Adr = ADR_DISP3DCNT and
                         gb_bus.acc /= ACCESS_8BIT else
                 gxstat_word when gb_bus.Adr = ADR_GXSTAT else
                 (others => '0');
   wired_done <= '1' when gb_bus.Adr = ADR_DISP3DCNT or
                           gb_bus.Adr = ADR_GXSTAT else '0';

   trig_gx <= service_ready and fifo_below_half;

   irq_gxfifo <= '1' when (irq_mode = "01" and fifo_below_half = '1') or
                           (irq_mode = "10" and fifo_empty = '1') else '0';

   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            irq_mode <= "00";
            disp3dcnt <= (others => '0');
         elsif (gb_bus.ena = '1' and gb_bus.rnw = '0') then
            if (gb_bus.Adr = ADR_GXSTAT and gb_bus.bEna(3) = '1') then
               -- The membus aligns Adr to 0x600 and places byte/halfword data
               -- in the selected lanes. Thus this covers word writes,
               -- halfword writes at 0x602, and byte writes at 0x603 without
               -- reconstructing address low bits.
               irq_mode <= gb_bus.Din(31 downto 30);
            elsif (gb_bus.Adr = ADR_DISP3DCNT and
                   gb_bus.acc /= ACCESS_8BIT) then
               if (gb_bus.bEna(0) = '1') then
                  disp3dcnt(7 downto 0) <= gb_bus.Din(7 downto 0);
               end if;
               if (gb_bus.bEna(1) = '1') then
                  disp3dcnt(11 downto 8) <= gb_bus.Din(11 downto 8);
                  disp3dcnt(14) <= gb_bus.Din(14);
                  disp3dcnt(13 downto 12) <= "00";
               end if;
            end if;
         end if;
      end if;
   end process;
end architecture;
