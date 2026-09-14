library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity tb_nds_sound_dma_yield is
 generic (ENABLE_YIELD : boolean := true; CHANNELS : positive range 1 to 16 := 1; PCM16 : boolean := false; REPEAT_TRIGGER : boolean := false);
end entity;
architecture test of tb_nds_sound_dma_yield is
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal vblank : std_logic := '0';
 signal regs : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,(others=>'0'),'0');
 type words is array(0 to 1) of std_logic_vector(31 downto 0);
 type diagnostics is array(0 to 1) of std_logic_vector(127 downto 0);
 signal diagnostic : diagnostics;
 type samples is array(0 to 1) of std_logic_vector(15 downto 0);
 signal sreq,sown,sena,done,bus_ena,bus_rnw,valid : std_logic_vector(0 to 1) := (others=>'0');
 signal saddr,data,bus_addr,bus_data : words := (others=>(others=>'0'));
 signal left_sample,right_sample : samples;
 signal slim_req,slim_own,slim_ena,slim_valid : std_logic;
 signal slim_addr : std_logic_vector(31 downto 0);
 signal slim_left,slim_right : std_logic_vector(15 downto 0);
 signal slim_diagnostic : std_logic_vector(127 downto 0);
 signal dma_on,dma_own,dma_ena,dma_rnw,dma_ok,sound_ok,yield_req : std_logic;
 signal dma_addr,dma_data : std_logic_vector(31 downto 0);
 signal irq : std_logic_vector(3 downto 0);
 type counts is array(0 to 1) of natural;
 signal write_count : counts := (others=>0);
 signal writes,irqs,mismatches,varied,longest_wait : natural := 0;
 function contents(address : std_logic_vector(31 downto 0)) return std_logic_vector is
  variable v : std_logic_vector(31 downto 0); variable n : natural;
 begin
  n:=to_integer(unsigned(address(13 downto 2)));
  for b in 0 to 3 loop
   v(b*8+7 downto b*8):=std_logic_vector(to_unsigned((n*4+b)*13 mod 256,8));
  end loop;
  return v;
 end function;
begin
 clk<=not clk after 5 ns;
 writes<=write_count(1);
 -- Production grant equations; false retains the original baseline control.
 -- CPU is parked and its bus is fully drained.
 dma_ok<=not sown(1) and not sreq(1) when ENABLE_YIELD else not sown(1);
 sound_ok<=not dma_own when ENABLE_YIELD else not dma_on and not dma_own;
 yield_req<=sreq(1) when ENABLE_YIELD else '0';
 dma: entity work.nds_dma7 port map (
  clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>open,wired_done=>open,
  trig_vblank=>vblank,trig_card=>'0',cpu_bus_idle=>dma_ok,yield_bus=>yield_req,
  dma_on=>dma_on,dma_bus_on=>dma_own,mb_ena=>dma_ena,mb_rnw=>dma_rnw,
  mb_adr=>dma_addr,mb_acc=>open,mb_lowbits=>open,mb_dout=>dma_data,
  mb_din=>data(1),mb_done=>done(1),irq_dma=>irq);
 snd: for i in 0 to 1 generate
  signal granted : std_logic;
 begin
  granted<='1' when i=0 else sound_ok;
  unit: entity work.nds_sound generic map (is_simu=>'1',ADPCM_TABLE_RAM=>0,DIAGNOSTICS=>i)
  port map (clk=>clk,ce=>'1',reset=>reset,bus7=>regs,
   wired_out7=>open,wired_done7=>open,snd_bus_req=>sreq(i),snd_bus_ok=>granted,
   snd_bus_own=>sown(i),mb_ena=>sena(i),mb_adr=>saddr(i),mb_din=>data(i),mb_done=>done(i),
   sample_l=>left_sample(i),sample_r=>right_sample(i),sample_valid=>valid(i),
   snd_enable=>open,snd_active=>open,diagnostic=>diagnostic(i));
 end generate;
 -- Mode 2 sees exactly the production instance's accepted responses. Require
 -- every request, sample and retained counter to remain cycle-identical, even
 -- in the deliberately starving negative control and repeated DMA cases.
 slim: entity work.nds_sound generic map (is_simu=>'1',ADPCM_TABLE_RAM=>0,DIAGNOSTICS=>2)
 port map (clk=>clk,ce=>'1',reset=>reset,bus7=>regs,
  wired_out7=>open,wired_done7=>open,snd_bus_req=>slim_req,snd_bus_ok=>sound_ok,
  snd_bus_own=>slim_own,mb_ena=>slim_ena,mb_adr=>slim_addr,mb_din=>data(1),mb_done=>done(1),
  sample_l=>slim_left,sample_r=>slim_right,sample_valid=>slim_valid,
  snd_enable=>open,snd_active=>open,diagnostic=>slim_diagnostic);
 process(clk)
 begin
  if rising_edge(clk) and reset='0' then
   assert slim_req=sreq(1) and slim_own=sown(1) and slim_ena=sena(1) and
          slim_addr=saddr(1) and slim_left=left_sample(1) and
          slim_right=right_sample(1) and slim_valid=valid(1)
    report "slim diagnostic changed sound requests or samples" severity failure;
   assert slim_diagnostic(63 downto 0)=diagnostic(1)(63 downto 0) and
          slim_diagnostic(127 downto 64)=x"0000000000000000"
    report "slim diagnostic changed fetch counters or kept full counters" severity failure;
  end if;
 end process;
 bus_ena(0)<=sena(0);bus_rnw(0)<='1';bus_addr(0)<=saddr(0);bus_data(0)<=(others=>'0');
 bus_ena(1)<=dma_ena when dma_own='1' else sena(1) when sown(1)='1' else '0';
 bus_rnw(1)<=dma_rnw when dma_own='1' else '1';
 bus_addr(1)<=dma_addr when dma_own='1' else saddr(1);
 bus_data(1)<=dma_data when dma_own='1' else (others=>'0');
 memories: for i in 0 to 1 generate
 begin
  process(clk)
   variable delay : natural:=0;
   variable address,value : std_logic_vector(31 downto 0);
   variable rnw : std_logic;
  begin
   if rising_edge(clk) then
    done(i)<='0';
    if reset='1' then delay:=0;
    else
     if delay>0 then
      delay:=delay-1;
      if delay=0 then
       done(i)<='1';data(i)<=contents(address);
       if i=1 and rnw='0' then
        assert address=std_logic_vector(to_unsigned(16#02010000#+writes*4,32))
         report "DMA destination skipped/repeated across yield" severity failure;
        assert value=contents(std_logic_vector(to_unsigned(16#02000000#+writes*4,32)))
         report "DMA read/write unit lost its data" severity failure;
        write_count(i)<=write_count(i)+1;
       end if;
      end if;
     end if;
     if bus_ena(i)='1' then
      assert delay=0 report "overlapping memory operations" severity failure;
      delay:=24;address:=bus_addr(i);value:=bus_data(i);rnw:=bus_rnw(i);
     end if;
    end if;
   end if;
  end process;
 end generate;
 process(clk)
  variable wait_cycles : natural:=0;
  variable last_sample : std_logic_vector(15 downto 0):=(others=>'0');
 begin
  if rising_edge(clk) and reset='0' then
   assert not(dma_own='1' and sown(1)='1') report "DMA/SPU double grant" severity failure;
   if irq(0)='1' then irqs<=irqs+1;end if;
   if sreq(1)='1' and sown(1)='0' then
    wait_cycles:=wait_cycles+1;
    if wait_cycles>longest_wait then longest_wait<=wait_cycles;end if;
   else wait_cycles:=0;end if;
   assert valid(0)=valid(1) report "mixer output cadence changed" severity failure;
   if valid(0)='1' then
    if left_sample(0)/=left_sample(1) or right_sample(0)/=right_sample(1) then mismatches<=mismatches+1;end if;
    if left_sample(0)/=last_sample then varied<=varied+1;end if;
    last_sample:=left_sample(0);
   end if;
  end if;
 end process;
 stimulus: process
  procedure write_reg(constant address : natural;constant value : std_logic_vector(31 downto 0)) is
  begin
   regs.Adr<=std_logic_vector(to_unsigned(address,28));regs.Din<=value;
   regs.rnw<='0';regs.ena<='1';regs.bEna<="1111";
   wait until rising_edge(clk);wait for 1 ns;
   regs.ena<='0';regs.rnw<='1';regs.bEna<="0000";
   wait until rising_edge(clk);wait for 1 ns;
  end procedure;
 begin
  wait until rising_edge(clk);wait until rising_edge(clk);wait for 1 ns;reset<='0';
  write_reg(16#500#,x"0000807F");
  for channel in 0 to CHANNELS-1 loop
   write_reg(16#404#+channel*16,std_logic_vector(to_unsigned(16#02020000#+channel*16#400#,32)));
   write_reg(16#408#+channel*16,x"0000FE00");write_reg(16#40C#+channel*16,x"00001000");
   if PCM16 then write_reg(16#400#+channel*16,x"A8400007");
   else write_reg(16#400#+channel*16,x"8840007F");end if;
  end loop;
  for i in 1 to 12000 loop wait until rising_edge(clk);end loop;wait for 1 ns;
  write_reg(16#B0#,x"02000000");write_reg(16#B4#,x"02010000");
  if REPEAT_TRIGGER then
   write_reg(16#B8#,x"D6000400"); -- VBlank repeat, two triggers, increment addresses
   vblank<='1';wait until rising_edge(clk);wait for 1 ns;vblank<='0';
   for i in 1 to 3000 loop wait until rising_edge(clk);end loop;wait for 1 ns;
   assert dma_on='1' report "repeat trigger must arrive during the transfer" severity failure;
   vblank<='1';wait until rising_edge(clk);wait for 1 ns;vblank<='0';
  else
   write_reg(16#B8#,x"C4000400");
  end if;
  for i in 1 to 150000 loop wait until rising_edge(clk);end loop;wait for 1 ns;
  if REPEAT_TRIGGER then
   assert writes=2048 and irqs=2 and dma_on='0' report "pending repeat trigger lost across yield" severity failure;
  else
   assert writes=1024 and irqs=1 and dma_on='0' report "DMA did not finish exactly once" severity failure;
  end if;
  assert varied>20 report "audio fixture did not generate varied samples" severity failure;
  if ENABLE_YIELD then
   assert mismatches=0 report "sound diverged from the unblocked reference" severity failure;
   assert longest_wait<128 report "sound refill waited too long" severity failure;
   report "SOUND_DMA_YIELD_PASS channels="&integer'image(CHANNELS)&" pcm16="&boolean'image(PCM16)&" words="&integer'image(writes)&" samples_changed="&integer'image(varied)&" max_wait="&integer'image(longest_wait);
  else
   assert mismatches>20 and longest_wait>20000 report "baseline did not reproduce sound starvation" severity failure;
   report "SOUND_DMA_STARVATION_REPRO mismatched_samples="&integer'image(mismatches)&" max_wait="&integer'image(longest_wait);
  end if;
  assert diagnostic(0) = (diagnostic(0)'range => '0')
   report "disabled sound diagnostics did not prune to zero" severity failure;
  assert diagnostic(1)(127 downto 124)=x"A" and diagnostic(1)(95 downto 92)=x"B" and
         diagnostic(1)(63 downto 60)=x"C" and diagnostic(1)(31 downto 28)=x"D"
   report "sound diagnostic tags malformed" severity failure;
  if ENABLE_YIELD then
   assert diagnostic(1)(123 downto 96)=x"0000000"
    report "corrected sound unexpectedly underruns in reference workload" severity failure;
  else
   assert unsigned(diagnostic(1)(123 downto 112))/=0 and diagnostic(1)(96)='1'
    report "sound diagnostic failed to observe reproduced starvation" severity failure;
  end if;
  report "SOUND_DIAGNOSTIC_PASS receipt=" & to_hstring(diagnostic(1)) severity note;
  std.env.stop;wait;
 end process;
end architecture;
