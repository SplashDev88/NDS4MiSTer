-- SPDX-License-Identifier: GPL-3.0-or-later
-- Drained event queues restart empty; epochs and future deliveries persist.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
entity tb_nds_checkpoint_graphics_restore is
 generic(RESTORING:boolean:=false; COMPRESS:boolean:=false; SPARSE:boolean:=false;
         QUEUE_BITS:positive:=2; SCENARIO:natural:=0; GAP:natural:=0; CHECK_IMAGE:boolean:=true);
end;
architecture sim of tb_nds_checkpoint_graphics_restore is
 constant ENABLE:boolean:=true;
   signal request, producers_stopped, stopped : std_logic := '0';
   signal clk, reset, service_ready : std_logic := '0';
   signal timestamp : std_logic_vector(63 downto 0);
   signal current_frame : std_logic_vector(31 downto 0);
   signal source_fault : std_logic;

   signal gpu_source_valid, gpu_source_is_cpu : std_logic := '0';
   signal gpu_source_address : std_logic_vector(27 downto 0) := (others => '0');
   signal gpu_source_access : std_logic_vector(1 downto 0) := "10";
   signal gpu_source_be : std_logic_vector(3 downto 0) := "1111";
   signal gpu_source_data : std_logic_vector(31 downto 0) := (others => '0');
   signal gpu_source_ready, gpu_cpu_complete : std_logic;
   signal gpu_event_valid, gpu_event_ready : std_logic := '0';
   signal gpu_event_address : std_logic_vector(27 downto 0);
   signal gpu_event_access : std_logic_vector(1 downto 0);
   signal gpu_event_be : std_logic_vector(3 downto 0);
   signal gpu_event_data : std_logic_vector(31 downto 0);
   signal gpu_event_scanline : std_logic_vector(8 downto 0);
   signal gpu_event_timestamp : std_logic_vector(63 downto 0);

   signal v9_source_valid : std_logic := '0';
   signal v9_source_address : std_logic_vector(31 downto 0) := (others => '0');
   signal v9_source_access : std_logic_vector(1 downto 0) := "10";
   signal v9_source_be : std_logic_vector(3 downto 0) := "1111";
   signal v9_source_data : std_logic_vector(31 downto 0) := (others => '0');
   signal v9_source_ready, v9_issue : std_logic;
   signal v9_event_valid, v9_event_ready : std_logic := '0';
   signal v9_event_address, v9_event_data : std_logic_vector(31 downto 0);
   signal v9_event_scanline : std_logic_vector(8 downto 0);
   signal v9_event_access : std_logic_vector(1 downto 0);
   signal v9_event_be : std_logic_vector(3 downto 0);
   signal v9_event_timestamp : std_logic_vector(63 downto 0);

   signal v7_source_valid : std_logic := '0';
   signal v7_source_address : std_logic_vector(31 downto 0) := (others => '0');
   signal v7_source_access : std_logic_vector(1 downto 0) := "01";
   signal v7_source_be : std_logic_vector(3 downto 0) := "0011";
   signal v7_source_data : std_logic_vector(31 downto 0) := (others => '0');
   signal v7_source_ready, v7_issue : std_logic;
   signal v7_event_valid, v7_event_ready : std_logic := '0';
   signal v7_event_address, v7_event_data : std_logic_vector(31 downto 0);
   signal v7_event_scanline : std_logic_vector(8 downto 0);
   signal v7_event_access : std_logic_vector(1 downto 0);
   signal v7_event_be : std_logic_vector(3 downto 0);
   signal v7_event_timestamp : std_logic_vector(63 downto 0);

   signal hblank_pulse, hblank_event_valid : std_logic := '0';
   signal hblank_event_ready : std_logic := '0';
   signal hblank_line, hblank_event_line :
      std_logic_vector(8 downto 0) := (others => '0');
   signal hblank_event_frame : std_logic_vector(31 downto 0);
   signal hblank_event_timestamp : std_logic_vector(63 downto 0);

   signal frame_pulse, frame_event_valid, frame_event_ready : std_logic := '0';
   signal frame_event_number : std_logic_vector(31 downto 0);
   signal frame_event_timestamp : std_logic_vector(63 downto 0);
   signal source_fault_reason : std_logic_vector(1 downto 0);
   signal frame_pending_level : std_logic_vector(8 downto 0);
 signal cp_addr:unsigned(2 downto 0):=(others=>'0');
 signal cp_data,cp_wdata:std_logic_vector(31 downto 0);
 signal cp_valid,cp_ready,cp_error:std_logic;
 signal restoring_state,write_state:std_logic:='0';
 signal ref_time:std_logic_vector(63 downto 0);
 signal ref_frame:std_logic_vector(31 downto 0);
 signal ref_fault:std_logic;
 signal ref_reason:std_logic_vector(1 downto 0);
 signal ref_level:std_logic_vector(8 downto 0);
 signal ref_control:std_logic_vector(10 downto 0);
 signal ref_gpu:std_logic_vector(138 downto 0);
 signal ref_v9,ref_v7:std_logic_vector(142 downto 0);
 signal ref_hb:std_logic_vector(104 downto 0);
 signal ref_boundary:std_logic_vector(95 downto 0);

begin
 clk<=not clk after 5 ns;
   dut : entity work.nds_h3d_console_event_gate
   generic map(CHECKPOINT_ENABLE => ENABLE, COMPRESS_HBLANK => COMPRESS,
      SPARSE_HBLANK => SPARSE, GPU_QUEUE_ADDRESS_BITS => QUEUE_BITS)
   port map
   (
      clk => clk, reset => reset, service_ready => service_ready,
      checkpoint_request => request, checkpoint_producers_stopped => producers_stopped,
      checkpoint_stopped => stopped,
      checkpoint_address=>cp_addr, checkpoint_data=>cp_data, checkpoint_valid=>cp_valid,
      checkpoint_restore=>restoring_state, checkpoint_write=>write_state, checkpoint_write_data=>cp_wdata,
      checkpoint_restore_ready=>cp_ready, checkpoint_restore_error=>cp_error,
      timestamp => timestamp, current_frame => current_frame,
      source_fault => source_fault,
      source_fault_reason => source_fault_reason,
      gpu_source_valid => gpu_source_valid,
      gpu_source_is_cpu => gpu_source_is_cpu,
      gpu_source_address => gpu_source_address,
      gpu_source_access => gpu_source_access,
      gpu_source_be => gpu_source_be,
      gpu_source_data => gpu_source_data,
      gpu_source_ready => gpu_source_ready,
      gpu_cpu_complete => gpu_cpu_complete,
      gpu_event_valid => gpu_event_valid,
      gpu_event_ready => gpu_event_ready,
      gpu_event_address => gpu_event_address,
      gpu_event_access => gpu_event_access,
      gpu_event_be => gpu_event_be,
      gpu_event_data => gpu_event_data,
      gpu_event_scanline => gpu_event_scanline,
      gpu_event_timestamp => gpu_event_timestamp,
      vram9_source_valid => v9_source_valid,
      vram9_source_address => v9_source_address,
      vram9_source_access => v9_source_access,
      vram9_source_be => v9_source_be,
      vram9_source_data => v9_source_data,
      vram9_source_ready => v9_source_ready,
      vram9_issue => v9_issue,
      vram9_event_valid => v9_event_valid,
      vram9_event_ready => v9_event_ready,
      vram9_event_address => v9_event_address,
      vram9_event_access => v9_event_access,
      vram9_event_be => v9_event_be,
      vram9_event_data => v9_event_data,
      vram9_event_scanline => v9_event_scanline,
      vram9_event_timestamp => v9_event_timestamp,
      vram7_source_valid => v7_source_valid,
      vram7_source_address => v7_source_address,
      vram7_source_access => v7_source_access,
      vram7_source_be => v7_source_be,
      vram7_source_data => v7_source_data,
      vram7_source_ready => v7_source_ready,
      vram7_issue => v7_issue,
      vram7_event_valid => v7_event_valid,
      vram7_event_ready => v7_event_ready,
      vram7_event_address => v7_event_address,
      vram7_event_access => v7_event_access,
      vram7_event_be => v7_event_be,
      vram7_event_data => v7_event_data,
      vram7_event_scanline => v7_event_scanline,
      vram7_event_timestamp => v7_event_timestamp,
      hblank_pulse => hblank_pulse,
      hblank_line => hblank_line,
      hblank_event_valid => hblank_event_valid,
      hblank_event_ready => hblank_event_ready,
      hblank_event_line => hblank_event_line,
      hblank_event_frame => hblank_event_frame,
      hblank_event_timestamp => hblank_event_timestamp,
      frame_pulse => frame_pulse,
      frame_event_valid => frame_event_valid,
      frame_event_ready => frame_event_ready,
      frame_event_number => frame_event_number,
      frame_event_timestamp => frame_event_timestamp,
      frame_pending_level => frame_pending_level
   );

   reference_gate : entity work.nds_h3d_console_event_gate_reference
   generic map(CHECKPOINT_ENABLE => ENABLE, COMPRESS_HBLANK => COMPRESS,
      SPARSE_HBLANK => SPARSE, GPU_QUEUE_ADDRESS_BITS => QUEUE_BITS)
   port map
   (
      clk => clk, reset => reset, service_ready => service_ready,
      checkpoint_request => request, checkpoint_producers_stopped => producers_stopped,
      checkpoint_stopped => open,
      timestamp => ref_time, current_frame => ref_frame,
      source_fault => ref_fault,
      source_fault_reason => ref_reason,
      gpu_source_valid => gpu_source_valid,
      gpu_source_is_cpu => gpu_source_is_cpu,
      gpu_source_address => gpu_source_address,
      gpu_source_access => gpu_source_access,
      gpu_source_be => gpu_source_be,
      gpu_source_data => gpu_source_data,
      gpu_source_ready => ref_control(0),
      gpu_cpu_complete => ref_control(1),
      gpu_event_valid => ref_control(6),
      gpu_event_ready => gpu_event_ready,
      gpu_event_address => ref_gpu(27 downto 0),
      gpu_event_access => ref_gpu(29 downto 28),
      gpu_event_be => ref_gpu(33 downto 30),
      gpu_event_data => ref_gpu(65 downto 34),
      gpu_event_scanline => ref_gpu(74 downto 66),
      gpu_event_timestamp => ref_gpu(138 downto 75),
      vram9_source_valid => v9_source_valid,
      vram9_source_address => v9_source_address,
      vram9_source_access => v9_source_access,
      vram9_source_be => v9_source_be,
      vram9_source_data => v9_source_data,
      vram9_source_ready => ref_control(2),
      vram9_issue => ref_control(3),
      vram9_event_valid => ref_control(7),
      vram9_event_ready => v9_event_ready,
      vram9_event_address => ref_v9(31 downto 0),
      vram9_event_access => ref_v9(33 downto 32),
      vram9_event_be => ref_v9(37 downto 34),
      vram9_event_data => ref_v9(69 downto 38),
      vram9_event_scanline => ref_v9(78 downto 70),
      vram9_event_timestamp => ref_v9(142 downto 79),
      vram7_source_valid => v7_source_valid,
      vram7_source_address => v7_source_address,
      vram7_source_access => v7_source_access,
      vram7_source_be => v7_source_be,
      vram7_source_data => v7_source_data,
      vram7_source_ready => ref_control(4),
      vram7_issue => ref_control(5),
      vram7_event_valid => ref_control(8),
      vram7_event_ready => v7_event_ready,
      vram7_event_address => ref_v7(31 downto 0),
      vram7_event_access => ref_v7(33 downto 32),
      vram7_event_be => ref_v7(37 downto 34),
      vram7_event_data => ref_v7(69 downto 38),
      vram7_event_scanline => ref_v7(78 downto 70),
      vram7_event_timestamp => ref_v7(142 downto 79),
      hblank_pulse => hblank_pulse,
      hblank_line => hblank_line,
      hblank_event_valid => ref_control(9),
      hblank_event_ready => hblank_event_ready,
      hblank_event_line => ref_hb(8 downto 0),
      hblank_event_frame => ref_hb(40 downto 9),
      hblank_event_timestamp => ref_hb(104 downto 41),
      frame_pulse => frame_pulse,
      frame_event_valid => ref_control(10),
      frame_event_ready => frame_event_ready,
      frame_event_number => ref_boundary(31 downto 0),
      frame_event_timestamp => ref_boundary(95 downto 32),
      frame_pending_level => ref_level
   );


 stimulus:process
  file state_file,trace_file:text;variable line_buffer:line;
  type image_t is array(0 to 3) of std_logic_vector(31 downto 0);variable image:image_t;
  variable actual,reference_value,expected:std_logic_vector(767 downto 0);
  variable recording:boolean:=false;variable observations:natural:=0;
  variable rng:unsigned(31 downto 0):=to_unsigned(7919*(SCENARIO+1),32);
  procedure observe is
  begin
   actual:=(others=>'0');reference_value:=(others=>'0');
   actual(63 downto 0):=timestamp;actual(95 downto 64):=current_frame;
   actual(98 downto 96):=source_fault_reason&source_fault;actual(107 downto 99):=frame_pending_level;
   actual(118 downto 108):=frame_event_valid&hblank_event_valid&v7_event_valid&v9_event_valid&gpu_event_valid&v7_issue&v7_source_ready&v9_issue&v9_source_ready&gpu_cpu_complete&gpu_source_ready;
   if gpu_event_valid='1' then actual(257 downto 119):=gpu_event_timestamp&gpu_event_scanline&gpu_event_data&gpu_event_be&gpu_event_access&gpu_event_address;end if;
   if v9_event_valid='1' then actual(400 downto 258):=v9_event_timestamp&v9_event_scanline&v9_event_data&v9_event_be&v9_event_access&v9_event_address;end if;
   if v7_event_valid='1' then actual(543 downto 401):=v7_event_timestamp&v7_event_scanline&v7_event_data&v7_event_be&v7_event_access&v7_event_address;end if;
   if hblank_event_valid='1' then actual(648 downto 544):=hblank_event_timestamp&hblank_event_frame&hblank_event_line;end if;
   if frame_event_valid='1' then actual(744 downto 649):=frame_event_timestamp&frame_event_number;end if;
   if not RESTORING then
    reference_value(63 downto 0):=ref_time;reference_value(95 downto 64):=ref_frame;
    reference_value(98 downto 96):=ref_reason&ref_fault;reference_value(107 downto 99):=ref_level;reference_value(118 downto 108):=ref_control;
    if ref_control(6)='1' then reference_value(257 downto 119):=ref_gpu;end if;
    if ref_control(7)='1' then reference_value(400 downto 258):=ref_v9;end if;
    if ref_control(8)='1' then reference_value(543 downto 401):=ref_v7;end if;
    if ref_control(9)='1' then reference_value(648 downto 544):=ref_hb;end if;
    if ref_control(10)='1' then reference_value(744 downto 649):=ref_boundary;end if;
    assert actual=reference_value report "graphics pinned baseline differs" severity failure;
   end if;
   if recording then
    if RESTORING then assert not endfile(trace_file) report "graphics trace truncated" severity failure;
     readline(trace_file,line_buffer);hread(line_buffer,expected);
     assert actual=expected report "graphics continuation mismatch at step "&integer'image(observations) severity failure;
    else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;
    observations:=observations+1;
   end if;
  end;
  procedure step(n:natural:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);observe;wait for 2 ns;end loop;end;
  procedure sources_off is
  begin gpu_source_valid<='0';v9_source_valid<='0';v7_source_valid<='0';hblank_pulse<='0';frame_pulse<='0';end;
  procedure sinks_on is
  begin gpu_event_ready<='1';v9_event_ready<='1';v7_event_ready<='1';hblank_event_ready<='1';frame_event_ready<='1';end;
  procedure stream(n:natural) is
  begin
   for k in 0 to n-1 loop
    rng:=rng xor shift_left(rng,13);rng:=rng xor shift_right(rng,17);rng:=rng xor shift_left(rng,5);
    gpu_event_ready<=rng(0);v9_event_ready<=rng(1);v7_event_ready<=rng(2);frame_event_ready<=rng(3);
    if SPARSE then hblank_event_ready<='1';else hblank_event_ready<=rng(4);end if;
    wait for 1 ns;
    gpu_source_valid<=gpu_source_ready and rng(5);gpu_source_is_cpu<=rng(6);
    gpu_source_data<=std_logic_vector(rng);gpu_source_address<=x"0000"&std_logic_vector(rng(11 downto 0));
    gpu_source_access<=std_logic_vector(rng(8 downto 7));gpu_source_be<=std_logic_vector(rng(12 downto 9));
    v9_source_valid<=v9_source_ready and rng(13);v9_source_data<=std_logic_vector(rotate_left(rng,7));v9_source_address<=std_logic_vector(rng xor x"06000000");
    v7_source_valid<=v7_source_ready and rng(14);v7_source_data<=std_logic_vector(rotate_left(rng,11));v7_source_address<=std_logic_vector(rng xor x"06800000");
    hblank_line<=std_logic_vector(to_unsigned((k*11+SCENARIO) mod 263,9));
    hblank_pulse<='0';frame_pulse<='0';if k mod 3=0 then hblank_pulse<='1';end if;if k mod 2=0 then frame_pulse<='1';end if;
    step;
   end loop;
   sources_off;sinks_on;step(1100);
   assert source_fault='0' and unsigned(frame_pending_level)=0 report "graphics fixture did not drain cleanly" severity failure;
  end;
  procedure load_word(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cp_addr<=to_unsigned(a,3);cp_wdata<=d;write_state<='1';step;write_state<='0';step(1+GAP*(a+1));end;
  procedure new_attempt is
  begin restoring_state<='0';step;restoring_state<='1';step;assert cp_ready='0' report "graphics stale coverage" severity failure;end;
  procedure load_all is
  begin for a in image'range loop load_word(a,image(a));if a<3 then assert cp_ready='0' report "graphics partial restore accepted" severity failure;end if;end loop;
   if service_ready='1' then assert cp_ready='1' and cp_error='0' report "graphics complete restore not ready" severity failure;end if;
  end;
  procedure read_image is
  begin for a in image'range loop cp_addr<=to_unsigned(a,3);wait for 1 ns;assert cp_valid='1' report "graphics image unavailable" severity failure;
   if RESTORING then if CHECK_IMAGE then assert cp_data=image(a) report "graphics restored word mismatch "&integer'image(a) severity failure;end if;
   else image(a):=cp_data;end if;step(2);end loop;
   cp_addr<="100";wait for 1 ns;assert cp_valid='0' and cp_data=x"00000000" report "graphics invalid address exposed data" severity failure;
  end;
 begin
  reset<='1';step(4);sinks_on;
  if RESTORING then
   file_open(state_file,"graphics.state",read_mode);for a in image'range loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
   assert endfile(state_file) severity failure;file_close(state_file);
   request<='1';producers_stopped<='1';restoring_state<='1';step;load_all;
   assert cp_ready='0' and cp_error='0' report "graphics missing service accepted" severity failure;
   service_ready<='1';step;assert cp_ready='1' report "graphics restored service did not qualify" severity failure;read_image;
   load_word(4,x"00000000");assert cp_error='1' and cp_ready='0' report "graphics extra word accepted" severity failure;
   for fault in 0 to 8 loop
    new_attempt;
    case fault is
     when 0=>load_word(1,image(1));when 1=>load_word(0,image(0));load_word(0,image(0));
     when 2=>request<='0';step;request<='1';step;
     when 3=>producers_stopped<='0';step;producers_stopped<='1';step;
     when others=>
      case fault is when 4=>gpu_source_valid<='1';when 5=>v9_source_valid<='1';when 6=>v7_source_valid<='1';when 7=>hblank_pulse<='1';when others=>frame_pulse<='1';end case;
      wait for 1 ns;
      assert gpu_source_ready='0' and v9_source_ready='0' and v7_source_ready='0' and gpu_cpu_complete='0' and v9_issue='0' and v7_issue='0' and
       gpu_event_valid='0' and v9_event_valid='0' and v7_event_valid='0' and hblank_event_valid='0' and frame_event_valid='0'
       report "graphics event escaped restore isolation" severity failure;
      step;sources_off;step;
    end case;
    assert cp_error='1' and cp_ready='0' and cp_valid='0' report "graphics invalid restore accepted" severity failure;
    load_word(0,image(0));assert cp_error='1' report "graphics poisoned restore recovered" severity failure;
   end loop;
   -- Independent arithmetic checks exercise bits too high to reach by a
   -- short ordinary run; these synthetic epochs are discarded before replay.
   new_attempt;load_word(0,x"FFFFFFFE");load_word(1,x"12345678");load_word(2,x"FFFFFFFE");load_word(3,x"FFFFFFFE");
   assert cp_ready='1' severity failure;reset<='0';restoring_state<='0';request<='0';producers_stopped<='0';
   frame_pulse<='1';hblank_pulse<='1';hblank_line<=std_logic_vector(to_unsigned(262,9));step(3);
   assert timestamp=x"1234567900000001" and current_frame=x"00000001" and hblank_event_frame=x"00000001"
    report "graphics restored epoch carry failed" severity failure;
   sources_off;request<='1';producers_stopped<='1';reset<='1';new_attempt;load_all;read_image;
   reset<='0';restoring_state<='0';step(4);restoring_state<='1';load_word(0,x"00000000");
   assert cp_error='1' and cp_ready='0' report "graphics live restore accepted" severity failure;
   restoring_state<='0';step;read_image;reset<='1';new_attempt;load_all;read_image;
   reset<='0';restoring_state<='0';step(4);
   file_open(trace_file,"graphics.trace",read_mode);
  else
   reset<='0';service_ready<='1';step(2);
   if SCENARIO>0 then stream(700*SCENARIO);end if;
   -- Leave nonzero queue positions and old records in RAM. No live payload
   -- remains at capture; fresh restore uses reset-empty queue positions.
   request<='1';producers_stopped<='1';step(6);assert stopped='1' report "graphics capture did not qualify" severity failure;read_image;
   file_open(state_file,"graphics.state",write_mode);for a in image'range loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;file_close(state_file);
   file_open(trace_file,"graphics.trace",write_mode);
  end if;
  recording:=true;step(2);request<='0';producers_stopped<='0';step;
  rng:=to_unsigned(104729*(SCENARIO+1),32);stream(1800);
  -- Exercise the held ARM7 stage and a CPU write in the GPU overflow skid.
  v7_event_ready<='0';v7_source_valid<='1';v7_source_address<=x"06001234";v7_source_data<=x"89ABCDEF";step;
  v7_source_valid<='0';step(17);v7_event_ready<='1';step(2);
  gpu_event_ready<='0';gpu_source_is_cpu<='1';gpu_source_valid<='1';
  for k in 0 to 2**QUEUE_BITS loop gpu_source_data<=std_logic_vector(to_unsigned(65536+k,32));step;end loop;
  gpu_source_valid<='0';step(17);gpu_event_ready<='1';step(2**QUEUE_BITS+4);
  -- A newly retained regular run crosses physical line262 with six source
  -- events, including exactly one display-epoch wrap. No future events exist.
  if not SPARSE then hblank_event_ready<='0';end if;
  for k in 0 to 5 loop
   hblank_line<=std_logic_vector(to_unsigned((260+k) mod 263,9));hblank_pulse<='1';step;hblank_pulse<='0';
   if k<5 then step(2129);end if;
  end loop;
  sinks_on;step(20);request<='1';producers_stopped<='1';step(6);
  assert stopped='1' and source_fault='0' report "graphics resumed stream failed to drain" severity failure;
  if RESTORING then assert endfile(trace_file) report "graphics extra trace records" severity failure;end if;file_close(trace_file);
  report "CHECKPOINT_GRAPHICS_RESTORE_PASS restoring="&boolean'image(RESTORING)&" compressed="&boolean'image(COMPRESS)&" sparse="&boolean'image(SPARSE)&" queue_bits="&integer'image(QUEUE_BITS)&" scenario="&integer'image(SCENARIO)&" gap="&integer'image(GAP)&" observations="&integer'image(observations);
  std.env.stop;wait;
 end process;
 process begin wait for 5 ms;assert false report "graphics restore watchdog" severity failure;end process;
end;
