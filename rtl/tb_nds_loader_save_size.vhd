-- Directed header regression for the YQUE 64 KiB save-size hint.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_nds_loader_save_size is
end entity;

architecture sim of tb_nds_loader_save_size is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal start : std_logic := '0';
   signal busy, done, load_error : std_logic;
   signal arm9_entry, arm7_entry, cart_id : std_logic_vector(31 downto 0);
   signal save_is_64k : std_logic;
   signal save_gamecode : std_logic_vector(31 downto 0);
   signal save_gamecode_valid : std_logic;
   signal save_code_seen : std_logic := '0';
   signal ir_cart_latched : std_logic := '0';
   signal card_ena, card_done : std_logic := '0';
   signal card_addr : std_logic_vector(26 downto 2);
   signal card_rdata : std_logic_vector(31 downto 0) := (others => '0');
   signal wr_ena, wr_rnw : std_logic;
   signal wr_addr, wr_data : std_logic_vector(31 downto 0);
   signal vfy_bad : std_logic_vector(17 downto 0);
   signal vfy_addr : std_logic_vector(31 downto 0);
   signal game_code : std_logic_vector(31 downto 0) := x"45555159";
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_loader
   generic map (is_simu => '1', skip_copy => '1')
   port map (
      clk => clk, reset => reset, start => start, direct => '0', fw_boot => '1',
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
         if reset = '1' then
            save_code_seen <= '0';
            ir_cart_latched <= '0';
         elsif save_gamecode_valid = '1' then
            save_code_seen <= '1';
            if save_gamecode(7 downto 0) = x"49" then
               ir_cart_latched <= '1';
            else
               ir_cart_latched <= '0';
            end if;
         end if;
         card_done <= card_ena;
         if card_ena = '1' then
            if unsigned(card_addr) = 3 then
               card_rdata <= game_code;
            elsif unsigned(card_addr) = 16#20# then
               card_rdata <= x"08000000";
            else
               card_rdata <= (others => '0');
            end if;
         end if;
      end if;
   end process;

   process
      procedure launch_and_check(
         constant expected_64k : std_logic;
         constant expected_ir  : std_logic) is
      begin
         wait until falling_edge(clk);
         start <= '1';
         wait until falling_edge(clk);
         start <= '0';
         wait until done = '1';
         wait for 1 ns;
         assert load_error = '0' report "loader unexpectedly failed" severity failure;
         assert save_is_64k = expected_64k
            report "loader save-size hint mismatch" severity failure;
         assert save_code_seen = '1' and save_gamecode = game_code
            report "loader game-code profile trigger mismatch" severity failure;
         assert ir_cart_latched = expected_ir
            report "little-endian IR game-code latch mismatch" severity failure;
      end procedure;
   begin
      wait for 30 ns;
      wait until falling_edge(clk);
      reset <= '0';
      launch_and_check('1', '0');

      -- The low byte is the first game-code character.  An I-prefixed retail
      -- code selects the cartridge IR wrapper and the selection must persist
      -- after the loader's one-cycle valid pulse.
      wait until falling_edge(clk);
      reset <= '1';
      game_code <= x"45475049"; -- IPGE, first/little-endian byte is 'I'
      wait until falling_edge(clk);
      reset <= '0';
      launch_and_check('0', '1');
      for n in 0 to 3 loop wait until rising_edge(clk); end loop;
      assert ir_cart_latched = '1'
         report "IR game-code selection did not remain latched" severity failure;

      wait until falling_edge(clk);
      reset <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      assert ir_cart_latched = '0'
         report "reset did not clear IR game-code latch" severity failure;
      wait until falling_edge(clk);
      game_code <= x"454d414e"; -- non-YQUE
      wait until falling_edge(clk);
      reset <= '0';
      launch_and_check('0', '0');

      report "PASS: loader save-size hint and resettable I-prefix IR latch";
      stop;
      wait;
   end process;
end architecture;
