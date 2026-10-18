-- Compare the experimental event stop to the existing clock-enable cadence.
-- Reference timer pulses are sampled only on virtual counter edges; raster
-- pulses already emitted before a stop must still be delivered once.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_timing is
 generic (PRESCALER : natural range 0 to 3 := 0);
end entity;
architecture test of tb_nds_checkpoint_timing is
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal stop_events,run_ce : std_logic := '0';
 signal compare : boolean := true;
 signal regs : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,(others=>'0'),'1');
 constant idle_bus : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,(others=>'0'),'0');
 type words is array(0 to 1) of std_logic_vector(31 downto 0);
 type irqs is array(0 to 1) of std_logic_vector(3 downto 0);
 type pulses is array(0 to 1) of std_logic_vector(12 downto 0);
 type counters is array(0 to 1,0 to 3) of unsigned(15 downto 0);
 type lines is array(0 to 1) of integer range 0 to 191;
 type vcounts is array(0 to 1) of unsigned(8 downto 0);
 signal timer_irq : irqs;
 signal raster_pulse : pulses;
 signal timer_debug : counters;
 signal timer_read,raster_read : words;
 signal raster_line,object_line : lines;
 signal vcount,phase_line : vcounts;
 signal timer_stopped,raster_stopped,tick0,tick1 : std_logic_vector(0 to 1);
 signal played_cycles,vblank_count,hblank_count,timer_count,cascade_count : natural := 0;
begin
 clk<=not clk after 5 ns;
 regs.rst<=reset;
 g_event: for i in 0 to 1 generate
  signal enabled : std_logic;
 begin
  enabled<=run_ce and not stop_events when i=0 else run_ce;
  timer: entity work.gba_timer
   generic map(is_simu=>'1',EXPERIMENTAL_CHECKPOINT=>i=1)
   port map(clk=>clk,ce=>enabled,reset=>reset,savestate_bus=>idle_bus,
    ss_wired_out=>open,ss_wired_done=>open,loading_savestate=>'0',
    gb_bus=>regs,wired_out=>timer_read(i),wired_done=>open,IRP_Timer=>timer_irq(i),
    timer0_tick=>tick0(i),timer1_tick=>tick1(i),debugout0=>timer_debug(i,0),
    debugout1=>timer_debug(i,1),debugout2=>timer_debug(i,2),debugout3=>timer_debug(i,3),
    checkpoint_stop=>stop_events,checkpoint_stopped=>timer_stopped(i));
  raster: entity work.nds_gpu_timing
   generic map(EXPERIMENTAL_CHECKPOINT=>i=1)
   port map(clk=>clk,ce=>enabled,reset=>reset,gb_bus9=>regs,gb_bus7=>regs,
    wired_out9=>raster_read(i),wired_done9=>open,wired_out7=>open,wired_done7=>open,
    irq9_vblank=>raster_pulse(i)(0),irq9_hblank=>raster_pulse(i)(1),irq9_vcount=>raster_pulse(i)(2),
    irq7_vblank=>raster_pulse(i)(3),irq7_hblank=>raster_pulse(i)(4),irq7_vcount=>raster_pulse(i)(5),
    drawline=>raster_pulse(i)(6),drawObj=>raster_pulse(i)(7),line_trigger=>raster_pulse(i)(8),
    hblank_trigger=>raster_pulse(i)(9),lcd_phase=>raster_pulse(i)(10),
    vblank_trigger=>raster_pulse(i)(11),refpoint_update=>raster_pulse(i)(12),
    linecounter=>raster_line(i),linecounter_obj=>object_line(i),vcount_out=>vcount(i),lcd_phase_line=>phase_line(i),
    checkpoint_stop=>stop_events,checkpoint_stopped=>raster_stopped(i));
 end generate;
 monitor: process(clk)
 begin
  if rising_edge(clk) then
   if reset='1' then
    played_cycles<=0;vblank_count<=0;hblank_count<=0;timer_count<=0;cascade_count<=0;
   elsif compare then
    if stop_events='0' and run_ce='1' then played_cycles<=played_cycles+1;end if;
    assert raster_pulse(0)=raster_pulse(1) and raster_read(0)=raster_read(1) and
     raster_line(0)=raster_line(1) and object_line(0)=object_line(1) and vcount(0)=vcount(1) and phase_line(0)=phase_line(1)
     report "raster events or phase changed across checkpoint stop" severity failure;
    assert timer_read(0)=timer_read(1) report "timer readback changed across checkpoint stop" severity failure;
    for ch in 0 to 3 loop
     assert timer_debug(0,ch)=timer_debug(1,ch) report "timer counter changed across checkpoint stop" severity failure;
    end loop;
    if stop_events='0' then
     assert timer_irq(0)=timer_irq(1) and tick0(0)=tick0(1) and tick1(0)=tick1(1)
      report "timer/cascade event lost on resume" severity failure;
    else
     assert timer_irq(1)="0000" and tick0(1)='0' and tick1(1)='0'
      report "timer event escaped a stopped counter edge" severity failure;
    end if;
    if raster_pulse(1)(0)='1' then vblank_count<=vblank_count+1;end if;
    if raster_pulse(1)(1)='1' then hblank_count<=hblank_count+1;end if;
    if timer_irq(1)(0)='1' and run_ce='1' then timer_count<=timer_count+1;end if;
    if timer_irq(1)(1)='1' and run_ce='1' then cascade_count<=cascade_count+1;end if;
    assert timer_stopped(0)='0' and raster_stopped(0)='0'
     report "disabled checkpoint option acknowledged a request" severity failure;
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
   if stop_events='1' then
    assert timer_stopped(1)='0' and raster_stopped(1)='0'
     report "event owner acknowledged a live register access" severity failure;
   end if;
   step;regs.ena<='0';regs.rnw<='1';regs.bEna<="0000";step;
  end;
  procedure hold_events(duration : positive) is
   variable before_timer,before_cascade : natural;
  begin
   stop_events<='1';step;
   assert timer_stopped(1)='1' and raster_stopped(1)='1' report "events did not stop" severity failure;
   before_timer:=timer_count;before_cascade:=cascade_count;
   step(duration);
   assert before_timer=timer_count and before_cascade=cascade_count
    report "timer IRQ repeated while held" severity failure;
   stop_events<='0';step;
   assert timer_stopped(1)='0' and raster_stopped(1)='0' report "event stop did not cancel" severity failure;
  end;
  type phases is array(natural range <>) of natural;
  constant slots : phases := (0,1,1583,1584,1585,1586,1587,2128,2129);
 begin
  step(4);reset<='0';run_ce<='1';
  write_reg(16#4#,x"00023838"); -- both CPU sets: VCount match=56, all IRQs
  write_reg(16#100#,std_logic_vector(unsigned'(x"00C0FFF0") or shift_left(to_unsigned(PRESCALER,32),16)));
  write_reg(16#104#,x"00C4FFFC"); -- cascade from timer 0
  write_reg(16#108#,x"00C1FFFC"); -- /64
  write_reg(16#10C#,x"00C4FFFE"); -- cascade from timer 2
  -- Interrupt immediately before an overflow edge, including cascade ticks.
  for k in 1 to 20000 loop step;exit when timer_irq(1)(0)='1';end loop;
  assert timer_irq(1)(0)='1' report "fixture missed timer overflow" severity failure;
  hold_events(71);
  for p in slots'range loop
   step;while played_cycles mod 2130/=slots(p) loop step;end loop;
   hold_events(31+p*13);
  end loop;
  -- VCOUNT writes are queued even while the raster is stopped.
  stop_events<='1';step;write_reg(16#4#,x"00BF3838");step(29);
  stop_events<='0';step;
  for k in 1 to 2131 loop step;exit when vcount(1)=191;end loop;
  assert vcount(1)=191 report "VCOUNT write was lost while stopped" severity failure;
  for k in 0 to 63 loop step(137+(k*53 mod 1019));hold_events(11+(k*17 mod 79));end loop;
  -- Preserve the existing sleep/CE behavior while a checkpoint is held.
  run_ce<='0';hold_events(17);step(23);run_ce<='1';step;
  while played_cycles<1130000 loop step;end loop;
  assert vblank_count>=2 and hblank_count>500 and timer_count>30 and cascade_count>5
   report "timing fixture did not cover enough frame/timer events" severity failure;
  -- A CPU control write after stopping must still start a timer. Test this
  -- independently: the old CE-only reference intentionally cannot handle it.
  compare<=false;write_reg(16#100#,x"00000000");reset<='1';step(4);reset<='0';
  stop_events<='1';step;write_reg(16#100#,x"00C0FFFE");step(20);
  assert timer_stopped(1)='1' and timer_irq(1)="0000" report "timer write escaped held state" severity failure;
  stop_events<='0';step(8);
  assert unsigned(timer_read(1)(15 downto 0))>=16#FFFE#
   report "timer start write was discarded during stop" severity failure;
  report "CHECKPOINT_TIMING_PASS prescaler="&integer'image(PRESCALER)&" virtual_clocks=1130000";
  std.env.stop;wait;
 end process;
 process begin wait for 20 ms;assert false report "timing checkpoint watchdog" severity failure;end process;
end architecture;
