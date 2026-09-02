-- Directed AUXSPI regression for tiny/regular EEPROM, FRAM-compatible regular
-- devices, and retail flash program/read/erase/status semantics.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_card_eeprom_sizes is
end entity;

architecture sim of tb_nds_card_eeprom_sizes is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal backup_save_type : std_logic_vector(3 downto 0) := "0010";
   signal bus9, bus7 : proc_bus_gb_type := (
      Din => (others => '0'), Adr => (others => '0'), rnw => '1',
      ena => '0', acc => ACCESS_32BIT, bEna => (others => '0'), rst => '0');
   signal wired_out9, wired_out7 : std_logic_vector(31 downto 0);
   signal wired_done9, wired_done7 : std_logic;
   signal backup_addr : std_logic_vector(19 downto 0);
   signal backup_write_data : std_logic_vector(7 downto 0);
   signal backup_write_enable : std_logic;
   signal backup_read_data : std_logic_vector(7 downto 0) := (others => '1');
   signal backup_write_toggle : std_logic;
   signal backup_access_active : std_logic;
   signal card_ena : std_logic;
   signal card_addr : std_logic_vector(26 downto 2);
   signal irq9_xfer, irq7_xfer, dma9_card, dma7_card : std_logic;
   signal dbg_card : std_logic_vector(31 downto 0);

   -- Sparse model: only the directed addresses need storage. The product's
   -- complete address is still checked, without allocating a 1 MiB VHDL array.
   signal m00123, m0e123, m1e123, m12345, m12410, mfe123 :
      std_logic_vector(7 downto 0) := x"FF";
   signal last_write_addr : std_logic_vector(19 downto 0) := (others => '0');
   signal last_write_data : std_logic_vector(7 downto 0) := (others => '0');

   constant ADR_AUXSPI : std_logic_vector(27 downto 0) := x"00001A0";
begin
   clk <= not clk after 5 ns;

   process (clk)
   begin
      if rising_edge(clk) then
         if backup_write_enable = '1' then
            last_write_addr <= backup_addr;
            last_write_data <= backup_write_data;
            case to_integer(unsigned(backup_addr)) is
               when 16#00123# => m00123 <= backup_write_data;
               when 16#0E123# => m0e123 <= backup_write_data;
               when 16#1E123# => m1e123 <= backup_write_data;
               when 16#12345# => m12345 <= backup_write_data;
               when 16#12410# => m12410 <= backup_write_data;
               when 16#FE123# => mfe123 <= backup_write_data;
               when others => null;
            end case;
         end if;
         case to_integer(unsigned(backup_addr)) is
            when 16#00123# => backup_read_data <= m00123;
            when 16#0E123# => backup_read_data <= m0e123;
            when 16#1E123# => backup_read_data <= m1e123;
            when 16#12345# => backup_read_data <= m12345;
            when 16#12410# => backup_read_data <= m12410;
            when 16#FE123# => backup_read_data <= mfe123;
            when others => backup_read_data <= x"FF";
         end case;
      end if;
   end process;

   dut : entity work.nds_card
   generic map (CARDSPEED_SHIFT => 2)
   port map (
      clk => clk, ce => '1', reset => reset, card7 => '0', fw_boot => '0',
      chipid => x"00001FC2", bus9 => bus9, wired_out9 => wired_out9,
      wired_done9 => wired_done9, bus7 => bus7, wired_out7 => wired_out7,
      wired_done7 => wired_done7, irq9_xfer => irq9_xfer,
      irq7_xfer => irq7_xfer, dbg_card => dbg_card,
      dma9_card => dma9_card, dma7_card => dma7_card,
      backup_addr => backup_addr, backup_write_data => backup_write_data,
      backup_write_enable => backup_write_enable,
      backup_read_data => backup_read_data,
      backup_write_toggle => backup_write_toggle,
      backup_save_type => backup_save_type,
      backup_access_active => backup_access_active,
      backup_cache_ready => '1',
      card_ena => card_ena, card_addr => card_addr,
      card_din => (others => '0'), card_done => '0');

   process
      procedure bus_write(
         constant data : std_logic_vector(31 downto 0);
         constant be   : std_logic_vector(3 downto 0)) is
      begin
         wait until falling_edge(clk);
         bus9.Adr <= ADR_AUXSPI;
         bus9.Din <= data;
         bus9.bEna <= be;
         bus9.rnw <= '0';
         bus9.ena <= '1';
         wait until falling_edge(clk);
         bus9.ena <= '0';
         bus9.rnw <= '1';
         bus9.bEna <= (others => '0');
      end procedure;

      procedure spi_byte(
         constant value : std_logic_vector(7 downto 0);
         constant hold  : std_logic) is
         variable ctl : std_logic_vector(31 downto 0) := (others => '0');
         variable dat : std_logic_vector(31 downto 0) := (others => '0');
      begin
         ctl(6) := hold;
         bus_write(ctl, "0001");
         dat(23 downto 16) := value;
         bus_write(dat, "0100");
         for n in 0 to 66 loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      procedure command(constant value : std_logic_vector(7 downto 0)) is
      begin
         spi_byte(value, '0');
      end procedure;

      procedure write_enable is begin command(x"06"); end procedure;
      procedure write_disable is begin command(x"04"); end procedure;

      procedure regular_write(
         constant addr : natural;
         constant bytes : natural;
         constant cmd : std_logic_vector(7 downto 0);
         constant value : std_logic_vector(7 downto 0)) is
      begin
         write_enable;
         spi_byte(cmd, '1');
         if bytes = 3 then
            spi_byte(std_logic_vector(to_unsigned((addr / 65536) mod 256, 8)), '1');
         end if;
         spi_byte(std_logic_vector(to_unsigned((addr / 256) mod 256, 8)), '1');
         spi_byte(std_logic_vector(to_unsigned(addr mod 256, 8)), '1');
         spi_byte(value, '0');
      end procedure;

      procedure regular_read(
         constant addr : natural;
         constant bytes : natural;
         constant cmd : std_logic_vector(7 downto 0);
         constant expected : std_logic_vector(7 downto 0)) is
      begin
         spi_byte(cmd, '1');
         if bytes = 3 then
            spi_byte(std_logic_vector(to_unsigned((addr / 65536) mod 256, 8)), '1');
         end if;
         spi_byte(std_logic_vector(to_unsigned((addr / 256) mod 256, 8)), '1');
         spi_byte(std_logic_vector(to_unsigned(addr mod 256, 8)), '1');
         if cmd = x"0B" then spi_byte(x"00", '1'); end if;
         spi_byte(x"00", '0');
         wait for 1 ns;
         assert wired_out9(23 downto 16) = expected
            report "backup SPI readback mismatch" severity failure;
      end procedure;

      procedure read_status(constant expected_wel : std_logic) is
      begin
         spi_byte(x"05", '1');
         spi_byte(x"00", '0');
         wait for 1 ns;
         assert wired_out9(17) = expected_wel
            report "write-enable status mismatch" severity failure;
      end procedure;

      procedure flash_erase(
         constant cmd : std_logic_vector(7 downto 0);
         constant addr : natural;
         constant wait_cycles : natural) is
      begin
         write_enable;
         spi_byte(cmd, '1');
         spi_byte(std_logic_vector(to_unsigned((addr / 65536) mod 256, 8)), '1');
         spi_byte(std_logic_vector(to_unsigned((addr / 256) mod 256, 8)), '1');
         spi_byte(std_logic_vector(to_unsigned(addr mod 256, 8)), '0');
         for n in 0 to wait_cycles loop wait until rising_edge(clk); end loop;
      end procedure;

      variable toggle_before : std_logic;
   begin
      wait for 40 ns;
      wait until falling_edge(clk);
      reset <= '0';
      bus_write(x"0000A000", "0010"); -- slot enable + backup SPI

      -- 8 KiB regular EEPROM still masks two address bytes to 13 bits.
      backup_save_type <= "0010";
      toggle_before := backup_write_toggle;
      regular_write(16#2123#, 2, x"02", x"A5");
      wait until rising_edge(clk);
      assert m00123 = x"A5" and last_write_addr = x"00123"
         report "8 KiB EEPROM address mask failed" severity failure;
      assert backup_write_toggle /= toggle_before
         report "8 KiB EEPROM dirty toggle did not change" severity failure;
      regular_read(16#2123#, 2, x"03", x"A5");

      -- 64 KiB regular EEPROM preserves all 16 address bits.
      backup_save_type <= "0011";
      regular_write(16#E123#, 2, x"02", x"B6");
      assert m0e123 = x"B6" and last_write_addr = x"0E123"
         report "64 KiB EEPROM high address failed" severity failure;
      regular_read(16#E123#, 2, x"03", x"B6");

      -- Type 4 is the three-address-byte regular protocol used by the largest
      -- EEPROM/FRAM-compatible profile.
      backup_save_type <= "0100";
      regular_write(16#1E123#, 3, x"02", x"C7");
      assert m1e123 = x"C7" and last_write_addr = x"1E123"
         report "FRAM-compatible three-byte address failed" severity failure;
      regular_read(16#1E123#, 3, x"03", x"C7");

      -- Flash status/WREN/WRDI and JEDEC behavior.
      backup_save_type <= "0101";
      write_enable;
      read_status('1');
      write_disable;
      read_status('0');
      spi_byte(x"9F", '1');
      spi_byte(x"00", '0');
      wait for 1 ns;
      assert wired_out9(23 downto 16) = x"FF"
         report "flash JEDEC ID did not match melonDS FF oracle" severity failure;

      -- 0Ah page write stores bytes; 02h page program can only clear bits.
      regular_write(16#12345#, 3, x"0A", x"F3");
      assert m12345 = x"F3" severity failure;
      regular_write(16#12345#, 3, x"02", x"5F");
      assert m12345 = x"53"
         report "flash page program did not enforce 1-to-0 semantics" severity failure;
      regular_read(16#12345#, 3, x"03", x"53");
      regular_read(16#12345#, 3, x"0B", x"53");

      -- The largest flash profile retains all 20 address bits.
      backup_save_type <= "0111";
      regular_write(16#FE123#, 3, x"0A", x"6D");
      assert mfe123 = x"6D" and last_write_addr = x"FE123"
         report "1 MiB flash complete address failed" severity failure;
      regular_read(16#FE123#, 3, x"03", x"6D");
      backup_save_type <= "0101";

      -- DB page erase and D8 64 KiB sector erase restore FF and clear WEL.
      regular_write(16#12410#, 3, x"0A", x"11");
      flash_erase(x"DB", 16#12410#, 300);
      assert m12410 = x"FF" report "flash page erase failed" severity failure;
      read_status('0');
      regular_write(16#12345#, 3, x"0A", x"22");
      flash_erase(x"D8", 16#12345#, 66000);
      assert m12345 = x"FF" report "flash sector erase failed" severity failure;
      read_status('0');

      report "PASS: EEPROM/FRAM/flash AUXSPI protocol, WEL, ID, program and erase";
      stop;
      wait;
   end process;
end architecture;
