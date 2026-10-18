-- SPDX-License-Identifier: GPL-3.0-or-later
-- Preserve both product GPU readback banks across a fresh process.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_display_restore is
 generic(RESTORING:boolean:=false; ENGINE_B:boolean:=true; SCENARIO:natural:=0;
         GAP:natural:=0; CHECK_IMAGE:boolean:=true);
end;
architecture sim of tb_nds_checkpoint_display_restore is
 signal clk:std_logic:='0';signal reset:std_logic:='1';
 signal bus9:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
 signal q,rq,cp_data,cp_wdata:std_logic_vector(31 downto 0);
 signal done,rdone,idle,valid,ready,err:std_logic;
 signal restoring_state,write_state:std_logic:='0';
 signal cp_addr:unsigned(2 downto 0):=(others=>'0');
begin
 clk<=not clk after 5 ns;bus9.rst<=reset;
 dut:entity work.nds_gpu2d_register_shadow generic map(is_engine_b=>ENGINE_B,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,reset=>reset,gb_bus=>bus9,wired_out=>q,wired_done=>done,checkpoint_idle=>idle,
  checkpoint_address=>cp_addr,checkpoint_data=>cp_data,checkpoint_valid=>valid,checkpoint_restore=>restoring_state,
  checkpoint_write=>write_state,checkpoint_write_data=>cp_wdata,checkpoint_restore_ready=>ready,checkpoint_restore_error=>err);
 reference_display:entity work.nds_gpu2d_register_shadow_reference generic map(is_engine_b=>ENGINE_B)
 port map(clk=>clk,reset=>reset,gb_bus=>bus9,wired_out=>rq,wired_done=>rdone);
 baseline:process
 begin wait until clk'event;wait for 1 ns;
  if not RESTORING then assert q=rq and done=rdone report "display pinned baseline differs" severity failure;end if;
 end process;
 stimulus:process
  file state_file,trace_file:text;variable line_buffer:line;
  type image_t is array(0 to 5) of std_logic_vector(31 downto 0);variable image:image_t;
  type addresses_t is array(0 to 8) of natural;
  constant addresses:addresses_t:=(16#000#,16#008#,16#00C#,16#048#,16#050#,16#06C#,16#040#,16#054#,16#1008#);
  variable actual,expected:std_logic_vector(32 downto 0);
  variable recording:boolean:=false;variable observations:natural:=0;
  variable rng:unsigned(31 downto 0):=to_unsigned(7919*(SCENARIO+1),32);
  procedure observe is
  begin if recording then
   actual:=q&done;
   if RESTORING then assert not endfile(trace_file) severity failure;readline(trace_file,line_buffer);hread(line_buffer,expected);
    assert actual=expected report "display continuation mismatch at step "&integer'image(observations) severity failure;
   else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;observations:=observations+1;
  end if;end;
  procedure step(n:natural:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;observe;end loop;end;
  procedure write_reg(a:natural;d:std_logic_vector(31 downto 0);be:std_logic_vector(3 downto 0):="1111") is
  begin bus9.Adr<=std_logic_vector(to_unsigned(a,28));bus9.Din<=d;bus9.bEna<=be;bus9.rnw<='0';bus9.ena<='1';
   wait for 1 ns;assert idle='0' report "display idle with bus request" severity failure;
   step;bus9.ena<='0';bus9.rnw<='1';step;end;
  procedure load_word(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cp_addr<=to_unsigned(a,3);cp_wdata<=d;write_state<='1';step;write_state<='0';step(1+GAP*(a+1));end;
  procedure new_attempt is
  begin restoring_state<='0';step;restoring_state<='1';step;assert ready='0' report "display stale coverage" severity failure;end;
  procedure load_all is
  begin for a in image'range loop load_word(a,image(a));if a<5 then assert ready='0' report "display partial restore accepted" severity failure;end if;end loop;
   assert ready='1' and err='0' report "display complete restore not ready" severity failure;end;
  procedure read_image is
  begin for a in image'range loop cp_addr<=to_unsigned(a,3);wait for 1 ns;assert valid='1' report "display image unavailable" severity failure;
   if RESTORING then if CHECK_IMAGE then assert cp_data=image(a) report "display restored word mismatch "&integer'image(a) severity failure;end if;
   else image(a):=cp_data;end if;step(2);end loop;
   cp_addr<="110";wait for 1 ns;assert valid='0' and cp_data=x"00000000" report "display invalid address exposed data" severity failure;
  end;
 begin
  step(4);
  if RESTORING then
   file_open(state_file,"display.state",read_mode);for a in image'range loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
   assert endfile(state_file) severity failure;file_close(state_file);restoring_state<='1';step;load_all;read_image;step(17);read_image;
   load_word(6,x"00000000");assert err='1' and ready='0' report "display extra word accepted" severity failure;
   for fault in 0 to 8 loop
    new_attempt;
    case fault is
     when 0 => load_word(1,image(1));
     when 1 => load_word(0,image(0));load_word(0,image(0));
     when 2 => if ENGINE_B then load_word(0,image(0) or x"00000008");else bus9.ena<='1';step;bus9.ena<='0';step;end if;
     when 3 => for a in 0 to 2 loop load_word(a,image(a));end loop;load_word(3,image(3) or x"00000040");
     when 4 => for a in 0 to 3 loop load_word(a,image(a));end loop;load_word(4,image(4) or x"00004000");
     when 5 | 6 | 7 => for a in 0 to 4 loop load_word(a,image(a));end loop;
      if fault=5 then load_word(5,image(5) or x"00000020");elsif fault=6 then load_word(5,image(5) or x"00000100");else load_word(5,image(5) or x"00010000");end if;
     when others => bus9.ena<='1';step;bus9.ena<='0';step;
    end case;
    assert err='1' and ready='0' and valid='0' report "display invalid restore accepted" severity failure;
    load_word(0,image(0));assert err='1' and ready='0' report "display poisoned restore recovered" severity failure;
   end loop;
   new_attempt;load_all;reset<='0';restoring_state<='0';step;
   restoring_state<='1';load_word(0,x"00000000");assert err='1' and ready='0' report "display live restore accepted" severity failure;
   restoring_state<='0';step;read_image;reset<='1';new_attempt;load_all;read_image;reset<='0';restoring_state<='0';step;
   file_open(trace_file,"display.trace",read_mode);
  else
   reset<='0';step;
   if SCENARIO>0 then
    for k in 0 to 63+SCENARIO*13 loop
     rng:=rng xor shift_left(rng,13);rng:=rng xor shift_right(rng,17);rng:=rng xor shift_left(rng,5);
     write_reg(addresses(k mod 9),std_logic_vector(rng),std_logic_vector(to_unsigned(k mod 16,4)));
    end loop;
   end if;
   bus9.Adr<=(others=>'0');step;read_image;
   file_open(state_file,"display.state",write_mode);for a in image'range loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;file_close(state_file);
   file_open(trace_file,"display.trace",write_mode);
  end if;
  recording:=true;observe;
  for a in addresses'range loop bus9.Adr<=std_logic_vector(to_unsigned(addresses(a),28));step(2);end loop;
  -- Include high-address aliasing, read/modify/write and masked byte lanes.
  rng:=to_unsigned(104729*(SCENARIO+1),32);
  for k in 0 to 511 loop
   rng:=rng xor shift_left(rng,13);rng:=rng xor shift_right(rng,17);rng:=rng xor shift_left(rng,5);
   bus9.Adr<=std_logic_vector(to_unsigned(addresses(k mod 9),28));step;
   write_reg(addresses(k mod 9),q xor std_logic_vector(rng),std_logic_vector(rng(3 downto 0)));
  end loop;
  reset<='1';step(3);reset<='0';step;for a in addresses'range loop bus9.Adr<=std_logic_vector(to_unsigned(addresses(a),28));step;end loop;
  if RESTORING then assert endfile(trace_file) severity failure;end if;file_close(trace_file);
  report "CHECKPOINT_DISPLAY_RESTORE_PASS restoring="&boolean'image(RESTORING)&" engine_b="&boolean'image(ENGINE_B)&" scenario="&integer'image(SCENARIO)&" gap="&integer'image(GAP)&" observations="&integer'image(observations);
  std.env.stop;wait;
 end process;
 process begin wait for 1 ms;assert false report "display restore watchdog" severity failure;end process;
end;
