library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_nds_nitro_bootbios is end entity;
architecture test of tb_nds_nitro_bootbios is
   signal clk : std_logic := '0';
   signal reset, we : std_logic := '0';
   signal a7, l7 : unsigned(13 downto 2) := (others => '0');
   signal a9 : unsigned(14 downto 2) := (others => '0');
   signal l9 : unsigned(11 downto 2) := (others => '0');
   signal d7, d9, r7, r9, w7, w9 : std_logic_vector(31 downto 0);
   signal be : std_logic_vector(3 downto 0) := "1111";
begin
   clk <= not clk after 5 ns;
   legacy7 : entity work.nds_nitro_freebios7 generic map(is_simu => '1')
      port map(clk => clk, bios_addr => a7, bios_data => r7);
   legacy9 : entity work.nds_nitro_freebios9 generic map(is_simu => '1')
      port map(clk => clk, brom_addr => a9, brom_data => r9);
   new7 : entity work.nds_nitro_bootbios7 generic map(is_simu => '1')
      port map(clk => clk, reset => reset, bios_addr => a7, bios_data => d7,
         load_addr => l7, load_data => w7, load_be => be, load_we => we);
   new9 : entity work.nds_nitro_bootbios9 generic map(is_simu => '1')
      port map(clk => clk, reset => reset, brom_addr => a9, brom_data => d9,
         load_addr => l9, load_data => w9, load_be => be, load_we => we);
   process
      procedure read_at(i : natural) is
         variable prior7, prior9 : std_logic_vector(31 downto 0);
      begin
         wait until falling_edge(clk);
         prior7 := d7; prior9 := d9;
         a7 <= to_unsigned(i mod 4096, 12);
         a9 <= to_unsigned(i, 13);
         wait for 1 ns;
         assert d7 = prior7 and d9 = prior9
            report "BIOS read is asynchronous" severity failure;
         wait until rising_edge(clk); wait for 1 ns;
      end procedure;
      procedure compare_public is
      begin
         for i in 0 to 8191 loop
            read_at(i);
            assert d7 = r7 and d9 = r9
               report "FreeBIOS content/one-cycle mismatch at " & integer'image(i)
               severity failure;
         end loop;
      end procedure;
   begin
      wait until rising_edge(clk); wait for 1 ns;
      compare_public;
      -- Native uploads cover every word of both windows, including addresses
      -- beyond the compact FreeBIOS contents. Only synthetic fixtures here.
      reset <= '1';
      for i in 0 to 4095 loop
         wait until falling_edge(clk);
         l7 <= to_unsigned(i, 12); l9 <= to_unsigned(i mod 1024, 10);
         w7 <= std_logic_vector(to_unsigned(16#71000000# + i, 32));
         w9 <= std_logic_vector(to_unsigned(16#19000000# + (i mod 1024), 32));
         we <= '1';
         wait until rising_edge(clk); wait for 1 ns;
      end loop;
      we <= '0'; reset <= '0';
      for i in 0 to 8191 loop
         read_at(i);
         assert d7 = std_logic_vector(to_unsigned(16#71000000# + (i mod 4096), 32))
            report "BIOS7 full-window upload mismatch" severity failure;
         if i < 1024 then
            assert d9 = std_logic_vector(to_unsigned(16#19000000# + i, 32))
               report "BIOS9 upload mismatch" severity failure;
         else
            assert d9 = x"00000000" report "BIOS9 upper-window alias" severity failure;
         end if;
      end loop;
      -- Byte-enable behavior and refusal of live writes are separate cases.
      wait until falling_edge(clk);
      reset <= '1'; we <= '1'; be <= "0101";
      l7 <= (others => '0'); l9 <= (others => '0');
      w7 <= x"89ABCDEF"; w9 <= x"89ABCDEF";
      wait until rising_edge(clk); wait for 1 ns;
      reset <= '0'; be <= "1111"; w7 <= x"DEADBEEF"; w9 <= x"DEADBEEF";
      wait until rising_edge(clk); wait for 1 ns; we <= '0';
      read_at(0);
      assert d7 = x"71AB00EF" and d9 = x"19AB00EF"
         report "byte enables or reset-only write guard failed" severity failure;
      -- Host reload restores FreeBIOS after native firmware sessions.
      reset <= '1';
      for i in 0 to 4095 loop
         read_at(i mod 1024);
         -- ARM7 source has its own complete address window.
         wait until falling_edge(clk);
         a7 <= to_unsigned(i, 12);
         wait until rising_edge(clk); wait for 1 ns;
         wait until falling_edge(clk);
         l7 <= to_unsigned(i, 12); l9 <= to_unsigned(i mod 1024, 10);
         w7 <= r7; w9 <= r9; we <= '1';
         wait until rising_edge(clk); wait for 1 ns; we <= '0';
      end loop;
      reset <= '0'; compare_public;
      report "PASS: reloadable BIOS initialization, all addresses, latency, byte enables, write guard and FreeBIOS restore";
      stop;
   end process;
end architecture;
