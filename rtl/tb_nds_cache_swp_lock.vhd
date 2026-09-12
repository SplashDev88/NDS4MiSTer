-- SPDX-License-Identifier: GPL-3.0-or-later
-- Production membus/cache/mainram regression for an uncached SWP queued behind
-- a critical-word-first fill or maintenance writeback. The SDRAM boundary model
-- returns the high word two cycles after the low word, as the real port does.
-- Clocks are intentionally shared here: this checks transaction attribution,
-- not CDC timing. legacy_live_lock recreates beta.12's wrong request flag source.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity tb_nds_cache_swp_lock is
   generic (legacy_live_lock : boolean := false; memory_delay : natural := 2);
end entity;
architecture test of tb_nds_cache_swp_lock is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal adr, dout, din : std_logic_vector(31 downto 0) := (others => '0');
   signal ena, done, dma, code, cached, cpu_lock : std_logic := '0';
   signal rnw : std_logic := '1';
   signal acc : std_logic_vector(1 downto 0) := ACCESS_32BIT;
   signal mem_ena, mem_rnw, mem_pair, mem_lock, applied_lock, mem_done : std_logic;
   signal mem_addr : std_logic_vector(21 downto 2);
   signal mem_be : std_logic_vector(3 downto 0);
   signal mem_wdata, mem_rdata, mem_rdata_hi : std_logic_vector(31 downto 0);
   signal op_ena, op_busy : std_logic := '0';
   signal op : std_logic_vector(3 downto 0) := x"0";
   signal op_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal sd_ena, sd_rnw, sd_done32, sd_done64, active, busy : std_logic := '0';
   signal sd_addr : std_logic_vector(26 downto 0);
   signal sd_be : std_logic_vector(3 downto 0);
   signal sd_wdata, sd_rdata, sd_rdata_hi : std_logic_vector(31 downto 0) := (others => '0');
   signal pair_count, locked_reads, locked_writes, writes : natural := 0;
   constant WORDS : natural := 4096;
   type t_mem is array (0 to WORDS-1) of std_logic_vector(31 downto 0);
   function pattern(i : natural) return std_logic_vector is
   begin return std_logic_vector(to_unsigned(16#12340000# + i*257,32)); end;
   function init return t_mem is
      variable m : t_mem;
   begin
      for i in m'range loop m(i) := pattern(i); end loop;
      return m;
   end;
   signal backing : t_mem := init;
   function expected(a : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin return pattern(to_integer(unsigned(a(13 downto 2)))); end;
begin
   clk <= not clk after 5 ns;
   applied_lock <= cpu_lock and not cached when legacy_live_lock else mem_lock;
   dut : entity work.nds_membus9
      generic map (is_simu => '1')
      port map (
         clk => clk, reset => reset,
         itcm_ena => '0', itcm_load => '0', itcm_size => "00000",
         dtcm_ena => '0', dtcm_load => '0', dtcm_base => x"00000", dtcm_size => "00000",
         bus_cacheable_i => cached, bus_cacheable_d => cached,
         cache_op_ena => op_ena, cache_op => op, cache_op_addr => op_addr, cache_op_busy => op_busy,
         dma_bus => dma, cpu_adr => adr, cpu_rnw => rnw, cpu_ena => ena, cpu_code => code, cpu_lock => cpu_lock,
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
         pal_we => open, pal_addr => open, pal_din => open, pal_be => open,
         pal_readdata => x"00000000",
         oam_we => open, oam_addr => open, oam_din => open, oam_be => open,
         mr_ena => mem_ena, mr_rnw => mem_rnw, mr_addr => mem_addr, mr_be => mem_be, mr_writedata => mem_wdata,
         mr_done => mem_done, mr_readdata => mem_rdata, mr_pair => mem_pair,
         mr_readdata_hi => mem_rdata_hi, mr_lock => mem_lock,
         io_ce_next => '1', io_bus => open, io_wired_out => x"00000000", io_wired_done => '0');


   ram : entity work.nds_mainram
      generic map (Softmap_NDS_MAINRAM_ADDR => 0)
      port map (
         clk1x => clk, clkMem => clk, clkMemIndex => "00", reset => reset,
         arm7_priority => '0',
         mem9_ena => mem_ena, mem9_lock => applied_lock, mem9_rnw => mem_rnw,
         mem9_addr => mem_addr, mem9_be => mem_be, mem9_writedata => mem_wdata,
         mem9_pair => mem_pair, mem9_done => mem_done, mem9_readdata => mem_rdata,
         mem9_readdata_hi => mem_rdata_hi,
         mem7_ena => '0', mem7_rnw => '1', mem7_addr => (others => '0'),
         mem7_be => "1111", mem7_writedata => (others => '0'),
         mem7_done => open, mem7_readdata => open,
         mainram_allow => '1', mainram_active => active, mainram_busy => busy,
         mr_sdram_ena => sd_ena, mr_sdram_rnw => sd_rnw, mr_sdram_Adr => sd_addr,
         mr_sdram_Din => sd_wdata, mr_sdram_be => sd_be,
         sdram_Dout => sd_rdata, sdram_Dout_hi => sd_rdata_hi,
         sdram_done32 => sd_done32, sdram_done64 => sd_done64);
   process(clk)
      variable countdown : integer := -1;
      variable idx : natural := 0;
      variable rd : std_logic;
      variable data : std_logic_vector(31 downto 0);
      variable be : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clk) then
         sd_done32 <= '0'; sd_done64 <= '0';
         if sd_ena = '1' then
            assert countdown = -1 report "overlapping SDRAM requests" severity failure;
            countdown := memory_delay + 2;
            idx := to_integer(unsigned(sd_addr(13 downto 2)));
            rd := sd_rnw; data := sd_wdata; be := sd_be;
         elsif countdown >= 0 then
            if countdown = 2 then
               if rd = '1' then sd_rdata <= backing(idx);
               else
                  for lane in 0 to 3 loop
                     if be(lane) = '1' then
                        backing(idx)(lane*8+7 downto lane*8) <= data(lane*8+7 downto lane*8);
                     end if;
                  end loop;
               end if;
               sd_done32 <= '1';
            elsif countdown = 0 then
               sd_rdata_hi <= backing((idx+1) mod WORDS);
               sd_done64 <= '1';
            end if;
            countdown := countdown - 1;
         end if;
         if mem_ena = '1' then
            if mem_pair = '1' then pair_count <= pair_count + 1; end if;
            if mem_rnw = '0' then writes <= writes + 1; end if;
            if applied_lock = '1' then
               if mem_rnw = '1' then locked_reads <= locked_reads + 1;
               else locked_writes <= locked_writes + 1; end if;
            end if;
         end if;
      end if;
   end process;
   process
      variable pairs_before, lr, lw, wr : natural;
      procedure cycle is
      begin wait until rising_edge(clk); wait for 1 ns; end;
      procedure transfer(a, value : std_logic_vector(31 downto 0);
                         rd, cacheable, instruction, locked : std_logic;
                         is_dma : std_logic := '0') is
      begin
         wait until falling_edge(clk);
         adr <= a; dout <= value; rnw <= rd; cached <= cacheable;
         code <= instruction; cpu_lock <= locked; dma <= is_dma; ena <= '1';
         cycle; ena <= '0';
         for n in 0 to 10000 loop
            exit when done = '1'; cycle;
         end loop;
         assert done = '1' report "request timed out address=" & to_hstring(a) severity failure;
         if rd = '1' then
            assert din = value report "read mismatch address=" & to_hstring(a) &
               " expected=" & to_hstring(value) & " actual=" & to_hstring(din) severity failure;
         end if;
         cycle;
      end;
      procedure swap(a : std_logic_vector(31 downto 0)) is
      begin
         transfer(a,expected(a),'1','0','0','1');
         transfer(a,x"56789ABC",'0','0','0','1');
         transfer(a,x"56789ABC",'1','0','0','0');
      end;
   begin
      cycle; cycle; reset <= '0'; cycle;
      -- Returning the critical word must leave three pair fills in flight.
      transfer(x"02000000",expected(x"02000000"),'1','1','1','0');
      assert pair_count < 4 report "critical-word-first no longer returns early" severity failure;
      swap(x"023FFFE8");
      -- A poisoned background pair supplies a stale high word here with legacy wiring.
      for i in 1 to 7 loop
         transfer(std_logic_vector(to_unsigned(16#02000000#+i*4,32)),pattern(i),'1','1','1','0');
      end loop;
      assert pair_count = 4 report "warm instruction line unexpectedly refilled" severity failure;
      assert locked_reads = 1 and locked_writes = 1
         report "background fill inherited the next SWP lock" severity failure;
      report "PASS: critical-word-first, all eight cached words, and queued SWP read/write";

      -- Dirty maintenance writeback must remain unlocked while a SWP waits.
      transfer(x"02000400",expected(x"02000400"),'1','1','0','0');
      transfer(x"02000400",x"A55A3CC3",'0','1','0','0');
      lr := locked_reads; lw := locked_writes; wr := writes;
      op_addr <= x"02000400"; op <= "0111"; op_ena <= '1';
      cycle; op_ena <= '0';
      swap(x"023FFFD8");
      assert locked_reads = lr+1 and locked_writes = lw+1
         report "maintenance writeback inherited a pending SWP lock" severity failure;
      assert writes = wr+9 report "expected eight writeback words and one SWP write" severity failure;
      transfer(x"02400400",x"A55A3CC3",'1','0','0','0');
      report "PASS: dirty maintenance, pending SWP, and backing-memory contents";

      -- Stale CPU lock is irrelevant to DMA and instruction requests. A cached
      -- data write miss bypasses to memory but must not claim an uncached lock.
      lr := locked_reads; lw := locked_writes;
      transfer(x"02000800",expected(x"02000800"),'1','1','0','1','1');
      transfer(x"02400804",expected(x"02400804"),'1','0','1','1');
      transfer(x"02000C00",x"76543210",'0','1','0','1');
      transfer(x"02400C00",x"76543210",'1','0','0','0');
      assert locked_reads = lr and locked_writes = lw
         report "DMA, instruction fetch or cached write miss acquired a lock" severity failure;
      report "PASS: DMA/code/cacheability qualification and no extra fill transactions";
      std.env.stop; wait;
   end process;
end architecture;
