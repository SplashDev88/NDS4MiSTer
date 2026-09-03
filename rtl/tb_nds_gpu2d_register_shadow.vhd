library IEEE;
use IEEE.std_logic_1164.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_gpu2d_register_shadow is
end entity;

architecture sim of tb_nds_gpu2d_register_shadow is
   signal clk, reset : std_logic := '0';
   signal gb_bus : proc_bus_gb_type :=
      (Din => (others => '0'), Adr => (others => '0'), rnw => '1',
       ena => '0', acc => ACCESS_32BIT, bEna => "0000", rst => '0');
   signal wired_out : std_logic_vector(31 downto 0);
   signal wired_done : std_logic;
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_gpu2d_register_shadow
      port map
      (
         clk => clk, reset => reset, gb_bus => gb_bus,
         wired_out => wired_out, wired_done => wired_done
      );

   stimulus : process
      procedure write_word(
         constant address : std_logic_vector(27 downto 0);
         constant data    : std_logic_vector(31 downto 0);
         constant be      : std_logic_vector(3 downto 0)) is
      begin
         wait until falling_edge(clk);
         gb_bus.Adr <= address;
         gb_bus.Din <= data;
         gb_bus.rnw <= '0';
         gb_bus.ena <= '1';
         gb_bus.bEna <= be;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         gb_bus.ena <= '0';
         gb_bus.rnw <= '1';
         gb_bus.bEna <= "0000";
         wait for 1 ns;
      end procedure;

      procedure read_expect(
         constant address : std_logic_vector(27 downto 0);
         constant expected : std_logic_vector(31 downto 0);
         constant claimed : std_logic := '1') is
      begin
         gb_bus.Adr <= address;
         wait for 1 ns;
         assert wired_done = claimed
            report "unexpected Engine B shadow decode" severity failure;
         assert wired_out = expected
            report "unexpected Engine B shadow readback" severity failure;
      end procedure;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';

      read_expect(x"0000000", x"00000000");

      -- This is the exact NSMB failure sequence.  The game enables display
      -- mode 1, later updates low control bits through a read/modify/write,
      -- and must not lose bit 16 merely because the large B renderer is off.
      write_word(x"0000000", x"00010000", "1111");
      read_expect(x"0000000", x"00010000");
      write_word(x"0000000", x"00000400", "0011");
      read_expect(x"0000000", x"00010000");
      -- A CPU read now supplies bit 16 to the software merge, so the full
      -- writes captured by the ARM transport retain the correct mode.
      write_word(x"0000000", x"00010400", "1111");
      read_expect(x"0000000", x"00010000");
      write_word(x"0000000", x"00011400", "1111");
      read_expect(x"0000000", x"00010000");

      -- Only the supported Engine B display-mode bit is retained in this
      -- space-constrained compatibility shadow.
      write_word(x"0000000", x"FFFFFFFF", "1111");
      read_expect(x"0000000", x"00010000");

      -- All other Engine B words remain unclaimed in this minimum footprint.
      read_expect(x"0000008", x"00000000", '0');
      read_expect(x"0000018", x"00000000", '0');

      gb_bus.rst <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      gb_bus.rst <= '0';
      read_expect(x"0000000", x"00000000");

      report "PASS: Engine B register shadow preserves read/modify/write state"
         severity note;
      stop;
      wait;
   end process;
end architecture;
