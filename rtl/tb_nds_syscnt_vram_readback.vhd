-- SPDX-License-Identifier: GPL-3.0-or-later
-- Regression coverage for InsaneFriend (saneFriend)'s King Kong VRAMCNT fix.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_syscnt_vram_readback is end;
architecture test of tb_nds_syscnt_vram_readback is
   signal clk : std_logic := '0';
   signal reset, preset : std_logic := '0';
   constant idle : proc_bus_gb_type := (
      Din => (others => '0'), Adr => (others => '0'), rnw => '1',
      ena => '0', acc => ACCESS_32BIT, bEna => "0000", rst => '0');
   signal b9, b7 : proc_bus_gb_type := idle;
   signal d9, d7 : std_logic_vector(31 downto 0);
   signal done9, done7 : std_logic;
   signal vram : std_logic_vector(71 downto 0);
   signal wram : std_logic_vector(1 downto 0);
begin
   clk <= not clk after 5 ns;
   dut: entity work.nds_syscnt port map (
      clk => clk, reset => reset, bus9 => b9, wired_out9 => d9,
      wired_done9 => done9, bus7 => b7, wired_out7 => d7,
      wired_done7 => done7, preset_direct => preset,
      wramcnt => wram, vramcnt => vram, pow_2da => open, pow_2db => open,
      pow_swap => open, exmem_gba7 => open, exmem_card7 => open,
      exmem_prio7 => open, halt7 => open);
   process
      type bytes is array (0 to 8) of std_logic_vector(7 downto 0);
      -- melonDS GPU::MapVRAM_AB/CD/E/FG/H/I implemented register bits.
      constant masks : bytes := (x"9B",x"9B",x"9F",x"9F",x"87",x"9F",x"9F",x"83",x"83");
      variable expected : bytes := (others => x"00");
      variable saved : std_logic_vector(7 downto 0);
      variable address, lane : natural;
      procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end;
      procedure put(signal busx : out proc_bus_gb_type;
                    adr : natural; data : std_logic_vector(31 downto 0);
                    mask : std_logic_vector(3 downto 0)) is
      begin
         busx <= idle;
         busx.Adr <= std_logic_vector(to_unsigned(adr, 28));
         busx.Din <= data; busx.bEna <= mask; busx.ena <= '1'; busx.rnw <= '0';
         tick; busx <= idle; wait for 1 ns;
      end;
      procedure put_byte(adr, value : natural) is
         variable data : std_logic_vector(31 downto 0) := (others => '0');
         variable mask : std_logic_vector(3 downto 0) := (others => '0');
      begin
         data((adr mod 4)*8+7 downto (adr mod 4)*8) := std_logic_vector(to_unsigned(value,8));
         mask(adr mod 4) := '1'; put(b9, adr - (adr mod 4), data, mask);
      end;
      procedure check_all(w : natural) is
         variable rd : bytes;
      begin
         for bank in 0 to 8 loop rd(bank) := expected(bank) and masks(bank); end loop;
         b9.Adr <= x"0000240"; wait for 1 ns;
         assert done9 = '1' and d9 = rd(3)&rd(2)&rd(1)&rd(0)
            report "VRAMCNT A-D readback/lane preservation" severity failure;
         b9.Adr <= x"0000244"; wait for 1 ns;
         assert done9 = '1' and d9 = std_logic_vector(to_unsigned(w,8))&rd(6)&rd(5)&rd(4)
            report "VRAMCNT E-G / WRAMCNT shared word" severity failure;
         b9.Adr <= x"0000248"; wait for 1 ns;
         assert done9 = '1' and d9 = x"0000"&rd(8)&rd(7)
            report "VRAMCNT H-I / unused lanes" severity failure;
         for bank in 0 to 8 loop
            assert vram(bank*8+7 downto bank*8) = expected(bank)
               report "VRAM mapping output changed" severity failure;
         end loop;
      end;
   begin
      reset <= '1'; tick; reset <= '0'; check_all(0);
      preset <= '1'; tick; preset <= '0'; check_all(3);
      for bank in 0 to 8 loop
         if bank < 7 then address := 16#240# + bank;
         else address := 16#241# + bank; end if;
         for value in 0 to 255 loop
            put_byte(address, value); expected(bank) := std_logic_vector(to_unsigned(value,8));
            check_all(3);
         end loop;
      end loop;
      -- King's texture streaming: save the byte, enable LCDC, restore it.
      for bank in 0 to 8 loop
         if bank < 7 then address := 16#240# + bank;
         else address := 16#241# + bank; end if;
         put_byte(address, 16#83#); expected(bank) := x"83";
         b9.Adr <= std_logic_vector(to_unsigned(address - address mod 4,28)); wait for 1 ns;
         lane := address mod 4; saved := d9(lane*8+7 downto lane*8);
         put_byte(address,16#80#); expected(bank) := x"80"; check_all(3);
         put_byte(address,to_integer(unsigned(saved))); expected(bank) := saved; check_all(3);
      end loop;
      -- ARM7's status view and its write protection remain independent.
      put_byte(16#242#,16#82#); expected(2) := x"82";
      put_byte(16#243#,16#82#); expected(3) := x"82";
      b7.Adr <= x"0000240"; wait for 1 ns;
      assert done7 = '1' and d7 = x"00000303" severity failure;
      put(b7,16#240#,x"ffffffff","1111"); check_all(3);
      put_byte(16#247#,16#fe#); check_all(2);
      b7.Adr <= x"0000240"; wait for 1 ns;
      assert d7 = x"00000203" and wram = "10" severity failure;
      -- Full-word stores retain their lane order, including unused bytes.
      put(b9,16#240#,x"84838281","1111");
      expected(0):=x"81"; expected(1):=x"82"; expected(2):=x"83"; expected(3):=x"84";
      put(b9,16#244#,x"ff878685","1111");
      expected(4):=x"85"; expected(5):=x"86"; expected(6):=x"87";
      put(b9,16#248#,x"ffff8988","1111"); expected(7):=x"88"; expected(8):=x"89";
      check_all(3);
      reset <= '1'; tick; reset <= '0'; expected := (others => x"00"); check_all(0);
      report "SYSCNT_VRAM_READBACK_PASS bytes=2304 streaming_restore=9 arm7=1 reset=1";
      stop; wait;
   end process;
end architecture;
