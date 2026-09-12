-- SPDX-License-Identifier: GPL-3.0-or-later
-- Direct VRAM display, one accepted line at a time. Four word credits cover
-- both outstanding memory reads and returned words awaiting pixel output.
-- The ordinary renderer and ARM service do no work for this reader while idle.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nds_lcdc_line is
   port (
      clk, reset, start : in std_logic;
      line_y : in integer range 0 to 191;
      bank : in std_logic_vector(1 downto 0);
      busy : out std_logic;
      mem_req : out std_logic;
      mem_addr : out integer range 0 to 131071;
      mem_accept, mem_done : in std_logic;
      mem_data : in std_logic_vector(31 downto 0);
      pixel_we : out std_logic := '0';
      pixel_x : out integer range 0 to 255 := 0;
      pixel_y : out integer range 0 to 191 := 0;
      pixel_data : out std_logic_vector(17 downto 0) := (others => '0')
   );
end entity;

architecture rtl of nds_lcdc_line is
   type words_t is array (0 to 3) of std_logic_vector(31 downto 0);
   signal words : words_t;
   signal active : std_logic := '0';
   signal base : integer range 0 to 130944 := 0;
   signal y : integer range 0 to 191 := 0;
   signal issued, returned, consumed : integer range 0 to 128 := 0;
   signal high_half : std_logic := '0';
   signal request : std_logic;
begin
   busy <= active;
   request <= '1' when active = '1' and issued < 128 and issued-consumed < 4 else '0';
   mem_req <= request;
   -- Clamp the inactive address as well: after issuing the last word of bank D
   -- the counter may be 128, but that is not a valid request address.
   mem_addr <= base + issued when issued < 128 else base;

   process(clk)
      variable color : std_logic_vector(15 downto 0);
   begin
      if rising_edge(clk) then
         pixel_we <= '0';
         if reset = '1' then
            active <= '0'; issued <= 0; returned <= 0; consumed <= 0;
            high_half <= '0';
         elsif start = '1' and active = '0' then
            active <= '1';
            base <= to_integer(unsigned(bank))*32768 + line_y*128;
            y <= line_y;
            issued <= 0; returned <= 0; consumed <= 0;
            high_half <= '0';
         elsif active = '1' then
            if request = '1' and mem_accept = '1' then
               issued <= issued + 1;
            end if;
            if mem_done = '1' then
               assert returned < issued or (request = '1' and mem_accept = '1')
                  report "LCDC reply without an accepted request" severity failure;
               words(returned mod 4) <= mem_data;
               returned <= returned + 1;
            end if;
            if consumed < returned then
               if high_half = '0' then
                  color := words(consumed mod 4)(15 downto 0);
                  pixel_x <= consumed*2;
                  high_half <= '1';
               else
                  color := words(consumed mod 4)(31 downto 16);
                  pixel_x <= consumed*2+1;
                  high_half <= '0';
                  consumed <= consumed+1;
                  if consumed = 127 then active <= '0'; end if;
               end if;
               -- LCDC displays opaque BGR555; bit15 has no transparency role.
               -- Its 5-to-6-bit conversion appends zero, as in DS VRAM display.
               pixel_data <= color(14 downto 10) & '0' & color(9 downto 5) & '0' & color(4 downto 0) & '0';
               pixel_y <= y;
               pixel_we <= '1';
            end if;
         end if;
      end if;
   end process;
end architecture;
