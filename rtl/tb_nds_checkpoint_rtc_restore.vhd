-- SPDX-License-Identifier: GPL-3.0-or-later
-- Fresh-process RTC restore, including partially shifted serial commands.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_rtc_restore is
 generic(RESTORING : boolean := false; SCENARIO : natural := 0;
         GAP : natural := 0; CHECK_IMAGE : boolean := true; SECOND_CLOCKS : positive := 4096);
end;
architecture sim of tb_nds_checkpoint_rtc_restore is
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal fw : std_logic := '1';
 signal seed_data,datetime,reference_date,snapshot : std_logic_vector(55 downto 0) := (others=>'0');
 signal seed_toggle,changed,reference_changed : std_logic := '0';
 signal request,ready,done,reference_done,valid,restore_ready,err : std_logic := '0';
 signal restoring_state,write_state : std_logic := '0';
 signal cp_addr : unsigned(3 downto 0) := (others=>'0');
 signal cp_data,cp_wdata : std_logic_vector(31 downto 0);
 signal fraction : unsigned(31 downto 0);
 signal q,reference_q : std_logic_vector(31 downto 0);
 signal bus7 : proc_bus_gb_type := ((others=>'0'),x"0000138",'1','0',ACCESS_16BIT,"0000",'0');
 signal cycles,sample_cycle : natural := 0;
 subtype byte_t is std_logic_vector(7 downto 0);
 type bytes_t is array(natural range <>) of byte_t;
 constant READ_COMMANDS : bytes_t := (x"86",x"C6",x"A6",x"E6",x"96",x"D6",x"B6",x"F6");
begin
 clk<=not clk after 5 ns;
 dut:entity work.nds_nitro_rtc generic map(CYCLES_PER_SECOND=>SECOND_CLOCKS,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>'1',reset=>reset,fw_boot=>fw,rtc_seed=>seed_data,rtc_seed_toggle=>seed_toggle,
  rtc_datetime=>datetime,date_written=>changed,bus7=>bus7,wired_out7=>q,wired_done7=>done,
  checkpoint_request=>request,checkpoint_ready=>ready,checkpoint_datetime=>snapshot,checkpoint_subsecond=>fraction,
  checkpoint_address=>cp_addr,checkpoint_data=>cp_data,checkpoint_valid=>valid,checkpoint_restore=>restoring_state,
  checkpoint_write=>write_state,checkpoint_write_data=>cp_wdata,checkpoint_restore_ready=>restore_ready,checkpoint_restore_error=>err);
 reference_rtc:entity work.nds_nitro_rtc_reference generic map(CYCLES_PER_SECOND=>SECOND_CLOCKS)
 port map(clk=>clk,ce=>'1',reset=>reset,fw_boot=>fw,rtc_seed=>seed_data,rtc_seed_toggle=>seed_toggle,
  rtc_datetime=>reference_date,date_written=>reference_changed,bus7=>bus7,wired_out7=>reference_q,wired_done7=>reference_done);
 comparison:process
 begin
  wait until clk'event;wait for 1 ns;
  if not RESTORING then
   assert datetime=reference_date and changed=reference_changed and q=reference_q and done=reference_done
    report "RTC pinned baseline differs" severity failure;
  end if;
 end process;
 sampling:process
  variable was_ready : std_logic;
  variable old_cycle : natural;
 begin
  wait until rising_edge(clk);was_ready:=ready;old_cycle:=cycles;cycles<=cycles+1;wait for 1 ns;
  if ready='1' and was_ready='0' then sample_cycle<=old_cycle;end if;
 end process;
 stimulus:process
  alias live_fraction is << signal .tb_nds_checkpoint_rtc_restore.dut.sec_div : integer range 0 to SECOND_CLOCKS-1 >>;
  file state_file,trace_file : text;
  variable line_buffer : line;
  type image_t is array(0 to 8) of std_logic_vector(31 downto 0);
  variable image : image_t;
  variable actual,expected : std_logic_vector(121 downto 0);
  variable recording : boolean := false;
  variable observations,lag,saved_fraction : natural := 0;
  variable saved_date : std_logic_vector(55 downto 0);
  variable saved_phase : std_logic;
  procedure observe is
  begin
   if recording then
    actual:=datetime & std_logic_vector(to_unsigned(live_fraction,32)) & changed & q & done;
    if RESTORING then
     assert not endfile(trace_file) report "RTC trace truncated" severity failure;
     readline(trace_file,line_buffer);hread(line_buffer,expected);
     assert actual=expected report "RTC continuation mismatch at step "&integer'image(observations)&
      " actual="&to_hstring(actual)&" expected="&to_hstring(expected) severity failure;
    else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;
    observations:=observations+1;
   end if;
  end;
  procedure step(n:natural:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;observe;end loop;end;
  procedure poke(v:byte_t) is
  begin
   bus7.Din<=x"000000"&v;bus7.ena<='1';bus7.rnw<='0';bus7.bEna<="0001";
   step;bus7.ena<='0';bus7.rnw<='1';step;
  end;
  procedure begin_serial is begin poke(x"10");poke(x"16");end;
  procedure send_bits(v:byte_t;lo:natural:=0;hi:natural:=7) is
   variable bits : byte_t;
  begin
   for b in lo to hi loop bits:=x"16";bits(0):=v(b);poke(bits);bits(1):='0';poke(bits);end loop;
  end;
  procedure receive_bits(n:natural) is
  begin for b in 1 to n loop poke(x"06");poke(x"04");end loop;end;
  procedure register_write(cmd:byte_t;data:bytes_t) is
  begin begin_serial;send_bits(cmd);for b in data'range loop send_bits(data(b));end loop;poke(x"10");end;
  procedure seed(v:std_logic_vector(55 downto 0)) is
  begin seed_data<=v;step(2);seed_toggle<=not seed_toggle;step(8);end;
  procedure load_word(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cp_addr<=to_unsigned(a,4);cp_wdata<=d;write_state<='1';step;write_state<='0';step(1+GAP*(a+1));end;
  procedure new_attempt is
  begin restoring_state<='0';step;restoring_state<='1';step;assert restore_ready='0' report "RTC stale coverage" severity failure;end;
  procedure load_all(expect_ready:boolean:=true) is
  begin
   for a in image'range loop
    load_word(a,image(a));if a<8 then assert restore_ready='0' report "RTC partial restore accepted" severity failure;end if;
   end loop;step(8);
   if expect_ready then assert restore_ready='1' and err='0' report "RTC complete restore not ready" severity failure;end if;
  end;
  procedure read_image is
  begin
   for a in image'range loop
    cp_addr<=to_unsigned(a,4);wait for 1 ns;assert valid='1' report "RTC image unavailable" severity failure;
    if RESTORING then
     if CHECK_IMAGE then assert cp_data=image(a) report "RTC restored word mismatch "&integer'image(a) severity failure;end if;
    else image(a):=cp_data;end if;
    step(3+a);
   end loop;
   cp_addr<="1001";wait for 1 ns;assert valid='0' and cp_data=x"00000000" report "RTC undefined word exposed data" severity failure;
  end;
 begin
  if SCENARIO mod 2=1 then fw<='0';end if;step(4);
  if RESTORING then
   file_open(state_file,"rtc.state",read_mode);
   for a in image'range loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
   readline(state_file,line_buffer);read(line_buffer,lag);
   assert endfile(state_file) report "RTC extra state words" severity failure;file_close(state_file);
   -- A dormant payload need not equal the old seed. The sender phase MUST.
   seed_data<=x"01010101010101";seed_toggle<=image(1)(29);restoring_state<='1';step;load_all;read_image;
   saved_date:=datetime;saved_fraction:=live_fraction;step(SECOND_CLOCKS+17);
   assert datetime=saved_date and live_fraction=saved_fraction report "RTC advanced during restore" severity failure;
   load_word(9,x"00000000");assert err='1' and restore_ready='0' report "RTC extra word accepted" severity failure;
   for fault in 0 to 11 loop
    new_attempt;
    case fault is
     when 0 => load_word(1,image(1));
     when 1 => load_word(0,image(0));load_word(0,image(0));
     when 2 => load_word(0,image(0));load_word(1,image(1) or x"00001C00");
     when 3 => for a in 0 to 4 loop load_word(a,image(a));end loop;load_word(5,image(5) or x"01000000");
     when 4 | 5 | 6 | 7 =>
      for a in 0 to 5 loop load_word(a,image(a));end loop;
      case fault is
       when 4 => load_word(6,(image(6) and x"FFFFFF00") or x"000000FA");
       when 5 => load_word(6,(image(6) and x"FFFF00FF"));
       when 6 => load_word(6,(image(6) and x"FF00FFFF") or x"00320000");
       when others => load_word(6,(image(6) and x"00FFFFFF") or x"07000000");
      end case;
     when 8 | 9 =>
      for a in 0 to 6 loop load_word(a,image(a));end loop;
      if fault=8 then load_word(7,image(7) or x"01000000");else load_word(7,x"00606024");end if;
     when 10 => for a in 0 to 7 loop load_word(a,image(a));end loop;load_word(8,std_logic_vector(to_unsigned(SECOND_CLOCKS,32)));
     when others => bus7.ena<='1';step;bus7.ena<='0';step;
    end case;
    assert err='1' and restore_ready='0' and valid='0' report "RTC invalid restore accepted" severity failure;
    load_word(0,image(0));assert err='1' and restore_ready='0' report "RTC poisoned restore recovered" severity failure;
   end loop;
   -- A mismatched host seed phase cannot qualify, then can settle safely.
   new_attempt;seed_toggle<=not image(1)(29);load_all(false);
   assert restore_ready='0' and err='0' report "RTC unmatched seed phase accepted" severity failure;
   seed_toggle<=image(1)(29);step(10);assert restore_ready='1' report "RTC corrected seed phase did not settle" severity failure;read_image;
   -- Reject live writes before final reload, so failed attempts do not alter
   -- the reference timeline. No reset defaults may overwrite final state.
   reset<='0';restoring_state<='0';step;restoring_state<='1';load_word(0,x"00000000");
   assert err='1' and restore_ready='0' report "RTC live restore accepted" severity failure;
   request<='1';restoring_state<='0';step(7);cp_addr<="0000";wait for 1 ns;
   assert valid='1' report "RTC live restore lost sampling" severity failure;
   if CHECK_IMAGE then assert cp_data=image(0) report "RTC live restore mutated serial state" severity failure;end if;
   request<='0';reset<='1';new_attempt;load_all;read_image;
   reset<='0';restoring_state<='0';step(lag);
   file_open(trace_file,"rtc.trace",read_mode);
  else
   reset<='0';step(3);
   if SCENARIO>=2 then
    seed(x"59582305310124");if SCENARIO mod 2=0 then seed(x"59582305310124");end if;
    register_write(x"46",(0=>x"A4"));
    register_write(x"16",(x"91",x"B2",x"D3"));register_write(x"56",(x"84",x"A5",x"C6"));
    register_write(x"36",(0=>x"5A"));register_write(x"76",(0=>x"E7"));
    if SCENARIO mod 3=0 then register_write(x"06",(0=>x"00"));end if;
    -- Exercise both notification phases without keeping the setup time.
    if SCENARIO mod 2=1 then register_write(x"66",(x"63",x"58",x"59"));end if;
    seed(x"59582305310124");
    case SCENARIO is
     when 2 => begin_serial;send_bits(x"A6",0,2);
     when 3 => begin_serial;send_bits(x"26");send_bits(x"25",0,5);
     when 4 => begin_serial;send_bits(x"26");send_bits(x"25");send_bits(x"02");
      assert datetime(23 downto 0)=x"310225" report "RTC partial invalid date fixture missing" severity failure;
     when 5 => begin_serial;send_bits(x"66");send_bits(x"63");send_bits(x"58");send_bits(x"57",0,2);
     when 6 => begin_serial;send_bits(x"A6");receive_bits(11);
     when 7 => begin_serial;send_bits(x"A6");receive_bits(51);
     when 8 => begin_serial;send_bits(x"96");receive_bits(9);
     when 9 => begin_serial;send_bits(x"D6");receive_bits(17);
     when 10 => begin_serial;send_bits(x"F6");receive_bits(3);
     when 11 => begin_serial;send_bits(x"86");receive_bits(2);
     when 12 => begin_serial;send_bits(x"C6");receive_bits(2);
     when 13 => begin_serial;send_bits(x"B6");receive_bits(5);
     when 14 => begin_serial;send_bits(x"16");send_bits(x"12");send_bits(x"34",0,4);
     when 15 => begin_serial;send_bits(x"00");for k in 1 to 20 loop send_bits(x"A5");end loop;
     when 16 => seed(x"59592304123199");step(SECOND_CLOCKS-40);
     when 17 => register_write(x"06",(0=>x"00"));begin_serial;send_bits(x"E6");receive_bits(6);
     when 18 => begin_serial;send_bits(x"06");send_bits(x"03",0,4);
     when 19 => register_write(x"46",(0=>x"00"));begin_serial;send_bits(x"96");receive_bits(3);
     when others => null;
    end case;
   end if;
   request<='1';for k in 1 to 20 loop exit when ready='1';step;end loop;
   assert ready='1' report "RTC sample timeout" severity failure;read_image;request<='0';step;
   -- Snapshot is pre-edge; count every subsequent live tick, including the
   -- sample edge and the deliberately slow image read. Restore replays ONLY
   -- these quiet ticks, not a seed or the prior serial command prefix.
   lag:=cycles-sample_cycle;
   file_open(state_file,"rtc.state",write_mode);
   for a in image'range loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;
   write(line_buffer,lag);writeline(state_file,line_buffer);file_close(state_file);
   file_open(trace_file,"rtc.trace",write_mode);
  end if;
  recording:=true;observe;step(SECOND_CLOCKS+19);
  -- Complete exactly the interrupted command before replacing its context.
  case SCENARIO is
   when 2 => send_bits(x"A6",3,7);receive_bits(56);
   when 3 => send_bits(x"25",6,7);send_bits(x"02");send_bits(x"28");send_bits(x"05");send_bits(x"63");send_bits(x"59");send_bits(x"58");
   when 4 => send_bits(x"28");send_bits(x"05");send_bits(x"63");send_bits(x"59");send_bits(x"58");
   when 5 => send_bits(x"57",3,7);
   when 6 => receive_bits(45);
   when 7 => receive_bits(5);
   when 14 => send_bits(x"34",5,7);send_bits(x"56");
   when 18 => send_bits(x"03",5,7);
   when others => receive_bits(56);
  end case;
  poke(x"10");
  for c in READ_COMMANDS'range loop begin_serial;send_bits(READ_COMMANDS(c));receive_bits(56);poke(x"10");end loop;
  step(SECOND_CLOCKS*2+31);
  reset<='1';step(3);reset<='0';step;
  begin_serial;send_bits(x"86");receive_bits(8);poke(x"10");
  saved_phase:=changed;seed(x"57592304290224");assert changed=saved_phase report "RTC seed emitted guest notification" severity failure;
  step(SECOND_CLOCKS*3+7);assert datetime=x"00000005010324" report "RTC seed/rollover after restore failed" severity failure;
  -- Ordinary guest reset still advances the clock and observes seed_valid.
  reset<='1';step(SECOND_CLOCKS+3);reset<='0';step(3);
  begin_serial;send_bits(x"86");receive_bits(8);poke(x"10");
  if RESTORING then assert endfile(trace_file) report "RTC extra trace records" severity failure;end if;file_close(trace_file);
  report "CHECKPOINT_RTC_RESTORE_PASS restoring="&boolean'image(RESTORING)&" scenario="&integer'image(SCENARIO)&
   " gap="&integer'image(GAP)&" lag="&integer'image(lag)&" observations="&integer'image(observations);
  std.env.stop;wait;
 end process;
 process begin wait for 10 ms;assert false report "RTC restore watchdog" severity failure;end process;
end;
