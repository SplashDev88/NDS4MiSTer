-- SPDX-License-Identifier: GPL-3.0-or-later
-- Partial cartridge transfer/erase stop, with independent backing models.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_card is
 generic(OWNER : natural := 0; PREFETCH : positive := 4; LATENCY : positive := 17;
         EXERCISE_STOP : boolean := true);
end;
architecture sim of tb_nds_checkpoint_card is
 constant IDLE_BUS : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal ce,respond,cache_ready : std_logic := '1';
 signal hold,held : std_logic := '0';
 signal master,other_bus,bus9,bus7 : proc_bus_gb_type := IDLE_BUS;
 signal q,q9,q7,rq9,rq7,dbg,rdbg,data : std_logic_vector(31 downto 0);
 signal req,ack,save_we,save_toggle,save_active : std_logic := '0';
 signal addr,raddr : std_logic_vector(28 downto 2);
 signal save_addr,rsave_addr : std_logic_vector(19 downto 0);
 signal save_data,rsave_data : std_logic_vector(7 downto 0);
 signal irqs,dmas,done,rirqs,rdmas,rdone : std_logic_vector(1 downto 0);
 signal rreq,rsave_we,rsave_toggle,rsave_active : std_logic;
 signal requests,returns,writes : natural := 0;
 signal last_write : std_logic_vector(19 downto 0);
 signal check_erase : boolean := false;
 signal erase_base : natural := 16#1200#;
 signal compare : boolean := true;
 function pattern(a : std_logic_vector(28 downto 2)) return std_logic_vector is
 begin return std_logic_vector(resize(unsigned(a),32) xor unsigned'(x"A55A0000"));end;
begin
 clk<=not clk after 5 ns;
 bus9<=master when OWNER=0 else other_bus;bus7<=master when OWNER=1 else other_bus;
 q<=q9 when OWNER=0 else q7;
 dut:entity work.nds_card generic map(CARDSPEED_SHIFT=>2,CARDPREFETCH=>PREFETCH,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>ce,reset=>reset,card7=>std_logic'val(OWNER+2),chipid=>x"12345678",
  bus9=>bus9,wired_out9=>q9,wired_done9=>done(0),bus7=>bus7,wired_out7=>q7,wired_done7=>done(1),
  irq9_xfer=>irqs(0),irq7_xfer=>irqs(1),dma9_card=>dmas(0),dma7_card=>dmas(1),dbg_card=>dbg,
  card_ena=>req,card_addr=>addr,card_din=>data,card_done=>ack,
  backup_addr=>save_addr,backup_write_data=>save_data,backup_write_enable=>save_we,
  backup_read_data=>x"FF",backup_write_toggle=>save_toggle,backup_save_type=>x"5",
  backup_access_active=>save_active,backup_cache_ready=>cache_ready,
  checkpoint_stop=>hold,checkpoint_stopped=>held);
 reference_card:entity work.nds_card_reference generic map(CARDSPEED_SHIFT=>2,CARDPREFETCH=>PREFETCH)
 port map(clk=>clk,ce=>ce,reset=>reset,card7=>std_logic'val(OWNER+2),chipid=>x"12345678",
  bus9=>bus9,wired_out9=>rq9,wired_done9=>rdone(0),bus7=>bus7,wired_out7=>rq7,wired_done7=>rdone(1),
  irq9_xfer=>rirqs(0),irq7_xfer=>rirqs(1),dma9_card=>rdmas(0),dma7_card=>rdmas(1),dbg_card=>rdbg,
  card_ena=>rreq,card_addr=>raddr,card_din=>data,card_done=>ack,
  backup_addr=>rsave_addr,backup_write_data=>rsave_data,backup_write_enable=>rsave_we,
  backup_read_data=>x"FF",backup_write_toggle=>rsave_toggle,backup_save_type=>x"5",
  backup_access_active=>rsave_active,backup_cache_ready=>cache_ready);
 backing:process(clk)
  variable remaining : integer := -1;
  variable saved_addr : std_logic_vector(28 downto 2);
  variable next_erase : natural := 0;
 begin
  if rising_edge(clk) then
   ack<='0';
   if reset='1' then remaining:=-1;requests<=0;returns<=0;writes<=0;next_erase:=0;
   else
    if req='1' then
     assert remaining=-1 report "overlapping card request" severity failure;
     remaining:=LATENCY;saved_addr:=addr;requests<=requests+1;
    elsif remaining=0 and respond='1' then
     data<=pattern(saved_addr);ack<='1';returns<=returns+1;remaining:=-1;
    elsif remaining>0 then remaining:=remaining-1;end if;
    if save_we='1' then
     assert cache_ready='1' report "save write without backing ownership" severity failure;
     writes<=writes+1;last_write<=save_addr;
     if check_erase then
      assert to_integer(unsigned(save_addr))=erase_base+next_erase and save_data=x"FF"
       report "erase skipped/duplicated address or data" severity failure;
      next_erase:=next_erase+1;
     end if;
    end if;
   end if;
  end if;
 end process;
 monitor:process
 begin
  wait until clk'event;wait for 1 ns;
  if compare then
   assert q9=rq9 and q7=rq7 and done=rdone and dbg=rdbg and irqs=rirqs and dmas=rdmas and
    req=rreq and addr=raddr and save_addr=rsave_addr and save_data=rsave_data and
    save_we=rsave_we and save_toggle=rsave_toggle and save_active=rsave_active
    report "unrequested card checkpoint changed baseline behavior" severity failure;
  end if;
  if held='1' then
   assert reset='0' and hold='1' and requests=returns and req='0' and ack='0' and
    save_we='0' and irqs="00" and dmas="00" and master.ena='0' and other_bus.ena='0'
    report "card acknowledged outstanding work" severity failure;
  end if;
 end process;
 no_admissions:process
  variable stopped_edge,quiet_bus : boolean;
 begin
  wait until rising_edge(clk);stopped_edge:=hold='1';quiet_bus:=master.ena='0' and other_bus.ena='0';
  wait for 1 ns;
  if stopped_edge and reset='0' then
   assert req='0' report "card issued prefetch while stopped" severity failure;
   if quiet_bus then assert save_we='0' report "card issued erase byte while stopped" severity failure;end if;
  end if;
 end process;
 stimulus:process
 alias pacing is << signal .tb_nds_checkpoint_card.dut.delay_cnt : unsigned(19 downto 0) >>;
 alias erase_left is << signal .tb_nds_checkpoint_card.dut.erase_remaining : unsigned(16 downto 0) >>;
  variable popped,total,before_requests,before_writes : natural;
  variable frozen_dbg : std_logic_vector(31 downto 0);
  variable frozen_pacing : unsigned(19 downto 0);
  variable frozen_erase : unsigned(16 downto 0);
  variable frozen_save : std_logic_vector(19 downto 0);
  procedure step(n : positive := 1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;end loop;end;
  procedure write_reg(a:std_logic_vector(27 downto 0);d:std_logic_vector(31 downto 0);be:std_logic_vector(3 downto 0):="1111") is
  begin
   master.Adr<=a;master.Din<=d;master.bEna<=be;master.rnw<='0';master.ena<='1';
   wait for 1 ns;assert held='0' report "card register admission falsely held" severity failure;
   step;master.ena<='0';master.rnw<='1';wait for 1 ns;
  end;
  procedure wait_held is
  begin
   for k in 1 to LATENCY+800 loop exit when held='1';step;end loop;
   assert held='1' report "card accepted work did not drain" severity failure;
  end;
  procedure freeze is
   variable held_requests,held_writes : natural;
  begin
   if EXERCISE_STOP then
    compare<=false;hold<='1';wait_held;
    frozen_dbg:=dbg;frozen_pacing:=pacing;frozen_erase:=erase_left;frozen_save:=save_addr;
    held_requests:=requests;held_writes:=writes;
    step(43);
    assert held='1' and dbg=frozen_dbg and pacing=frozen_pacing and erase_left=frozen_erase and
     save_addr=frozen_save and requests=held_requests and writes=held_writes
     report "held card pacing/prefetch/erase changed" severity failure;
   end if;
  end;
  procedure release_hold is begin hold<='0';step;end;
  procedure wait_ready is
  begin
   for k in 1 to LATENCY+200 loop exit when dbg(27)='1';step;end loop;
   assert dbg(27)='1' report "card did not publish next word" severity failure;
  end;
  procedure pop_word is
  begin
   wait_ready;master.Adr<=x"0100010";master.rnw<='1';master.ena<='1';wait for 1 ns;
   assert q=pattern(std_logic_vector(to_unsigned(16#2000#+popped,27)))
    report "resumed card word skipped/duplicated/corrupted" severity failure;
   step;master.ena<='0';popped:=popped+1;wait for 1 ns;
  end;
  procedure start_block(empty : boolean:=false) is
  begin
   popped:=0;write_reg(x"00001A0",x"0000C000","0010");
   write_reg(x"00001A8",x"800000B7");write_reg(x"00001AC",x"00000000");
   if empty then write_reg(x"00001A4",x"80000000");else write_reg(x"00001A4",x"81000000");end if;
  end;
  procedure byte_tx(v:std_logic_vector(7 downto 0);cs:std_logic:='1';wait_done:boolean:=true) is
   variable cnt:std_logic_vector(31 downto 0):=x"0000A000";
  begin
   cnt(6):=cs;write_reg(x"00001A0",cnt,"0011");write_reg(x"00001A0",x"00"&v&x"0000","0100");
   if wait_done then
    for k in 1 to 600 loop exit when q(7)='0';step;end loop;
    assert q(7)='0' report "backup byte failed to drain" severity failure;
   end if;
  end;
 begin
  step(4);reset<='0';step(2);
  for phase in 0 to 5 loop
   total:=128;
   if phase=0 then freeze;end if;
   start_block(phase=5);
   if phase=0 then
    if EXERCISE_STOP then wait_held;assert dbg(31 downto 29)="001" report "held register start was lost" severity failure;end if;
    release_hold;
   else
    if phase=4 then pop_word;end if;
    for k in 1 to LATENCY+200 loop exit when to_integer(unsigned(dbg(31 downto 29)))=phase;step;end loop;
    assert to_integer(unsigned(dbg(31 downto 29)))=phase report "target card phase not reached" severity failure;
    freeze;
    if phase=3 and EXERCISE_STOP then
     -- A read admitted during acquisition must still retire exactly once.
     pop_word;wait_held;
    end if;
    release_hold;
   end if;
   if phase=5 then total:=0;end if;
   for k in popped to total-1 loop pop_word;end loop;
   step(5);assert dbg(28 downto 27)="00" report "card block did not finish after release" severity failure;
  end loop;
  if EXERCISE_STOP then
   -- Withheld response blocks acknowledgement; cancel preserves its owner.
   respond<='0';start_block;
   for k in 1 to 100 loop exit when req='1';step;end loop;
   hold<='1';step(LATENCY+10);assert held='0' report "missing card response acknowledged" severity failure;
   hold<='0';step(10);assert requests=returns+1 report "cancel discarded card ownership" severity failure;
   hold<='1';respond<='1';wait_held;release_hold;
   for k in 0 to 127 loop pop_word;end loop;step(4);
  end if;
  -- Write/program with CS held; checkpoint must retain command/address/WEL.
  byte_tx(x"06",'0');byte_tx(x"0A");byte_tx(x"00");byte_tx(x"01");byte_tx(x"FE");
  before_writes:=writes;byte_tx(x"5A",'1',false);freeze;release_hold;
  step(70);assert writes=before_writes+1 and last_write=x"001FE" report "accepted backup program lost" severity failure;
  byte_tx(x"A6",'0');assert last_write=x"001FF" report "program command/address not retained" severity failure;
  -- Pause an erase mid-page; accepted byte commits, remaining bytes wait.
  byte_tx(x"06",'0');byte_tx(x"DB");byte_tx(x"00");byte_tx(x"12");
  check_erase<=true;before_writes:=writes;byte_tx(x"00",'0',false);step(7);
  freeze;
  if EXERCISE_STOP then
   cache_ready<='0';step(9);assert held='0' report "backing-cache miss falsely acknowledged" severity failure;
   cache_ready<='1';wait_held;
  end if;
  release_hold;step(300);
  assert writes=before_writes+256 and erase_left=0 report "erase resume byte count mismatch" severity failure;
  check_erase<=false;
  if EXERCISE_STOP then
   freeze;reset<='1';step(3);assert held='0' report "reset retained card hold" severity failure;
   hold<='0';reset<='0';step(3);
  end if;
  report "CHECKPOINT_CARD_PASS owner="&integer'image(OWNER)&" prefetch="&integer'image(PREFETCH)&" latency="&integer'image(LATENCY)&" stop="&boolean'image(EXERCISE_STOP);
  stop;wait;
 end process;
 process begin wait for 10 ms;assert false report "card checkpoint watchdog" severity failure;end process;
end;
