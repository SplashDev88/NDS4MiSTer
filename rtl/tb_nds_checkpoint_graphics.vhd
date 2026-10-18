library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_nds_checkpoint_graphics is
   generic (ENABLE : boolean := true; COMPRESS : boolean := false;
      SPARSE : boolean := false; QUEUE_BITS : positive := 2; DELAY : positive := 1);
end entity;

architecture sim of tb_nds_checkpoint_graphics is
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
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_h3d_console_event_gate
   generic map(CHECKPOINT_ENABLE => ENABLE, COMPRESS_HBLANK => COMPRESS,
      SPARSE_HBLANK => SPARSE, GPU_QUEUE_ADDRESS_BITS => QUEUE_BITS)
   port map
   (
      clk => clk, reset => reset, service_ready => service_ready,
      checkpoint_request => request, checkpoint_producers_stopped => producers_stopped,
      checkpoint_stopped => stopped,
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

   stimulus : process
      type event_record is record
         data : std_logic_vector(31 downto 0);
         line : std_logic_vector(8 downto 0);
         stamp : std_logic_vector(63 downto 0);
      end record;
      type events is array(0 to 2047) of event_record;
      variable gpu, v9, v7, hb, frame : events;
      variable gw, gr, vw9, vr9, vw7, vr7, hw, hr, fw, fr : natural := 0;
      variable completions, guest_frames, display_frames, cycles : natural := 0;
      variable before_time, freeze_time : std_logic_vector(63 downto 0);
      variable should_freeze : boolean;
      variable input_line : natural;
      procedure append(variable q : inout events; variable n : inout natural;
                       d : std_logic_vector(31 downto 0); l : std_logic_vector(8 downto 0)) is
      begin
         q(n) := (d, l, timestamp); n := n + 1;
      end procedure;
      procedure tick is
      begin
         wait until rising_edge(clk);
         before_time := timestamp;
         should_freeze := ENABLE and reset = '0' and request = '1' and producers_stopped = '1' and
            gpu_source_valid = '0' and v9_source_valid = '0' and v7_source_valid = '0' and
            hblank_pulse = '0' and frame_pulse = '0';
         if reset = '0' and service_ready = '1' then
            if gpu_cpu_complete = '1' then completions := completions + 1; end if;
            if gpu_event_valid = '1' and gpu_event_ready = '1' then
               assert gr < gw report "unexpected GPU event" severity failure;
               assert gpu_event_data = gpu(gr).data and gpu_event_timestamp = gpu(gr).stamp and
                  gpu_event_scanline = gpu(gr).line and gpu_event_address = x"0000400" and
                  gpu_event_access = "10" and gpu_event_be = "1111"
                  report "GPU record order/payload/timestamp changed" severity failure;
               gr := gr + 1;
            end if;
            if v9_event_valid = '1' and v9_event_ready = '1' then
               assert vr9 < vw9 report "unexpected VRAM9 event" severity failure;
               assert v9_event_data = v9(vr9).data and v9_event_timestamp = v9(vr9).stamp and
                  v9_event_scanline = v9(vr9).line and v9_event_address = x"06800100"
                  report "VRAM9 record changed" severity failure;
               vr9 := vr9 + 1;
            end if;
            if v7_event_valid = '1' and v7_event_ready = '1' then
               assert vr7 < vw7 report "unexpected VRAM7 event" severity failure;
               assert v7_event_data = v7(vr7).data and v7_event_timestamp = v7(vr7).stamp and
                  v7_event_scanline = v7(vr7).line and v7_event_address = x"06000200"
                  report "VRAM7 record changed" severity failure;
               vr7 := vr7 + 1;
            end if;
            if hblank_event_valid = '1' and hblank_event_ready = '1' then
               assert hr < hw report "unexpected HBlank event" severity failure;
               assert hblank_event_frame = hb(hr).data and hblank_event_timestamp = hb(hr).stamp and
                  hblank_event_line = hb(hr).line report "HBlank record changed" severity failure;
               hr := hr + 1;
            end if;
            if frame_event_valid = '1' and frame_event_ready = '1' then
               assert fr < fw report "unexpected frame event" severity failure;
               assert frame_event_number = frame(fr).data and frame_event_timestamp = frame(fr).stamp
                  report "frame record changed" severity failure;
               fr := fr + 1;
            end if;
         end if;
         wait for 1 ns;
         cycles := cycles + 1;
         if reset = '0' then
            if should_freeze then
               assert timestamp = before_time report "graphics clock moved while producers stopped" severity failure;
            else
               assert unsigned(timestamp) = unsigned(before_time) + 1
                  report "graphics clock stopped before producers" severity failure;
            end if;
         end if;
      end procedure;
      procedure clocks(n : natural) is
      begin for i in 1 to n loop tick; end loop; end procedure;
      procedure qualify is
      begin
         clocks(4);
         if ENABLE then
            assert stopped = '1' report "drained graphics owner did not stop" severity failure;
         else
            assert stopped = '0' report "disabled graphics owner acknowledged" severity failure;
         end if;
      end procedure;
      procedure gpu_post(d : natural) is
      begin
         gpu_source_data <= std_logic_vector(to_unsigned(d,32)); gpu_source_valid <= '1';
         append(gpu,gw,std_logic_vector(to_unsigned(d,32)),hblank_line);
         tick; gpu_source_valid <= '0';
      end procedure;
      procedure hblank_post(l : natural) is
      begin
         hblank_line <= std_logic_vector(to_unsigned(l,9)); hblank_pulse <= '1';
         if not SPARSE or l = 0 or l = 192 then
            append(hb,hw,std_logic_vector(to_unsigned(display_frames,32)),std_logic_vector(to_unsigned(l,9)));
         end if;
         tick; hblank_pulse <= '0';
         if l = 262 then display_frames := display_frames + 1; end if;
      end procedure;
      procedure frame_post is
      begin
         guest_frames := guest_frames + 1; frame_pulse <= '1';
         append(frame,fw,std_logic_vector(to_unsigned(guest_frames,32)),hblank_line);
         tick; frame_pulse <= '0';
      end procedure;
      procedure check_no_records is
      begin
         assert gr = gw and vr9 = vw9 and vr7 = vw7 and hr = hw and fr = fw
            report "accepted graphics records lost" severity failure;
         assert completions = gw report "CPU posting completed missing or duplicate writes" severity failure;
      end procedure;
   begin
      reset <= '1'; service_ready <= '1'; clocks(2); reset <= '0';
      gpu_source_is_cpu <= '1'; gpu_source_address <= x"0000400";
      v9_source_address <= x"06800100"; v7_source_address <= x"06000200";
      if SPARSE then hblank_event_ready <= '1'; end if;
      clocks(DELAY);
      request <= '1'; -- Request alone must not stop active producers.
      for n in 0 to 2 ** QUEUE_BITS loop gpu_post(n+100); end loop;
      -- The last one-cycle CPU write is retained in the overflow skid. Both
      -- VRAM paths and the timing queues are independently stalled as well.
      v9_source_valid <= '1'; v9_source_data <= x"12345678";
      v7_source_valid <= '1'; v7_source_data <= x"CAFEBABE";
      append(v9,vw9,x"12345678",hblank_line); append(v7,vw7,x"CAFEBABE",hblank_line);
      tick; v9_source_valid <= '0'; v7_source_valid <= '0';
      for n in 0 to 8 loop
         if n = 4 then input_line := 262; elsif n = 5 then input_line := 0; else input_line := n+1; end if;
         hblank_post(input_line); clocks(DELAY);
         if n mod 3 = 0 then frame_post; end if;
      end loop;
      assert stopped = '0' report "active producers falsely stopped" severity failure;
      producers_stopped <= '1'; clocks(19);
      assert stopped = '0' report "pending queues falsely stopped" severity failure;
      -- Drain each source separately, leaving the others blocked. In dense
      -- modes HBlank is deliberately last, including the compressed queue.
      gpu_event_ready <= '1'; clocks(2 ** QUEUE_BITS+4);
      assert stopped = '0' report "pending VRAM queues falsely stopped" severity failure;
      v9_event_ready <= '1'; clocks(4);
      assert stopped = '0' report "pending VRAM7 queue falsely stopped" severity failure;
      v7_event_ready <= '1'; clocks(4);
      assert stopped = '0' report "pending frame queue falsely stopped" severity failure;
      frame_event_ready <= '1'; clocks(7);
      if not SPARSE then
         assert stopped = '0' report "pending HBlank queue falsely stopped" severity failure;
      end if;
      hblank_event_ready <= '1'; clocks(12);
      qualify; check_no_records;
      freeze_time := timestamp;
      clocks(100);
      if ENABLE then assert timestamp = freeze_time report "held timestamp changed" severity failure; end if;
      -- Every late producer revokes readiness in the same cycle. Work still
      -- retires once; downstream queues never flush to manufacture an ack.
      for source in 0 to 4 loop
         case source is
            when 0 => gpu_source_valid <= '1'; gpu_source_data <= x"76543210";
               append(gpu,gw,x"76543210",hblank_line);
            when 1 => v9_source_valid <= '1'; v9_source_data <= x"AABBCCDD";
               append(v9,vw9,x"AABBCCDD",hblank_line);
            when 2 => v7_source_valid <= '1'; v7_source_data <= x"BAADF00D";
               append(v7,vw7,x"BAADF00D",hblank_line);
            when 3 => hblank_pulse <= '1'; hblank_line <= (others => '0');
               append(hb,hw,std_logic_vector(to_unsigned(display_frames,32)),(others => '0'));
            when others => frame_pulse <= '1'; guest_frames := guest_frames + 1;
               append(frame,fw,std_logic_vector(to_unsigned(guest_frames,32)),hblank_line);
         end case;
         wait for 1 ns;
         assert stopped = '0' report "late producer did not revoke graphics readiness" severity failure;
         tick;
         gpu_source_valid <= '0'; v9_source_valid <= '0'; v7_source_valid <= '0';
         hblank_pulse <= '0'; frame_pulse <= '0';
         qualify; check_no_records;
      end loop;
      -- Cancellation retains queued work and immediately restarts virtual
      -- time. A following attempt must acquire independently.
      request <= '0'; producers_stopped <= '0'; clocks(2);
      gpu_event_ready <= '0'; gpu_post(999); request <= '1'; producers_stopped <= '1'; clocks(7);
      assert stopped = '0' report "cancel scenario falsely ready" severity failure;
      request <= '0'; clocks(9);
      assert gpu_event_valid = '1' report "cancel discarded GPU record" severity failure;
      gpu_event_ready <= '1'; tick; check_no_records;
      request <= '1'; qualify;
      -- A single destructive service-off edge poisons the entire attempt,
      -- even after all ports again appear idle. Only release starts anew.
      service_ready <= '0'; wait for 1 ns;
      assert stopped = '0' report "service loss did not revoke readiness" severity failure;
      tick; service_ready <= '1'; clocks(8);
      assert stopped = '0' report "service loss reopened poisoned graphics attempt" severity failure;
      request <= '0'; clocks(2); request <= '1'; qualify;
      reset <= '1'; wait for 1 ns;
      assert stopped = '0' report "reset left graphics owner ready" severity failure;
      tick; request <= '0'; producers_stopped <= '0'; reset <= '0'; clocks(2);
      assert current_frame = x"00000000" report "reset failed to clear frame epoch" severity failure;
      -- Overflow cannot be repaired by draining the surviving records. The
      -- stream has lost an ownership boundary and must fail closed.
      guest_frames := 0; display_frames := 0; frame_event_ready <= '0';
      request <= '1'; producers_stopped <= '1';
      for n in 0 to 256 loop frame_post; end loop;
      assert source_fault_reason(1) = '1' report "frame overflow was not recorded" severity failure;
      frame_event_ready <= '1'; clocks(270);
      assert stopped = '0' report "faulted graphics stream falsely stopped" severity failure;
      report "PASS: graphics checkpoint enable=" & boolean'image(ENABLE) &
         " compressed=" & boolean'image(COMPRESS) & " sparse=" & boolean'image(SPARSE) &
         " queue_bits=" & integer'image(QUEUE_BITS) & " delay=" & integer'image(DELAY) &
         " clocks=" & integer'image(cycles) & " records=" & integer'image(gw+vw9+vw7+hw+fw);
      stop; wait;
   end process;
   watchdog : process begin wait for 1 ms; assert false report "graphics checkpoint timeout" severity failure; end process;
end architecture;
