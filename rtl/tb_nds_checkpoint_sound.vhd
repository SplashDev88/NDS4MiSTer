-- Memory keeps running during a pause. Compare actual SPU stereo samples in
-- playback-time order against an uninterrupted, checkpoint-disabled reference.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_sound is
 generic (CHANNELS : positive range 1 to 16 := 16;
          FORMAT : natural range 0 to 3 := 0;
          TABLE_RAM : natural range 0 to 1 := 1;
          LATENCY : positive := 4);
end entity;
architecture test of tb_nds_checkpoint_sound is
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal stop_sound : std_logic := '0';
 signal grant_dut,respond_dut : std_logic := '1';
 signal compare : boolean := false;
 signal regs : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,(others=>'0'),'0');
 type words is array(0 to 1) of std_logic_vector(31 downto 0);
 type samples is array(0 to 1) of std_logic_vector(15 downto 0);
 type counts is array(0 to 1) of natural;
 signal req,own,ena,done,valid,stopped : std_logic_vector(0 to 1) := (others=>'0');
 signal addr,data,readback : words := (others=>(others=>'0'));
 signal left_sample,right_sample,active : samples;
 signal accepted,completed : counts := (others=>0);
 signal sample_count,played_cycles,varied : natural := 0;
 function contents(a : std_logic_vector(31 downto 0)) return std_logic_vector is
  variable v : std_logic_vector(31 downto 0);
  variable word_index,channel : natural;
 begin
  channel := (to_integer(unsigned(a))-16#02020000#)/4096;
  word_index := to_integer(unsigned(a(11 downto 2)));
  if FORMAT=2 and word_index=0 then
   v := x"00140000";
   v(15 downto 0) := std_logic_vector(to_signed(channel*97-1000,16));
  else
   for b in 0 to 3 loop
    v(b*8+7 downto b*8):=std_logic_vector(to_unsigned(((word_index*4+b)*13+channel*17) mod 256,8));
   end loop;
  end if;
  return v;
 end;
begin
 clk<=not clk after 5 ns;
 g_sound: for i in 0 to 1 generate
  signal stop_input,granted : std_logic;
 begin
  stop_input<=stop_sound when i=1 else '0';
  granted<=grant_dut when i=1 else '1';
  sound: entity work.nds_sound
   generic map(is_simu=>'1',ADPCM_TABLE_RAM=>TABLE_RAM,EXPERIMENTAL_CHECKPOINT=>i=1)
   port map(clk=>clk,ce=>'1',reset=>reset,bus7=>regs,
    wired_out7=>readback(i),wired_done7=>open,
    snd_bus_req=>req(i),snd_bus_ok=>granted,snd_bus_own=>own(i),
    mb_ena=>ena(i),mb_adr=>addr(i),mb_din=>data(i),mb_done=>done(i),
    sample_l=>left_sample(i),sample_r=>right_sample(i),sample_valid=>valid(i),
    snd_enable=>open,snd_active=>active(i),
    checkpoint_stop=>stop_input,checkpoint_stopped=>stopped(i));
 end generate;
 memories: for i in 0 to 1 generate
 begin
  process(clk)
   type channel_counts is array(0 to 15) of natural;
   variable fetches : channel_counts := (others=>0);
   variable pending : boolean := false;
   variable delay,channel : natural := 0;
   variable address : std_logic_vector(31 downto 0);
  begin
   if rising_edge(clk) then
    done(i)<='0';
    if reset='1' then
     pending:=false;fetches:=(others=>0);accepted(i)<=0;completed(i)<=0;
    else
     if pending and (i=0 or respond_dut='1') then
      if delay=0 then
       done(i)<='1';data(i)<=contents(address);pending:=false;
       completed(i)<=completed(i)+1;
      else delay:=delay-1;end if;
     end if;
     if ena(i)='1' then
      assert not pending report "overlapping sound read" severity failure;
      assert own(i)='1' report "unowned sound read" severity failure;
      channel:=(to_integer(unsigned(addr(i)))-16#02020000#)/4096;
      assert channel<CHANNELS report "unexpected sound channel" severity failure;
      assert to_integer(unsigned(addr(i)(11 downto 0)))=(fetches(channel) mod 64)*4
       report "sound fetch pointer lost, repeated or skipped across stop" severity failure;
      fetches(channel):=fetches(channel)+1;
      accepted(i)<=accepted(i)+1;pending:=true;delay:=LATENCY-1;address:=addr(i);
     end if;
    end if;
   end if;
  end process;
 end generate;
 monitor: process(clk)
  type stereo_log is array(0 to 1023) of std_logic_vector(31 downto 0);
  variable reference : stereo_log;
  variable rn,dn : natural := 0;
  variable previous : std_logic_vector(31 downto 0) := (others=>'0');
 begin
  if rising_edge(clk) then
   if reset='1' then
    rn:=0;dn:=0;sample_count<=0;played_cycles<=0;varied<=0;previous:=(others=>'0');
   else
    if stop_sound='0' then played_cycles<=played_cycles+1;end if;
    if compare then
     if valid(0)='1' then reference(rn):=left_sample(0)&right_sample(0);rn:=rn+1;end if;
     if valid(1)='1' then
      assert dn<rn report "sound sample cadence advanced during hold" severity failure;
      assert (left_sample(1)&right_sample(1))=reference(dn)
       report "resumed stereo sample differs from uninterrupted playback at "&integer'image(dn)
       severity failure;
      if (left_sample(1)&right_sample(1))/=previous then varied<=varied+1;end if;
      previous:=left_sample(1)&right_sample(1);dn:=dn+1;sample_count<=dn;
     end if;
    end if;
    if stopped(1)='1' then
     assert stop_sound='1' and req(1)='0' and own(1)='0' and ena(1)='0' and valid(1)='0'
      report "stopped sound still publishes work" severity failure;
     assert accepted(1)=completed(1) report "sound acknowledged an outstanding read" severity failure;
    end if;
   end if;
  end if;
 end process;
 stimulus: process
  procedure step(n : positive := 1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 1 ns;end loop;end;
  procedure write_reg(a : natural;v : std_logic_vector(31 downto 0)) is
  begin
   regs.Adr<=std_logic_vector(to_unsigned(a,28));regs.Din<=v;regs.rnw<='0';regs.ena<='1';regs.bEna<="1111";
   wait for 1 ns;
   if stop_sound='1' then assert stopped(1)='0' report "sound acknowledged a live register write" severity failure;end if;
   step;regs.ena<='0';regs.rnw<='1';regs.bEna<="0000";step;
  end;
  procedure hold_sound(duration : positive) is
   variable l,r : std_logic_vector(15 downto 0);
  begin
   stop_sound<='1';
   for k in 1 to LATENCY+120 loop step;exit when stopped(1)='1';end loop;
   assert stopped(1)='1' report "sound failed to drain before deadline" severity failure;
   l:=left_sample(1);r:=right_sample(1);
   for k in 1 to duration loop
    step;
    assert stopped(1)='1' and left_sample(1)=l and right_sample(1)=r and valid(1)='0'
     report "sound playback advanced during hold" severity failure;
   end loop;
   stop_sound<='0';step;
   assert stopped(1)='0' report "sound hold did not cancel" severity failure;
  end;
  procedure await_request is
  begin
   for k in 1 to 10000 loop step;exit when req(1)='1' and own(1)='0';end loop;
   assert req(1)='1' and own(1)='0' report "fixture did not reach sound grant wait" severity failure;
  end;
  type phases is array(natural range <>) of natural;
  constant slots : phases := (0,1,15,16,17,18,511,1022,1023);
  variable control : unsigned(31 downto 0);
 begin
  step(3);reset<='0';stop_sound<='1';step(110);
  assert stopped(1)='1' report "idle sound did not stop after ROM initialization" severity failure;
  write_reg(16#400#,x"8840007F");
  assert active(1)(0)='1' and readback(1)(31)='1'
   report "sound register write was lost while playback stopped" severity failure;
  step(30);assert stopped(1)='1' and req(1)='0' report "channel start escaped sound stop" severity failure;
  reset<='1';stop_sound<='0';step(3);reset<='0';compare<=true;
  write_reg(16#500#,x"0000807F");
  for ch in 0 to CHANNELS-1 loop
   write_reg(16#404#+ch*16,std_logic_vector(to_unsigned(16#02020000#+ch*4096,32)));
   write_reg(16#408#+ch*16,x"0000FE00");write_reg(16#40C#+ch*16,x"00000040");
   control:=unsigned'(x"88000003") or shift_left(to_unsigned(FORMAT,32),29) or
            shift_left(to_unsigned((ch*7+3) mod 128,32),16) or
            shift_left(to_unsigned(ch mod 7,32),24);
   write_reg(16#400#+ch*16,std_logic_vector(control));
  end loop;
  step(3000);
  if FORMAT/=3 then
   grant_dut<='0';await_request;hold_sound(97);grant_dut<='1';
   -- Stop after ownership, before the request pulse: drain the granted word.
   for k in 1 to 10000 loop step;exit when own(1)='1' and ena(1)='0';end loop;
   assert own(1)='1' and ena(1)='0' report "missing granted sound read" severity failure;
   hold_sound(19);
   respond_dut<='0';
   for k in 1 to 10000 loop step;exit when ena(1)='1';end loop;
   assert ena(1)='1' report "missing in-flight sound read" severity failure;
   stop_sound<='1';step(64);
   assert stopped(1)='0' and own(1)='1' report "missing response was discarded during stop" severity failure;
   stop_sound<='0';step(8);respond_dut<='1';step(LATENCY+20);
   -- Completion has arrived, but the fetch pointer write is not committed yet.
   for k in 1 to 10000 loop step;exit when done(1)='1';end loop;
   assert done(1)='1' report "missing sound response edge" severity failure;
   hold_sound(37);
  end if;
  for p in slots'range loop
   step;while played_cycles mod 1024/=slots(p) loop step;end loop;
   hold_sound(23+p*11);
  end loop;
  for k in 0 to 31 loop step(157+(k*31 mod 293));hold_sound(17+(k*43 mod 127));end loop;
  -- More than 512 samples covers a complete 64-word ADPCM loop too.
  for k in 1 to 650000 loop step;exit when sample_count>=600;end loop;
  assert sample_count>=600 and varied>5 report "sound fixture lacked varied resumed samples" severity failure;
  if FORMAT/=3 then assert accepted(1)>CHANNELS*16 report "sound fixture lacked repeated refills" severity failure;end if;
  report "CHECKPOINT_SOUND_STREAM_PASS channels="&integer'image(CHANNELS)&" format="&integer'image(FORMAT)&
   " table="&integer'image(TABLE_RAM)&" latency="&integer'image(LATENCY)&" samples="&integer'image(sample_count)&
   " varied="&integer'image(varied)&" reads="&integer'image(accepted(1));
  hold_sound(23);stop_sound<='1';step(80);reset<='1';step(3);
  assert stopped(1)='0' and req(1)='0' and own(1)='0' and ena(1)='0' and valid(1)='0'
   report "common reset failed to invalidate held sound state" severity failure;
  compare<=false;reset<='0';step(10);
  assert stopped(1)='1' and active(1)=x"0000" report "sound rearmed with stale channel after reset" severity failure;
  stop_sound<='0';step(30);
  assert req(1)='0' and own(1)='0' and ena(1)='0' report "old read escaped common reset" severity failure;
  report "CHECKPOINT_SOUND_PASS";std.env.stop;wait;
 end process;
 process begin wait for 10 ms;assert false report "sound checkpoint test watchdog" severity failure;end process;
end architecture;
