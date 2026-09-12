-- SPDX-License-Identifier: GPL-3.0-or-later
-- Product-path regression for a new ROMCTRL start immediately after the final
-- data-port read of the preceding transfer.

library IEEE;
use IEEE.std_logic_1164.all;

use work.pProc_bus_gba.all;

entity tb_nds_card_back_to_back is
   generic (owner_cpu : natural range 0 to 1 := 0;
            enable_irq : boolean := false;
            next_gap : natural := 0);
end entity;

architecture sim of tb_nds_card_back_to_back is
   constant ADR_AUXSPI  : std_logic_vector(27 downto 0) := x"00001A0";
   constant ADR_ROMCTRL : std_logic_vector(27 downto 0) := x"00001A4";
   constant ADR_CMD0    : std_logic_vector(27 downto 0) := x"00001A8";
   constant ADR_DATA    : std_logic_vector(27 downto 0) := x"0100010";

   signal clk, ce       : std_logic := '0';
   signal reset         : std_logic := '1';
   signal done          : boolean := false;
   signal bus9          : proc_bus_gb_type :=
      ((others => '0'), (others => '0'), '1', '0', ACCESS_32BIT,
       (others => '0'), '0');
   signal bus7          : proc_bus_gb_type :=
      ((others => '0'), (others => '0'), '1', '0', ACCESS_32BIT,
       (others => '0'), '0');
   signal port9, port7 : proc_bus_gb_type;
   signal actual_out9, actual_out7 : std_logic_vector(31 downto 0);
   signal card_owner : std_logic;
   signal wired_out9, wired_out7 : std_logic_vector(31 downto 0);
   signal wired_done9, wired_done7 : std_logic;
   signal irq9_xfer, irq7_xfer, dma9_card, dma7_card : std_logic;
   signal dbg_card      : std_logic_vector(31 downto 0);
   signal card_ena      : std_logic;
   signal card_addr     : std_logic_vector(26 downto 2);
   signal chipid        : std_logic_vector(31 downto 0) := x"12345678";
begin
   clk <= not clk after 5 ns when not done else '0';
   ce  <= '1';
   card_owner <= '0' when owner_cpu = 0 else '1';
   port9 <= bus9 when owner_cpu = 0 else bus7;
   port7 <= bus9 when owner_cpu = 1 else bus7;
   wired_out9 <= actual_out9 when owner_cpu = 0 else actual_out7;

   dut : entity work.nds_card
   generic map
   (
      CARDSPEED_SHIFT => 2,
      CARDPREFETCH    => 4
   )
   port map
   (
      clk => clk, ce => ce, reset => reset, card7 => card_owner, fw_boot => '0',
      chipid => chipid,
      backup_read_data => (others => '1'),
      bus9 => port9, wired_out9 => actual_out9, wired_done9 => wired_done9,
      bus7 => port7, wired_out7 => actual_out7, wired_done7 => wired_done7,
      irq9_xfer => irq9_xfer, irq7_xfer => irq7_xfer,
      dbg_card => dbg_card, dma9_card => dma9_card, dma7_card => dma7_card,
      card_ena => card_ena, card_addr => card_addr,
      card_din => (others => '0'), card_done => '0'
   );

   process
      procedure idle_bus is
      begin
         bus9.ena <= '0';
         bus9.rnw <= '1';
         bus9.bEna <= (others => '0');
      end procedure;

      procedure write9(
         constant address : std_logic_vector(27 downto 0);
         constant value   : std_logic_vector(31 downto 0);
         constant be      : std_logic_vector(3 downto 0)) is
      begin
         wait until falling_edge(clk);
         bus9.Adr <= address;
         bus9.Din <= value;
         bus9.rnw <= '0';
         bus9.bEna <= be;
         bus9.ena <= '1';
         wait until rising_edge(clk);
         wait for 1 ns;
         idle_bus;
      end procedure;

      procedure start_b8 is
      begin
         write9(ADR_CMD0, x"000000B8", "0001");
         -- busy=1, read direction, block-size 7 = one 32-bit word.
         write9(ADR_ROMCTRL, x"87000000", "1111");
      end procedure;

      procedure wait_ready is
      begin
         for i in 0 to 63 loop
            wait until rising_edge(clk);
            wait for 1 ns;
            exit when dbg_card(27) = '1';
         end loop;
         assert dbg_card(27) = '1'
            report "card word did not become ready" severity failure;
      end procedure;

      procedure pop_then_start_b8 is
      begin
         -- Present the final read for one bus cycle. The next ROMCTRL write is
         -- intentionally issued on the immediately following bus cycle, as
         -- a bus master may legally issue adjacent transfers.
         wait until falling_edge(clk);
         bus9.Adr <= ADR_DATA;
         bus9.rnw <= '1';
         bus9.bEna <= "1111";
         bus9.ena <= '1';
         wait until rising_edge(clk);
         wait for 1 ns;
         assert wired_out9 = x"12345678"
            report "first B8 returned the wrong chip ID" severity failure;
         assert dbg_card(28 downto 27) = "00"
            report "final pop did not clear busy and data-ready" severity failure;
         if enable_irq then
            assert (owner_cpu = 0 and irq9_xfer = '1' and irq7_xfer = '0') or
                   (owner_cpu = 1 and irq7_xfer = '1' and irq9_xfer = '0')
               report "completion IRQ missing or delivered to wrong CPU" severity failure;
         else
            assert irq9_xfer = '0' and irq7_xfer = '0'
               report "IRQ asserted while disabled" severity failure;
         end if;
         idle_bus;
         for i in 1 to next_gap loop
            wait until rising_edge(clk); wait for 1 ns;
            assert irq9_xfer = '0' and irq7_xfer = '0'
               report "duplicate completion IRQ" severity failure;
         end loop;

         chipid <= x"89ABCDEF";
         write9(ADR_ROMCTRL, x"87000000", "1111");
      end procedure;
   begin
      idle_bus;
      for i in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';

      -- Enable the slot in ROM mode, then perform two adjacent one-word card
      -- transfers without inserting an artificial idle cycle between them.
      if enable_irq then
         write9(ADR_AUXSPI, x"0000C000", "0010");
      else
         write9(ADR_AUXSPI, x"00008000", "0010");
      end if;
      start_b8;
      wait_ready;
      -- An access from the CPU that does not own the cartridge cannot pop
      -- its ready word or produce a completion interrupt.
      wait until falling_edge(clk);
      bus7.Adr <= ADR_DATA; bus7.rnw <= '1'; bus7.ena <= '1';
      bus7.bEna <= "1111";
      wait until rising_edge(clk); wait for 1 ns;
      bus7.ena <= '0';
      assert dbg_card(28 downto 27) = "11" and irq9_xfer = '0' and irq7_xfer = '0'
         report "nonowner read consumed cartridge data" severity failure;
      pop_then_start_b8;
      wait_ready;

      wait until falling_edge(clk);
      bus9.Adr <= ADR_DATA;
      bus9.rnw <= '1';
      bus9.bEna <= "1111";
      bus9.ena <= '1';
      wait for 1 ns;
      assert wired_out9 = x"89ABCDEF"
         report "back-to-back B8 start was lost or returned stale data"
         severity failure;

      wait until rising_edge(clk); wait for 1 ns; idle_bus;
      assert dbg_card(28 downto 27) = "00"
         report "second transfer did not complete" severity failure;
      wait until rising_edge(clk); wait for 1 ns;
      assert irq9_xfer = '0' and irq7_xfer = '0'
         report "completion IRQ lasted more than one cycle" severity failure;
      report "PASS: final card pop, IRQ routing and following ROMCTRL start complete"
         severity note;
      done <= true;
      wait;
   end process;

   process
   begin
      wait for 10 us;
      assert done report "back-to-back card regression timeout" severity failure;
      wait;
   end process;
end architecture;
