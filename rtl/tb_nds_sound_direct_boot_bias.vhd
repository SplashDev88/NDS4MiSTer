-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Focused regression for the direct-boot SOUNDBIAS contract.
--
-- The captured NSMB (A2DE) ARM7 trace enables the master mixer with byte
-- writes to 0x04000501/0x04000500, but contains no write to SOUNDBIAS in its
-- first 2,048 sound-MMIO writes. A direct boot must therefore provide the
-- post-firmware 0x200 midpoint before game code starts. Robert's register
-- map and melonDS SetupDirectBoot use that same value.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_nds_sound_direct_boot_bias is
end entity;

architecture test of tb_nds_sound_direct_boot_bias is
   constant CLK_PERIOD : time := 10 ns;

   signal clk   : std_logic := '0';
   signal ce    : std_logic := '1';
   signal reset : std_logic := '1';

   signal bus7 : proc_bus_gb_type := (
      Din  => (others => '0'),
      Adr  => (others => '0'),
      rnw  => '1',
      ena  => '0',
      acc  => ACCESS_32BIT,
      bEna => (others => '0'),
      rst  => '0'
   );
   signal wired_out7  : std_logic_vector(31 downto 0);
   signal wired_done7 : std_logic;

   signal snd_bus_req : std_logic;
   signal snd_bus_own : std_logic;
   signal mb_ena      : std_logic;
   signal mb_adr      : std_logic_vector(31 downto 0);

   signal sample_l     : std_logic_vector(15 downto 0);
   signal sample_r     : std_logic_vector(15 downto 0);
   signal sample_valid : std_logic;
   signal snd_enable   : std_logic;
   signal snd_active   : std_logic_vector(15 downto 0);
begin
   clk <= not clk after CLK_PERIOD / 2;

   dut : entity work.nds_sound
   generic map
   (
      is_simu         => '1',
      ADPCM_TABLE_RAM => 0
   )
   port map
   (
      clk          => clk,
      ce           => ce,
      reset        => reset,
      bus7         => bus7,
      wired_out7   => wired_out7,
      wired_done7  => wired_done7,
      snd_bus_req  => snd_bus_req,
      snd_bus_ok   => '0',
      snd_bus_own  => snd_bus_own,
      mb_ena       => mb_ena,
      mb_adr       => mb_adr,
      mb_din       => (others => '0'),
      mb_done      => '0',
      sample_l     => sample_l,
      sample_r     => sample_r,
      sample_valid => sample_valid,
      snd_enable   => snd_enable,
      snd_active   => snd_active
   );

   stimulus : process
      procedure write_reg(
         constant address : natural;
         constant value   : std_logic_vector(31 downto 0);
         constant lanes   : std_logic_vector(3 downto 0)) is
      begin
         bus7.Adr  <= std_logic_vector(to_unsigned(address, bus7.Adr'length));
         bus7.Din  <= value;
         bus7.rnw  <= '0';
         bus7.ena  <= '1';
         bus7.bEna <= lanes;
         wait until rising_edge(clk);
         wait for 1 ns;
         bus7.rnw  <= '1';
         bus7.ena  <= '0';
         bus7.bEna <= (others => '0');
      end procedure;

      procedure select_read(constant address : natural) is
      begin
         bus7.Adr <= std_logic_vector(to_unsigned(address, bus7.Adr'length));
         bus7.rnw <= '1';
         bus7.ena <= '1';
         wait for 1 ns;
      end procedure;
   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait for 1 ns;
      reset <= '0';

      -- Replay the first three master-control writes from the hardware trace.
      -- Deliberately do not write SOUNDBIAS: NSMB relies on boot state.
      write_reg(16#0501#, x"00008000", "0010");
      write_reg(16#0501#, x"00008000", "0010");
      write_reg(16#0500#, x"0000007F", "0001");

      -- With no active channels, the first completed signed PCM pair must be
      -- zero. A zero SOUNDBIAS instead produces -32768 on both channels and
      -- irreversibly clips the negative half of subsequent audio.
      loop
         wait until rising_edge(clk);
         wait for 1 ns;
         exit when sample_valid = '1';
      end loop;
      assert sample_l = x"0000" and sample_r = x"0000"
         report "direct-boot master enable did not produce centered silence"
         severity failure;

      select_read(16#0504#);
      assert wired_done7 = '1' and wired_out7(9 downto 0) = "1000000000"
         report "direct-boot SOUNDBIAS is not the 0x200 midpoint"
         severity failure;

      -- Guest writes retain full control after the boot preset.
      write_reg(16#0504#, x"00000155", "0011");
      select_read(16#0504#);
      assert wired_out7(9 downto 0) = "0101010101"
         report "guest SOUNDBIAS write did not override the boot preset"
         severity failure;

      -- A new direct-boot/reset epoch must restore the midpoint.
      bus7.ena <= '0';
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait for 1 ns;
      reset <= '0';
      select_read(16#0504#);
      assert wired_done7 = '1' and wired_out7(9 downto 0) = "1000000000"
         report "reset did not restore the direct-boot SOUNDBIAS midpoint"
         severity failure;

      report "PASS: direct boot supplies centered SOUNDBIAS and preserves guest writes"
         severity note;
      std.env.stop;
      wait;
   end process;
end architecture;
