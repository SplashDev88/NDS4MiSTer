-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cartridge continuations in a new process, including retained prefetch cells,
-- partial AUXSPI commands, erase progress and the external write-toggle epoch.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_card_restore is
 generic(RESTORING : boolean := false; SCENARIO : natural := 0; OWNER : natural := 0;
         PREFETCH : positive := 4; LATENCY : positive := 17; GAP : natural := 0;
         CHECK_IMAGE : boolean := true);
end;
architecture sim of tb_nds_checkpoint_card_restore is
 constant IDLE_BUS : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
 constant WORDS : positive := 15+PREFETCH;
 function save_kind return std_logic_vector is
 begin if SCENARIO=15 then return x"1";elsif SCENARIO=16 then return x"2";else return x"5";end if;end;
 function firmware_boot return std_logic is
 begin if (SCENARIO>=7 and SCENARIO<=10) or SCENARIO=23 then return '1';else return '0';end if;end;
 function infrared return std_logic is
 begin if SCENARIO=17 or SCENARIO=18 then return '1';else return '0';end if;end;
 type memory_t is array(0 to 255) of std_logic_vector(31 downto 0);
 function initial_memory return memory_t is
  variable m : memory_t;
 begin
  for i in m'range loop for j in 0 to 3 loop
   m(i)(j*8+7 downto j*8):=std_logic_vector(to_unsigned(((i*4+j)*13+63) mod 256,8));
  end loop;end loop;return m;
 end;
 function pattern(a : std_logic_vector(26 downto 0)) return std_logic_vector is
 begin return std_logic_vector(resize(unsigned(a),32) xor unsigned'(x"A55A0000"));end;
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal ce,cache_ready : std_logic := '1';
 signal hold,held,load_memory,track_erase : std_logic := '0';
 signal master,other_bus,bus9,bus7 : proc_bus_gb_type := IDLE_BUS;
 signal q,q9,q7,rq9,rq7,dbg,rdbg,rom_data : std_logic_vector(31 downto 0);
 signal req,ack,back_ack,bad_ack,save_we,save_toggle,save_active : std_logic := '0';
 signal addr,raddr : std_logic_vector(28 downto 2);
 signal save_addr,rsave_addr : std_logic_vector(19 downto 0);
 signal save_data,rsave_data,save_read : std_logic_vector(7 downto 0);
 signal irqs,dmas,done,rirqs,rdmas,rdone : std_logic_vector(1 downto 0);
 signal rreq,rsave_we,rsave_toggle,rsave_active : std_logic;
 signal cp_addr : unsigned(4 downto 0) := (others=>'0');
 signal cp_data,cp_wdata : std_logic_vector(31 downto 0);
 signal restoring_state,write_state : std_logic := '0';
 signal valid,ready,err : std_logic;
 signal memory,seed_memory : memory_t := initial_memory;
 signal digest : std_logic_vector(31 downto 0);
 signal erase_next,erase_total,erase_done : natural := 0;
begin
 clk<=not clk after 5 ns;ack<=back_ack or bad_ack;
 bus9<=master when OWNER=0 else other_bus;bus7<=master when OWNER=1 else other_bus;
 q<=q9 when OWNER=0 else q7;
 dut:entity work.nds_card generic map(CARDSPEED_SHIFT=>2,CARDPREFETCH=>PREFETCH,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>ce,reset=>reset,card7=>std_logic'val(OWNER+2),chipid=>x"12345678",fw_boot=>firmware_boot,
  bus9=>bus9,wired_out9=>q9,wired_done9=>done(0),bus7=>bus7,wired_out7=>q7,wired_done7=>done(1),
  irq9_xfer=>irqs(0),irq7_xfer=>irqs(1),dma9_card=>dmas(0),dma7_card=>dmas(1),dbg_card=>dbg,
  card_ena=>req,card_addr=>addr,card_din=>rom_data,card_done=>ack,
  backup_addr=>save_addr,backup_write_data=>save_data,backup_write_enable=>save_we,
  backup_read_data=>save_read,backup_write_toggle=>save_toggle,backup_save_type=>save_kind,backup_ir_enable=>infrared,
  backup_access_active=>save_active,backup_cache_ready=>cache_ready,
  checkpoint_stop=>hold,checkpoint_stopped=>held,checkpoint_address=>cp_addr,checkpoint_data=>cp_data,
  checkpoint_valid=>valid,checkpoint_restore=>restoring_state,checkpoint_write=>write_state,
  checkpoint_write_data=>cp_wdata,checkpoint_restore_ready=>ready,checkpoint_restore_error=>err);
 reference_card:entity work.nds_card_reference generic map(CARDSPEED_SHIFT=>2,CARDPREFETCH=>PREFETCH,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>ce,reset=>reset,card7=>std_logic'val(OWNER+2),chipid=>x"12345678",fw_boot=>firmware_boot,
  bus9=>bus9,wired_out9=>rq9,wired_done9=>rdone(0),bus7=>bus7,wired_out7=>rq7,wired_done7=>rdone(1),
  irq9_xfer=>rirqs(0),irq7_xfer=>rirqs(1),dma9_card=>rdmas(0),dma7_card=>rdmas(1),dbg_card=>rdbg,
  card_ena=>rreq,card_addr=>raddr,card_din=>rom_data,card_done=>ack,
  backup_addr=>rsave_addr,backup_write_data=>rsave_data,backup_write_enable=>rsave_we,
  backup_read_data=>save_read,backup_write_toggle=>rsave_toggle,backup_save_type=>save_kind,backup_ir_enable=>infrared,
  backup_access_active=>rsave_active,backup_cache_ready=>cache_ready,checkpoint_stop=>hold);
 baseline:process
 begin
  wait until clk'event;wait for 1 ns;
  if not RESTORING then
   assert q9=rq9 and q7=rq7 and dbg=rdbg and done=rdone and irqs=rirqs and dmas=rdmas and
    req=rreq and addr=raddr and save_addr=rsave_addr and save_data=rsave_data and save_we=rsave_we and
    save_toggle=rsave_toggle and save_active=rsave_active report "card pinned baseline differs" severity failure;
  end if;
 end process;
 save_read<=memory(to_integer(unsigned(save_addr(9 downto 2))))(to_integer(unsigned(save_addr(1 downto 0)))*8+7 downto to_integer(unsigned(save_addr(1 downto 0)))*8);
 backing:process(clk)
  variable remaining : integer := -1;
  variable saved_addr : std_logic_vector(28 downto 2);
  variable next_erase,completed : natural := 0;
 begin
  if rising_edge(clk) then
   back_ack<='0';
   if reset='1' then
    remaining:=-1;rom_data<=(others=>'0');
    if load_memory='1' then memory<=seed_memory;else memory<=initial_memory;end if;
   else
    if req='1' then
     assert remaining=-1 report "overlapping card backing request" severity failure;
     remaining:=LATENCY;saved_addr:=addr;
    elsif remaining=0 then rom_data<=pattern(saved_addr);back_ack<='1';remaining:=-1;
    elsif remaining>0 then remaining:=remaining-1;end if;
    if save_we='1' then
     assert cache_ready='1' report "card write without cache ownership" severity failure;
     memory(to_integer(unsigned(save_addr(9 downto 2))))(to_integer(unsigned(save_addr(1 downto 0)))*8+7 downto to_integer(unsigned(save_addr(1 downto 0)))*8)<=save_data;
     if track_erase='1' then
      assert to_integer(unsigned(save_addr))=next_erase and save_data=x"FF" and completed<erase_total
       report "card erase skipped/duplicated address or data" severity failure;
      next_erase:=next_erase+1;completed:=completed+1;
     end if;
    end if;
   end if;
   if track_erase='0' then next_erase:=erase_next;completed:=0;end if;
   erase_done<=completed;
  end if;
 end process;
 process(all)
  variable d : std_logic_vector(31 downto 0);
 begin d:=(others=>'0');for i in memory'range loop d:=d xor memory(i);end loop;digest<=d;end process;
 stimulus:process
  alias erase_left is << signal .tb_nds_checkpoint_card_restore.dut.erase_remaining : unsigned(16 downto 0) >>;
  file state_file,trace_file : text;
  variable line_buffer : line;
  type image_t is array(0 to WORDS-1) of std_logic_vector(31 downto 0);
  variable image : image_t;
  type address_list is array(0 to 9) of natural;
  constant invalid_addresses : address_list := (5,5,6,8,9,10,11,12,13,14);
  type mask_list is array(0 to 9) of std_logic_vector(31 downto 0);
  constant invalid_masks : mask_list := (x"00001001",x"02002000",x"00100000",x"00200200",x"08000000",
                                       x"80000000",x"10000000",x"10000000",x"00100000",x"00020000");
  variable backing_image : memory_t;
  variable actual,expected : std_logic_vector(194 downto 0);
  variable recording : boolean := false;
  variable observations,popped : natural := 0;
  variable got : std_logic_vector(7 downto 0);
  procedure observe is
  begin
   if recording then
    actual:=q9&q7&done&dbg&irqs&dmas&req&addr&save_addr&save_data&save_we&save_toggle&save_active&ack&cache_ready&digest;
    if RESTORING then
     assert not endfile(trace_file) report "card trace truncated" severity failure;
     readline(trace_file,line_buffer);hread(line_buffer,expected);
     assert actual=expected report "card continuation mismatch at step "&integer'image(observations) severity failure;
    else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;
    observations:=observations+1;
   end if;
  end;
  procedure step(n:positive:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;observe;end loop;end;
  procedure write_reg(a:std_logic_vector(27 downto 0);d:std_logic_vector(31 downto 0);be:std_logic_vector(3 downto 0):="1111") is
  begin master.Adr<=a;master.Din<=d;master.bEna<=be;master.rnw<='0';master.ena<='1';step;master.ena<='0';master.rnw<='1';wait for 1 ns;end;
  procedure wait_phase(phase:natural) is
  begin
   for k in 1 to LATENCY+1000 loop exit when to_integer(unsigned(dbg(31 downto 29)))=phase;step;end loop;
   assert to_integer(unsigned(dbg(31 downto 29)))=phase report "card target phase unreachable" severity failure;
  end;
  procedure command(c:std_logic_vector(7 downto 0);a:natural:=16#8000#;ctl:std_logic_vector(31 downto 0):=x"81010004") is
   variable av:std_logic_vector(31 downto 0):=std_logic_vector(to_unsigned(a,32));
  begin
   write_reg(x"00001A0",x"0000C000","0011");
   write_reg(x"00001A8",av(15 downto 8)&av(23 downto 16)&av(31 downto 24)&c);
   write_reg(x"00001AC",x"000000"&av(7 downto 0));write_reg(x"00001A4",ctl);popped:=0;
  end;
  procedure pop_word(base:natural) is
  begin
   wait_phase(3);master.Adr<=x"0100010";master.rnw<='1';master.ena<='1';wait for 1 ns;
   assert q=pattern(std_logic_vector(to_unsigned(base+popped,27))) report "card resumed ROM word wrong" severity failure;
   step;master.ena<='0';popped:=popped+1;wait for 1 ns;
  end;
  procedure finish_block(base:natural;total:natural:=128) is
  begin for k in popped to total-1 loop pop_word(base);end loop;step(5);assert dbg(28 downto 27)="00" report "card transfer did not finish" severity failure;end;
  procedure zero_command(c:std_logic_vector(7 downto 0)) is
  begin command(c,0,x"80000000");wait_phase(0);step(3);end;
  procedure close_spi is begin write_reg(x"00001A0",x"00000000","0011");step(2);end;
  procedure byte_tx(v:std_logic_vector(7 downto 0);cs:std_logic:='1';wait_done:boolean:=true) is
   variable cnt:std_logic_vector(31 downto 0):=x"0000A000";
  begin
   cnt(6):=cs;write_reg(x"00001A0",cnt,"0011");write_reg(x"00001A0",x"00"&v&x"0000","0100");
   if wait_done then
    for k in 1 to 1000 loop exit when q(7)='0';step;end loop;
    assert q(7)='0' report "card AUXSPI byte timeout" severity failure;
   end if;
   got:=q(23 downto 16);
  end;
  procedure begin_spi(c:std_logic_vector(7 downto 0)) is
  begin close_spi;if infrared='1' then byte_tx(x"00");end if;byte_tx(c);end;
  procedure write_enable is begin begin_spi(x"06");close_spi;end;
  procedure save_address(a:natural) is
   variable av:std_logic_vector(23 downto 0):=std_logic_vector(to_unsigned(a,24));
  begin
   if save_kind/=x"1" and save_kind/=x"2" then byte_tx(av(23 downto 16));end if;
   if save_kind/=x"1" then byte_tx(av(15 downto 8));end if;byte_tx(av(7 downto 0));
  end;
  procedure load_word(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cp_addr<=to_unsigned(a,5);cp_wdata<=d;write_state<='1';step;write_state<='0';step(1+GAP*(1+a mod 3));end;
  procedure new_attempt is
  begin restoring_state<='0';step;restoring_state<='1';step;assert ready='0' report "card stale coverage" severity failure;end;
  procedure load_all is
  begin
   for a in image'range loop
    load_word(a,image(a));if a<WORDS-1 then assert ready='0' report "card partial restore accepted" severity failure;end if;
   end loop;
   assert ready='1' and err='0' report "card complete restore not ready" severity failure;
  end;
  procedure read_image is
  begin
   for a in image'range loop
    cp_addr<=to_unsigned(a,5);wait for 1 ns;assert valid='1' report "card capture unavailable" severity failure;
    if RESTORING then
     if CHECK_IMAGE then assert cp_data=image(a) report "card restored word mismatch "&integer'image(a) severity failure;end if;
    else image(a):=cp_data;end if;
   end loop;
   cp_addr<=to_unsigned(WORDS,5);wait for 1 ns;assert valid='0' and cp_data=x"00000000" report "card undefined capture exposed data" severity failure;
  end;
 begin
  step(4);
  if RESTORING then
   file_open(state_file,"card.state",read_mode);
   for a in image'range loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
   for a in backing_image'range loop readline(state_file,line_buffer);hread(line_buffer,backing_image(a));end loop;
   assert endfile(state_file) report "card extra state words" severity failure;file_close(state_file);
   seed_memory<=backing_image;load_memory<='1';hold<='1';ce<='0';restoring_state<='1';step;load_all;read_image;
   load_word(WORDS,x"00000000");assert err='1' and ready='0' report "card extra word accepted" severity failure;
   for fault in 0 to 20 loop
    new_attempt;
    case fault is
     when 0 => load_word(1,image(1));
     when 1 => load_word(0,image(0));load_word(0,image(0));
     when 2 => load_word(0,(image(0) and x"FFF8FFFF") or x"00060000");
     when 3 => load_word(0,image(0) or x"03000000");
     when 4 =>
      for a in 0 to 7 loop load_word(a,image(a));end loop;
      load_word(8,(image(8) and x"FFFFFFF8") or std_logic_vector(to_unsigned(PREFETCH,32)));
     when 5 =>
      for a in 0 to 13 loop load_word(a,image(a));end loop;load_word(14,x"00010001");
     when 6 => load_word(0,image(0) or x"80000000");
     when 7 => master.ena<='1';step;master.ena<='0';
     when 8 => other_bus.ena<='1';step;other_bus.ena<='0';
     when 9 => bad_ack<='1';step;bad_ack<='0';
     when 10 => hold<='0';step;hold<='1';
     when others =>
      for a in 0 to invalid_addresses(fault-11)-1 loop load_word(a,image(a));end loop;
      load_word(invalid_addresses(fault-11),image(invalid_addresses(fault-11)) or invalid_masks(fault-11));
    end case;
    step;assert err='1' and ready='0' and valid='0' report "card invalid restore accepted" severity failure;
    load_word(0,image(0));assert err='1' and ready='0' report "card poisoned restore recovered" severity failure;
   end loop;
   new_attempt;load_all;read_image;
   if image(10)(29 downto 28)/="00" then
    cache_ready<='0';step(3);assert ready='0' report "card restore ignored backing cache miss" severity failure;
    cache_ready<='1';step;assert ready='1' and err='0' report "card backing cache retry failed" severity failure;
   end if;
   reset<='0';load_memory<='0';restoring_state<='0';step;
   restoring_state<='1';load_word(0,x"00000000");assert err='1' and ready='0' report "card live restore accepted" severity failure;
   restoring_state<='0';step;read_image;
   file_open(trace_file,"card.trace",read_mode);
  else
   reset<='0';step(3);
   case SCENARIO is
    when 0 | 7 => null;
    when 1 to 6 =>
     if SCENARIO=5 then command(x"B7",16#8000#,x"80000000");else command(x"B7");end if;
     if SCENARIO=4 then for k in 1 to 37 loop pop_word(16#2000#);end loop;
     elsif SCENARIO=6 then for k in 1 to 127 loop pop_word(16#2000#);end loop;wait_phase(3);
     else wait_phase(SCENARIO);end if;
     if SCENARIO=3 then step((LATENCY+3)*(PREFETCH+2));end if;
    when 8 to 10 =>
     zero_command(x"3C");if SCENARIO=9 then zero_command(x"00");end if;
     if SCENARIO=10 then
      command(x"20");finish_block(16#1800#);command(x"20");finish_block(16#1C00#);
     end if;
    when 11 to 14 | 22 =>
     write_enable;begin_spi(x"0A");
     if SCENARIO/=11 then byte_tx(x"00");byte_tx(x"01");end if;
     if SCENARIO=13 or SCENARIO=22 then byte_tx(x"FE");byte_tx(x"5A",'1',false);end if;
     if SCENARIO=14 then begin_spi(x"0B");save_address(16#1FD#);end if;
    when 15 => begin_spi(x"0B");byte_tx(x"FE");
    when 16 => write_enable;begin_spi(x"02");save_address(16#1FFF#);byte_tx(x"5A",'1',false);
    when 17 => write_enable;close_spi;byte_tx(x"00");
    when 18 => close_spi;byte_tx(x"08");
    when 19 to 21 =>
     write_enable;if SCENARIO=20 then begin_spi(x"D8");else begin_spi(x"DB");end if;
     byte_tx(x"00");byte_tx(x"12");byte_tx(x"00",'0',false);
     if SCENARIO=21 then
      for k in 1 to 300 loop exit when erase_left=1;step;end loop;
      assert erase_left=1 report "card final erase byte not reached" severity failure;
     else step(17);end if;
    when 23 => command(x"00",0);for k in 1 to 18 loop pop_word(0);end loop;wait_phase(3);
    when others => assert false severity failure;
   end case;
   hold<='1';master<=IDLE_BUS;
   for k in 1 to LATENCY+1100 loop exit when held='1';step;end loop;
   assert held='1' report "card capture failed to drain" severity failure;step(5);read_image;
   file_open(state_file,"card.state",write_mode);
   for a in image'range loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;
   for a in memory'range loop hwrite(line_buffer,memory(a));writeline(state_file,line_buffer);end loop;
   file_close(state_file);file_open(trace_file,"card.trace",write_mode);
  end if;
  popped:=to_integer(unsigned(image(5)(25 downto 13)));
  erase_next<=to_integer(unsigned(image(13)(19 downto 0)));erase_total<=to_integer(unsigned(image(14)(16 downto 0)));step(2);
  if SCENARIO>=19 and SCENARIO<=21 then track_erase<='1';end if;
  recording:=true;observe;hold<='0';ce<='1';step;
  case SCENARIO is
   when 1 to 4 | 6 => finish_block(16#2000#);
   when 5 => wait_phase(0);step(4);
   when 7 => command(x"00",0);finish_block(0);zero_command(x"3C");
   when 10 => command(x"20");finish_block(16#1400#);
   when 11 | 12 | 13 | 22 =>
    if SCENARIO=11 then byte_tx(x"00");byte_tx(x"01");end if;
    if SCENARIO=11 or SCENARIO=12 then byte_tx(x"FE");end if;
    byte_tx(x"A6");byte_tx(x"B7");byte_tx(x"C8",'0');
   when 14 => byte_tx(x"00");assert got=x"00" report "card fast-read dummy lost" severity failure;byte_tx(x"00");assert got=x"18" report "card fast-read first byte wrong" severity failure;
   when 15 => byte_tx(x"00");assert got=x"25" report "card tiny EEPROM address lost" severity failure;byte_tx(x"00");byte_tx(x"00");
   when 16 => byte_tx(x"A6");byte_tx(x"B7",'0');assert memory(0)(15 downto 0)=x"B7A6" report "card EEPROM linear wrap lost" severity failure;
   when 17 => byte_tx(x"0A");save_address(16#1FE#);byte_tx(x"A6",'0');
   when 18 => byte_tx(x"00");assert got=x"AA" report "card IR selector lost" severity failure;
   when 19 to 21 =>
    for k in 1 to erase_total+5 loop step;end loop;
    assert erase_done=erase_total and erase_left=0 report "card erase remaining count lost" severity failure;track_erase<='0';
   when 23 => finish_block(0);zero_command(x"3C");
   when others => null;
  end case;
  if firmware_boot='1' then zero_command(x"00");zero_command(x"00");end if;
  close_spi;
  -- A fresh ROM request proves restored mode/counters allow continued service.
  command(x"B7");finish_block(16#2000#);
  -- Read across page/sector boundaries and past the saturated SPI position.
  begin_spi(x"03");save_address(16#1FC#);
  for k in 1 to 24 loop byte_tx(x"00");end loop;close_spi;
  begin_spi(x"05");byte_tx(x"00",'0');close_spi;step(4);
  if RESTORING then assert endfile(trace_file) report "card extra trace records" severity failure;end if;file_close(trace_file);
  report "CHECKPOINT_CARD_RESTORE_PASS restoring="&boolean'image(RESTORING)&" scenario="&integer'image(SCENARIO)&" owner="&integer'image(OWNER)&
   " prefetch="&integer'image(PREFETCH)&" latency="&integer'image(LATENCY)&" gap="&integer'image(GAP)&" observations="&integer'image(observations);
  std.env.stop;wait;
 end process;
 process begin wait for 20 ms;assert false report "card restore watchdog" severity failure;end process;
end;
