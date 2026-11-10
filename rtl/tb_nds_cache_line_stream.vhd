-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cache + mainram with the production related-clock pulse bridge. The SDRAM
-- boundary deliberately separates done32/done64, varies latency, and inserts
-- scheduler stalls. Compare legacy and streamed runs with identical inputs.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_nds_cache_line_stream is
   generic (line_stream : boolean := true; mem_ratio : positive := 3;
            memory_delay : natural := 2; priority7 : std_logic := '1');
end;
architecture test of tb_nds_cache_line_stream is
   signal clk1x, clk2x, clkMem : std_logic := '1';
   signal phase : unsigned(1 downto 0) := "00";
   signal reset : std_logic := '1';
   signal ena, code, response : std_logic := '0';
   signal addr, rdata : std_logic_vector(31 downto 0) := (others => '0');
   signal ce, cr, cp, cl, lock9, done1x, done2x : std_logic;
   signal ca : std_logic_vector(21 downto 2);
   signal cb : std_logic_vector(3 downto 0);
   signal cw, rd, rdhi : std_logic_vector(31 downto 0);
   signal debug : std_logic_vector(7 downto 0);
   signal toggle, seen, request1x, done_seen : std_logic := '0';
   signal ena7, done7 : std_logic := '0';
   signal rd7 : std_logic_vector(31 downto 0);
   constant ADDR7 : natural := 16#3F0000#;
   signal allow_mem : std_logic := '1';
   signal active, busy, se, sr, done32, done64 : std_logic := '0';
   signal sa : std_logic_vector(26 downto 0);
   signal sb : std_logic_vector(3 downto 0);
   signal sw, sd, sdhi : std_logic_vector(31 downto 0) := (others => '0');
   signal cycles, logical_requests, physical_requests, responses7 : natural := 0;
   type address_log is array(0 to 4095) of natural;
   signal addresses : address_log := (others => 0);
   function pattern(a : natural) return std_logic_vector is
   begin return std_logic_vector(to_unsigned(a/4,32) xor x"97E14C23"); end;
begin
   assert mem_ratio = 3 or mem_ratio = 4 severity failure;
   clk1x <= not clk1x after 15 ns;
   clk2x <= not clk2x after 7500 ps;
   clkMem <= not clkMem after 15 ns / mem_ratio;
   process(clkMem)
      variable ticks : natural := 0;
   begin
      if rising_edge(clkMem) then
         if phase = mem_ratio-1 then phase <= "00"; else phase <= phase+1; end if;
         ticks := ticks+1;
         if reset='1' then ticks:=0; end if;
         -- Exercise request admission stalls without changing return timing.
         if ticks mod 19 < 5 then allow_mem <= '0'; else allow_mem <= '1'; end if;
      end if;
   end process;
   process(clk2x)
   begin
      if rising_edge(clk2x) then
         cycles <= cycles+1;
         done_seen <= done1x;
         if reset='1' then toggle<='0';
         elsif ce='1' then toggle<=not toggle; end if;
         if ce='1' and reset='0' then logical_requests<=logical_requests+1; end if;
      end if;
   end process;
   process(clk1x)
   begin
      if rising_edge(clk1x) then
         seen <= toggle;
         request1x <= toggle xor seen;
         if done7='1' then
            assert rd7=pattern(ADDR7) report "ARM7 response corrupted" severity failure;
            responses7<=responses7+1;
         end if;
      end if;
   end process;
   done2x <= done1x and not done_seen;
   cache : entity work.nds_cache9
      generic map(is_simu=>'1', cache_line_stream=>line_stream)
      port map(clk=>clk2x, reset=>reset, req_ena=>ena, req_rnw=>'1',
         req_code=>code, req_cacheable=>'1', req_addr=>addr, req_be=>"1111",
         req_wdata=>(others=>'0'), spec_addr=>addr, resp_done=>response, resp_rdata=>rdata,
         mem_ena=>ce, mem_rnw=>cr, mem_addr=>ca, mem_be=>cb, mem_wdata=>cw,
         mem_done=>done2x, mem_rdata=>rd, mem_rdata_hi=>rdhi, mem_pair=>cp,
         mem_line=>cl, mem_lock=>lock9, op_ena=>'0', op=>x"0",
         op_addr=>(others=>'0'), op_busy=>open, dbg_state=>debug);
   ram : entity work.nds_mainram
      generic map(Softmap_NDS_MAINRAM_ADDR=>0)
      port map(clk1x=>clk1x, clkMem=>clkMem, clkMemIndex=>phase, reset=>reset,
         arm7_priority=>priority7, mem9_ena=>request1x, mem9_lock=>lock9,
         mem9_rnw=>cr, mem9_addr=>ca, mem9_be=>cb, mem9_writedata=>cw,
         mem9_pair=>cp, mem9_line=>cl, mem9_done=>done1x,
         mem9_readdata=>rd, mem9_readdata_hi=>rdhi,
         mem7_ena=>ena7, mem7_rnw=>'1', mem7_addr=>std_logic_vector(to_unsigned(ADDR7/4,20)),
         mem7_be=>"1111", mem7_writedata=>(others=>'0'), mem7_done=>done7, mem7_readdata=>rd7,
         mainram_allow=>allow_mem, mainram_active=>active, mainram_busy=>busy,
         mr_sdram_ena=>se, mr_sdram_rnw=>sr, mr_sdram_Adr=>sa,
         mr_sdram_Din=>sw, mr_sdram_be=>sb, sdram_Dout=>sd,
         sdram_Dout_hi=>sdhi, sdram_done32=>done32, sdram_done64=>done64);
   process(clkMem)
      variable left : integer := -1;
      variable a, delay : natural := 0;
   begin
      if rising_edge(clkMem) then
         done32<='0'; done64<='0';
         -- A controller may accept a new request while the previous done64
         -- tail is retiring. Preserve the old tail before accepting the new.
         if left>=0 then
            if left=2 then sd<=pattern(a); done32<='1'; end if;
            if left=0 then sdhi<=pattern(a+4); done64<='1'; end if;
            left:=left-1;
         end if;
         if se='1' then
            assert left<0 report "overlapping physical SDRAM reads" severity failure;
            assert sr='1' report "read test issued a write" severity failure;
            a:=to_integer(unsigned(sa));
            assert a mod 8=0 report "unaligned pair" severity failure;
            addresses(physical_requests)<=a;
            physical_requests<=physical_requests+1;
            delay:=memory_delay+(a/8 mod 7);
            left:=delay+2;
         end if;
      end if;
   end process;
   process
      variable first, logical_start, cstart, critical, finish, pair_index, expected_addr : natural;
      variable base, a, response7_start : natural;
      variable mode : std_logic;
      procedure cycle is
      begin wait until rising_edge(clk2x); wait for 1 ns; end;
      procedure drain is
      begin
         for n in 0 to 10000 loop
            exit when debug(3 downto 0)=x"0" and busy='0' and active='0'; cycle;
         end loop;
         assert debug(3 downto 0)=x"0" and busy='0' and active='0'
            report "cache/mainram drain timeout" severity failure;
         for n in 0 to 5 loop
            assert response='0' report "duplicate cache response" severity failure; cycle;
         end loop;
      end;
      procedure launch(a : natural; instruction : std_logic) is
      begin
         wait until falling_edge(clk2x);
         addr<=std_logic_vector(to_unsigned(16#02000000#+a,32)); code<=instruction; ena<='1';
         cycle; ena<='0';
      end;
      procedure await_response(a : natural) is
      begin
         for n in 0 to 10000 loop exit when response='1'; cycle; end loop;
         assert response='1' report "cache response timeout" severity failure;
         assert rdata=pattern(a) report "cache stream data mismatch" severity failure;
      end;
      procedure reset_drain is
      begin
         wait until falling_edge(clk1x); reset<='1'; ena<='0'; ena7<='0';
         -- Reset cancels unissued pairs; allow any issued controller read to
         -- drain before releasing the next session, as at the console boundary.
         for n in 0 to 10000 loop
            cycle;
            exit when busy='0' and active='0' and n>20;
         end loop;
         assert busy='0' and active='0' report "reset failed to drain" severity failure;
         for n in 0 to 9 loop cycle; end loop;
         wait until falling_edge(clk1x); reset<='0'; cycle;
      end;
   begin
      reset_drain;
      -- All eight critical words, both caches, varied launch phases. Check the
      -- exact physical wrap order, one response, all eight words and warm hits.
      for instruction in 0 to 1 loop
         if instruction=0 then mode:='0'; else mode:='1'; end if;
         for offset in 0 to 7 loop
            reset_drain;
            base:=16#1000#+instruction*16#1000#+offset*32;
            a:=base+offset*4;
            for n in 0 to offset mod 3 loop cycle; end loop;
            first:=physical_requests; logical_start:=logical_requests; cstart:=cycles;
            launch(a,mode); await_response(a); critical:=cycles-cstart;
            assert physical_requests-first<4 report "critical word waited for full line" severity failure;
            cycle;
            for n in 0 to 10000 loop
               exit when debug(3 downto 0)=x"0"; cycle;
            end loop;
            assert debug(3 downto 0)=x"0" report "fill never completed" severity failure;
            finish:=cycles-cstart; drain;
            assert physical_requests-first=4 report "line did not issue exactly four physical pairs" severity failure;
            if line_stream then
               assert logical_requests-logical_start=1 report "stream repeated logical request" severity failure;
            else
               assert logical_requests-logical_start=4 report "legacy request count changed" severity failure;
            end if;
            for pair in 0 to 3 loop
               expected_addr:=base+((offset/2+pair) mod 4)*8;
               assert addresses(first+pair)=expected_addr report "line wrap/address order mismatch" severity failure;
            end loop;
            for word in 0 to 7 loop
               launch(base+word*4,mode); await_response(base+word*4); cycle; drain;
            end loop;
            assert physical_requests-first=4 report "warm word caused extra refill" severity failure;
            report "METRIC stream="&boolean'image(line_stream)&" ratio="&integer'image(mem_ratio)&
               " delay="&integer'image(memory_delay)&" code="&integer'image(instruction)&
               " offset="&integer'image(offset)&" critical="&integer'image(critical)&
               " complete="&integer'image(finish);
         end loop;
      end loop;
      -- ARM7 queues after the first pair starts; it must be admitted between
      -- pairs with priority7 set and eventually with either priority setting.
      first:=physical_requests; response7_start:=responses7;
      base:=16#8000#; launch(base+28,'1');
      wait until physical_requests>first;
      wait until falling_edge(clk1x); ena7<='1';
      wait until rising_edge(clk1x); wait for 1 ns; ena7<='0';
      await_response(base+28); cycle; drain;
      assert responses7=response7_start+1 report "ARM7 starved or duplicate response" severity failure;
      assert physical_requests=first+5 report "contended fill lost a request" severity failure;
      pair_index:=0;
      for entry in first to first+4 loop
         if addresses(entry)/=ADDR7 then
            assert addresses(entry)=base+((3+pair_index) mod 4)*8 report "contended fill order" severity failure;
            pair_index:=pair_index+1;
         end if;
      end loop;
      if priority7='1' then
         assert addresses(first+1)=ADDR7 report "ARM7 priority not honored between pairs" severity failure;
      end if;
      -- Abort at every physical pair, then verify a fresh session's full line.
      for abort_pair in 1 to 4 loop
         base:=16#A000#+abort_pair*64;
         first:=physical_requests; launch(base+20,'0');
         wait until physical_requests>=first+abort_pair;
         reset_drain;
         first:=physical_requests;
         launch(base+28,'1'); await_response(base+28); cycle; drain;
         assert physical_requests=first+4 report "reset leaked/omitted a pair" severity failure;
         for word in 0 to 7 loop
            launch(base+word*4,'1'); await_response(base+word*4); cycle; drain;
         end loop;
         assert physical_requests=first+4 report "reset recovery line incomplete" severity failure;
      end loop;
      report "PASS line-stream CDC, critical ordering, warm hits, ARM7 arbitration and reset";
      std.env.stop;
      wait;
   end process;
   process begin wait for 5 ms; assert false report "watchdog timeout" severity failure; end process;
end;
