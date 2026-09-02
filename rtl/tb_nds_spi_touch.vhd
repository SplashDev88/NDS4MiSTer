-- Touchscreen SPI regression against melonDS's 12-bit TSC contract.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_spi_touch is
end entity;

architecture sim of tb_nds_spi_touch is
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
   signal fw_req : std_logic;
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_spi
   port map (
      clk => clk, reset => reset,
      bus7 => bus7, wired_out7 => wired_out7, wired_done7 => wired_done7,
      irq_spi => irq_spi,
      touch_active => touch_active, touch_x => touch_x, touch_y => touch_y,
      fw_addr => fw_addr, fw_req => fw_req,
      fw_done => '0', fw_data => (others => '0'));

   process
      variable value : std_logic_vector(7 downto 0);
      procedure write_control(constant hold : boolean := true) is
         variable control_word : std_logic_vector(31 downto 0);
      begin
         control_word := x"00008200"; -- enabled, touchscreen device, baud 0
         if hold then control_word(11) := '1'; end if;
         wait until falling_edge(clk);
         bus7.Din <= control_word;
         bus7.rnw <= '0';
         bus7.ena <= '1';
         bus7.bEna <= "0010";
         wait until falling_edge(clk);
         bus7.rnw <= '1';
         bus7.ena <= '0';
         bus7.bEna <= "0000";
      end procedure;

      procedure disable_control is
      begin
         wait until falling_edge(clk);
         bus7.Din <= (others => '0');
         bus7.rnw <= '0';
         bus7.ena <= '1';
         bus7.bEna <= "0010";
         wait until falling_edge(clk);
         bus7.rnw <= '1';
         bus7.ena <= '0';
         bus7.bEna <= "0000";
      end procedure;

      procedure transfer(
         constant value : std_logic_vector(7 downto 0);
         variable result : out std_logic_vector(7 downto 0)) is
         variable word_value : std_logic_vector(31 downto 0);
      begin
         word_value := (others => '0');
         word_value(23 downto 16) := value;
         wait until falling_edge(clk);
         bus7.Din <= word_value;
         bus7.rnw <= '0';
         bus7.ena <= '1';
         bus7.bEna <= "0100";
         wait until falling_edge(clk);
         bus7.rnw <= '1';
         bus7.ena <= '0';
         bus7.bEna <= "0000";
         while wired_out7(7) = '1' loop
            wait until falling_edge(clk);
         end loop;
         wait for 1 ns;
         result := wired_out7(23 downto 16);
      end procedure;

      procedure read_conversion(
         constant command : std_logic_vector(7 downto 0);
         constant expected_high : std_logic_vector(7 downto 0);
         constant expected_low : std_logic_vector(7 downto 0)) is
         variable value : std_logic_vector(7 downto 0);
      begin
         transfer(command, value);
         assert value = x"00"
            report "TSC control transfer returned nonzero data" severity failure;
         transfer(x"00", value);
         assert value = expected_high
            report "TSC high conversion byte mismatch" severity failure;
         transfer(x"00", value);
         assert value = expected_low
            report "TSC low conversion byte mismatch" severity failure;
      end procedure;
   begin
      wait for 30 ns;
      wait until falling_edge(clk);
      reset <= '0';
      write_control;
      assert wired_done7 = '1'
         report "SPI register did not claim its address" severity failure;

      -- Center touch: X=128 -> 0x800, Y=96 -> 0x600.
      touch_active <= '1';
      touch_x <= x"80";
      touch_y <= x"60";
      read_conversion(x"D0", x"40", x"00");
      read_conversion(x"90", x"30", x"00");

      -- Native lower-right pixel: X=255 -> 0xFF0, Y=191 -> 0xBF0.
      touch_x <= x"FF";
      touch_y <= x"BF";
      read_conversion(x"D0", x"7F", x"80");
      read_conversion(x"90", x"5F", x"80");

      -- Releasing chip-select after a command resets DataPos in melonDS.
      -- The first byte of a later held transaction must therefore be the
      -- position-0 zero, not the stale conversion high byte.
      write_control(false);
      transfer(x"D0", value);
      assert value = x"00"
         report "unheld TSC command returned nonzero data" severity failure;
      write_control(true);
      transfer(x"00", value);
      assert value = x"00"
         report "TSC DataPos survived unheld chip-select release" severity failure;
      transfer(x"00", value);
      assert value = x"7F"
         report "TSC conversion did not restart after release" severity failure;

      -- Disabling SPICNT also releases the selected device.
      transfer(x"90", value);
      disable_control;
      write_control(true);
      transfer(x"00", value);
      assert value = x"00"
         report "TSC DataPos survived SPICNT disable" severity failure;
      disable_control;
      write_control(true);

      -- melonDS release sentinel: X=0, Y=0xFFF.
      touch_active <= '0';
      read_conversion(x"D0", x"00", x"00");
      read_conversion(x"90", x"7F", x"F8");

      report "PASS: touchscreen SPI matches melonDS held and released samples";
      stop;
      wait;
   end process;
end architecture;
