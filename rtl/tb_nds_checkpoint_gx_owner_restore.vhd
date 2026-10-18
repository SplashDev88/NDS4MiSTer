-- SPDX-License-Identifier: GPL-3.0-or-later
-- Fresh-process query/status restoration with a separately persisted cache.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_gx_owner_restore is
 generic(RESTORING:boolean:=false;SCENARIO:natural:=0;GAP:natural:=0;CHECK_IMAGE:boolean:=true);
end;
architecture sim of tb_nds_checkpoint_gx_owner_restore is
 function initial_sequence return std_logic_vector is
 begin if SCENARIO=14 then return x"FFFFFFFE";elsif SCENARIO=13 then return x"FFFFFF00";else return x"00000000";end if;end;
 signal clk:std_logic:='0';signal reset:std_logic:='1';
 signal service,cpu_read,geometry_write,gx_write,response_valid,request_ready:std_logic:='0';
 signal address,gx_address:std_logic_vector(27 downto 0):=(others=>'0');
 signal gx_data,response_id,response_status:std_logic_vector(31 downto 0):=(others=>'0');
 signal selected,busy,complete,fence,request,rselected,rbusy,rcomplete,rfence,rrequest:std_logic;
 signal token,data,rtoken,rdata,cache_data,rcache_data:std_logic_vector(31 downto 0);
 signal index,rindex:std_logic_vector(4 downto 0);signal bits,rbits:std_logic_vector(1 downto 0);
 type cache_t is array(0 to 31) of std_logic_vector(31 downto 0);signal cache:cache_t:=(others=>(others=>'0'));
 signal bus9:proc_bus_gb_type:=((others=>'0'),x"0000600",'1','0',ACCESS_32BIT,"1111",'0');
 signal level:std_logic_vector(8 downto 0):=(others=>'0');signal stack:std_logic_vector(6 downto 0):=(others=>'0');signal geom_busy:std_logic:='0';
 signal sq,rsq:std_logic_vector(31 downto 0);signal sdone,strig,sirq,sack,rsdone,rstrig,rsirq,rsack:std_logic;
 signal idle,valid,ready,err:std_logic_vector(1 downto 0);
 signal restoring_state,cache_ready:std_logic:='0';signal writes:std_logic_vector(1 downto 0):="00";
 signal qaddr:unsigned(2 downto 0):=(others=>'0');signal saddr:unsigned(0 downto 0):=(others=>'0');
 signal qcp,scp,wdata:std_logic_vector(31 downto 0);
begin
 clk<=not clk after 5 ns;bus9.rst<=reset;
 query:entity work.nds_h3d_gx_readback_owner generic map(INITIAL_REQUEST_SEQUENCE=>initial_sequence,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,reset=>reset,service_ready=>service,cpu_read=>cpu_read,address=>address,geometry_write=>geometry_write,
  gx_write=>gx_write,gx_address=>gx_address,gx_data=>gx_data,test_result_bits=>bits,selected=>selected,busy=>busy,complete=>complete,
  read_data=>data,fence_valid=>fence,request_valid=>request,request_ready=>request_ready,request_id=>token,
  response_valid=>response_valid,response_id=>response_id,response_status=>response_status,cache_index=>index,cache_data=>cache_data,
  checkpoint_idle=>idle(0),checkpoint_address=>qaddr,checkpoint_data=>qcp,checkpoint_valid=>valid(0),checkpoint_restore=>restoring_state,
  checkpoint_write=>writes(0),checkpoint_write_data=>wdata,checkpoint_cache_ready=>cache_ready,checkpoint_restore_ready=>ready(0),checkpoint_restore_error=>err(0));
 query_reference:entity work.nds_h3d_gx_readback_owner_reference generic map(INITIAL_REQUEST_SEQUENCE=>initial_sequence)
 port map(clk=>clk,reset=>reset,service_ready=>service,cpu_read=>cpu_read,address=>address,geometry_write=>geometry_write,
  gx_write=>gx_write,gx_address=>gx_address,gx_data=>gx_data,test_result_bits=>rbits,selected=>rselected,busy=>rbusy,complete=>rcomplete,
  read_data=>rdata,fence_valid=>rfence,request_valid=>rrequest,request_ready=>request_ready,request_id=>rtoken,
  response_valid=>response_valid,response_id=>response_id,response_status=>response_status,cache_index=>rindex,cache_data=>rcache_data);
 status_owner:entity work.nds_h3d_gx_status generic map(EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,reset=>reset,service_ready=>service,fifo_level=>level,geometry_busy=>geom_busy,stack_status=>stack,
  stack_ack=>sack,test_result_bits=>bits,gb_bus=>bus9,wired_out=>sq,wired_done=>sdone,trig_gx=>strig,irq_gxfifo=>sirq,
  checkpoint_idle=>idle(1),checkpoint_address=>saddr,checkpoint_data=>scp,checkpoint_valid=>valid(1),checkpoint_restore=>restoring_state,
  checkpoint_write=>writes(1),checkpoint_write_data=>wdata,checkpoint_restore_ready=>ready(1),checkpoint_restore_error=>err(1));
 status_reference:entity work.nds_h3d_gx_status_reference
 port map(clk=>clk,reset=>reset,service_ready=>service,fifo_level=>level,geometry_busy=>geom_busy,stack_status=>stack,
  stack_ack=>rsack,test_result_bits=>rbits,gb_bus=>bus9,wired_out=>rsq,wired_done=>rsdone,trig_gx=>rstrig,irq_gxfifo=>rsirq);
 cache_model:process(clk)
 begin if rising_edge(clk) then cache_data<=cache(to_integer(unsigned(index)));rcache_data<=cache(to_integer(unsigned(rindex)));end if;end process;
 baseline:process
 begin wait until clk'event;wait for 1 ns;
  if not RESTORING then assert (selected&busy&complete&fence&request&token&data&index&bits&sq&sdone&strig&sirq&sack)=
   (rselected&rbusy&rcomplete&rfence&rrequest&rtoken&rdata&rindex&rbits&rsq&rsdone&rstrig&rsirq&rsack)
   report "GX owner pinned baseline differs" severity failure;end if;
 end process;
 stimulus:process
  file state_file,cache_file,trace_file:text;variable line_buffer:line;
  type image_t is array(0 to 6) of std_logic_vector(31 downto 0);variable image:image_t;
  variable cache_image:cache_t;variable actual,expected:std_logic_vector(111 downto 0);
  variable recording:boolean:=false;variable observations:natural:=0;
  procedure observe is
  begin if recording then actual:=selected&busy&complete&fence&request&token&data&index&bits&sq&sdone&strig&sirq&sack;
   if RESTORING then assert not endfile(trace_file) severity failure;readline(trace_file,line_buffer);hread(line_buffer,expected);
    assert actual=expected report "GX owner continuation mismatch at step "&integer'image(observations) severity failure;
   else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;observations:=observations+1;
  end if;end;
  procedure step(n:natural:=1) is begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;observe;end loop;end;
  procedure invalidate is begin geometry_write<='1';step;geometry_write<='0';step;end;
  procedure write_gx(a:natural;d:std_logic_vector(31 downto 0)) is
  begin gx_address<=std_logic_vector(to_unsigned(a,28));gx_data<=d;gx_write<='1';step;gx_write<='0';step;end;
  procedure write_status(a:natural;d:std_logic_vector(31 downto 0);be:std_logic_vector(3 downto 0):="1111";acc:std_logic_vector(1 downto 0):=ACCESS_32BIT) is
  begin bus9.Adr<=std_logic_vector(to_unsigned(a,28));bus9.Din<=d;bus9.bEna<=be;bus9.acc<=acc;bus9.rnw<='0';bus9.ena<='1';step;
   bus9.ena<='0';bus9.rnw<='1';step;end;
  procedure read_query(a:natural;status:std_logic_vector(31 downto 0):=x"00000002";intervening:boolean:=false) is
   variable issued:std_logic_vector(31 downto 0);
  begin
   address<=std_logic_vector(to_unsigned(a,28));cpu_read<='1';step;cpu_read<='0';
   assert busy='1' and complete='0' and idle(0)='0' report "GX query was not held" severity failure;
   if request='1' then
    issued:=token;step(5);assert request='1' and fence='0' report "GX request did not retain ownership" severity failure;
    request_ready<='1';step;request_ready<='0';assert complete='0' and busy='1' report "GX posting retired query" severity failure;
    response_valid<='1';response_id<=std_logic_vector(unsigned(issued)-1);response_status<=x"FFFFFFFF";step(3);response_valid<='0';
    assert complete='0' and busy='1' report "GX stale response accepted" severity failure;
    if intervening then invalidate;write_gx(16#5c0#,x"00000000");end if;
    response_id<=issued;response_status<=status;response_valid<='1';step;response_valid<='0';
   end if;
   step;assert complete='0' report "GX cache returned early" severity failure;step;
   assert complete='1' and busy='0' and idle(0)='0' report "GX reply did not retire exactly once" severity failure;
   step;assert complete='0' and idle(0)='1' report "GX completion did not drain" severity failure;
  end;
  procedure qload(a:natural;d:std_logic_vector(31 downto 0)) is
  begin qaddr<=to_unsigned(a,3);wdata<=d;writes<="01";step;writes<="00";step(1+GAP*(a+1));end;
  procedure sload(a:natural;d:std_logic_vector(31 downto 0)) is
  begin saddr<=to_unsigned(a,1);wdata<=d;writes<="10";step;writes<="00";step(1+GAP);end;
  procedure new_attempt is
  begin restoring_state<='0';step;restoring_state<='1';step;assert ready="00" report "GX stale coverage" severity failure;end;
  procedure load_all is
  begin for a in 0 to 5 loop qload(a,image(a));if a<5 then assert ready(0)='0' report "GX partial restore accepted" severity failure;end if;end loop;
   assert ready(1)='0' report "GX status missing word accepted" severity failure;sload(0,image(6));assert ready(1)='1' and err="00" report "GX complete restore not ready" severity failure;
  end;
  procedure read_image is
  begin for a in 0 to 5 loop qaddr<=to_unsigned(a,3);wait for 1 ns;assert valid(0)='1' report "GX image unavailable" severity failure;
   if RESTORING then if CHECK_IMAGE then assert qcp=image(a) report "GX restored word mismatch "&integer'image(a) severity failure;end if;
   else image(a):=qcp;end if;step;end loop;
   saddr<="0";wait for 1 ns;assert valid(1)='1' report "GX status image unavailable" severity failure;
   if RESTORING then if CHECK_IMAGE then assert scp=image(6) report "GX status restored word mismatch" severity failure;end if;else image(6):=scp;end if;
   qaddr<="110";saddr<="1";wait for 1 ns;assert valid="00" and qcp=x"00000000" and scp=x"00000000" report "GX invalid address exposed data" severity failure;
  end;
 begin
  level<=std_logic_vector(to_unsigned((SCENARIO*17) mod 257,9));stack<=std_logic_vector(to_unsigned((SCENARIO*11) mod 128,7));
  if SCENARIO mod 2=1 then geom_busy<='1';end if;
  step(4);
  if RESTORING then
   file_open(state_file,"gx.state",read_mode);for a in image'range loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;assert endfile(state_file) severity failure;file_close(state_file);
   file_open(cache_file,"gx.cache",read_mode);for a in cache_image'range loop readline(cache_file,line_buffer);hread(line_buffer,cache_image(a));end loop;assert endfile(cache_file) severity failure;file_close(cache_file);
   restoring_state<='1';step;load_all;assert ready(0)='0' report "GX missing service accepted" severity failure;
   service<='1';step;if image(5)(5)='1' then assert ready(0)='0' report "GX missing cache generation accepted" severity failure;end if;
   cache<=cache_image;step(3);cache_ready<='1';step;assert ready="11" report "GX cache restoration did not qualify" severity failure;read_image;
   qload(6,x"00000000");assert err(0)='1' and ready(0)='0' report "GX extra word accepted" severity failure;
   for fault in 0 to 8 loop
    new_attempt;
    case fault is
     when 0=>qload(1,image(1));when 1=>qload(0,image(0));qload(0,image(0));
     when 2|3|4=>for a in 0 to 4 loop qload(a,image(a));end loop;
      if fault=2 then qload(5,image(5) or x"00200000");elsif fault=3 then qload(5,image(5) or x"00007000");else qload(5,image(5) or x"001F8000");end if;
     when 5=>cpu_read<='1';step;cpu_read<='0';step;
     when 6=>geometry_write<='1';step;geometry_write<='0';step;
     when 7=>gx_write<='1';step;gx_write<='0';step;
     when others=>response_valid<='1';step;response_valid<='0';step;
    end case;
    assert err(0)='1' and ready(0)='0' and valid(0)='0' report "GX invalid restore accepted" severity failure;
    qload(0,image(0));assert err(0)='1' report "GX poisoned restore recovered" severity failure;
   end loop;
   for fault in 0 to 4 loop
    new_attempt;
    case fault is
     when 0=>sload(1,image(6));when 1=>sload(0,image(6));sload(0,image(6));
     when 2=>sload(0,image(6) or x"00001000");when 3=>sload(0,image(6) or x"00020000");
     when others=>bus9.ena<='1';step;bus9.ena<='0';step;
    end case;
    assert err(1)='1' and ready(1)='0' report "GX status invalid restore accepted" severity failure;
   end loop;
   new_attempt;load_all;reset<='0';restoring_state<='0';step;restoring_state<='1';qload(0,x"00000000");sload(0,x"00000000");
   assert err="11" and ready="00" report "GX live restore accepted" severity failure;
   restoring_state<='0';step;read_image;reset<='1';new_attempt;load_all;read_image;reset<='0';restoring_state<='0';step;
   address<=x"0000610";bus9.Adr<=x"0000600";step;file_open(trace_file,"gx.trace",read_mode);
  else
   for a in cache'range loop cache(a)<=std_logic_vector(to_unsigned(16#10000000#+SCENARIO*65536+a*257,32));end loop;
   service<='1';reset<='0';step(3);
   write_status(16#600#,std_logic_vector(shift_left(to_unsigned(SCENARIO mod 4,32),30) or x"00008000"));write_status(16#60#,x"00005A95");
   case SCENARIO is
    when 1=>read_query(16#640#);
    when 2=>read_query(16#688#,x"08000002");
    when 3=>read_query(16#67c#);invalidate;
    when 4=>write_gx(16#5c0#,x"00000000");
    when 5|6=>write_gx(16#5c4#,x"00100010");if SCENARIO=5 then read_query(16#600#,x"00000001");else read_query(16#600#);end if;
    when 7=>write_gx(16#400#,x"00007123");write_gx(16#400#,x"00001234");
    when 8=>write_gx(16#400#,x"00007016");for k in 1 to 7 loop write_gx(16#400#,x"12345678");end loop;
    when 9=>write_gx(16#400#,x"00717170");write_gx(16#400#,x"00000001");write_gx(16#400#,x"00000002");
    when 10=>write_gx(16#400#,x"71707034"); -- four commands, all32 SHININESS parameters still pending
    when 11=>write_gx(16#400#,x"00700000");
    when 12=>write_gx(16#400#,x"00000050");
    when 13=>read_query(16#640#);invalidate;read_query(16#68c#);
    when 14=>read_query(16#640#);invalidate;
    when 15=>write_gx(16#5c0#,x"00000001");read_query(16#600#,x"00000002",true);
    when others=>null;
   end case;
   address<=x"0000610";bus9.Adr<=x"0000600";step(3);assert idle="11" report "GX capture boundary missing" severity failure;read_image;
   file_open(state_file,"gx.state",write_mode);for a in image'range loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;file_close(state_file);
   file_open(cache_file,"gx.cache",write_mode);for a in cache'range loop hwrite(line_buffer,cache(a));writeline(cache_file,line_buffer);end loop;file_close(cache_file);
   file_open(trace_file,"gx.trace",write_mode);
  end if;
  recording:=true;observe;
  if SCENARIO=1 or SCENARIO=2 or SCENARIO=3 or SCENARIO=13 then read_query(16#640#);end if;
  for k in 0 to 300 loop level<=std_logic_vector(to_unsigned(k,9));step;end loop;
  bus9.Adr<=x"0000060";step;bus9.Adr<=x"0000600";step;address<=x"0000600";step;
  if SCENARIO/=14 then
   -- Finish any captured command prefix before starting a fresh packet.
   for k in 0 to 39 loop write_gx(16#400#,x"00000000");end loop;
   write_gx(16#5c0#,x"00000000");read_query(16#600#,x"00000002",true);read_query(16#600#);
   for k in 0 to 24 loop read_query(16#640#+4*k);end loop;
   invalidate;read_query(16#688#,x"08000002");read_query(16#688#);
   reset<='1';step(2);reset<='0';step;read_query(16#640#);
  else
   address<=x"0000640";cpu_read<='1';step;cpu_read<='0';response_valid<='1';response_id<=x"FFFFFFFF";
   step(12);assert busy='1' and complete='0' and request='0' and idle(0)='0' report "GX exhausted sequence resumed stale reply" severity failure;
   response_valid<='0';reset<='1';step;reset<='0';step;cpu_read<='1';step;cpu_read<='0';step(7);
   assert busy='1' and request='0' and idle(0)='0' report "GX exhausted sequence reset incorrectly" severity failure;
  end if;
  for mode in 0 to 3 loop
   write_status(16#600#,std_logic_vector(shift_left(to_unsigned(mode,32),30) or x"00008000"));
   for k in 0 to 256 loop level<=std_logic_vector(to_unsigned(k,9));step;end loop;
   write_status(16#60#,x"0000FFFF","0011",ACCESS_8BIT);write_status(16#60#,x"0000FFFF","0001",ACCESS_16BIT);
  end loop;
  if RESTORING then assert endfile(trace_file) severity failure;end if;file_close(trace_file);
  report "CHECKPOINT_GX_OWNER_RESTORE_PASS restoring="&boolean'image(RESTORING)&" scenario="&integer'image(SCENARIO)&" gap="&integer'image(GAP)&" observations="&integer'image(observations);
  std.env.stop;wait;
 end process;
 process begin wait for 2 ms;assert false report "GX owner restore watchdog" severity failure;end process;
end;
