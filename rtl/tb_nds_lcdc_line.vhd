-- SPDX-License-Identifier: GPL-3.0-or-later
-- Public synthetic LCDC lines: ordered replies, request stalls, bank/line
-- latching and all 256 pixels including bit15-clear pixels and final words.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_nds_lcdc_line is
   generic (reply_delay : natural := 0);
end;
architecture sim of tb_nds_lcdc_line is
   signal clk : std_logic := '0';
   signal reset, start : std_logic := '0';
   signal line_y : integer range 0 to 191 := 0;
   signal bank : std_logic_vector(1 downto 0) := "00";
   signal busy, req, accept, done, we : std_logic := '0';
   signal addr : integer range 0 to 131071;
   signal data : std_logic_vector(31 downto 0) := (others => '0');
   signal px : integer range 0 to 255;
   signal py : integer range 0 to 191;
   signal color : std_logic_vector(17 downto 0);
   signal expected_base : natural := 0;
   signal expected_y : natural := 0;
   signal requests, pixels, cycles : natural := 0;
   type queue_t is array(0 to 3) of natural;
   function pattern(a : natural) return std_logic_vector is
      variable lo, hi : unsigned(15 downto 0);
   begin
      lo := to_unsigned((a*13) mod 65536,16);
      hi := to_unsigned((a*29+12345) mod 65536,16);
      return std_logic_vector(hi & lo);
   end;
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_lcdc_line port map (
      clk,reset,start,line_y,bank,busy,req,addr,accept,done,data,we,px,py,color);
   accept <= '1' when req='1' and cycles mod 7 /= 2 and cycles mod 7 /= 3 else '0';
   memory : process(clk)
      variable q, ready : queue_t := (others=>0);
      variable head, tail, count : natural := 0;
   begin
      if rising_edge(clk) then
         done <= '0';
         if reset='1' then
            head:=0;tail:=0;count:=0;requests<=0;cycles<=0;
         else
            cycles<=cycles+1;
            if count>0 then
               if ready(head)<=cycles then
                  done<='1';data<=pattern(q(head));head:=(head+1) mod 4;count:=count-1;
               end if;
            end if;
            if accept='1' then
               assert addr=expected_base+requests report "incorrect LCDC address/order" severity failure;
               assert requests<128 report "extra LCDC request" severity failure;
               assert count<4 report "LCDC credit overflow" severity failure;
               q(tail):=addr;ready(tail):=cycles+reply_delay+requests mod 3;
               tail:=(tail+1) mod 4;count:=count+1;requests<=requests+1;
            end if;
         end if;
      end if;
   end process;
   monitor : process(clk)
      variable w : std_logic_vector(31 downto 0);
      variable c : std_logic_vector(15 downto 0);
      variable expected : std_logic_vector(17 downto 0);
   begin
      if rising_edge(clk) then
         if reset='1' then pixels<=0;
         elsif we='1' then
            assert px=pixels and py=expected_y report "LCDC pixel coordinates/order" severity failure;
            w:=pattern(expected_base+pixels/2);
            if pixels mod 2=0 then c:=w(15 downto 0); else c:=w(31 downto 16); end if;
            expected:=c(14 downto 10)&'0'&c(9 downto 5)&'0'&c(4 downto 0)&'0';
            assert color=expected report "LCDC pixel color/bit15" severity failure;
            pixels<=pixels+1;
         end if;
      end if;
   end process;
   test : process
   begin
      -- Reset both ends with reads in flight, then start a fresh line below.
      reset<='1';wait until falling_edge(clk);wait until falling_edge(clk);
      reset<='0';start<='1';wait until falling_edge(clk);start<='0';
      for i in 1 to 7 loop wait until falling_edge(clk);end loop;
      for b in 0 to 3 loop
         for ycase in 0 to 1 loop
            reset<='1';wait until falling_edge(clk);wait until falling_edge(clk);
            reset<='0';bank<=std_logic_vector(to_unsigned(b,2));line_y<=ycase*191;
            expected_base<=b*32768+ycase*191*128;expected_y<=ycase*191;
            wait until falling_edge(clk);start<='1';wait until falling_edge(clk);start<='0';
            -- Input changes must not retarget an accepted line.
            bank<=std_logic_vector(to_unsigned((b+1) mod 4,2));line_y<=37;
            wait until busy='0';wait until falling_edge(clk);wait until falling_edge(clk);
            assert pixels=256 and requests=128 report "incomplete LCDC line" severity failure;
            for i in 1 to 10 loop wait until falling_edge(clk); assert req='0' and we='0' report "idle LCDC traffic" severity failure; end loop;
         end loop;
      end loop;
      report "PASS: LCDC all banks, edge lines, delayed memory, latched inputs and bit15" severity note;
      stop;wait;
   end process;
   watchdog : process begin wait for 1 ms;assert false report "LCDC timeout" severity failure;end process;
end;
