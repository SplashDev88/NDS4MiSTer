library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
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
      variable rmw_value : std_logic_vector(31 downto 0);
      variable tile_destination, map_destination : unsigned(31 downto 0);
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';

      read_expect(x"0000000", x"00000000");

      -- Preserve unaffected bytes across partial writes before exercising the
      -- complete NSMB read/modify/write below.
      write_word(x"0000000", x"00010000", "1111");
      read_expect(x"0000000", x"00010000");
      write_word(x"0000000", x"00000400", "0011");
      read_expect(x"0000000", x"00010400");
      -- A CPU read now supplies bit 16 to the software merge, so the full
      -- writes captured by the ARM transport retain the correct mode.
      write_word(x"0000000", x"00010400", "1111");
      read_expect(x"0000000", x"00010400");
      write_word(x"0000000", x"00011400", "1111");
      read_expect(x"0000000", x"00011400");

      -- This is the exact frame-4677 failure captured on hardware. NSMB first
      -- has display mode 1 plus BG0-BG3/OBJ enabled, then performs a
      -- read/modify/write to set bit 4. Returning only bit 16 turns the
      -- correct 0x00011F10 write into 0x00010010 and blanks every B layer.
      write_word(x"0000000", x"00011F00", "1111");
      read_expect(x"0000000", x"00011F00");
      rmw_value := wired_out or x"00000010";
      write_word(x"0000000", rmw_value, "1111");
      read_expect(x"0000000", x"00011F10");

      -- Match melonDS's Engine-B unsupported/reserved-bit mask.
      write_word(x"0000000", x"FFFFFFFF", "1111");
      read_expect(x"0000000", x"C0B1FFF7");

      -- Kirby uses BG3CNT readback to obtain the graphics upload addresses.
      -- The hardware capture has map data at 0x06200000, but the melonDS ROM
      -- oracle writes the identical data to 0x06203800. A zero readback loses
      -- screen-base 7 and character-base 1 despite the renderer seeing 0x0707.
      write_word(x"000000C", x"07070000", "1100");
      read_expect(x"000000C", x"07070000");
      tile_destination := x"06200000" + shift_left(resize(unsigned(wired_out(21 downto 18)), 32), 14);
      map_destination := x"06200000" + shift_left(resize(unsigned(wired_out(28 downto 24)), 32), 11);
      assert tile_destination = x"06204000" and map_destination = x"06203800"
         report "Kirby BG3 upload destinations lost their register base" severity failure;
      read_expect(x"0000008", x"00000000");
      write_word(x"0000008", x"ABCD1234", "1111");
      read_expect(x"0000008", x"ABCD1234");
      write_word(x"0000008", x"00560000", "0100");
      read_expect(x"0000008", x"AB561234");
      write_word(x"000000C", x"000089AB", "0011");
      read_expect(x"000000C", x"070789AB");
      write_word(x"000000C", x"12000000", "1000");
      read_expect(x"000000C", x"120789AB");
      read_expect(x"0000018", x"00000000", '0');

      gb_bus.rst <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      gb_bus.rst <= '0';
      read_expect(x"0000000", x"00000000");
      read_expect(x"0000008", x"00000000");
      read_expect(x"000000C", x"00000000");

      report "PASS: Engine B register shadow preserves read/modify/write state"
         severity note;
      stop;
      wait;
   end process;
end architecture;
