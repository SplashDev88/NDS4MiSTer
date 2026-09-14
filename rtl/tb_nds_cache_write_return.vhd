-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cached-store commit, byte masks, response attribution and maintenance.
-- Authored synthetic data; runs on both baseline and accelerated cache RTL.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_nds_cache_write_return is
   generic (early : boolean := true; memory_delay : natural := 2;
            expect_early_write : boolean := true);
end entity;
architecture test of tb_nds_cache_write_return is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal ena, done, code, lock_req : std_logic := '0';
   signal rnw, cached, bufferable : std_logic := '1';
   signal adr, spec, din, dout : std_logic_vector(31 downto 0) := (others => '0');
   signal be : std_logic_vector(3 downto 0) := "1111";
   signal me, mr, mp, ml, md : std_logic := '0';
   signal ma : std_logic_vector(21 downto 2);
   signal mb : std_logic_vector(3 downto 0);
   signal mw, mlo, mhi : std_logic_vector(31 downto 0) := (others => '0');
   signal oe, ob : std_logic := '0';
   signal op : std_logic_vector(3 downto 0) := x"0";
   signal oa : std_logic_vector(31 downto 0) := (others => '0');
   signal dbg : std_logic_vector(7 downto 0);
   constant WORDS : natural := 8192;
   type ram_t is array (0 to WORDS-1) of std_logic_vector(31 downto 0);
   function pattern(i : natural) return std_logic_vector is
   begin return std_logic_vector(to_unsigned(16#12340000#+i*257,32)); end;
   function init return ram_t is
      variable m : ram_t;
   begin for i in m'range loop m(i):=pattern(i); end loop; return m; end;
   signal ram : ram_t := init;
   signal memory_reads, memory_writes : natural := 0;
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_cache9
      generic map (is_simu => '0', posted_write_misses => early)
      port map (
         clk=>clk, reset=>reset, req_ena=>ena, req_rnw=>rnw,
         req_code=>code, req_cacheable=>cached, req_bufferable=>bufferable, req_lock=>lock_req,
         req_addr=>adr, req_be=>be, req_wdata=>dout, spec_addr=>spec,
         resp_done=>done, resp_rdata=>din, mem_ena=>me, mem_rnw=>mr,
         mem_addr=>ma, mem_be=>mb, mem_wdata=>mw, mem_done=>md,
         mem_rdata=>mlo, mem_rdata_hi=>mhi, mem_pair=>mp, mem_lock=>ml,
         op_ena=>oe, op=>op, op_addr=>oa, op_busy=>ob, dbg_state=>dbg);
   process(clk)
      variable countdown : integer := -1;
      variable idx : natural := 0;
      variable rd, pair_req : std_logic;
      variable value : std_logic_vector(31 downto 0);
      variable lanes : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clk) then
         md <= '0';
         if me='1' then
            assert countdown=-1 report "overlapping memory commands" severity failure;

            countdown:=memory_delay; idx:=to_integer(unsigned(ma(14 downto 2)));
            rd:=mr; pair_req:=mp; value:=mw; lanes:=mb;
            if mr='1' then memory_reads<=memory_reads+1;
            else memory_writes<=memory_writes+1; end if;
         elsif countdown=0 then
            if rd='1' then
               mlo<=ram(idx); mhi<=ram((idx+1) mod WORDS);
               if pair_req='1' then assert idx mod 2=0 severity failure; end if;
            else
               assert pair_req='0' report "paired memory write" severity failure;
               for lane in 0 to 3 loop
                  if lanes(lane)='1' then
                     ram(idx)(lane*8+7 downto lane*8)<=value(lane*8+7 downto lane*8);
                  end if;
               end loop;
            end if;
            md<='1'; countdown:=-1;
         elsif countdown>0 then countdown:=countdown-1;
         end if;
      end if;
   end process;
   process
      variable expected : ram_t := init;
      variable cycles, fast_cycles, hit_total, measured_hits : natural := 0;
      variable before_reads, before_writes, index_value : natural;
      variable value : std_logic_vector(31 downto 0);
      variable mask : std_logic_vector(3 downto 0);
      procedure tick is
      begin wait until rising_edge(clk); wait for 1 ns; end;
      procedure idle is
      begin
         for n in 0 to 10000 loop
            exit when dbg(3 downto 0)=x"0" and ob='0'; tick;
         end loop;
         assert dbg(3 downto 0)=x"0" and ob='0' report "cache did not drain" severity failure;
      end;
      procedure transfer(index : natural; value : std_logic_vector(31 downto 0);
                         rd : std_logic; lanes : std_logic_vector(3 downto 0):="1111";
                         cacheable : std_logic:='1'; instruction : std_logic:='0') is
         variable a : std_logic_vector(31 downto 0);
      begin
         a:=std_logic_vector(to_unsigned(16#02000000#+index*4,32));
         -- The real membus exposes the live address one edge before req_*.
         wait until falling_edge(clk); spec<=a; tick;
         adr<=a; dout<=value; rnw<=rd; be<=lanes; cached<=cacheable; code<=instruction; ena<='1';
         tick; ena<='0'; cycles:=0;
         for n in 0 to 10000 loop
            exit when done='1'; tick; cycles:=cycles+1;
         end loop;
         assert done='1' report "cache response timeout" severity failure;
         if rd='1' then
            assert din=value report "read mismatch index="&integer'image(index)&
               " expected="&to_hstring(value)&" actual="&to_hstring(din) severity failure;
         end if;
      end;
      procedure store(index : natural; value : std_logic_vector(31 downto 0);
                      lanes : std_logic_vector(3 downto 0):="1111") is
      begin
         transfer(index,value,'0',lanes);
         for b in 0 to 3 loop
            if lanes(b)='1' then expected(index)(b*8+7 downto b*8):=value(b*8+7 downto b*8); end if;
         end loop;
      end;
      procedure maintain(index : natural; action : std_logic_vector(3 downto 0)) is
      begin
         oa<=std_logic_vector(to_unsigned(16#02000000#+index*4,32)); op<=action; oe<='1';
         tick; oe<='0'; tick; idle;
      end;
      procedure store_with_maintenance(index : natural; value : std_logic_vector(31 downto 0)) is
         variable a : std_logic_vector(31 downto 0);
      begin
         a:=std_logic_vector(to_unsigned(16#02000000#+index*4,32));
         wait until falling_edge(clk); spec<=a; tick;
         adr<=a; dout<=value; rnw<='0';be<=x"F";cached<='1';code<='0';ena<='1';
         tick;ena<='0';
         for n in 0 to 10000 loop exit when dbg(3 downto 0)=x"3";tick;end loop;
         assert dbg(3 downto 0)=x"3" report "write commit state not exercised" severity failure;
         oe<='1';op<="0101";oa<=a;
         wait for 1 ns;
         assert done='0' report "maintenance did not suppress early store response" severity failure;
         tick;oe<='0';
         assert done='1' report "store response lost on coincident maintenance" severity failure;
         tick;
         assert done='0' report "duplicate response after maintenance/store collision" severity failure;
         idle;
         assert ram(index)=value report "clean missed store on commit edge" severity failure;
         expected(index):=value;
      end;
      procedure reset_store(index : natural) is
         variable a : std_logic_vector(31 downto 0);
      begin
         transfer(index,expected(index),'1');idle;
         a:=std_logic_vector(to_unsigned(16#02000000#+index*4,32));
         wait until falling_edge(clk);spec<=a;tick;
         adr<=a;dout<=x"BAD00BAD";rnw<='0';be<=x"F";cached<='1';code<='0';ena<='1';
         tick;ena<='0';
         for n in 0 to 10000 loop exit when dbg(3 downto 0)=x"3";tick;end loop;
         assert dbg(3 downto 0)=x"3" report "reset did not hit commit state" severity failure;
         reset<='1';wait for 1 ns;
         assert done='0' report "reset did not suppress store completion" severity failure;
         tick;tick;reset<='0';
         for n in 0 to 3 loop tick;assert done='0' report "late store completion after reset" severity failure;end loop;
         transfer(index,expected(index),'1');idle;
      end;
   begin
      tick; tick; reset<='0'; tick;
      transfer(64,expected(64),'1',"1111",'1','1'); idle;
      before_writes:=memory_writes;
      store(2048,x"12345678");
      if early and memory_delay>=7 then
         assert ram(2048)/=expected(2048) report "buffered store did not overlap external write" severity failure;
      else
         assert not early or memory_writes>=before_writes report "bad write count" severity failure;
      end if;
      transfer(64,expected(64),'1',"1111",'1','1');
      if early and memory_delay>=17 then
         assert ram(2048)/=expected(2048) report "instruction hit did not overlap posted store" severity failure;
      end if;
      -- Reads wait for the outstanding store; partial byte lanes are preserved.
      transfer(2048,expected(2048),'1',"1111",'0');idle;
      assert ram(2048)=expected(2048) report "stale dependent read" severity failure;
      for lanes in 0 to 15 loop
         mask:=std_logic_vector(to_unsigned(lanes,4));
         store(2056+lanes*8,x"FEDCBA98",mask);
         maintain(0,"1001");
         assert ram(2056+lanes*8)=expected(2056+lanes*8)
            report "drain completed before masked write" severity failure;
      end loop;
      -- Two stores and an I-cache miss keep each transaction's address/data.
      store(2304,x"87654321");store(2312,x"01020304");
      transfer(1024,expected(1024),'1',"1111",'1','1');idle;
      assert ram(2304)=expected(2304) and ram(2312)=expected(2312)
         report "queued store transaction metadata changed" severity failure;
      -- Disabled attributes and a locked store must wait for physical commit.
      bufferable<='0'; store(2560,x"A5A5A5A5");
      assert ram(2560)=expected(2560) report "unbufferable store retired early" severity failure;
      bufferable<='1'; lock_req<='1';store(2568,x"5A5A5A5A");
      assert ram(2568)=expected(2568) report "locked store retired early" severity failure;
      lock_req<='0';
      -- A read pending while drain wins arbitration must not get the store's
      -- late memory response attributed to it.
      store(2816,x"01234567");op<="1001";oa<=x"00000000";oe<='1';
      tick;oe<='0';transfer(65,expected(65),'1',"1111",'1','1');idle;
      assert ram(2816)=expected(2816) report "pending drain was lost" severity failure;
      -- Cached store hits retain the accepted commit path and write-back semantics.
      transfer(3072,expected(3072),'1');idle;
      store(3073,x"CAFEBABE");transfer(3073,expected(3073),'1');
      maintain(3072,"0101");
      assert ram(3073)=expected(3073) report "cached hit or clean changed" severity failure;
      report "PASS: posted write overlap, drain, byte masks, dependent reads, locks and queued metadata";
      -- Four tags map to one set, covering every cache way and line word.
      maintain(0,"0010");
      for way in 0 to 3 loop
         transfer(way*256,expected(way*256),'1');idle;
      end loop;
      before_reads:=memory_reads;before_writes:=memory_writes;
      -- Consume an isolated write response, leaving no next request that could
      -- hide a second response pulse in its speculative prefetch cycle.
      store(0,x"77665544");tick;
      assert done='0' report "duplicate isolated cached-store response" severity failure;
      tick;
      assert done='0' report "late isolated cached-store response" severity failure;
      transfer(0,expected(0),'1');tick;
      for way in 0 to 3 loop
         for word in 0 to 7 loop
            index_value:=way*256+word;
            for lanes in 0 to 15 loop
               value:=std_logic_vector(to_unsigned(16#980000#+way*65536+word*256+lanes,32)) xor x"C3A55A3C";
               mask:=std_logic_vector(to_unsigned(lanes,4));
               store(index_value,value,mask);
               if expect_early_write then
                  assert cycles=0 report "qualified store gained a wait cycle" severity failure;
               else
                  assert cycles=2 report "baseline cached-store latency changed" severity failure;
               end if;
               transfer(index_value,expected(index_value),'1');tick;
               for n in 0 to 1 loop assert done='0' report "duplicate cached-store/read response" severity failure;tick;end loop;
            end loop;
         end loop;
      end loop;
      assert memory_reads=before_reads and memory_writes=before_writes
         report "warm stores/reads generated unexpected external memory traffic" severity failure;
      for way in 0 to 3 loop
         maintain(way*256,"0101");
         for word in 0 to 7 loop
            assert ram(way*256+word)=expected(way*256+word)
               report "masked cached store lost before clean" severity failure;
         end loop;
      end loop;
      report "PASS: all4ways,8words,16byte masks; exact cached values and clean contents";

      -- Overwrite a warm word repeatedly before cleaning; latest store wins.
      for n in 0 to 31 loop
         store(1,std_logic_vector(to_unsigned(16#ABC000#+n,32)));
      end loop;
      transfer(1,expected(1),'1');tick;
      lock_req<='1';store(2,x"F00DFACE");
      assert cycles=2 report "locked cached store did not retain registered completion" severity failure;
      lock_req<='0';transfer(2,expected(2),'1');tick;
      store_with_maintenance(3,x"CAFE4455");
      assert ram(1)=expected(1) and ram(2)=expected(2)
         report "back-to-back or locked store lost on clean" severity failure;

      -- Invalidation winning request arbitration must force a store miss.
      op<="0010";oa<=x"00000000";oe<='1';
      wait until falling_edge(clk);spec<=x"02000000";tick;
      oe<='0';adr<=x"02000000";dout<=x"99887766";rnw<='0';be<=x"F";cached<='1';code<='0';ena<='1';
      tick;ena<='0';
      for n in 0 to 10000 loop exit when done='1';tick;end loop;
      assert done='1' report "store lost behind invalidation" severity failure;
      tick;maintain(0,"1001");
      assert ram(0)=x"99887766" report "store used invalidated cache tag" severity failure;
      expected(0):=x"99887766";
      reset_store(128);
      report "PASS: repeated/locked stores, maintenance at commit, queued invalidation and reset";

      std.env.stop; wait;
   end process;
end architecture;
