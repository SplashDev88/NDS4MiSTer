-- SPDX-License-Identifier: GPL-3.0-or-later
-- Fresh-process product SPI restore. Capture/continuation also agree with the
-- pinned pre-serializer implementation; backing bytes are independently saved.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_spi_restore is
 generic(RESTORING : boolean := false; SCENARIO : natural := 0;
         GAP : natural := 0; LATENCY : positive := 1500; BAUD : natural := 0;
         CHECK_IMAGE : boolean := true);
end;
architecture sim of tb_nds_checkpoint_spi_restore is
 type memory_t is array(0 to 63) of std_logic_vector(31 downto 0);
 function initial_memory return memory_t is
  variable m : memory_t;
 begin
  for i in m'range loop
   for j in 0 to 3 loop m(i)(j*8+7 downto j*8):=std_logic_vector(to_unsigned((i*4+j)*37 mod 256,8));end loop;
  end loop;return m;
 end;
 signal clk : std_logic := '0';
 signal reset,hold,lid : std_logic := '1';
 signal mic,touch : std_logic := '1';
 signal tx,ty : std_logic_vector(7 downto 0) := x"63";
 signal bus7 : proc_bus_gb_type := ((others=>'0'),x"00001C0",'1','0',ACCESS_32BIT,"0000",'0');
 signal q,rq,dq,fw_data : std_logic_vector(31 downto 0);
 signal req,wr,cs,irq,lirq,done,ack,back_ack,bad_ack,busy : std_logic := '0';
 signal rr,rw,rc,ri,rl,rd,dr,dw,dc,di,dl,dd : std_logic;
 signal addr,ra,da : unsigned(17 downto 2);
 signal lane,rlane,dlane : unsigned(1 downto 0);
 signal wd,rwd,dwd : std_logic_vector(7 downto 0);
 signal cp_addr : unsigned(3 downto 0) := (others=>'0');
 signal cp_data,cp_wdata : std_logic_vector(31 downto 0);
 signal held,valid,ready,err : std_logic;
 signal restoring_state,write_state,load_memory : std_logic := '0';
 signal memory,seed_memory : memory_t := initial_memory;
 signal digest : std_logic_vector(31 downto 0);
begin
 clk<=not clk after 5 ns; ack<=back_ack or bad_ack;
 dut:entity work.nds_nitro_spi generic map(EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,reset=>reset,bus7=>bus7,wired_out7=>q,wired_done7=>done,
  fw_addr=>addr,fw_req=>req,fw_wr=>wr,fw_wlane=>lane,fw_wdata=>wd,
  fw_done=>ack,fw_data=>fw_data,fw_busy=>busy,fw_release=>cs,
  irq_spi=>irq,irq_lid=>lirq,lid_closed=>lid,touch_active=>touch,touch_x=>tx,touch_y=>ty,mic_blow=>mic,
  checkpoint_stop=>hold,checkpoint_stopped=>held,checkpoint_address=>cp_addr,
  checkpoint_data=>cp_data,checkpoint_valid=>valid,checkpoint_restore=>restoring_state,
  checkpoint_write=>write_state,checkpoint_write_data=>cp_wdata,
  checkpoint_restore_ready=>ready,checkpoint_restore_error=>err);
 reference_spi:entity work.nds_nitro_spi_reference generic map(EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,reset=>reset,bus7=>bus7,wired_out7=>rq,wired_done7=>rd,
  fw_addr=>ra,fw_req=>rr,fw_wr=>rw,fw_wlane=>rlane,fw_wdata=>rwd,
  fw_done=>ack,fw_data=>fw_data,fw_busy=>busy,fw_release=>rc,
  irq_spi=>ri,irq_lid=>rl,lid_closed=>lid,touch_active=>touch,touch_x=>tx,touch_y=>ty,mic_blow=>mic,
  checkpoint_stop=>hold);
 disabled_spi:entity work.nds_nitro_spi
 port map(clk=>clk,reset=>reset,bus7=>bus7,wired_out7=>dq,wired_done7=>dd,
  fw_addr=>da,fw_req=>dr,fw_wr=>dw,fw_wlane=>dlane,fw_wdata=>dwd,
  fw_done=>ack,fw_data=>fw_data,fw_busy=>busy,fw_release=>dc,
  irq_spi=>di,irq_lid=>dl,lid_closed=>lid,touch_active=>touch,touch_x=>tx,touch_y=>ty,mic_blow=>mic);
 baseline:process
 begin
  wait until clk'event;wait for 1 ns;
  if not RESTORING then
   assert q=rq and done=rd and addr=ra and req=rr and wr=rw and lane=rlane and wd=rwd and cs=rc and irq=ri and lirq=rl
    report "SPI pinned baseline differs" severity failure;
   -- Physical inputs remain constant during holds in this fixture, so the
   -- disabled instance must match too. Deferred lid changes are tested below
   -- immediately on release, and in the separate hold/drain regression.
   assert q=dq and done=dd and addr=da and req=dr and wr=dw and lane=dlane and wd=dwd and cs=dc and irq=di and lirq=dl
    report "SPI disabled baseline differs" severity failure;
  end if;
 end process;
 backing:process(clk)
  variable remaining : integer := -1;
  variable a,l : natural;
  variable is_write : boolean;
  variable b : std_logic_vector(7 downto 0);
 begin
  if rising_edge(clk) then
   back_ack<='0';
   if reset='1' then
    remaining:=-1;fw_data<=(others=>'0');
    if load_memory='1' then memory<=seed_memory;else memory<=initial_memory;end if;
   else
    if req='1' or wr='1' then
     assert remaining=-1 and not(req='1' and wr='1') report "SPI overlapping backing requests" severity failure;
     a:=to_integer(addr) mod 64;l:=to_integer(lane);is_write:=wr='1';b:=wd;remaining:=LATENCY;
    elsif remaining=0 then
     remaining:=-1;back_ack<='1';
     if is_write then memory(a)(l*8+7 downto l*8)<=b;else fw_data<=memory(a);end if;
    elsif remaining>0 then remaining:=remaining-1;
    end if;
   end if;
  end if;
 end process;
 process(all)
  variable d : std_logic_vector(31 downto 0);
 begin d:=(others=>'0');for i in memory'range loop d:=d xor memory(i);end loop;digest<=d;end process;
 stimulus:process
  file state_file,trace_file : text;
  variable line_buffer : line;
  type image_t is array(0 to 8) of std_logic_vector(31 downto 0);
  variable image : image_t;
  type address_list is array(0 to 4) of natural;
  constant reserved_words : address_list := (3,5,6,7,8);
  variable backing_image : memory_t;
  variable expected,actual : std_logic_vector(97 downto 0);
  variable recording : boolean := false;
  variable observations : natural := 0;
  variable mic_warmup : positive;
  variable got : std_logic_vector(7 downto 0);
  procedure observe is
  begin
   if recording then
    actual:=q & std_logic_vector(addr) & wd & std_logic_vector(lane) & req & wr & cs & irq & lirq & done & busy & ack & digest;
    if RESTORING then
     assert not endfile(trace_file) report "SPI trace truncated" severity failure;
     readline(trace_file,line_buffer);hread(line_buffer,expected);
     assert actual=expected report "SPI continuation mismatch at step "&integer'image(observations) severity failure;
    else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;
    observations:=observations+1;
   end if;
  end;
  procedure step(n:positive:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;observe;end loop;end;
  procedure write_reg(d:std_logic_vector(31 downto 0);be:std_logic_vector(3 downto 0)) is
  begin bus7.Din<=d;bus7.bEna<=be;bus7.rnw<='0';bus7.ena<='1';step;bus7.ena<='0';bus7.rnw<='1';bus7.bEna<="0000";step;end;
  procedure control(d:std_logic_vector(15 downto 0)) is
  begin write_reg(x"0000"&std_logic_vector(unsigned(d) or to_unsigned(BAUD,16)),"0011");end;
  procedure transfer(v:std_logic_vector(7 downto 0)) is
  begin
   write_reg(x"00"&v&x"0000","0100");
   for k in 1 to LATENCY+1100 loop exit when q(7)='0';step;end loop;
   assert q(7)='0' report "SPI byte timeout" severity failure;
   got:=q(23 downto 16);step(2);
  end;
  procedure close_cs is begin control(x"0000");step(2);end;
  procedure address_bytes is begin transfer(x"FF");transfer(x"FF");transfer(x"FD");end;
  procedure load_word(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cp_addr<=to_unsigned(a,4);cp_wdata<=d;write_state<='1';step;write_state<='0';step(1+GAP*(1+a mod 4));end;
  procedure new_attempt is
  begin restoring_state<='0';step;restoring_state<='1';step;assert ready='0' report "SPI stale coverage" severity failure;end;
  procedure load_all is
  begin
   for a in 0 to 8 loop
    load_word(a,image(a));
    if a<8 then assert ready='0' report "SPI partial restore accepted" severity failure;end if;
   end loop;
   assert ready='1' and err='0' report "SPI complete restore not ready" severity failure;
  end;
  procedure read_image is
  begin
   for a in 0 to 8 loop
    cp_addr<=to_unsigned(a,4);wait for 1 ns;
    assert valid='1' report "SPI capture unavailable" severity failure;
    if RESTORING then
     if CHECK_IMAGE then assert cp_data=image(a) report "SPI restored word mismatch "&integer'image(a) severity failure;end if;
    else image(a):=cp_data;end if;
   end loop;
   cp_addr<=to_unsigned(9,4);wait for 1 ns;assert valid='0' and cp_data=x"00000000" report "SPI invalid capture address exposed data" severity failure;
  end;
 begin
  step(4);
  if RESTORING then
   file_open(state_file,"spi.state",read_mode);
   for a in image'range loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
   for a in backing_image'range loop readline(state_file,line_buffer);hread(line_buffer,backing_image(a));end loop;
   assert endfile(state_file) report "SPI extra state words" severity failure;file_close(state_file);
   seed_memory<=backing_image;load_memory<='1';restoring_state<='1';step;load_all;read_image;
   load_word(9,x"00000000");assert err='1' and ready='0' report "SPI extra word accepted" severity failure;
   -- Wrong order, duplicates, invalid addresses/bits and external activity
   -- poison the attempt. Withdrawal plus a full retry is required.
   for fault in 0 to 11 loop
    new_attempt;
    case fault is
     when 0 => load_word(9,x"00000000");
     when 1 => load_word(1,image(1));
     when 2 => load_word(0,image(0));load_word(0,image(0));
     when 3 => load_word(0,image(0) or x"00000080");
     when 4 to 8 =>
      for a in 0 to reserved_words(fault-4)-1 loop load_word(a,image(a));end loop;
      load_word(reserved_words(fault-4),image(reserved_words(fault-4)) or x"80000000");
     when 9 => bus7.ena<='1';step;bus7.ena<='0';
     when 10 => bad_ack<='1';step;bad_ack<='0';
     when others => hold<='0';step;hold<='1';
    end case;
    step;assert err='1' and ready='0' and valid='0' report "SPI invalid restore accepted" severity failure;
    load_word(0,image(0));assert err='1' and ready='0' report "SPI poisoned restore recovered" severity failure;
   end loop;
   new_attempt;load_all;read_image;
   -- A live attempt must neither reset nor overwrite retained component state.
   reset<='0';load_memory<='0';restoring_state<='0';step;
   restoring_state<='1';load_word(0,x"00000000");
   assert err='1' and ready='0' report "SPI live restore accepted" severity failure;
   restoring_state<='0';step;read_image;
   file_open(trace_file,"spi.trace",read_mode);
  else
   reset<='0';hold<='0';step(3);
   if SCENARIO/=0 then
    -- Populate all independent histories before choosing a byte boundary.
    for r in 0 to 7 loop close_cs;control(x"C800");transfer(std_logic_vector(to_unsigned(r,8)));transfer(x"5B");end loop;
    close_cs;control(x"C900");transfer(x"06");close_cs;control(x"C900");transfer(x"0A");address_bytes;transfer(x"A6");transfer(x"B7");
    close_cs;control(x"C900");transfer(x"03");address_bytes;transfer(x"00");close_cs;
    control(x"CA00");
    mic_warmup:=5+SCENARIO mod 4;
    if SCENARIO=16 then mic_warmup:=7;elsif SCENARIO=17 then mic_warmup:=8;end if;
    for k in 1 to mic_warmup loop transfer(x"E8");transfer(x"00");transfer(x"00");end loop;
    close_cs;
   end if;
   case SCENARIO is
    when 0 | 14 => null;
    when 1 => control(x"C800");transfer(x"03");
    when 2 => control(x"C800");transfer(x"80");
    when 3 to 7 =>
     control(x"C900");transfer(x"03");
     if SCENARIO>=4 then transfer(x"FF");end if;
     if SCENARIO>=5 then transfer(x"FF");end if;
     if SCENARIO>=6 then transfer(x"FD");end if;
     if SCENARIO=7 then write_reg(x"00000000","0100");end if;
    when 8 | 9 | 15 =>
     control(x"C900");transfer(x"02");transfer(x"FF");transfer(x"FF");
     if SCENARIO/=8 then transfer(x"FD");write_reg(x"003C0000","0100");end if;
    when 10 => control(x"C900");transfer(x"05");
    when 11 | 12 => control(x"CA00");transfer(x"D0");if SCENARIO=12 then transfer(x"00");end if;
    when others => control(x"CA00");transfer(x"E8");
   end case;
   hold<='1';
   for k in 1 to LATENCY+1100 loop exit when held='1';step;end loop;
   assert held='1' report "SPI capture failed to drain" severity failure;step(5);read_image;
   file_open(state_file,"spi.state",write_mode);
   for a in image'range loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;
   for a in memory'range loop hwrite(line_buffer,memory(a));writeline(state_file,line_buffer);end loop;
   file_close(state_file);file_open(trace_file,"spi.trace",write_mode);
  end if;
  recording:=true;observe;hold<='0';lid<='0';step;
  assert lirq='1' report "SPI restored lid reopen missing" severity failure;step(3);
  case SCENARIO is
   when 1 => transfer(x"02");close_cs;control(x"C800");transfer(x"83");transfer(x"00");assert got=x"02" report "SPI PM command continuation lost" severity failure;
   when 2 => transfer(x"00");assert got=x"5B" report "SPI PM read continuation lost" severity failure;
   when 3 to 7 =>
    if SCENARIO=3 then transfer(x"FF");end if;
    if SCENARIO<=4 then transfer(x"FF");end if;
    if SCENARIO<=5 then transfer(x"FD");end if;
    transfer(x"00");
    if SCENARIO<7 then assert got=x"A6" report "SPI firmware read continuation lost" severity failure;
    else assert got=x"B7" report "SPI firmware next lane lost" severity failure;end if;
    transfer(x"00");transfer(x"00");transfer(x"00");
    if SCENARIO<7 then assert got=x"00" report "SPI firmware 24-bit wrap lost" severity failure;
    else assert got=x"25" report "SPI firmware wrap next byte lost" severity failure;end if;
   when 8 | 9 =>
    if SCENARIO=8 then transfer(x"FD");end if;transfer(x"5A");transfer(x"6B");transfer(x"7C");
   when 10 => busy<='1';transfer(x"00");assert got=x"03" report "SPI status WEL/cache busy lost" severity failure;busy<='0';
   when 11 => transfer(x"00");assert got=x"31" report "SPI TSC high result lost" severity failure;transfer(x"00");assert got=x"80" report "SPI TSC low result lost" severity failure;
   when 12 => transfer(x"00");assert got=x"80" report "SPI TSC phase lost" severity failure;
   when 13 | 16 | 17 => transfer(x"00");transfer(x"00");
   when others => null;
  end case;
  close_cs;
  -- Exercise saved register values, all mic phases and both touch conversions.
  for r in 0 to 7 loop control(x"C800");transfer(std_logic_vector(to_unsigned(128+r,8)));transfer(x"00");close_cs;end loop;
  control(x"CA00");for k in 1 to 25 loop transfer(x"E8");transfer(x"00");transfer(x"00");end loop;
  mic<='0';transfer(x"E0");transfer(x"00");assert got=x"40" report "SPI mic rest value changed" severity failure;transfer(x"00");
  touch<='0';transfer(x"90");transfer(x"00");assert got=x"7F" report "SPI released touch Y changed" severity failure;transfer(x"00");assert got=x"F8" severity failure;
  close_cs;control(x"C900");transfer(x"03");address_bytes;
  for k in 1 to 8 loop transfer(x"00");end loop;close_cs;
  lid<='1';step(5);lid<='0';step(5);assert lirq='0' report "SPI lid IRQ repeated" severity failure;
  if RESTORING then assert endfile(trace_file) report "SPI trace has extra records" severity failure;end if;
  file_close(trace_file);
  report "CHECKPOINT_SPI_RESTORE_PASS restoring="&boolean'image(RESTORING)&" scenario="&integer'image(SCENARIO)&" gap="&integer'image(GAP)&" observations="&integer'image(observations);
  std.env.stop;wait;
 end process;
 process begin wait for 20 ms;assert false report "SPI restore watchdog" severity failure;end process;
end;
