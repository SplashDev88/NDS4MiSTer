library IEEE;
use IEEE.std_logic_1164.all;

library work;
use work.pProc_bus_gba.all;

-- Readback-only footprint of a disabled GPU2D engine.  Games commonly read a
-- control register, change one field, and write the complete word back.  When
-- Engine B's large FPGA renderer is omitted, returning zero for those reads
-- silently clears unrelated fields before the ARM video mirror sees the
-- write.  Engine B hardware only supports display modes 0/1, so preserve its
-- mode bit here; all pixel, palette, OAM, and remaining register work stays on
-- the HPS.  This is the measured minimum needed by NSMB: hardware lost bit 16
-- while melonDS retained it (0x10400 became 0x0400, 0x11400 became 0x1400).
entity nds_gpu2d_register_shadow is
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;
      gb_bus     : in  proc_bus_gb_type;
      wired_out  : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done : out std_logic := '0'
   );
end entity;

architecture rtl of nds_gpu2d_register_shadow is
   signal display_mode : std_logic := '0';
begin
   process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' or gb_bus.rst = '1' then
            display_mode <= '0';
         elsif gb_bus.ena = '1' and gb_bus.rnw = '0' and
               gb_bus.Adr(11 downto 0) = x"000" and
               gb_bus.bEna(2) = '1' then
            display_mode <= gb_bus.Din(16);
         end if;
      end if;
   end process;

   process (all)
   begin
      wired_out <= (others => '0');
      wired_done <= '0';
      if gb_bus.Adr(11 downto 0) = x"000" then
         wired_out(16) <= display_mode;
         wired_done <= '1';
      end if;
   end process;
end architecture;
