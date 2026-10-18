-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored sample memory, fresh-process SPU restore, exact enabled fetches and
-- stereo/IO continuation. This is component persistence, not a game state.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_sound_rotation is
 generic(ROTATING:boolean:=false;RESTORING:boolean:=false;TABLE_RAM:natural range 0 to 1:=1;
         SCENARIO:natural range 0 to 4:=0;SLOT:natural range 0 to 1023:=17;
         LATENCY:positive:=4;WRITE_GAPS:natural range 0 to 1:=0);
end;
architecture sim of tb_nds_checkpoint_sound_rotation is
 constant N:positive:=270;
 signal clk:std_logic:='0';signal reset:std_logic:='1';
 signal regs:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
 signal hold,stopped,restore,wr,valid,wr_ready,ready,error,release_ready:std_logic:='0';
 signal address,sound_address:unsigned(8 downto 0):=(others=>'0');
 signal sound_hold,return_permission:std_logic;
 signal allow_scan:std_logic:='1';
 signal image_data,write_data,readback:std_logic_vector(31 downto 0):=(others=>'0');
 signal req,own,ena,done,grant,sample_valid,enabled:std_logic:='0';
 signal mem_address,mem_data:std_logic_vector(31 downto 0):=(others=>'0');
 signal left_sample,right_sample,active:std_logic_vector(15 downto 0);
 signal pending:std_logic:='0';signal fetched,sampled,varied:natural:=0;
 function contents(a:std_logic_vector(31 downto 0)) return std_logic_vector is
  variable v:std_logic_vector(31 downto 0);variable c,w,f:natural;
 begin
  c:=(to_integer(unsigned(a))-16#02020000#)/4096;w:=to_integer(unsigned(a(11 downto 2)));
  f:=c mod 4;if SCENARIO=1 then f:=2;elsif SCENARIO=2 then f:=0;end if;
  if f=2 and w=0 then
   v:=x"00140000";v(15 downto 0):=std_logic_vector(to_signed(c*97-1000,16));
  elsif SCENARIO=2 then v:=x"7F7F7F7F";
  else
   for b in 0 to 3 loop v(b*8+7 downto b*8):=std_logic_vector(to_unsigned(((w*4+b)*13+c*17) mod 256,8));end loop;
  end if;
  return v;
 end;
begin
 clk<=not clk after 5 ns;
 scan_guard:if ROTATING generate
  guard:entity work.nds_checkpoint_audio_scan_guard
   port map(capture_request=>hold,capture_held=>hold and stopped and allow_scan,
    restore_active=>restore and reset,channel_order_ready=>release_ready,outer_return_permission=>'1',
    requested_address=>address,device_hold=>sound_hold,return_permission=>return_permission,sound_address=>sound_address);
 end generate;
 no_scan:if not ROTATING generate sound_hold<=hold;sound_address<=address;return_permission<='1';end generate;
 dut:entity work.nds_sound generic map(is_simu=>'1',ADPCM_TABLE_RAM=>TABLE_RAM,EXPERIMENTAL_CHECKPOINT=>true)
  port map(clk=>clk,ce=>'1',reset=>reset,bus7=>regs,wired_out7=>readback,wired_done7=>open,
   snd_bus_req=>req,snd_bus_ok=>grant,snd_bus_own=>own,mb_ena=>ena,mb_adr=>mem_address,mb_din=>mem_data,mb_done=>done,
   sample_l=>left_sample,sample_r=>right_sample,sample_valid=>sample_valid,snd_enable=>enabled,snd_active=>active,
   checkpoint_stop=>sound_hold,checkpoint_stopped=>stopped,checkpoint_address=>sound_address,checkpoint_data=>image_data,
   checkpoint_valid=>valid,checkpoint_restore=>restore,checkpoint_write=>wr,checkpoint_write_data=>write_data,
   checkpoint_write_ready=>wr_ready,checkpoint_restore_ready=>ready,checkpoint_restore_error=>error,checkpoint_release_ready=>release_ready);
 memory:process(clk)
  variable busy:boolean:=false;variable delay:natural:=0;
  variable a:std_logic_vector(31 downto 0);variable previous:std_logic_vector(31 downto 0):=(others=>'0');
 begin
  if rising_edge(clk) then
   done<='0';
   if reset='1' then
    assert not busy report "SPU reset discarded accepted memory request" severity failure;
    fetched<=0;sampled<=0;varied<=0;previous:=(others=>'0');
   else
    if busy then
     if delay=0 then done<='1';mem_data<=contents(a);busy:=false;
     else delay:=delay-1;end if;
    end if;
    if ena='1' then
     assert not busy and own='1' report "SPU overlapping/unowned request" severity failure;
     assert unsigned(mem_address)>=16#02020000# and unsigned(mem_address)<16#02030000# and mem_address(1 downto 0)="00"
      and unsigned(mem_address(11 downto 2))<8 report "SPU fetch outside authored sample memory" severity failure;
     busy:=true;a:=mem_address;delay:=LATENCY-1+to_integer(unsigned(a(3 downto 2)));fetched<=fetched+1;
    end if;
    if sample_valid='1' then
     sampled<=sampled+1;if (left_sample&right_sample)/=previous then varied<=varied+1;end if;
     previous:=left_sample&right_sample;
    end if;
   end if;
   if busy then pending<='1';else pending<='0';end if;
   if stopped='1' then
    assert not busy and req='0' and own='0' and ena='0' and sample_valid='0' report "SPU acknowledged live work" severity failure;
   end if;
   if restore='1' and reset='1' then
    assert req='0' and own='0' and ena='0' and sample_valid='0' report "SPU executed partial restore" severity failure;
   end if;
  end if;
 end process;
 stimulus:process
  type words is array(0 to N-1) of std_logic_vector(31 downto 0);
  variable state:words;
  file sf,tf,pf:text;variable l:line;
  variable observed,expected:std_logic_vector(127 downto 0);
  variable ctl:unsigned(31 downto 0);variable f,idx,fetch_start,sample_start:natural;
  procedure step(n:positive:=1) is begin for k in 1 to n loop wait until rising_edge(clk);wait for 1 ns;end loop;end;
  procedure reg(a:natural;v:std_logic_vector(31 downto 0)) is
  begin regs.Adr<=std_logic_vector(to_unsigned(a,28));regs.Din<=v;regs.rnw<='0';regs.ena<='1';step;regs.ena<='0';regs.rnw<='1';step;end;
  procedure select_word(a:natural) is
  begin
   address<=to_unsigned(a,9);wait for 1 ns;
   for k in 1 to 20 loop exit when valid='1' or (restore='1' and wr_ready='1');step;end loop;
  end;
  procedure load_word(a:natural;v:std_logic_vector(31 downto 0)) is
  begin
   select_word(a);assert wr_ready='1' report "SPU restore word never writable" severity failure;
   write_data<=v;wr<='1';step;wr<='0';
   if WRITE_GAPS=0 then step;else step(3+a mod 7);end if;
  end;
  procedure load_image is
   variable a:natural;
  begin
   for i in 0 to N-1 loop
    a:=i; -- exact ascending stream; vary idle gaps, not coverage order
    load_word(a,state(a));
    assert error='0' report "SPU rejected image word "&integer'image(a)&" value "&to_hstring(state(a)) severity failure;
    if i<N-1 then assert ready='0' report "SPU incomplete image accepted" severity failure;end if;
   end loop;
   step(4);assert ready='1' and error='0' report "SPU complete image rejected" severity failure;
  end;
  procedure read_image(compare:boolean) is
   variable a:natural;
  begin
   for i in 0 to N-1 loop
    a:=(i*17) mod N; -- permute every word, including backward channel changes
    select_word(a);assert valid='1' report "SPU image word unavailable" severity failure;
    if compare then assert image_data=state(a) report "SPU restored word differs at "&integer'image(a) severity failure;
    else state(a):=image_data;end if;
   end loop;
  end;
  procedure exercise_rotation_cancel is
  begin
   if ROTATING then
    allow_scan<='0';address<=to_unsigned(244,9);step(20);
    assert release_ready='1' report "SPU rotated before common acquisition" severity failure;
    address<=to_unsigned(256,9);allow_scan<='1';step;
    for owner_loss in 0 to 1 loop
    for c in 1 to 15 loop
     select_word(256);assert release_ready='1' report "SPU initial rotation order not restored" severity failure;
     -- Interrupt at every ring position, including an unfinished rotation.
     address<=to_unsigned(244,9);step(c);
     assert release_ready='0' report "SPU early rotation release" severity failure;
     if owner_loss=0 then hold<='0';else allow_scan<='0';end if;wait for 1 ns;
     assert release_ready='0' report "SPU cancellation skipped rotation unwind" severity failure;
     for k in 1 to 20 loop
      exit when release_ready='1';
      assert sound_hold='1' and return_permission='0' report "SPU scan guard released owners early" severity failure;
      assert sample_valid='0' and req='0' and own='0' and ena='0' report "SPU advanced before rotation unwind" severity failure;
      step;
     end loop;
     assert release_ready='1' report "SPU rotation cancellation did not drain" severity failure;
     -- Rehold before the next edge: no guest cycle is allowed before the
     -- release-ready fence, and this fixture does not execute that guest edge.
     address<=to_unsigned(256,9);hold<='1';allow_scan<='1';step(3);
     read_image(true);
    end loop;
    end loop;
   end if;
  end;
  procedure new_attempt is
  begin restore<='0';step;restore<='1';step(2);assert ready='0' and error='0' report "SPU stale restore coverage/error" severity failure;end;
  procedure bad_word(a:natural;v:std_logic_vector(31 downto 0)) is
  begin
   new_attempt;
   if a<N then for i in 0 to a-1 loop load_word(i,state(i));end loop;end if;
   address<=to_unsigned(a,9);write_data<=v;step(2);wr<='1';step;wr<='0';step;
   assert ready='0' and error='1' report "SPU invalid image accepted" severity failure;
   address<=to_unsigned(0,9);write_data<=state(0);wr<='1';step;wr<='0';step;
   assert ready='0' and error='1' report "SPU error not sticky" severity failure;
  end;
 begin
  hold<='1';step(4);reset<='0';step(110);grant<='1';
  assert stopped='1' report "SPU failed initial hold" severity failure;
  if RESTORING then
   file_open(sf,"sound.state",read_mode);
   for a in 0 to N-1 loop readline(sf,l);hread(l,state(a));end loop;file_close(sf);
   reset<='1';restore<='1';step(3);
   bad_word(270,x"00000000");bad_word(511,x"00000000");bad_word(8,x"00590000");bad_word(9,x"007F0000");
   bad_word(1,x"80000000");bad_word(14,x"00000001");bad_word(263,x"00000400");bad_word(269,x"00800000");
   -- Switching a RAM channel and writing on the same edge is not a valid
   -- registered-port transaction. Reject rather than use stale read data.
   new_attempt;for a in 0 to 27 loop load_word(a,state(a));end loop;
   address<=to_unsigned(12,9);step(2);address<=to_unsigned(28,9);write_data<=state(28);wr<='1';step;wr<='0';step;
   assert error='1' and ready='0' report "SPU stale RAM port accepted" severity failure;
   -- Strict stream coverage: rejected duplicates/skips/reordering must
   -- not be treated as progress, even when data and masks are otherwise valid.
   for kind in 0 to 3 loop
    new_attempt;
    if kind=0 then idx:=1;
    elsif kind=1 then load_word(0,state(0));idx:=0;
    elsif kind=2 then for a in 0 to 10 loop load_word(a,state(a));end loop;idx:=12;
    else load_image;idx:=269;end if;
    address<=to_unsigned(idx,9);write_data<=state(idx);step(2);wr<='1';step;wr<='0';step;
    assert error='1' and ready='0' report "SPU invalid restore order accepted" severity failure;
   end loop;
   new_attempt;load_image;read_image(true);
   -- Normal register writes and live memory response inputs cannot change a
   -- reset-held image. Retain silence, flags and decoded pipeline on gaps.
   regs.Adr<=x"0000400";regs.Din<=x"FFFFFFFF";regs.ena<='1';regs.rnw<='0';step(7);regs.ena<='0';regs.rnw<='1';read_image(true);
   restore<='0';reset<='0';step(3);read_image(true);
   -- Reject live writes to every image word without modifying live state.
   for a in 0 to N-1 loop
    restore<='0';step;address<=to_unsigned(a,9);write_data<=state(a);
    if a=0 then write_data<=state(a) xor x"00000001";end if;
    restore<='1';wr<='1';step;wr<='0';step;
    assert error='1' and ready='0' report "SPU live restore accepted" severity failure;
   end loop;
   restore<='0';step(2);read_image(true);
   -- Repeat from a fresh coverage attempt after live poisoning.
   reset<='1';restore<='1';step;load_image;read_image(true);
   restore<='0';reset<='0';step(3);
  else
   if SCENARIO/=4 then
    reg(16#500#,x"0000807F");reg(16#508#,x"00005AA5");
    reg(16#510#,x"02030000");reg(16#514#,x"00001234");reg(16#518#,x"02040000");reg(16#51C#,x"00005678");
    for c in 0 to 15 loop
     f:=c mod 4;if SCENARIO=1 then f:=2;elsif SCENARIO=2 then f:=0;end if;
     reg(16#404#+c*16,std_logic_vector(to_unsigned(16#02020000#+c*4096,32)));
     if SCENARIO=1 then ctl:=x"0000FFF8";else ctl:=x"0000FF80";end if;
     if f=2 then ctl(16):='1';end if; -- ADPCM loops after the header word.
     reg(16#408#+c*16,std_logic_vector(ctl));
     if f=2 then reg(16#40C#+c*16,x"00000007");else reg(16#40C#+c*16,x"00000008");end if;
     ctl:=unsigned'(x"88000003") or shift_left(to_unsigned(f,32),29) or shift_left(to_unsigned((c*7+3) mod 128,32),16) or shift_left(to_unsigned(c mod 7,32),24);
     if c mod 2=1 then ctl(15):='1';end if;
     if SCENARIO=2 then ctl(6 downto 0):=(others=>'1');ctl(22 downto 16):=(others=>'0');end if;
     reg(16#400#+c*16,std_logic_vector(ctl));
    end loop;
   end if;
   if SCENARIO/=3 then
    hold<='0';step(20000);hold<='1';
    for k in 1 to 200 loop step;exit when stopped='1';end loop;
    assert stopped='1' report "SPU prephase drain timed out" severity failure;
    address<=to_unsigned(263,9);wait for 1 ns;idx:=to_integer(unsigned(image_data(9 downto 0)));
    hold<='0';step((SLOT+1024-idx) mod 1024+1024);hold<='1';
    for k in 1 to LATENCY+100 loop step;exit when stopped='1';end loop;
    assert stopped='1' report "SPU capture drain timed out" severity failure;
   end if;
   step(3);read_image(false);
   if SCENARIO=2 then assert left_sample=x"7FFF" and right_sample=x"0000" report "SPU independent saturation/pan check failed" severity failure;end if;
   if SCENARIO/=3 then assert to_integer(unsigned(state(263)))=SLOT report "SPU fixture missed mixer phase" severity failure;end if;
   if SCENARIO=0 or SCENARIO=1 then assert varied>2 and fetched>100 report "SPU fixture failed to exercise samples/fetches" severity failure;end if;
   file_open(sf,"sound.state",write_mode);for a in 0 to N-1 loop hwrite(l,state(a));writeline(sf,l);end loop;file_close(sf);
  end if;
  read_image(true);
  exercise_rotation_cancel;
  -- One resumed edge consumes the saved ADPCM ROM result. Check the whole
  -- held image again so a missing pipeline word cannot hide behind a channel
  -- whose timer happens not to decode before its next lookup refresh.
  hold<='0';step;hold<='1';
  for k in 1 to LATENCY+100 loop step;exit when stopped='1';end loop;
  assert stopped='1' report "SPU first resumed edge failed to drain" severity failure;
  step(2);
  if RESTORING then file_open(pf,"sound-first-step.state",read_mode);else file_open(pf,"sound-first-step.state",write_mode);end if;
  for a in 0 to N-1 loop
   select_word(a);assert valid='1' report "SPU first-step state unavailable" severity failure;
   if RESTORING then readline(pf,l);hread(l,ctl);assert image_data=std_logic_vector(ctl)
    report "SPU first resumed state differs at "&integer'image(a) severity failure;
   else hwrite(l,image_data);writeline(pf,l);end if;
  end loop;
  file_close(pf);
  address<=to_unsigned(511,9);wait for 1 ns;assert valid='0' and image_data=x"00000000" report "SPU undefined address exposed state" severity failure;
  -- Unsettled guest writes must suppress capture immediately.
  regs.ena<='1';address<=to_unsigned(0,9);wait for 1 ns;assert valid='0' report "SPU captured live register access" severity failure;regs.ena<='0';
  regs.Adr<=x"0000500";regs.rnw<='1';step(3);
  if RESTORING then file_open(tf,"sound.trace",read_mode);else file_open(tf,"sound.trace",write_mode);end if;
  fetch_start:=fetched;sample_start:=sampled;hold<='0';
  for k in 0 to 65535 loop
   if k mod 43<5 then grant<='0';else grant<='1';end if;
   if k mod 1024=300 then regs.Adr<=std_logic_vector(to_unsigned(16#400#+((k/1024) mod 16)*16,28));
   elsif k mod 1024=301 then regs.Adr<=x"0000500";end if;
   -- Change master settings after several samples to check the resumed latch
   -- pipeline as well as static output. Both runs receive identical inputs.
   if k=8208 or k=16400 then regs.Adr<=x"0000500";regs.Din<=x"0000804F";regs.rnw<='0';regs.ena<='1';
   else regs.rnw<='1';regs.ena<='0';end if;
   step;
   observed:=(others=>'0');observed(31 downto 0):=right_sample&left_sample;observed(63 downto 32):=readback;
   if ena='1' then observed(95 downto 64):=mem_address;end if;
   observed(111 downto 96):=active;observed(118 downto 112):=enabled&sample_valid&done&ena&own&req&stopped;
   if RESTORING then readline(tf,l);hread(l,expected);assert observed=expected report "SPU continuation differs at "&integer'image(k)&" got "&to_hstring(observed)&" expected "&to_hstring(expected) severity failure;
   else hwrite(l,observed);writeline(tf,l);end if;
  end loop;
  file_close(tf);hold<='1';for k in 1 to LATENCY+100 loop step;exit when stopped='1';end loop;
  assert stopped='1' and pending='0' report "SPU final drain failed" severity failure;
  assert sampled-sample_start>=63 report "SPU continuation missed stereo samples" severity failure;
  if SCENARIO/=4 then assert fetched-fetch_start>100 report "SPU continuation missed sample fetches" severity failure;end if;
  report "CHECKPOINT_SOUND_RESTORE_PASS restoring="&boolean'image(RESTORING)&" scenario="&integer'image(SCENARIO)&" table="&integer'image(TABLE_RAM)&" slot="&integer'image(SLOT)&" samples="&integer'image(sampled-sample_start)&" fetches="&integer'image(fetched-fetch_start);
  std.env.stop;wait;
 end process;
end;
