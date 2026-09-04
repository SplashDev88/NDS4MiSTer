-- Directed cartridge-IR AUXSPI regression.
--
-- Retail IR carts place a one-byte transceiver command in front of the normal
-- save command.  This bench proves that the extra stage is opt-in, advances
-- the save protocol by exactly one byte for command 00h, answers the IR ID
-- command, and does not leak unsupported IR commands into the save device.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_card_ir is
end entity;

architecture sim of tb_nds_card_ir is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal backup_ir_enable : std_logic := '0';
   signal bus9, bus7 : proc_bus_gb_type := (
      Din => (others => '0'), Adr => (others => '0'), rnw => '1',
      ena => '0', acc => ACCESS_32BIT, bEna => (others => '0'), rst => '0');
   signal wired_out9, wired_out7 : std_logic_vector(31 downto 0);
   signal wired_done9, wired_done7 : std_logic;
   signal backup_addr : std_logic_vector(19 downto 0);
   signal backup_write_data : std_logic_vector(7 downto 0);
   signal backup_write_enable : std_logic;
   signal backup_read_data : std_logic_vector(7 downto 0);
   signal backup_write_toggle : std_logic;
   signal backup_access_active : std_logic;
   signal card_ena : std_logic;
   signal card_addr : std_logic_vector(26 downto 2);
   signal irq9_xfer, irq7_xfer, dma9_card, dma7_card : std_logic;
   signal dbg_card : std_logic_vector(31 downto 0);
   signal write_count : natural := 0;

   constant ADR_AUXSPI : std_logic_vector(27 downto 0) := x"00001A0";
begin
   clk <= not clk after 5 ns;

   -- A combinational backing-store model makes the expected read byte depend
   -- only on the address produced by the real nds_card state machine.
   with backup_addr select
      backup_read_data <= x"5A" when x"12345",
                          x"FF" when others;

   process (clk)
   begin
      if rising_edge(clk) and backup_write_enable = '1' then
         write_count <= write_count + 1;
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
      backup_save_type => "0101", backup_ir_enable => backup_ir_enable,
      backup_access_active => backup_access_active,
      backup_cache_ready => '1', card_ena => card_ena,
      card_addr => card_addr, card_din => (others => '0'), card_done => '0');

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
         constant hold  : std_logic;
         variable reply : out std_logic_vector(7 downto 0)) is
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
         wait for 1 ns;
         reply := wired_out9(23 downto 16);
      end procedure;

      procedure read_flash_byte(
         constant ir_prefix : boolean;
         variable reply : out std_logic_vector(7 downto 0)) is
      begin
         if ir_prefix then
            spi_byte(x"00", '1', reply);
            assert reply = x"00" and backup_access_active = '0'
               report "IR passthrough prefix was not consumed" severity failure;
         end if;
         spi_byte(x"03", '1', reply);
         assert backup_access_active = '0' severity failure;
         spi_byte(x"01", '1', reply);
         assert backup_access_active = '0' severity failure;
         spi_byte(x"23", '1', reply);
         assert backup_access_active = '0' severity failure;
         spi_byte(x"45", '1', reply);
         assert backup_access_active = '1'
            report "save address did not become active after its third byte"
            severity failure;
         assert backup_addr = x"12345"
            report "IR effective-position address was shifted" severity failure;
         spi_byte(x"00", '0', reply);
      end procedure;

      procedure ir_read_status(
         variable reply : out std_logic_vector(7 downto 0)) is
      begin
         spi_byte(x"00", '1', reply);
         spi_byte(x"05", '1', reply);
         spi_byte(x"00", '0', reply);
      end procedure;

      variable reply : std_logic_vector(7 downto 0);
      variable writes_before : natural;
   begin
      wait for 40 ns;
      wait until falling_edge(clk);
      reset <= '0';
      bus_write(x"0000A000", "0010"); -- slot enable + backup SPI

      -- With IR disabled, the original save protocol is byte-for-byte
      -- unchanged: command 03h starts at position zero and three address bytes
      -- select 12345h.
      backup_ir_enable <= '0';
      read_flash_byte(false, reply);
      assert reply = x"5A"
         report "non-IR save protocol changed" severity failure;

      -- On an IR cart, prefix 00h is consumed and the same flash transaction
      -- begins one physical byte later.  Address activation and readback prove
      -- that every downstream position used the effective one-byte offset.
      backup_ir_enable <= '1';
      read_flash_byte(true, reply);
      assert reply = x"5A"
         report "IR 00h did not pass through to the save device" severity failure;

      -- Command 08h belongs to the transceiver and returns its retail ID.
      spi_byte(x"08", '1', reply);
      assert reply = x"00"
         report "IR command byte did not return the idle value" severity failure;
      spi_byte(x"00", '0', reply);
      assert reply = x"AA"
         report "IR 08h did not return transceiver ID AAh" severity failure;

      -- Unsupported transceiver commands are swallowed.  In particular, 06h
      -- must not leak through as flash WREN, and no backing-store access/write
      -- may be generated.
      writes_before := write_count;
      spi_byte(x"09", '1', reply);
      spi_byte(x"06", '0', reply);
      assert backup_access_active = '0' and write_count = writes_before
         report "unsupported IR command reached the save device" severity failure;
      ir_read_status(reply);
      assert reply(1) = '0'
         report "unsupported IR command leaked flash write-enable" severity failure;

      -- Reset clears the card-side command state.  Set WEL through the valid
      -- passthrough path first, then prove reset returns status to zero.
      spi_byte(x"00", '1', reply);
      spi_byte(x"06", '0', reply);
      ir_read_status(reply);
      assert reply(1) = '1'
         report "IR passthrough failed to set flash WEL before reset" severity failure;
      wait until falling_edge(clk);
      reset <= '1';
      wait until falling_edge(clk);
      reset <= '0';
      bus_write(x"0000A000", "0010");
      ir_read_status(reply);
      assert reply(1) = '0' and backup_access_active = '0'
         report "reset did not clear cartridge IR/save command state" severity failure;

      report "PASS: non-IR AUXSPI, IR 00h offset, 08h ID, command swallow, reset";
      stop;
      wait;
   end process;
end architecture;
