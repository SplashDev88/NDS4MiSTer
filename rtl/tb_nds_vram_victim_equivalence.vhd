-- SPDX-License-Identifier: GPL-3.0-or-later
-- Complete-instance test template, expanded by test_vram_victim_equivalence.py.
-- Passive probes expose canonical cache records; no product behavior is stubbed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_nds_vram_victim_equivalence is
   generic(SEED : natural := 1; POSTED : boolean := true; RANDOM_CYCLES : natural := 12000);
end;
architecture sim of tb_nds_vram_victim_equivalence is
-- @DECLARATIONS@
   type addr_array is array(0 to 7) of unsigned(16 downto 0);
   type word_array is array(0 to 7) of std_logic_vector(31 downto 0);
   type counts_array is array(natural range <>) of natural;
   signal addresses : addr_array := (others=>(others=>'0'));
   signal requests, accepts, dones : std_logic_vector(7 downto 0) := (others=>'0');
   signal words : word_array;
   signal cycles, phase, comparisons : natural := 0;
   signal events : counts_array(0 to 11) := (others=>0);
   signal accepted, returned : counts_array(0 to 7) := (others=>0);
   signal fills_plus_hits, holes, backing_reads, cpu_writes, posted_acks, stalls : natural := 0;
   signal extra_delay : natural := 0;
   function fixture(bank, wordaddr : natural) return std_logic_vector is
   begin
      return x"A0" & std_logic_vector(to_unsigned(bank,8)) & std_logic_vector(to_unsigned(wordaddr,16));
   end;
begin
   clk <= not clk after 5 ns;
-- @INSTANCES@
-- @WIRING@
   rsrv_ready <= '1' when cycles mod 7/=3 and cycles mod 11/=5 else '0';

   -- Shared external memory answers accepted reference transactions. Every
   -- candidate request/payload/enable is asserted equal before the next edge.
   memory_model: process(clk)
      type memory_t is array(0 to 131071) of std_logic_vector(31 downto 0);
      type queue_t is array(0 to 63) of std_logic_vector(63 downto 0);
      type times_t is array(0 to 63) of natural;
      variable memory : memory_t := (others=>(others=>'0'));
      variable queue : queue_t;
      variable deadline : times_t;
      variable head, tail, count, delay, index : natural := 0;
      variable pending, initialized : boolean := false;
      variable write_op : boolean := false;
      variable data : std_logic_vector(31 downto 0);
      variable be : std_logic_vector(3 downto 0);
      variable i : natural;
   begin
      if rising_edge(clk) then
         cycles<=cycles+1;
         srv_done<='0'; rsrv_done<='0';
         if reset='1' then
            head:=0;tail:=0;count:=0;pending:=false;initialized:=false;
         else
            if clr_busy(0)='0' and not initialized then
               -- Test fixture upload after the DUT has completed its real
               -- full reset-clear pass. Subsequent CPU writes update this RAM.
               for k in memory'range loop memory(k):=fixture(k/32768,k mod 32768);end loop;
               initialized:=true;
            end if;
            if pending then
               if delay=0 then
                  srv_dout<=memory(index);
                  if write_op then
                     for lane in 0 to 3 loop
                        if be(lane)='1' then memory(index)(lane*8+7 downto lane*8):=data(lane*8+7 downto lane*8);end if;
                     end loop;
                     if initialized then cpu_writes<=cpu_writes+1;end if;
                  end if;
                  srv_done<='1';pending:=false;
               else delay:=delay-1;end if;
            elsif srv_req(0)='1' and srv_done='0' then
               index:=to_integer(unsigned(srv_bank(0)))*32768+to_integer(srv_addr(0));
               write_op:=srv_rnw(0)='0';data:=srv_din(0);be:=srv_be(0);pending:=true;
               if clr_busy(0)='1' then delay:=0; else delay:=(cycles+SEED) mod 5;end if;
            end if;
            if rsrv_req(0)='1' and rsrv_ready='1' then
               assert count<64 report "Backing response model overflow" severity failure;
               i:=to_integer(unsigned(rsrv_bank(0)))*32768+to_integer(rsrv_addr(0))*2;
               queue(tail):=memory(i+1)&memory(i);
               deadline(tail):=cycles+7+(SEED mod 23)+extra_delay;
               tail:=(tail+1) mod 64;count:=count+1;backing_reads<=backing_reads+1;
            end if;
            if count>0 and cycles>=deadline(head) then
               rsrv_dout<=queue(head);rsrv_done<='1';head:=(head+1) mod 64;count:=count-1;
            end if;
         end if;
      end if;
   end process;

   monitor: process
      variable outstanding : counts_array(0 to 7) := (others=>0);
   begin
      wait until rising_edge(clk);
      if reset='1' then outstanding:=(others=>0);
      else
         for i in 0 to 7 loop
            if accepts(i)='1' then outstanding(i):=outstanding(i)+1;accepted(i)<=accepted(i)+1;end if;
            if dones(i)='1' then
               assert outstanding(i)>0 report "Reply without accepted request" severity failure;
               outstanding(i):=outstanding(i)-1;returned(i)<=returned(i)+1;
            end if;
         end loop;
         if cpu9_wok(0)='1' and cpu9_ena='1' then posted_acks<=posted_acks+1;end if;
         if rsrv_req(0)='1' and rsrv_ready='0' then stalls<=stalls+1;end if;
      end if;
      wait for 1 ns;
-- @CHECKS@
      comparisons<=comparisons+1;
      if phase>0 and reset='0' then
         for i in 0 to 11 loop if audit_events(0)(i)='1' then events(i)<=events(i)+1;end if;end loop;
         if audit_events(0)(0)='1' and (audit_events(0)(1)='1' or audit_events(0)(2)='1') then fills_plus_hits<=fills_plus_hits+1;end if;
         if audit_victims(0)(80)='0' and audit_victims(0)(161)='1' then holes<=holes+1;end if;
      end if;
   end process;

   stimulus: process
      variable rng : unsigned(31 downto 0) := to_unsigned(SEED+1,32);
      variable chosen_line, next_word : natural := 0;
      procedure randomize is
      begin rng:=rng xor shift_left(rng,13);rng:=rng xor shift_right(rng,17);rng:=rng xor shift_left(rng,5);end;
      procedure wait_cycles(n : natural) is
      begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
      procedure drain is
      begin
         requests<=(others=>'0');cpu9_ena<='0';cpu7_ena<='0';
         wait_cycles(160);
         assert dbg_rbusy(0)='0' report "Renderer failed to drain" severity failure;
      end;
      procedure read_word(channel, wordaddr : natural) is
      begin
         wait until falling_edge(clk);addresses(channel)<=to_unsigned(wordaddr,17);requests(channel)<='1';
         wait until rising_edge(clk) and accepts(channel)='1';requests(channel)<='0';
         wait until rising_edge(clk) and dones(channel)='1';
         wait until falling_edge(clk);
      end;
      procedure issue_word(channel, wordaddr : natural) is
      begin
         wait until falling_edge(clk);addresses(channel)<=to_unsigned(wordaddr,17);requests(channel)<='1';
         wait until rising_edge(clk) and accepts(channel)='1';requests(channel)<='0';
      end;
      procedure write_word(wordaddr : natural; posted : std_logic) is
         variable ack : boolean;
      begin
         wait until falling_edge(clk);cpu9_addr<=to_unsigned(wordaddr,cpu9_addr'length);
         cpu9_be<="1111";cpu9_din<=std_logic_vector(rng);cpu9_rnw<='0';cpu9_wpost<=posted;cpu9_ena<='1';
         wait until rising_edge(clk);ack:=cpu9_wok(0)='1';
         wait until falling_edge(clk);cpu9_ena<='0';
         if not ack then wait until rising_edge(clk) and cpu9_done(0)='1';end if;
         wait_cycles(18);randomize;
      end;
      procedure traffic(n : natural; paired, arm7 : boolean) is
         variable busy9,busy7,ack9,ack7 : boolean := false;
         variable taken : std_logic_vector(7 downto 0);
      begin
         for step in 0 to n-1 loop
            wait until rising_edge(clk);
            taken:=accepts;
            ack9:=cpu9_done(0)='1' or (cpu9_ena='1' and cpu9_wok(0)='1');
            ack7:=cpu7_done(0)='1';
            if ack9 then busy9:=false;end if;
            if ack7 then busy7:=false;end if;
            wait until falling_edge(clk);
            randomize;
            for ch in 0 to 7 loop
               if requests(ch)='0' or taken(ch)='1' then
                  requests(ch)<='0';
                  if (not paired and rng(ch)='1') or (paired and ch=0) then
                     requests(ch)<='1';
                     if paired then
                        addresses(ch)<=to_unsigned((next_word/128 mod 4)*32768+(next_word mod 128),17);next_word:=next_word+1;
                     else addresses(ch)<=to_unsigned(((to_integer(rng(15 downto 8))+ch*3) mod 12)*2+to_integer(rng(16 downto 16)),17);end if;
                  end if;
               end if;
            end loop;
            cpu9_ena<='0';cpu7_ena<='0';
            if not busy9 and not paired and rng(21 downto 19)="000" then
               cpu9_addr<=to_unsigned((to_integer(rng(7 downto 3)) mod 12)*2,cpu9_addr'length);
               cpu9_rnw<=rng(22);cpu9_be<=std_logic_vector(rng(27 downto 24) or "0001");
               cpu9_din<=std_logic_vector(rng);cpu9_wpost<=rng(23);cpu9_ena<='1';busy9:=true;
            end if;
            if not busy7 and arm7 and rng(29 downto 28)="00" then
               cpu7_addr<=to_unsigned((to_integer(rng(7 downto 3)) mod 12)*2,cpu7_addr'length);
               cpu7_rnw<=rng(30);cpu7_be<="1111";cpu7_din<=not std_logic_vector(rng);cpu7_ena<='1';busy7:=true;
            end if;
         end loop;
         requests<=(others=>'0');
         -- Finish the last CPU pulse and wait for pending ordinary operations.
         wait until rising_edge(clk);
         if cpu9_done(0)='1' or (cpu9_ena='1' and cpu9_wok(0)='1') then busy9:=false;end if;
         if cpu7_done(0)='1' then busy7:=false;end if;
         wait until falling_edge(clk);cpu9_ena<='0';cpu7_ena<='0';
         while busy9 or busy7 loop
            wait until rising_edge(clk);
            if cpu9_done(0)='1' then busy9:=false;end if;
            if cpu7_done(0)='1' then busy7:=false;end if;
         end loop;
         drain;
      end;
   begin
      wait_cycles(3);reset<='0';wait until clr_busy(0)='0';wait_cycles(5);
      phase<=1;vramcnt<=x"838284858484848281";rdr_bg_lcdc<='0';
      wait_cycles(3);
      -- Deliberate MRU/LRU transitions followed by exact-line invalidation.
      for pass in 0 to 7 loop
         read_word(0,0);read_word(0,2);read_word(0,4);read_word(0,0);
         read_word(0,4);read_word(0,2);read_word(0,6);read_word(0,1);
      end loop;
      chosen_line:=to_integer(unsigned(audit_victims(0)(77 downto 64)));
      write_word(chosen_line*2,'0');
      read_word(0,6);read_word(0,8);read_word(0,10);
      chosen_line:=to_integer(unsigned(audit_victims(0)(77 downto 64)));
      write_word(chosen_line*2,'1');
      read_word(0,chosen_line*2);
      -- Three outstanding misses A,B,A: B's fill evicts A into a victim
      -- before the repeated A fill arrives and removes that duplicate.
      extra_delay<=48;
      issue_word(0,40);issue_word(0,42);issue_word(0,40);
      drain;extra_delay<=0;
      phase<=2;traffic(RANDOM_CYCLES,false,false);
      phase<=3;vramcnt<=x"000000000080808080";rdr_bg_lcdc<='1';wait_cycles(5);
      traffic(RANDOM_CYCLES/2,true,false);
      phase<=4;vramcnt<=x"83828485848A828281";rdr_bg_lcdc<='0';wait_cycles(5);
      traffic(RANDOM_CYCLES/2,false,true);
      -- Reconfiguration-style reset while read and CPU work are pending.
      phase<=5;requests<="00110011";cpu9_addr<=to_unsigned(6,cpu9_addr'length);cpu9_rnw<='0';cpu9_wpost<='0';cpu9_ena<='1';
      wait_cycles(1);cpu9_ena<='0';wait_cycles(9);reset<='1';requests<=(others=>'0');
      wait_cycles(3);reset<='0';wait until clr_busy(0)='0';wait_cycles(5);
      phase<=6;vramcnt<=x"838284858484848281";
      read_word(0,0);read_word(0,2);read_word(0,4);read_word(0,0);read_word(0,2);
      traffic(RANDOM_CYCLES/4,false,false);drain;
      assert events(0)>20 and events(1)>10 and events(2)>10 and events(3)>10 report "Insufficient fill/MRU/LRU/direct-hit coverage" severity failure;
      assert events(4)>10 and events(5)>10 report "No paired LCDC coverage" severity failure;
      assert events(6)>0 and holes>0 report "No live invalidation or invalid-hole coverage" severity failure;
      if POSTED then assert events(7)>0 and posted_acks>0 report "No posted invalidation coverage" severity failure;end if;
      assert events(8)>0 and fills_plus_hits>0 report "No write/fill or fill/hit collision coverage" severity failure;
      assert events(9)>0 report "No duplicate-victim fill coverage" severity failure;
      assert backing_reads>100 and cpu_writes>10 and stalls>10 report "Insufficient external traffic" severity failure;
      for ch in 0 to 7 loop assert returned(ch)>20 report "Renderer channel not exercised" severity failure;end loop;
      report "PASS: full VRAM cycles="&integer'image(comparisons)&" fills="&integer'image(events(0))&" mru="&integer'image(events(1))&" lru="&integer'image(events(2))&" direct="&integer'image(events(3))&" joins="&integer'image(events(4))&" paired="&integer'image(events(5))&" live_inv="&integer'image(events(6))&" posted_inv="&integer'image(events(7))&" no_refill="&integer'image(events(8))&" duplicate="&integer'image(events(9))&" fill_hits="&integer'image(fills_plus_hits)&" holes="&integer'image(holes)&" reads="&integer'image(backing_reads)&" writes="&integer'image(cpu_writes)&" posted="&integer'image(posted_acks)&" stalls="&integer'image(stalls) severity note;
      stop;wait;
   end process;
   process begin wait for 50 ms;assert false report "Full VRAM test timeout" severity failure;end process;
end;
