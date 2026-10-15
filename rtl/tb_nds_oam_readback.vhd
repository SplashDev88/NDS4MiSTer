-- SPDX-License-Identifier: GPL-3.0-or-later
-- Exercises the production ARM9 bus, including its real cache and read rotator.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;

entity tb_nds_oam_readback is end entity;
architecture test of tb_nds_oam_readback is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal adr, dout, din, oam_din : std_logic_vector(31 downto 0) := (others => '0');
   signal ena, done, oam_we, io_done, dma : std_logic := '0';
   signal rnw : std_logic := '1';
   signal acc : std_logic_vector(1 downto 0) := ACCESS_32BIT;
   signal oam_be : std_logic_vector(3 downto 0);
   signal oam_addr : integer range 0 to 511;
   signal oam_q : std_logic_vector(31 downto 0);
   signal busy : std_logic;
   signal power_a, power_b : std_logic := '1';
begin
   clk <= not clk after 5 ns;
   shadow : entity work.nds_palette_readback
      generic map (is_simu => '1', ignore_byte_writes => true)
      port map (clk => clk, reset => reset, power_a => power_a, power_b => power_b,
                addr => oam_addr, we => oam_we, be => oam_be, data => oam_din,
                q => oam_q, clear_busy => busy);
   dut : entity work.nds_membus9
      generic map (is_simu => '1')
      port map (
         clk => clk, reset => reset,
         itcm_ena => '0', itcm_load => '0', itcm_size => "00000",
         dtcm_ena => '0', dtcm_load => '0', dtcm_base => x"00000", dtcm_size => "00000",
         bus_cacheable_i => '0', bus_cacheable_d => '0',
         cache_op_ena => '0', cache_op => x"0", cache_op_addr => x"00000000", cache_op_busy => open,
         dma_bus => dma, cpu_adr => adr, cpu_rnw => rnw, cpu_ena => ena, cpu_code => '0',
         cpu_acc => acc, cpu_dout => dout, cpu_lowbits => adr(1 downto 0),
         cpu_lastread => x"BAD0BAD0", cpu_din => din, cpu_done => done,
         itcm_addr => open, itcm_we => open, itcm_be => open, itcm_writedata => open,
         itcm_readdata => x"00000000", dtcm_addr => open, dtcm_readdata => x"00000000",
         dtcm_addr_b => open, dtcm_we_b => open, dtcm_be_b => open, dtcm_writedata_b => open,
         brom_addr => open, brom_data => x"00000000",
         wsh_ena => open, wsh_rnw => open, wsh_addr => open, wsh_be => open, wsh_din => open,
         wsh_dout => x"00000000", wsh_done => '0', wsh_mapped => '0',
         vram_ena => open, vram_rnw => open, vram_addr => open, vram_be => open, vram_din => open,
         vram_dout => x"00000000", vram_done => '0',
         oam_we => oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => oam_be,
         oam_readdata => oam_q,
         pal_we => open, pal_addr => open, pal_din => open, pal_be => open,
         mr_ena => open, mr_rnw => open, mr_addr => open, mr_be => open, mr_writedata => open,
         mr_done => '0', mr_readdata => x"00000000", mr_pair => open,
         io_ce_next => '1', io_bus => open, io_wired_out => x"00000000", io_wired_done => io_done);

   -- Model the existing delayed OAM-write IO completion, not an immediate ACK.
   process (clk)
      variable delay : natural := 0;
   begin
      if rising_edge(clk) then
         io_done <= '0';
         if reset = '1' then delay := 0;
         elsif oam_we = '1' then delay := 4;
         elsif delay /= 0 then
            delay := delay - 1;
            if delay = 0 then io_done <= '1'; end if;
         end if;
      end if;
   end process;

   process
      function oam_address(i : natural) return std_logic_vector is
      begin return std_logic_vector(to_unsigned(16#07000000# + i * 4, 32)); end;
      function pattern(i : natural) return std_logic_vector is
      begin return std_logic_vector(to_unsigned(i * 65537 + 31708, 32)); end;
      procedure transfer(a, value : std_logic_vector(31 downto 0); read_op : std_logic;
                         width : std_logic_vector(1 downto 0) := ACCESS_32BIT) is
      begin
         wait until falling_edge(clk);
         adr <= a; dout <= value; rnw <= read_op; acc <= width; ena <= '1';
         wait until rising_edge(clk); wait for 1 ns; ena <= '0';
         for n in 0 to 20 loop
            exit when done = '1';
            wait until rising_edge(clk); wait for 1 ns;
         end loop;
         assert done = '1' report "OAM access timed out" severity failure;
         if read_op = '1' then
            assert din = value report "OAM read " & to_hstring(a) & " expected=" &
               to_hstring(value) & " actual=" & to_hstring(din) severity failure;
         end if;
         wait until rising_edge(clk); wait for 1 ns;
      end procedure;
      procedure burst_reads is
      begin
         -- Present the next request during the *same* cycle as the previous
         -- completion. The original bus contract must survive the extra wait.
         wait until falling_edge(clk);
         adr <= oam_address(0); rnw <= '1'; acc <= ACCESS_32BIT; ena <= '1';
         for i in 0 to 511 loop
            wait until rising_edge(clk); wait for 1 ns; ena <= '0';
            assert done = '0' report "OAM done before synchronous RAM data" severity failure;
            wait until rising_edge(clk); wait for 1 ns;
            assert done = '1' and din = pattern(i)
               report "back-to-back OAM read failed at word " & integer'image(i) severity failure;
            if i < 511 then
               adr <= oam_address(i+1); ena <= '1';
            end if;
         end loop;
         wait until rising_edge(clk); wait for 1 ns;
      end procedure;
   begin
      wait for 6 us;
      assert busy = '0' report "OAM reset clear deadlock" severity failure;
      reset <= '0';
      transfer(x"07000400", x"12345678", '0');
      transfer(x"07000400", x"12345678", '1');
      report "PASS: formerly failing ARM9 OAM read now returns 12345678, not zero";
      transfer(x"07000402", x"0000ABCD", '0', ACCESS_16BIT);
      transfer(x"07000400", x"ABCD5678", '1');
      transfer(x"07000400", x"00005678", '1', ACCESS_16BIT);
      transfer(x"07000402", x"0000ABCD", '1', ACCESS_16BIT);
      transfer(x"07000400", x"00000078", '1', ACCESS_8BIT);
      transfer(x"07000401", x"00000056", '1', ACCESS_8BIT);
      transfer(x"07000402", x"000000CD", '1', ACCESS_8BIT);
      transfer(x"07000403", x"000000AB", '1', ACCESS_8BIT);
      transfer(x"07FFFFFC", x"FEDCBA98", '0');
      transfer(x"070007FC", x"FEDCBA98", '1');
      transfer(x"07000401", x"78ABCD56", '1');
      transfer(x"07000402", x"5678ABCD", '1');
      transfer(x"07000403", x"CD5678AB", '1');
      transfer(x"07000401", x"78000056", '1', ACCESS_16BIT);
      transfer(x"07000403", x"CD0000AB", '1', ACCESS_16BIT);
      report "PASS: halfword lanes, byte extraction, address mirrors and unaligned rotation";

      -- Sprite read/modify/write: preserve shape, position and palette when
      -- changing only Y, X or the tile index. Zero readback loses those fields.
      transfer(x"07000200", x"806E403A", '0');
      transfer(x"07000204", x"0000C100", '0');
      transfer(x"07000200", x"806E403A", '1');
      transfer(x"07000200", (din and x"FFFFFF00") or x"000000C0", '0');
      transfer(x"07000200", x"806E40C0", '1');
      transfer(x"07000204", x"0000C100", '1', ACCESS_16BIT);
      transfer(x"07000204", (din and x"0000FC00") or x"00000108", '0', ACCESS_16BIT);
      transfer(x"07000200", x"806E40C0", '1');
      transfer(x"07000204", x"0000C108", '1');
      for lane in 0 to 3 loop
         transfer(std_logic_vector(to_unsigned(16#07000200# + lane, 32)),
                  x"000000FF", '0', ACCESS_8BIT);
      end loop;
      transfer(x"07000200", x"806E40C0", '1');
      report "PASS: sprite attribute updates preserve fields; all four byte-write lanes ignored";

      for i in 0 to 511 loop transfer(oam_address(i), pattern(i), '0'); end loop;
      burst_reads;
      dma <= '1';
      for i in 0 to 511 loop transfer(oam_address(i), pattern(i), '1'); end loop;
      dma <= '0';
      report "PASS: all 512 A/B sprite/affine words, completion-cycle requests and DMA reads";

      power_b <= '0';
      transfer(oam_address(256), x"00000000", '1');
      transfer(oam_address(256), x"DEADBEEF", '0');
      transfer(oam_address(0), pattern(0), '1');
      power_b <= '1'; power_a <= '0';
      transfer(oam_address(256), pattern(256), '1');
      transfer(oam_address(0), x"00000000", '1');
      transfer(oam_address(0), x"DEADBEEF", '0');
      power_a <= '1';
      transfer(oam_address(0), pattern(0), '1');
      report "PASS: engine power gating suppresses reads/writes without destroying stored attributes";

      reset <= '1'; wait for 6 us;
      assert busy = '0' report "second reset clear deadlock" severity failure;
      reset <= '0';
      for i in 0 to 511 loop transfer(oam_address(i), x"00000000", '1'); end loop;
      transfer(oam_address(511), x"89ABCDEF", '0');
      transfer(oam_address(511), x"89ABCDEF", '1');
      report "PASS: ROM reload clears both banks and subsequent access resumes";
      std.env.stop;
      wait;
   end process;
end architecture;
