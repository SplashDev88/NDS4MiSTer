-- Writable-firmware fix and test contributed by InsaneFriend (GitHub: saneFriend).
-- End-to-end SPI firmware access: nds_nitro_spi driving nds_nitro_firmware.
--
-- The store-level testbench proves the fw_* contract in isolation. This drives
-- real SPI transactions the way the ARM7 does -- select the firmware device,
-- send a command, shift three address bytes, clock data -- and covers BOTH
-- directions, because reads alone were not enough:
--
--   Pokemon Pearl issues 0x06 / 0x0A / 0x04 (write enable, page program, write
--   disable) during boot. Measured in melonDS, serving the image correctly but
--   discarding the writes leaves Pearl hanging in the same ARM9 spin loop seen
--   on hardware. New Super Mario Bros. only ever issues 0x03/0x05, which is why
--   it booted throughout.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_spi_firmware_read is
end entity;

architecture sim of tb_nds_spi_firmware_read is
   constant ADR_SPI : std_logic_vector(27 downto 0) := x"00001C0";
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal bus7 : proc_bus_gb_type := (
      Din => (others => '0'), Adr => ADR_SPI, rnw => '1', ena => '0',
      acc => ACCESS_32BIT, bEna => (others => '0'), rst => '0');
   signal wired_out7 : std_logic_vector(31 downto 0);
   signal wired_done7, irq_spi : std_logic;
   signal touch_active : std_logic := '0';
   signal touch_x : std_logic_vector(7 downto 0) := x"80";
   signal touch_y : std_logic_vector(7 downto 0) := x"60";
   signal fw_addr : unsigned(17 downto 2);
   signal fw_req  : std_logic;
   signal fw_done : std_logic;
   signal fw_data : std_logic_vector(31 downto 0);
   signal fw_wr    : std_logic;
   signal fw_wlane : unsigned(1 downto 0);
   signal fw_wdata : std_logic_vector(7 downto 0);
   -- nds_nitro_console_wrap converts these before the SystemVerilog island;
   -- model that here so the testbench matches the real connection. Note there
   -- is no separate write address: 0x0A drives fw_addr like a read does.
   signal fw_addr_slv  : std_logic_vector(15 downto 0);
   signal fw_wlane_slv : std_logic_vector(1 downto 0);
   signal errors  : integer := 0;
begin
   clk <= not clk after 5 ns;
   fw_addr_slv  <= std_logic_vector(fw_addr);
   fw_wlane_slv <= std_logic_vector(fw_wlane);

   spi : entity work.nds_nitro_spi
   port map (
      clk => clk, reset => reset,
      bus7 => bus7, wired_out7 => wired_out7, wired_done7 => wired_done7,
      irq_spi => irq_spi,
      touch_active => touch_active, touch_x => touch_x, touch_y => touch_y,
      fw_addr => fw_addr, fw_req => fw_req,
      fw_done => fw_done, fw_data => fw_data,
      fw_wr => fw_wr, fw_wlane => fw_wlane, fw_wdata => fw_wdata);

   rom : entity work.nds_nitro_firmware
   port map (
      clk => clk, fw_addr => fw_addr_slv, fw_req => fw_req,
      fw_done => fw_done, fw_data => fw_data,
      fw_wr => fw_wr, fw_wlane => fw_wlane_slv, fw_wdata => fw_wdata);

   process
      variable value : std_logic_vector(7 downto 0);

      -- SPICNT: bit15 enable, bits 9:8 device (01 = firmware flash),
      -- bit11 keeps chip-select asserted across bytes.
      procedure select_firmware(constant hold : boolean := true) is
         variable control_word : std_logic_vector(31 downto 0);
      begin
         control_word := x"00008100";
         if hold then control_word(11) := '1'; end if;
         wait until falling_edge(clk);
         bus7.Din <= control_word;
         bus7.rnw <= '0'; bus7.ena <= '1'; bus7.bEna <= "0010";
         wait until falling_edge(clk);
         bus7.rnw <= '1'; bus7.ena <= '0'; bus7.bEna <= "0000";
      end procedure;

      procedure deselect is
      begin
         wait until falling_edge(clk);
         bus7.Din <= (others => '0');
         bus7.rnw <= '0'; bus7.ena <= '1'; bus7.bEna <= "0010";
         wait until falling_edge(clk);
         bus7.rnw <= '1'; bus7.ena <= '0'; bus7.bEna <= "0000";
      end procedure;

      procedure transfer(
         constant value : std_logic_vector(7 downto 0);
         variable result : out std_logic_vector(7 downto 0)) is
         variable word_value : std_logic_vector(31 downto 0);
         variable guard : integer := 0;
      begin
         word_value := (others => '0');
         word_value(23 downto 16) := value;
         wait until falling_edge(clk);
         bus7.Din <= word_value;
         bus7.rnw <= '0'; bus7.ena <= '1'; bus7.bEna <= "0100";
         wait until falling_edge(clk);
         bus7.rnw <= '1'; bus7.ena <= '0'; bus7.bEna <= "0000";
         -- SPICNT bit7 is busy; a firmware fetch holds it until the word lands.
         while wired_out7(7) = '1' and guard < 200 loop
            wait until falling_edge(clk);
            guard := guard + 1;
         end loop;
         assert guard < 200 report "SPI stayed busy: fw handshake never completed"
            severity error;
         wait for 1 ns;
         result := wired_out7(23 downto 16);
      end procedure;

      procedure send_addr(constant a : integer) is
         variable v : std_logic_vector(7 downto 0);
      begin
         transfer(std_logic_vector(to_unsigned(a / 65536, 8)), v);
         transfer(std_logic_vector(to_unsigned((a / 256) mod 256, 8)), v);
         transfer(std_logic_vector(to_unsigned(a mod 256, 8)), v);
      end procedure;

      -- Command 0x03 + 24-bit address, then read four bytes.
      procedure read_at(constant a : integer;
                        constant e0, e1, e2, e3 : std_logic_vector(7 downto 0);
                        constant name : string) is
         variable v : std_logic_vector(7 downto 0);
         variable got : std_logic_vector(31 downto 0);
      begin
         select_firmware(true);
         transfer(x"03", v);
         send_addr(a);
         transfer(x"00", v); got(7 downto 0)   := v;
         transfer(x"00", v); got(15 downto 8)  := v;
         transfer(x"00", v); got(23 downto 16) := v;
         transfer(x"00", v); got(31 downto 24) := v;
         deselect;
         if got(7 downto 0) = e0 and got(15 downto 8) = e1 and
            got(23 downto 16) = e2 and got(31 downto 24) = e3 then
            report name & " OK" severity note;
         else
            report name & " MISMATCH" severity error;
            errors <= errors + 1;
         end if;
      end procedure;

      -- What Pearl does: WREN, page program one byte, WRDI.
      procedure program_byte(constant a : integer;
                             constant d : std_logic_vector(7 downto 0)) is
         variable v : std_logic_vector(7 downto 0);
      begin
         select_firmware(true);
         transfer(x"06", v);            -- write enable
         deselect;
         select_firmware(true);
         transfer(x"0A", v);            -- page program
         send_addr(a);
         transfer(d, v);
         deselect;
         select_firmware(true);
         transfer(x"04", v);            -- write disable
         deselect;
      end procedure;
   begin
      wait for 30 ns;
      wait until falling_edge(clk);
      reset <= '0';
      wait for 50 ns;

      -- Initial image contents.
      read_at(16#1FE00#, x"05", x"00", x"00", x"01", "read user settings @0x1FE00");
      read_at(16#0001D#, x"20", x"00", x"00", x"C0", "read header @0x0001D");

      -- THE CASE THAT MATTERS: program a byte and read it back through SPI.
      program_byte(16#1FE00#, x"A5");
      read_at(16#1FE00#, x"A5", x"00", x"00", x"01", "page program persists");
      program_byte(16#1FE02#, x"3C");
      read_at(16#1FE00#, x"A5", x"00", x"3C", x"01", "second lane persists");

      if errors = 0 then
         report "PASS: SPI firmware reads and writes both work" severity note;
      else
         report "FAIL: SPI firmware path is wrong" severity error;
      end if;
      stop;
      wait;
   end process;
end architecture;
