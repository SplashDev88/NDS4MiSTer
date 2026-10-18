-- SPDX-License-Identifier: GPL-3.0-or-later
-- Resume raster events at the exact saved cycle, without replaying old pulses.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_raster_restore is
 generic(RESTORING : boolean := false; SCENARIO : natural := 0;
         GAP : natural := 0; CHECK_IMAGE : boolean := true);
end;
architecture sim of tb_nds_checkpoint_raster_restore is
 constant IDLE_BUS : proc_bus_gb_type := ((others=>'0'),x"0000004",'1','0',ACCESS_32BIT,"1111",'0');
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal ce,stop_events : std_logic := '0';
 signal bus9,bus7 : proc_bus_gb_type := IDLE_BUS;
 signal q9,q7,rq9,rq7 : std_logic_vector(31 downto 0);
 signal done,rdone : std_logic_vector(1 downto 0);
 signal pulse,rpulse : std_logic_vector(12 downto 0);
 signal line,obj,rline,robj : integer range 0 to 191;
 signal vcount,phase_line,rvcount,rphase_line : unsigned(8 downto 0);
 signal dbg,rdbg,stopped,valid,ready,err : std_logic;
 signal restoring_state,write_state : std_logic := '0';
 signal cp_addr : unsigned(2 downto 0) := (others=>'0');
 signal cp_data,cp_wdata : std_logic_vector(31 downto 0);
begin
 clk<=not clk after 5 ns;
 bus9.rst<=reset;bus7.rst<=reset;
 dut:entity work.nds_gpu_timing generic map(EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>ce,reset=>reset,gb_bus9=>bus9,gb_bus7=>bus7,wired_out9=>q9,wired_out7=>q7,wired_done9=>done(0),wired_done7=>done(1),
  irq9_vblank=>pulse(0),irq9_hblank=>pulse(1),irq9_vcount=>pulse(2),irq7_vblank=>pulse(3),irq7_hblank=>pulse(4),irq7_vcount=>pulse(5),
  drawline=>pulse(6),drawObj=>pulse(7),line_trigger=>pulse(8),hblank_trigger=>pulse(9),lcd_phase=>pulse(10),vblank_trigger=>pulse(11),refpoint_update=>pulse(12),
  linecounter=>line,linecounter_obj=>obj,vcount_out=>vcount,lcd_phase_line=>phase_line,dbg_vbl_ena9=>dbg,
  checkpoint_stop=>stop_events,checkpoint_stopped=>stopped,checkpoint_address=>cp_addr,checkpoint_data=>cp_data,checkpoint_valid=>valid,
  checkpoint_restore=>restoring_state,checkpoint_write=>write_state,checkpoint_write_data=>cp_wdata,checkpoint_restore_ready=>ready,checkpoint_restore_error=>err);
 reference_raster:entity work.nds_gpu_timing_reference generic map(EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>ce,reset=>reset,gb_bus9=>bus9,gb_bus7=>bus7,wired_out9=>rq9,wired_out7=>rq7,wired_done9=>rdone(0),wired_done7=>rdone(1),
  irq9_vblank=>rpulse(0),irq9_hblank=>rpulse(1),irq9_vcount=>rpulse(2),irq7_vblank=>rpulse(3),irq7_hblank=>rpulse(4),irq7_vcount=>rpulse(5),
  drawline=>rpulse(6),drawObj=>rpulse(7),line_trigger=>rpulse(8),hblank_trigger=>rpulse(9),lcd_phase=>rpulse(10),vblank_trigger=>rpulse(11),refpoint_update=>rpulse(12),
  linecounter=>rline,linecounter_obj=>robj,vcount_out=>rvcount,lcd_phase_line=>rphase_line,dbg_vbl_ena9=>rdbg,checkpoint_stop=>stop_events);
 baseline:process
 begin
  wait until clk'event;wait for 1 ns;
  if not RESTORING then
   assert q9=rq9 and q7=rq7 and done=rdone and pulse=rpulse and line=rline and obj=robj and vcount=rvcount and phase_line=rphase_line and dbg=rdbg
    report "raster pinned baseline differs" severity failure;
  end if;
 end process;
 stimulus:process
  alias raster_cycle is << signal .tb_nds_checkpoint_raster_restore.dut.cycles : integer range 0 to 2129 >>;
  alias raster_line is << signal .tb_nds_checkpoint_raster_restore.dut.line : integer range 0 to 262 >>;
  file state_file,trace_file : text;
  variable line_buffer : std.textio.line;
  type image_t is array(0 to 4) of std_logic_vector(31 downto 0);
  variable image : image_t;
  type phases_t is array(0 to 19) of natural;
  constant lines : phases_t := (0,0,0,0,0,1,191,191,192,192,215,261,262,262,1,1,55,56,2,2);
  constant phases : phases_t := (0,1583,1584,1585,1586,2129,1583,2129,0,1585,1585,2129,1585,2129,2128,2129,2129,0,1584,1586);
  variable actual,expected : std_logic_vector(113 downto 0);
  variable recording : boolean := false;
  variable observations : natural := 0;
  procedure observe is
  begin
   if recording then
    actual:=q9&q7&done&pulse&std_logic_vector(to_unsigned(line,8))&std_logic_vector(to_unsigned(obj,8))&std_logic_vector(vcount)&std_logic_vector(phase_line)&dbg;
    if RESTORING then
     assert not endfile(trace_file) report "raster trace truncated" severity failure;
     readline(trace_file,line_buffer);hread(line_buffer,expected);
     assert actual=expected report "raster continuation mismatch at step "&integer'image(observations) severity failure;
    else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;
    observations:=observations+1;
   end if;
  end;
  procedure step(n:natural:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;observe;end loop;end;
  procedure write_reg(cpu:natural;d:std_logic_vector(31 downto 0);be:std_logic_vector(3 downto 0):="0011") is
  begin
   if cpu=9 then bus9.Din<=d;bus9.bEna<=be;bus9.rnw<='0';bus9.ena<='1';
   else bus7.Din<=d;bus7.bEna<=be;bus7.rnw<='0';bus7.ena<='1';end if;
   wait for 1 ns;assert stopped='0' report "raster stopped during bus admission" severity failure;
   step;bus9.ena<='0';bus7.ena<='0';bus9.rnw<='1';bus7.rnw<='1';step;
  end;
  procedure load_word(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cp_addr<=to_unsigned(a,3);cp_wdata<=d;write_state<='1';step;write_state<='0';step(1+GAP*(a+1));end;
  procedure new_attempt is
  begin restoring_state<='0';step;restoring_state<='1';step;assert ready='0' report "raster stale coverage" severity failure;end;
  procedure load_all is
  begin
   for a in image'range loop
    load_word(a,image(a));if a<4 then assert ready='0' report "raster partial restore accepted" severity failure;end if;
   end loop;assert ready='1' and err='0' report "raster complete restore not ready" severity failure;
  end;
  procedure read_image is
  begin
   for a in image'range loop
    cp_addr<=to_unsigned(a,3);wait for 1 ns;assert valid='1' report "raster image unavailable" severity failure;
    if RESTORING then
     if CHECK_IMAGE then assert cp_data=image(a) report "raster restored word mismatch "&integer'image(a) severity failure;end if;
    else image(a):=cp_data;end if;step(2);
   end loop;
   cp_addr<="101";wait for 1 ns;assert valid='0' and cp_data=x"00000000" report "raster undefined word exposed data" severity failure;
  end;
 begin
  step(4);
  if RESTORING then
   file_open(state_file,"raster.state",read_mode);
   for a in image'range loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
   assert endfile(state_file) report "raster extra state words" severity failure;file_close(state_file);
   ce<='1';stop_events<='1';restoring_state<='1';step;load_all;read_image;
   step(2200);read_image;assert pulse=(pulse'range=>'0') report "raster events escaped reset-held restore" severity failure;
   load_word(5,x"00000000");assert err='1' and ready='0' report "raster extra word accepted" severity failure;
   for fault in 0 to 12 loop
    new_attempt;
    case fault is
     when 0 => load_word(1,image(1));
     when 1 => load_word(0,image(0));load_word(0,image(0));
     when 2 => load_word(0,(image(0) and x"FFFFF000") or x"00000852");
     when 3 => load_word(0,(image(0) and x"FFE00FFF") or x"00107000");
     when 4 | 5 => load_word(0,image(0));
      if fault=4 then load_word(1,image(1) or x"00200000");else load_word(1,(image(1) and x"FFE00FFF") or x"00107000");end if;
     when 6 | 7 => for a in 0 to 1 loop load_word(a,image(a));end loop;
      if fault=6 then load_word(2,x"000000C0");else load_word(2,x"0000C000");end if;
     when 8 | 9 => for a in 0 to 2 loop load_word(a,image(a));end loop;
      if fault=8 then load_word(3,image(3) or x"00000001");else load_word(3,image(3) or x"00010000");end if;
     when 10 => bus9.ena<='1';step;bus9.ena<='0';step;
     when 11 => bus7.ena<='1';step;bus7.ena<='0';step;
     when others => stop_events<='0';step;stop_events<='1';step;
    end case;
    assert err='1' and ready='0' and valid='0' report "raster invalid restore accepted" severity failure;
    load_word(0,image(0));assert err='1' and ready='0' report "raster poisoned restore recovered" severity failure;
   end loop;
   new_attempt;load_all;read_image;
   reset<='0';restoring_state<='0';step(2);restoring_state<='1';load_word(0,x"00000000");
   assert err='1' and ready='0' report "raster live restore accepted" severity failure;
   restoring_state<='0';step;read_image;
   reset<='1';new_attempt;load_all;read_image;reset<='0';restoring_state<='0';step(2);
   file_open(trace_file,"raster.trace",read_mode);
  else
   reset<='0';step(2);
   write_reg(9,x"0000C038");write_reg(7,x"000006B8");
   ce<='1';wait for 1 ns;
   while raster_line/=lines(SCENARIO) or raster_cycle/=phases(SCENARIO) loop step;end loop;
   stop_events<='1';step(2);assert stopped='1' report "raster stop did not drain pulses" severity failure;
   if SCENARIO=14 then
    bus9.Din<=x"00C00000";bus9.bEna<="1100";bus9.rnw<='0';bus9.ena<='1';
    bus7.Din<=x"01060000";bus7.bEna<="1100";bus7.rnw<='0';bus7.ena<='1';step;
    bus9.ena<='0';bus7.ena<='0';bus9.rnw<='1';bus7.rnw<='1';step;
   elsif SCENARIO=15 then write_reg(9,x"00BF0000","1100");write_reg(9,x"0000BF38");
   elsif SCENARIO=16 then write_reg(7,x"00C00000","1100");
   elsif SCENARIO=17 then write_reg(9,x"01FF0000","1100");write_reg(9,x"0000FFB8");
   end if;
   read_image;
   file_open(state_file,"raster.state",write_mode);
   for a in image'range loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;file_close(state_file);
   file_open(trace_file,"raster.trace",write_mode);
  end if;
  recording:=true;observe;step(2);stop_events<='0';step(5000);
  -- CE gaps and register writes have their original semantics after resume.
  ce<='0';step(17);write_reg(9,x"00005500","0010");write_reg(7,x"00000018","0001");
  write_reg(7,x"01FF0000","1100");step(3);ce<='1';step(2200);
  stop_events<='1';step(31);write_reg(9,x"00C00000","1100");stop_events<='0';step(7000);
  if RESTORING then assert endfile(trace_file) report "raster extra trace records" severity failure;end if;file_close(trace_file);
  report "CHECKPOINT_RASTER_RESTORE_PASS restoring="&boolean'image(RESTORING)&" scenario="&integer'image(SCENARIO)&
   " gap="&integer'image(GAP)&" observations="&integer'image(observations);
  std.env.stop;wait;
 end process;
 process begin wait for 10 ms;assert false report "raster restore watchdog" severity failure;end process;
end;
