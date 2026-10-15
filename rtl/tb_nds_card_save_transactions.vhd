-- Exercise the actual card register interface at save page/transaction limits.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_card_save_transactions is
   generic (TEST_CASE : natural := 0);
end entity;

architecture sim of tb_nds_card_save_transactions is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal kind : std_logic_vector(3 downto 0) := x"5";
   signal ir : std_logic := '0';
   signal bus9, bus7 : proc_bus_gb_type := (
      Din => (others => '0'), Adr => (others => '0'), rnw => '1',
      ena => '0', acc => ACCESS_32BIT, bEna => (others => '0'), rst => '0');
   signal response : std_logic_vector(31 downto 0);
   signal address, last_write : std_logic_vector(19 downto 0);
   signal write_data, read_data : std_logic_vector(7 downto 0);
   signal write_enable, access_active : std_logic;
   signal writes : natural := 0;
   function pattern(a : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(a mod 256, 8) xor
                             to_unsigned((a / 256) mod 256, 8) xor x"A5");
   end function;
begin
   clk <= not clk after 5 ns;
   -- Synchronous backing RAM, as in the product. Address-dependent contents
   -- catch a reset/reinterpreted command during a long sequential read.
   process(clk)
   begin
      if rising_edge(clk) then
         read_data <= pattern(to_integer(unsigned(address)));
         if write_enable = '1' then
            last_write <= address;
            writes <= writes + 1;
         end if;
      end if;
   end process;

   dut : entity work.nds_card
      generic map(CARDSPEED_SHIFT => 2)
      port map(clk => clk, ce => '1', reset => reset, card7 => '0', fw_boot => '0',
         chipid => x"00001FC2", bus9 => bus9, bus7 => bus7,
         wired_out9 => response, wired_done9 => open,
         wired_out7 => open, wired_done7 => open,
         irq9_xfer => open, irq7_xfer => open, dma9_card => open, dma7_card => open,
         dbg_card => open, card_ena => open, card_addr => open,
         card_din => (others => '0'), card_done => '0',
         backup_addr => address, backup_write_data => write_data,
         backup_write_enable => write_enable, backup_read_data => read_data,
         backup_write_toggle => open, backup_save_type => kind,
         backup_access_active => access_active, backup_cache_ready => '1',
         backup_ir_enable => ir);

   process
      procedure reg_write(data : std_logic_vector(31 downto 0);
                          enables : std_logic_vector(3 downto 0)) is
      begin
         wait until falling_edge(clk);
         bus9.Adr <= x"00001A0"; bus9.Din <= data; bus9.bEna <= enables;
         bus9.rnw <= '0'; bus9.ena <= '1';
         wait until falling_edge(clk);
         bus9.ena <= '0'; bus9.rnw <= '1'; bus9.bEna <= "0000";
      end procedure;
      procedure byte_tx(value : std_logic_vector(7 downto 0); hold : std_logic) is
         variable control, data : std_logic_vector(31 downto 0) := (others => '0');
      begin
         control(6) := hold;
         reg_write(control, "0001");
         data(23 downto 16) := value;
         reg_write(data, "0100");
         for i in 0 to 66 loop wait until rising_edge(clk); end loop;
         wait for 1 ns;
         assert response(7) = '0' report "SPI transfer failed to finish" severity failure;
      end procedure;
      procedure start_command(command : std_logic_vector(7 downto 0);
                              hold : std_logic := '1') is
      begin
         if ir = '1' then byte_tx(x"00", '1'); end if;
         byte_tx(command, hold);
      end procedure;
      procedure address_tx(a : natural; count : positive) is
      begin
         if count = 3 then byte_tx(std_logic_vector(to_unsigned(a / 65536, 8)), '1'); end if;
         if count >= 2 then byte_tx(std_logic_vector(to_unsigned((a / 256) mod 256, 8)), '1'); end if;
         byte_tx(std_logic_vector(to_unsigned(a mod 256, 8)), '1');
      end procedure;
      procedure page_test(device : natural; command : std_logic_vector(7 downto 0)) is
         variable before, expected, addrbytes : natural;
      begin
         kind <= std_logic_vector(to_unsigned(device, 4));
         wait until falling_edge(clk);
         start_command(x"06", '0');
         start_command(command);
         if device = 2 or device = 3 then addrbytes := 2; else addrbytes := 3; end if;
         address_tx(16#1FE#, addrbytes);
         for i in 0 to 3 loop
            before := writes;
            if i = 3 then byte_tx(x"5A", '0'); else byte_tx(x"5A", '1'); end if;
            if device >= 5 then expected := 16#100# + ((16#FE# + i) mod 256);
            else expected := 16#1FE# + i; end if;
            assert writes = before + 1 report "page write lost or duplicated a byte" severity failure;
            assert to_integer(unsigned(last_write)) = expected
               report "page address mismatch, device " & integer'image(device) &
                      " byte " & integer'image(i) & " got " &
                      integer'image(to_integer(unsigned(last_write))) severity failure;
         end loop;
         start_command(x"05"); byte_tx(x"00", '0');
         assert response(17) = '0' report "write enable stayed set after completed write" severity failure;
      end procedure;
      procedure long_read(device : natural; command : std_logic_vector(7 downto 0)) is
         variable count, size : positive;
      begin
         kind <= std_logic_vector(to_unsigned(device, 4));
         wait until falling_edge(clk);
         if device = 1 then count := 1; size := 512;
         elsif device = 2 then count := 2; size := 8192;
         elsif device = 3 then count := 2; size := 65536;
         else count := 3; size := 1048576; end if;
         start_command(command); address_tx(0, count);
         if command = x"0B" and device >= 5 then byte_tx(x"00", '1'); end if;
         for i in 0 to 65540 loop
            if i = 65540 then byte_tx(x"00", '0'); else byte_tx(x"00", '1'); end if;
            assert response(23 downto 16) = pattern(i mod size)
               report "long read changed command/address at byte " & integer'image(i) &
                      " device " & integer'image(device) severity failure;
         end loop;
         -- A subsequent command must still start at byte zero.
         start_command(x"06", '0'); start_command(x"05"); byte_tx(x"00", '0');
         assert response(17) = '1' report "new command failed after long transfer" severity failure;
      end procedure;
   begin
      wait for 40 ns; wait until falling_edge(clk); reset <= '0';
      reg_write(x"0000A000", "0010");
      if TEST_CASE = 0 or TEST_CASE = 1 then
         for device in 2 to 7 loop
            page_test(device, x"02");
            if device >= 5 then page_test(device, x"0A"); end if;
         end loop;
         ir <= '1'; wait until falling_edge(clk); page_test(7, x"0A"); ir <= '0';
         report "PASS: flash page wrap, regular EEPROM linear writes, IR page wrap";
      end if;
      if TEST_CASE = 0 or TEST_CASE = 2 then
         for device in 1 to 3 loop long_read(device, x"03"); end loop;
         long_read(7, x"03"); long_read(7, x"0B");
         ir <= '1'; wait until falling_edge(clk); long_read(7, x"0B");
         report "PASS: long tiny/regular/flash/IR transfers and subsequent command";
      end if;
      stop;
      wait;
   end process;
end architecture;
