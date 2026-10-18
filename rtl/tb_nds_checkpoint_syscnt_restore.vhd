-- SPDX-License-Identifier: GPL-3.0-or-later
-- Restore raw memory mappings, ownership/power, sticky POSTFLG and lid sleep.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_syscnt_restore is
 generic(RESTORING : boolean := false; SCENARIO : natural := 0; COLD : natural := 0;
         GAP : natural := 0; CHECK_IMAGE : boolean := true);
end;
architecture sim of tb_nds_checkpoint_syscnt_restore is
 constant IDLE_BUS : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal cold_boot,preset,wake : std_logic := '0';
 signal bus9,bus7 : proc_bus_gb_type := IDLE_BUS;
 signal q9,q7,rq9,rq7 : std_logic_vector(31 downto 0);
 signal done,rdone,wram,rwram : std_logic_vector(1 downto 0);
 signal vram,rvram : std_logic_vector(71 downto 0);
 signal power,rpower,owner,rowner : std_logic_vector(2 downto 0);
 signal halt,sleep,rhalt,rsleep,idle,valid,ready,err : std_logic;
 signal restoring_state,write_state : std_logic := '0';
 signal cp_addr : unsigned(2 downto 0) := (others=>'0');
 signal cp_data,cp_wdata : std_logic_vector(31 downto 0);
begin
 clk<=not clk after 5 ns;
 dut:entity work.nds_syscnt generic map(EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,reset=>reset,cold_boot=>cold_boot,bus9=>bus9,wired_out9=>q9,wired_done9=>done(0),
  bus7=>bus7,wired_out7=>q7,wired_done7=>done(1),preset_direct=>preset,wramcnt=>wram,vramcnt=>vram,
  pow_2da=>power(0),pow_2db=>power(1),pow_swap=>power(2),exmem_gba7=>owner(0),exmem_card7=>owner(1),exmem_prio7=>owner(2),
  halt7=>halt,wake7=>wake,console_sleep=>sleep,checkpoint_idle=>idle,checkpoint_address=>cp_addr,checkpoint_data=>cp_data,
  checkpoint_valid=>valid,checkpoint_restore=>restoring_state,checkpoint_write=>write_state,checkpoint_write_data=>cp_wdata,
  checkpoint_restore_ready=>ready,checkpoint_restore_error=>err);
 reference_syscnt:entity work.nds_syscnt_reference
 port map(clk=>clk,reset=>reset,cold_boot=>cold_boot,bus9=>bus9,wired_out9=>rq9,wired_done9=>rdone(0),
  bus7=>bus7,wired_out7=>rq7,wired_done7=>rdone(1),preset_direct=>preset,wramcnt=>rwram,vramcnt=>rvram,
  pow_2da=>rpower(0),pow_2db=>rpower(1),pow_swap=>rpower(2),exmem_gba7=>rowner(0),exmem_card7=>rowner(1),exmem_prio7=>rowner(2),
  halt7=>rhalt,wake7=>wake,console_sleep=>rsleep);
 baseline:process
 begin
  wait until clk'event;wait for 1 ns;
  if not RESTORING then
   assert q9=rq9 and q7=rq7 and done=rdone and wram=rwram and vram=rvram and power=rpower and owner=rowner and halt=rhalt and sleep=rsleep
    report "syscnt pinned baseline differs" severity failure;
  end if;
 end process;
 stimulus:process
  file state_file,trace_file : text;
  variable line_buffer : line;
  type image_t is array(0 to 3) of std_logic_vector(31 downto 0);
  variable image : image_t;
  type addresses_t is array(0 to 5) of std_logic_vector(27 downto 0);
  constant addresses : addresses_t := (x"0000204",x"0000240",x"0000244",x"0000248",x"0000304",x"0000300");
  variable actual,expected : std_logic_vector(147 downto 0);
  variable recording : boolean := false;
  variable observations : natural := 0;
  variable rng : unsigned(31 downto 0) := to_unsigned(7919*(SCENARIO+1)+COLD,32);
  procedure observe is
  begin
   if recording then
    actual:=q9&q7&done&wram&vram&power&owner&halt&sleep;
    if RESTORING then
     assert not endfile(trace_file) report "syscnt trace truncated" severity failure;
     readline(trace_file,line_buffer);hread(line_buffer,expected);
     assert actual=expected report "syscnt continuation mismatch at step "&integer'image(observations) severity failure;
    else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;
    observations:=observations+1;
   end if;
  end;
  procedure step(n:positive:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;observe;end loop;end;
  procedure write_reg(cpu:natural;a:std_logic_vector(27 downto 0);d:std_logic_vector(31 downto 0);be:std_logic_vector(3 downto 0):="1111") is
  begin
   if cpu=9 then bus9.Adr<=a;bus9.Din<=d;bus9.bEna<=be;bus9.rnw<='0';bus9.ena<='1';
   else bus7.Adr<=a;bus7.Din<=d;bus7.bEna<=be;bus7.rnw<='0';bus7.ena<='1';end if;
   wait for 1 ns;assert idle='0' report "syscnt idle during bus admission" severity failure;
   step;bus9.ena<='0';bus7.ena<='0';bus9.rnw<='1';bus7.rnw<='1';step(2);
  end;
  procedure load_word(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cp_addr<=to_unsigned(a,3);cp_wdata<=d;write_state<='1';step;write_state<='0';step(1+GAP*(a+1));end;
  procedure new_attempt is
  begin restoring_state<='0';step;restoring_state<='1';step;assert ready='0' report "syscnt stale coverage" severity failure;end;
  procedure load_all is
  begin
   for a in image'range loop
    load_word(a,image(a));if a<3 then assert ready='0' report "syscnt partial restore accepted" severity failure;end if;
   end loop;assert ready='1' and err='0' report "syscnt complete restore not ready" severity failure;
  end;
  procedure read_image is
  begin
   for a in image'range loop
    cp_addr<=to_unsigned(a,3);wait for 1 ns;assert valid='1' report "syscnt image unavailable" severity failure;
    if RESTORING then
     if CHECK_IMAGE then assert cp_data=image(a) report "syscnt restored word mismatch "&integer'image(a) severity failure;end if;
    else image(a):=cp_data;end if;
   end loop;
   cp_addr<="100";wait for 1 ns;assert valid='0' and cp_data=x"00000000" report "syscnt undefined image word exposed data" severity failure;
  end;
 begin
  cold_boot<=std_logic'val(COLD+2);step(4);
  if RESTORING then
   file_open(state_file,"syscnt.state",read_mode);
   for a in image'range loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
   assert endfile(state_file) report "syscnt extra state words" severity failure;file_close(state_file);
   -- Different reset defaults and an asserted wake must not erase loaded state.
   cold_boot<=not std_logic'val(COLD+2);wake<='1';restoring_state<='1';step;load_all;read_image;
   load_word(4,x"00000000");assert err='1' and ready='0' report "syscnt extra word accepted" severity failure;
   for fault in 0 to 7 loop
    new_attempt;
    case fault is
     when 0 => load_word(1,image(1));
     when 1 => load_word(0,image(0));load_word(0,image(0));
     when 2 => load_word(0,image(0) or x"80000000");
     when 3 | 4 =>
      for a in 0 to 2 loop load_word(a,image(a));end loop;
      if fault=3 then load_word(3,image(3) or x"00001000");else load_word(3,image(3) or x"80000000");end if;
     when 5 => bus9.ena<='1';step;bus9.ena<='0';
     when 6 => bus7.ena<='1';step;bus7.ena<='0';
     when others => preset<='1';step;preset<='0';
    end case;
    step;assert err='1' and ready='0' and valid='0' report "syscnt invalid restore accepted" severity failure;
    load_word(0,image(0));assert err='1' and ready='0' report "syscnt poisoned restore recovered" severity failure;
   end loop;
   new_attempt;load_all;read_image;
   wake<='0';cold_boot<=std_logic'val(COLD+2);reset<='0';restoring_state<='0';step;
   restoring_state<='1';load_word(0,x"00000000");assert err='1' and ready='0' report "syscnt live restore accepted" severity failure;
   restoring_state<='0';step;read_image;
   file_open(trace_file,"syscnt.trace",read_mode);
  else
   reset<='0';step(3);
   if SCENARIO=1 then preset<='1';step;preset<='0';step(2);end if;
   if SCENARIO>=2 then
    write_reg(9,addresses(0),x"0000A9C5");write_reg(7,addresses(0),x"00000053");
    write_reg(9,addresses(1),x"82E2FFFF");
    write_reg(9,addresses(2),std_logic_vector(to_unsigned((SCENARIO-2) mod 4,8))&x"ABF79D");
    write_reg(9,addresses(3),x"0000FEF3");write_reg(9,addresses(4),x"FFFFFFFF");
    write_reg(9,addresses(5),std_logic_vector(to_unsigned(SCENARIO mod 4,32)),"0001");
    write_reg(7,addresses(5),std_logic_vector(to_unsigned(SCENARIO mod 2,32)),"0001");
    bus9.Adr<=addresses(1);wait for 1 ns;
    assert q9=x"82829B9B" and vram(31 downto 0)=x"82E2FFFF" report "syscnt raw mapping/masked read changed" severity failure;
   end if;
   if SCENARIO=6 then write_reg(7,addresses(5),x"0000C000","0010");assert sleep='1' and halt='0' severity failure;
   elsif SCENARIO=7 then write_reg(7,addresses(5),x"00008000","0010");assert sleep='0' and halt='0' severity failure;
   elsif SCENARIO=8 then wake<='1';write_reg(7,addresses(5),x"0000C000","0010");assert sleep='0' severity failure;wake<='0';end if;
   bus9<=IDLE_BUS;bus7<=IDLE_BUS;step(3);read_image;
   file_open(state_file,"syscnt.state",write_mode);
   for a in image'range loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;file_close(state_file);
   file_open(trace_file,"syscnt.trace",write_mode);
  end if;
  recording:=true;observe;step(2);
  -- Every register and mapping output is observed before changing any state.
  for a in addresses'range loop bus9.Adr<=addresses(a);bus7.Adr<=addresses(a);step(2);end loop;
  wake<='1';wait for 1 ns;
  if sleep='1' then assert idle='0' report "syscnt acknowledged a pending wake" severity failure;end if;
  step;assert sleep='0' and halt='0' report "syscnt resumed wake failed or replayed HALT" severity failure;wake<='0';step(2);
  write_reg(9,addresses(5),x"00000000","0001");write_reg(7,addresses(5),x"00000000","0001");
  for k in 0 to 255 loop
   rng:=rng xor shift_left(rng,13);rng:=rng xor shift_right(rng,17);rng:=rng xor shift_left(rng,5);
   bus9.Adr<=addresses(k mod 6);bus7.Adr<=addresses((k+3) mod 6);
   bus9.Din<=std_logic_vector(rng);bus7.Din<=std_logic_vector(rotate_left(rng,13));
   bus9.bEna<=std_logic_vector(rng(3 downto 0));bus7.bEna<=std_logic_vector(rng(7 downto 4));
   bus9.rnw<='0';bus7.rnw<='0';bus9.ena<='1';bus7.ena<='1';wake<=rng(8);
   if k mod 31=0 then preset<='1';end if;
   step;preset<='0';bus9.ena<='0';bus7.ena<='0';step(2);
  end loop;
  bus9<=IDLE_BUS;bus7<=IDLE_BUS;wake<='0';step(3);
  if RESTORING then assert endfile(trace_file) report "syscnt extra trace records" severity failure;end if;file_close(trace_file);
  report "CHECKPOINT_SYSCNT_RESTORE_PASS restoring="&boolean'image(RESTORING)&" scenario="&integer'image(SCENARIO)&" cold="&integer'image(COLD)&" gap="&integer'image(GAP)&" observations="&integer'image(observations);
  std.env.stop;wait;
 end process;
 process begin wait for 5 ms;assert false report "syscnt restore watchdog" severity failure;end process;
end;
