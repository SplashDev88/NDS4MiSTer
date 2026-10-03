-- SPDX-License-Identifier: GPL-3.0-or-later
-- Exercise the real B7 command/data bus and prefetch engine with an address-
-- tagged memory model. Tail/padding policy belongs to the island, not nds_card:
-- this test checks all 29 cartridge address bits and their 512 MiB wrap.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pProc_bus_gba.all;

entity tb_nds_card_large_rom is
   generic (owner_cpu : natural range 0 to 1 := 0;
            prefetch_depth : positive := 4;
            memory_delay : natural := 3);
end entity;

architecture sim of tb_nds_card_large_rom is
   constant ADR_AUXSPI  : std_logic_vector(27 downto 0) := x"00001A0";
   constant ADR_ROMCTRL : std_logic_vector(27 downto 0) := x"00001A4";
   constant ADR_CMD0    : std_logic_vector(27 downto 0) := x"00001A8";
   constant ADR_CMD4    : std_logic_vector(27 downto 0) := x"00001AC";
   constant ADR_DATA    : std_logic_vector(27 downto 0) := x"0100010";
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal finished : boolean := false;
   signal owner_bus, idle_bus : proc_bus_gb_type :=
      ((others => '0'), (others => '0'), '1', '0', ACCESS_32BIT,
       (others => '0'), '0');
   signal bus9, bus7 : proc_bus_gb_type;
   signal out9, out7, owner_out, dbg_card : std_logic_vector(31 downto 0);
   signal card_owner, card_ena, card_done : std_logic := '0';
   signal card_addr : std_logic_vector(28 downto 2);
   signal card_din : std_logic_vector(31 downto 0) := (others => '0');
   signal case_id : natural := 0;
   signal expected_base : unsigned(31 downto 0) := (others => '0');
   signal expected_words, requests_seen : natural := 0;
   signal hold_reply, inject_stale, mem_pending : std_logic := '0';

   function effective_address(address : unsigned(31 downto 0))
      return std_logic_vector is
      variable result : unsigned(31 downto 0) := address;
   begin
      if address < 16#8000# then
         result := to_unsigned(16#8000#, 32) +
                   (address and to_unsigned(16#1FF#, 32));
      end if;
      return "000" & std_logic_vector(result(28 downto 2)) & "00";
   end function;

   function image_word(address : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      -- The new bits 27 and 28 remains observable in returned data as well as in the
      -- request scoreboard, so a lower-half alias cannot accidentally pass.
      return address xor x"A5965A69";
   end function;
begin
   clk <= not clk after 5 ns when not finished else '0';
   card_owner <= '0' when owner_cpu = 0 else '1';
   bus9 <= owner_bus when owner_cpu = 0 else idle_bus;
   bus7 <= owner_bus when owner_cpu = 1 else idle_bus;
   owner_out <= out9 when owner_cpu = 0 else out7;

   dut : entity work.nds_card
   generic map (CARDSPEED_SHIFT => 2, CARDPREFETCH => prefetch_depth)
   port map (
      clk => clk, ce => '1', reset => reset, card7 => card_owner,
      fw_boot => '0', chipid => x"12345678",
      bus9 => bus9, wired_out9 => out9, wired_done9 => open,
      bus7 => bus7, wired_out7 => out7, wired_done7 => open,
      irq9_xfer => open, irq7_xfer => open, dbg_card => dbg_card,
      dma9_card => open, dma7_card => open,
      card_ena => card_ena, card_addr => card_addr,
      card_din => card_din, card_done => card_done);

   memory : process(clk)
      variable active_case : natural := 0;
      variable request_index, delay_left : natural := 0;
      variable pending : boolean := false;
      variable pending_data : std_logic_vector(31 downto 0);
      variable wanted : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then
         card_done <= '0';
         if active_case /= case_id then
            active_case := case_id;
            request_index := 0;
            requests_seen <= 0;
         end if;
         if reset = '1' then
            -- The island/pager resets with the console and cancels its reply.
            pending := false;
            delay_left := 0;
         else
            if inject_stale = '1' then
               assert not pending report "stale injection overlaps memory request"
                  severity failure;
               card_din <= x"DEADBEEF";
               card_done <= '1';
            elsif pending and hold_reply = '0' then
               if delay_left = 0 then
                  card_din <= pending_data;
                  card_done <= '1';
                  pending := false;
               else
                  delay_left := delay_left - 1;
               end if;
            end if;
            if card_ena = '1' then
               assert not pending report "multiple card requests outstanding"
                  severity failure;
               assert request_index < expected_words
                  report "prefetch read beyond transfer end" severity failure;
               wanted := effective_address(expected_base + request_index * 4);
               assert card_addr = wanted(28 downto 2)
                  report "B7 request " & integer'image(request_index) &
                         " expected " & to_hstring(wanted) & " got " &
                         to_hstring("000" & card_addr & "00") severity failure;
               pending_data := image_word("000" & card_addr & "00");
               delay_left := memory_delay;
               pending := true;
               request_index := request_index + 1;
               requests_seen <= request_index;
            end if;
         end if;
         if pending then mem_pending <= '1'; else mem_pending <= '0'; end if;
      end if;
   end process;

   stimulus : process
      procedure release_bus is
      begin
         owner_bus.ena <= '0';
         owner_bus.rnw <= '1';
         owner_bus.bEna <= (others => '0');
      end procedure;

      procedure write_reg(constant address : std_logic_vector(27 downto 0);
                          constant value : std_logic_vector(31 downto 0)) is
      begin
         wait until falling_edge(clk);
         owner_bus.Adr <= address;
         owner_bus.Din <= value;
         owner_bus.rnw <= '0';
         owner_bus.bEna <= "1111";
         owner_bus.ena <= '1';
         wait until rising_edge(clk); wait for 1 ns;
         release_bus;
      end procedure;

      procedure start_b7(constant address : std_logic_vector(31 downto 0);
                         constant words : positive) is
      begin
         expected_base <= unsigned(address);
         expected_words <= words;
         case_id <= case_id + 1;
         write_reg(ADR_CMD0, address(15 downto 8) & address(23 downto 16) &
                            address(31 downto 24) & x"B7");
         write_reg(ADR_CMD4, x"000000" & address(7 downto 0));
         if words = 1 then
            write_reg(ADR_ROMCTRL, x"87000000");
         else
            assert words = 128 report "unsupported test transfer length"
               severity failure;
            write_reg(ADR_ROMCTRL, x"81000000");
         end if;
      end procedure;

      procedure wait_ready is
      begin
         for cycle in 0 to 255 loop
            wait until rising_edge(clk); wait for 1 ns;
            exit when dbg_card(27) = '1';
         end loop;
         assert dbg_card(27) = '1' report "B7 data-ready timeout" severity failure;
      end procedure;

      procedure read_transfer(constant address : std_logic_vector(31 downto 0);
                              constant words : positive) is
         variable wanted : std_logic_vector(31 downto 0);
      begin
         start_b7(address, words);
         for word_index in 0 to words - 1 loop
            wait_ready;
            if words > 1 and word_index = 0 then
               -- Allow prefetch to fill behind the held bus word, then drain
               -- it. This exercises queue wrap and backpressure at every depth.
               for cycle in 1 to 160 loop
                  wait until rising_edge(clk); wait for 1 ns;
               end loop;
               assert requests_seen = prefetch_depth + 1
                  report "prefetch did not stop at a full queue" severity failure;
            end if;
            wait until falling_edge(clk);
            owner_bus.Adr <= ADR_DATA;
            owner_bus.rnw <= '1';
            owner_bus.bEna <= "1111";
            owner_bus.ena <= '1';
            wait for 1 ns;
            wanted := image_word(effective_address(unsigned(address) + word_index * 4));
            assert owner_out = wanted
               report "B7 data " & integer'image(word_index) &
                      " expected " & to_hstring(wanted) & " got " &
                      to_hstring(owner_out) severity failure;
            wait until rising_edge(clk); wait for 1 ns;
            release_bus;
         end loop;
         assert dbg_card(28 downto 27) = "00"
            report "B7 did not complete after final word" severity failure;
         assert requests_seen = words report "B7 request count mismatch"
            severity failure;
      end procedure;
   begin
      release_bus;
      for cycle in 1 to 4 loop wait until rising_edge(clk); end loop;
      wait until falling_edge(clk); reset <= '0';
      write_reg(ADR_AUXSPI, x"00008000");

      read_transfer(x"00010000", 1);
      read_transfer(x"08010000", 1); -- identical low 27 bits, distinct data
      read_transfer(x"10010000", 1); -- bit 28 must not alias the first word
      read_transfer(x"00000000", 1); -- existing secure-area redirect
      read_transfer(x"04001234", 1); -- existing smaller-ROM addressing
      read_transfer(x"07FFFFFC", 1);
      read_transfer(x"08000000", 1);
      read_transfer(x"0FBFFFFC", 1);
      read_transfer(x"0FC00000", 1);
      read_transfer(x"0FFFFFFC", 1);
      read_transfer(x"10000000", 1);
      read_transfer(x"13BFFFFC", 1);
      read_transfer(x"13C00000", 1);
      read_transfer(x"1FFFFFFC", 1);
      read_transfer(x"20000000", 1); -- command low 29 bits wrap to word zero
      read_transfer(x"07FFFFF0", 128); -- prefetch across 128 MiB
      read_transfer(x"0FBFFFF0", 128); -- prefetch across 252 MiB
      read_transfer(x"0FFFFFF0", 128); -- prefetch across 256 MiB, bit 28 retained
      read_transfer(x"13BFFFF0", 128); -- prefetch across 316 MiB policy boundary
      read_transfer(x"1FFFFFF0", 128); -- low-29-bit wrap at 512 MiB

      -- Abort an outstanding high-half request, empty the queue, and present
      -- a late reply while idle. The next lower-half transfer must be fresh.
      hold_reply <= '1';
      start_b7(x"10020000", 128);
      for cycle in 0 to 63 loop
         wait until rising_edge(clk); wait for 1 ns;
         exit when mem_pending = '1';
      end loop;
      assert mem_pending = '1' report "reset test did not catch outstanding read"
         severity failure;
      wait until falling_edge(clk); reset <= '1';
      for cycle in 1 to 3 loop wait until rising_edge(clk); end loop;
      wait for 1 ns;
      assert dbg_card(28 downto 27) = "00" and dbg_card(15 downto 13) = "000"
         report "reset retained busy/data/prefetch state" severity failure;
      wait until falling_edge(clk);
      reset <= '0'; hold_reply <= '0'; inject_stale <= '1';
      wait until falling_edge(clk); inject_stale <= '0';
      wait until rising_edge(clk); wait for 1 ns;
      write_reg(ADR_AUXSPI, x"00008000");
      read_transfer(x"00020000", 1);
      read_transfer(x"08020000", 1);
      read_transfer(x"10020000", 1);

      report "PASS: B7 29-bit addressing, boundary prefetch, reset and owner " &
             integer'image(owner_cpu) & " depth " & integer'image(prefetch_depth) &
             " memory delay " & integer'image(memory_delay);
      finished <= true;
      wait;
   end process;

   watchdog : process
   begin
      wait for 1 ms;
      assert finished report "large-ROM card regression timeout" severity failure;
      wait;
   end process;
end architecture;
