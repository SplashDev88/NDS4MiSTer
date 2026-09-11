library IEEE;
use IEEE.std_logic_1164.all;

library work;
use work.pProc_bus_gba.all;

-- Readback-only footprint of a disabled GPU2D engine.  Games commonly read a
-- control register, change one field, and write the complete word back.  When
-- Engine B's large FPGA renderer is omitted, returning an incomplete DISPCNT
-- silently clears unrelated fields before the ARM video mirror sees the
-- write. Retain DISPCNT and all four BGxCNT words: games also read their
-- character/screen bases to calculate graphics upload destinations. Dropping
-- those readbacks sends correct tile data to the wrong VRAM addresses.
-- This module does not enable rendering or transport for Engine B. The
-- 0xC0B1FFF7 mask matches melonDS's Engine-B register semantics.
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
   signal disp_cnt : std_logic_vector(31 downto 0) := (others => '0');
   signal bg01_cnt, bg23_cnt : std_logic_vector(31 downto 0) := (others => '0');
begin
   process (clk)
      variable next_disp_cnt : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then
         if reset = '1' or gb_bus.rst = '1' then
            disp_cnt <= (others => '0');
            bg01_cnt <= (others => '0');
            bg23_cnt <= (others => '0');
         elsif gb_bus.ena = '1' and gb_bus.rnw = '0' and
               (gb_bus.Adr(11 downto 0) = x"008" or
                gb_bus.Adr(11 downto 0) = x"00C") then
            for lane in 0 to 3 loop
               if gb_bus.bEna(lane) = '1' then
                  if gb_bus.Adr(2) = '0' then
                     bg01_cnt(lane * 8 + 7 downto lane * 8) <=
                        gb_bus.Din(lane * 8 + 7 downto lane * 8);
                  else
                     bg23_cnt(lane * 8 + 7 downto lane * 8) <=
                        gb_bus.Din(lane * 8 + 7 downto lane * 8);
                  end if;
               end if;
            end loop;
         elsif gb_bus.ena = '1' and gb_bus.rnw = '0' and
               gb_bus.Adr(11 downto 0) = x"000" then
            next_disp_cnt := disp_cnt;
            for lane in 0 to 3 loop
               if gb_bus.bEna(lane) = '1' then
                  next_disp_cnt(lane * 8 + 7 downto lane * 8) :=
                     gb_bus.Din(lane * 8 + 7 downto lane * 8);
               end if;
            end loop;
            disp_cnt <= next_disp_cnt and x"C0B1FFF7";
         end if;
      end if;
   end process;

   process (all)
   begin
      wired_out <= (others => '0');
      wired_done <= '0';
      if gb_bus.Adr(11 downto 0) = x"000" then
         wired_out <= disp_cnt;
         wired_done <= '1';
      elsif gb_bus.Adr(11 downto 0) = x"008" then
         wired_out <= bg01_cnt;
         wired_done <= '1';
      elsif gb_bus.Adr(11 downto 0) = x"00C" then
         wired_out <= bg23_cnt;
         wired_done <= '1';
      end if;
   end process;
end architecture;
