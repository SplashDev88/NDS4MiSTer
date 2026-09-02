-- Direct-boot user-settings regression for melonDS touchscreen calibration.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_nds_loader_touch_calibration is
end entity;

architecture sim of tb_nds_loader_touch_calibration is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal start : std_logic := '0';
   signal busy, done, load_error : std_logic;
   signal arm9_entry, arm7_entry, cart_id : std_logic_vector(31 downto 0);
   signal save_is_64k : std_logic;
   signal save_gamecode : std_logic_vector(31 downto 0);
   signal save_gamecode_valid : std_logic;
   signal card_ena, card_done : std_logic := '0';
   signal card_addr : std_logic_vector(26 downto 2);
   signal card_rdata : std_logic_vector(31 downto 0) := (others => '0');
   signal wr_ena, wr_rnw : std_logic;
   signal wr_addr, wr_data : std_logic_vector(31 downto 0);
   signal vfy_bad : std_logic_vector(17 downto 0);
   signal vfy_addr : std_logic_vector(31 downto 0);
   signal saw_adc1_pixels_adc2x : std_logic := '0';
   signal saw_adc2y_pixels2 : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_loader
   generic map (is_simu => '1', skip_copy => '1')
   port map (
      clk => clk, reset => reset, start => start,
      direct => '1', fw_boot => '0',
      busy => busy, done => done, load_error => load_error,
      arm9_entry => arm9_entry, arm7_entry => arm7_entry, cart_id => cart_id,
      save_is_64k => save_is_64k,
      save_gamecode => save_gamecode,
      save_gamecode_valid => save_gamecode_valid,
      card_ena => card_ena, card_addr => card_addr,
      card_done => card_done, card_rdata => card_rdata,
      wr_ena => wr_ena, wr_rnw => wr_rnw, wr_addr => wr_addr,
      wr_data => wr_data, wr_done => '1', rd_data => (others => '0'),
      vfy_bad => vfy_bad, vfy_addr => vfy_addr);

   process (clk)
   begin
      if rising_edge(clk) then
         card_done <= card_ena;
         if card_ena = '1' then
            case to_integer(unsigned(card_addr)) is
               when 3  => card_rdata <= x"454d414e";
               when 8  => card_rdata <= x"00000000"; -- ARM9 ROM offset
               when 9  => card_rdata <= x"02000000"; -- ARM9 entry
               when 10 => card_rdata <= x"02000000"; -- ARM9 load address
               when 11 => card_rdata <= x"00000000"; -- ARM9 size
               when 12 => card_rdata <= x"00000000"; -- ARM7 ROM offset
               when 13 => card_rdata <= x"037F8000"; -- ARM7 entry
               when 14 => card_rdata <= x"037F8000"; -- ARM7 load address
               when 15 => card_rdata <= x"00000000"; -- ARM7 size
               when 16#20# => card_rdata <= x"02000000"; -- used ROM size
               when others => card_rdata <= (others => '0');
            end case;
         end if;

         if wr_ena = '1' then
            if wr_addr = x"02FFFCDC" then
               assert wr_data = x"0FF00000"
                  report "direct-boot Pixel1/ADC2-X calibration mismatch"
                  severity failure;
               saw_adc1_pixels_adc2x <= '1';
            elsif wr_addr = x"02FFFCE0" then
               assert wr_data = x"BFFFF00B"
                  report "direct-boot ADC2-Y/Pixel2 calibration mismatch"
                  severity failure;
               saw_adc2y_pixels2 <= '1';
            end if;
         end if;
      end if;
   end process;

   process
   begin
      wait for 30 ns;
      wait until falling_edge(clk);
      reset <= '0';
      wait until falling_edge(clk);
      start <= '1';
      wait until falling_edge(clk);
      start <= '0';
      wait until done = '1';
      wait for 1 ns;
      assert load_error = '0'
         report "direct-boot loader unexpectedly failed" severity failure;
      assert saw_adc1_pixels_adc2x = '1' and saw_adc2y_pixels2 = '1'
         report "direct-boot loader omitted touchscreen calibration"
         severity failure;
      report "PASS: direct-boot touchscreen calibration matches melonDS";
      stop;
      wait;
   end process;
end architecture;
