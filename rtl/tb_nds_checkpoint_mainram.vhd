-- Real main-RAM owner, independent SDRAM contents/response scoreboard.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_nds_checkpoint_mainram is
 generic (MEM_RATIO : positive range 1 to 3 := 3;
          PHASE_NS : natural := 0; LATENCY : positive := 4;
          PRIORITY7 : boolean := false);
end entity;
architecture test of tb_nds_checkpoint_mainram is
 signal clk1x,clkMem : std_logic := '0';
 signal phase_index : natural range 0 to MEM_RATIO-1 := MEM_RATIO-1;
 signal index : unsigned(1 downto 0);
 signal reset : std_logic := '1';
 signal allowed,respond32,respond64 : std_logic := '1';
 signal idle,active,busy,sd_ena,sd_rnw,sd32,sd64 : std_logic;
 type addresses is array(0 to 1) of std_logic_vector(21 downto 2);
 type words is array(0 to 1) of std_logic_vector(31 downto 0);
 type masks is array(0 to 1) of std_logic_vector(3 downto 0);
 signal req,locked,done,rnw : std_logic_vector(0 to 1) := (others=>'0');
 signal addr : addresses := (others=>(others=>'0'));
 signal din,dout : words := (others=>(others=>'0'));
 signal be : masks := (others=>"1111");
 signal pair9 : std_logic := '0';
 signal high9,sd_data,sd_high,sd_write : std_logic_vector(31 downto 0) := (others=>'0');
 signal sd_addr : std_logic_vector(26 downto 0);
 signal sd_be : std_logic_vector(3 downto 0);
 signal priority : std_logic;
 signal physical_pending : boolean := false;
 signal physical_writes,physical_reads,guest_completions : natural := 0;
 function pattern(a : natural) return std_logic_vector is
 begin return std_logic_vector(to_unsigned(16#13500000#+a*257,32));end;
begin
 clk1x<=not clk1x after 30 ns;
 process begin wait for PHASE_NS*1 ns;loop wait for 30 ns/MEM_RATIO;clkMem<=not clkMem;end loop;end process;
 index<=to_unsigned(phase_index,2);
 process(clkMem) begin if rising_edge(clkMem) then phase_index<=(phase_index+1) mod MEM_RATIO;end if;end process;
 priority<='1' when PRIORITY7 else '0';
 ram: entity work.nds_mainram generic map(Softmap_NDS_MAINRAM_ADDR=>0)
  port map(clk1x=>clk1x,clkMem=>clkMem,clkMemIndex=>index,reset=>reset,arm7_priority=>priority,
   mem9_ena=>req(0),mem9_lock=>locked(0),mem9_rnw=>rnw(0),mem9_addr=>addr(0),mem9_be=>be(0),mem9_writedata=>din(0),
   mem9_pair=>pair9,mem9_done=>done(0),mem9_readdata=>dout(0),mem9_readdata_hi=>high9,
   mem7_ena=>req(1),mem7_lock=>locked(1),mem7_rnw=>rnw(1),mem7_addr=>addr(1),mem7_be=>be(1),mem7_writedata=>din(1),
   mem7_done=>done(1),mem7_readdata=>dout(1),mainram_allow=>allowed,mainram_active=>active,mainram_busy=>busy,
   mr_sdram_ena=>sd_ena,mr_sdram_rnw=>sd_rnw,mr_sdram_Adr=>sd_addr,mr_sdram_Din=>sd_write,mr_sdram_be=>sd_be,
   sdram_Dout=>sd_data,sdram_Dout_hi=>sd_high,sdram_done32=>sd32,sdram_done64=>sd64,checkpoint_idle=>idle);
 backing: process(clkMem)
  type memory_t is array(0 to 255) of std_logic_vector(31 downto 0);
  function init return memory_t is variable v : memory_t;
  begin for k in v'range loop v(k):=pattern(k);end loop;return v;end;
  variable memory : memory_t := init;
  variable pending,low_returned : boolean := false;
  variable delay,tail,a : natural := 0;
  variable rd : std_logic;
  variable value : std_logic_vector(31 downto 0);
  variable mask : std_logic_vector(3 downto 0);
 begin
  if rising_edge(clkMem) then
   sd32<='0';sd64<='0';
   if pending then
    if not low_returned then
     if delay>0 then delay:=delay-1;
     elsif respond32='1' then
      if rd='0' then
       for b in 0 to 3 loop if mask(b)='1' then memory(a)(b*8+7 downto b*8):=value(b*8+7 downto b*8);end if;end loop;
       physical_writes<=physical_writes+1;
      else physical_reads<=physical_reads+1;end if;
      sd_data<=memory(a);sd32<='1';low_returned:=true;tail:=1;
     end if;
    elsif tail>0 then tail:=tail-1;
    elsif respond64='1' then
     sd_high<=memory((a+1) mod 256);sd64<='1';pending:=false;
    end if;
   end if;
   if sd_ena='1' then
    assert not pending report "overlapping SDRAM operations" severity failure;
    pending:=true;low_returned:=false;delay:=LATENCY-1;
    a:=to_integer(unsigned(sd_addr(9 downto 2)));rd:=sd_rnw;value:=sd_write;mask:=sd_be;
   end if;
   physical_pending<=pending;
  end if;
 end process;
 monitor: process(clk1x)
  type counts is array(0 to 1) of natural;
  variable owed : counts := (others=>0);
  variable n : natural;
 begin
  if rising_edge(clk1x) then
   if reset='1' then owed:=(others=>0);
   else
    n:=0;
    for c in 0 to 1 loop
     if req(c)='1' then owed(c):=owed(c)+1;end if;
     if done(c)='1' then
      assert owed(c)=1 report "main-RAM completion lost its owner" severity failure;
      owed(c):=owed(c)-1;n:=n+1;
     end if;
    end loop;
    guest_completions<=guest_completions+n;
    if idle='1' then
     assert owed(0)=0 and owed(1)=0 and not physical_pending and
      active='0' and busy='0' and sd_ena='0' and done="00"
      report "main-RAM idle preceded transaction/response retirement" severity failure;
    end if;
   end if;
  end if;
 end process;
 stimulus: process
  procedure step(n : positive := 1) is
  begin for k in 1 to n loop wait until rising_edge(clk1x);wait for 1 ns;end loop;end;
  procedure wait_idle is
  begin
   for k in 1 to 100 loop step;exit when idle='1';end loop;
   assert idle='1' report "main-RAM idle never qualified after drain" severity failure;
  end;
  procedure send(c,a : natural;rd : std_logic;value : std_logic_vector(31 downto 0);lock : std_logic := '0';pair : std_logic := '0') is
  begin
   addr(c)<=std_logic_vector(to_unsigned(a,20));rnw(c)<=rd;din(c)<=value;locked(c)<=lock;
   if c=0 then pair9<=pair;end if;
   req(c)<='1';wait for 1 ns;
   assert idle='0' report "fresh main-RAM admission retained stale idle" severity failure;
   step;req(c)<='0';
  end;
  procedure finish(c : natural;expected : std_logic_vector(31 downto 0);rd : boolean := true) is
  begin
   for k in 1 to 100 loop step;exit when done(c)='1';end loop;
   assert done(c)='1' report "main-RAM guest timed out" severity failure;
   if rd then assert dout(c)=expected report "main-RAM read data corrupted" severity failure;end if;
   assert idle='0' report "main-RAM idle overlapped guest completion" severity failure;
   step;
  end;
  variable before : natural;
 begin
  step(4);assert idle='0' severity failure;reset<='0';wait_idle;
  -- Allow backpressure: accepted guest work must prevent idle before issue.
  allowed<='0';send(0,4,'1',x"00000000");step(20);
  assert idle='0' and active='1' and sd_ena='0' report "queued request falsely idle" severity failure;
  allowed<='1';finish(0,pattern(4));wait_idle;
  for c in 0 to 1 loop
   send(c,16+c,'0',x"DEADBEEF");finish(c,x"00000000",false);wait_idle;
   send(c,16+c,'1',x"00000000");finish(c,x"DEADBEEF");wait_idle;
  end loop;
  -- Low half alone is not a pair response. Release the delayed upper half.
  respond64<='0';send(0,32,'1',x"00000000",'0','1');step(40);
  assert idle='0' and done(0)='0' and physical_pending report "pair capture ignored missing upper half" severity failure;
  respond64<='1';finish(0,pattern(32));assert high9=pattern(33) report "pair high word is stale" severity failure;wait_idle;
  -- Both CPUs' SWP reservations survive an empty-request gap and peer traffic.
  for owner in 0 to 1 loop
   send(owner,48+owner,'1',x"00000000",'1');finish(owner,pattern(48+owner));
   step(20);assert idle='0' and busy='1' and active='1' report "SWP gap falsely idle" severity failure;
   before:=guest_completions;send(1-owner,64+owner,'1',x"00000000");step(15);
   assert idle='0' and guest_completions=before report "peer escaped reserved SWP pair" severity failure;
   send(owner,48+owner,'0',x"A55A1234",'1');finish(owner,x"00000000",false);
   finish(1-owner,pattern(64+owner));wait_idle;
   send(owner,48+owner,'1',x"00000000");finish(owner,x"A55A1234");wait_idle;
  end loop;
  -- Simultaneous requests exercise both priority policies without changing them.
  allowed<='0';send(0,80,'1',x"00000000");send(1,81,'1',x"00000000");allowed<='1';
  if PRIORITY7 then finish(1,pattern(81));finish(0,pattern(80));
  else finish(0,pattern(80));finish(1,pattern(81));end if;
  wait_idle;
  -- A missing low response cannot be hidden by common reset. Let the real
  -- accepted operation drain while reset is held, then establish fresh idle.
  respond32<='0';send(0,96,'1',x"00000000");step(40);
  assert idle='0' and physical_pending report "missing response falsely idle" severity failure;
  reset<='1';step(8);assert idle='0' report "reset exposed stale idle" severity failure;
  respond32<='1';step(40);assert not physical_pending severity failure;
  reset<='0';wait_idle;send(1,97,'1',x"00000000");finish(1,pattern(97));wait_idle;
  assert physical_writes=4 and physical_reads=14 and guest_completions=17
   report "main-RAM transaction count changed" severity failure;
  report "CHECKPOINT_MAINRAM_PASS ratio="&integer'image(MEM_RATIO)&" phase="&integer'image(PHASE_NS)&
   " latency="&integer'image(LATENCY)&" priority7="&boolean'image(PRIORITY7);
  std.env.stop;wait;
 end process;
 process begin wait for 1 ms;assert false report "main-RAM checkpoint watchdog" severity failure;end process;
end architecture;
