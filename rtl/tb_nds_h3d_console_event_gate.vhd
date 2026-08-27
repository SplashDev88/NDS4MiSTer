library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_nds_h3d_console_event_gate is
end entity;

architecture sim of tb_nds_h3d_console_event_gate is
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
   signal gpu_event_data, gpu_event_frame : std_logic_vector(31 downto 0);
   signal gpu_event_timestamp : std_logic_vector(63 downto 0);

   signal v9_source_valid : std_logic := '0';
   signal v9_source_address : std_logic_vector(31 downto 0) := (others => '0');
   signal v9_source_access : std_logic_vector(1 downto 0) := "10";
   signal v9_source_be : std_logic_vector(3 downto 0) := "1111";
   signal v9_source_data : std_logic_vector(31 downto 0) := (others => '0');
   signal v9_source_ready, v9_issue : std_logic;
   signal v9_event_valid, v9_event_ready : std_logic := '0';
   signal v9_event_address, v9_event_data, v9_event_frame : std_logic_vector(31 downto 0);
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
   signal v7_event_address, v7_event_data, v7_event_frame : std_logic_vector(31 downto 0);
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
   signal frame_pending_level : std_logic_vector(8 downto 0);
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_h3d_console_event_gate
   port map
   (
      clk => clk, reset => reset, service_ready => service_ready,
      timestamp => timestamp, current_frame => current_frame,
      source_fault => source_fault,
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
      gpu_event_frame => gpu_event_frame,
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
      vram9_event_frame => v9_event_frame,
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
      vram7_event_frame => v7_event_frame,
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
      variable held_time : std_logic_vector(63 downto 0);
      variable second_time : std_logic_vector(63 downto 0);
      variable third_time : std_logic_vector(63 downto 0);
      variable fourth_time : std_logic_vector(63 downto 0);
      variable refill_time : std_logic_vector(63 downto 0);
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until falling_edge(clk);

      -- Service-off is transparent to the proven console path: no event is
      -- emitted and every source receives immediate architectural credit.
      gpu_source_valid <= '1';
      gpu_source_is_cpu <= '1';
      v9_source_valid <= '1';
      v7_source_valid <= '1';
      wait for 1 ns;
      assert gpu_source_ready = '1' and v9_source_ready = '1' and
             v7_source_ready = '1' and v9_issue = '1' and v7_issue = '1' and
             gpu_event_valid = '0' and v9_event_valid = '0' and
             v7_event_valid = '0' and gpu_cpu_complete = '0'
         report "service-off event gate changed legacy acceptance" severity failure;
      gpu_source_valid <= '0';
      v9_source_valid <= '0';
      v7_source_valid <= '0';

      service_ready <= '1';
      wait until rising_edge(clk);

      -- A one-cycle CPU IO request posts immediately into the GPU queue even
      -- through arbitrary sink backpressure. Architectural completion occurs
      -- at that durable posting point; the original frame/timestamp then hold.
      wait until falling_edge(clk);
      gpu_source_address <= x"0000400";
      gpu_source_data <= x"11223344";
      gpu_source_is_cpu <= '1';
      gpu_source_valid <= '1';
      gpu_event_ready <= '0';
      wait for 1 ns;
      assert gpu_source_ready = '1' and gpu_cpu_complete = '1'
         report "CPU GPU write did not complete at durable queue posting"
         severity failure;
      wait until rising_edge(clk);
      held_time := gpu_event_timestamp;
      wait until falling_edge(clk);
      gpu_source_valid <= '0';
      -- The console request pulse may disappear and the shared bus may move
      -- immediately afterward. The event itself must retain the exact write
      -- that melonDS applies atomically at this ordering point.
      gpu_source_address <= x"0000440";
      gpu_source_access <= "01";
      gpu_source_be <= "0011";
      gpu_source_data <= x"DEADBEEF";
      for i in 0 to 5 loop
         wait until falling_edge(clk);
         assert gpu_event_valid = '1' and gpu_cpu_complete = '0' and
                gpu_event_address = x"0000400" and
                gpu_event_access = "10" and gpu_event_be = "1111" and
                gpu_event_data = x"11223344" and
                gpu_event_timestamp = held_time and gpu_event_frame = x"00000000"
            report "CPU GPU event was lost or mutated while stalled" severity failure;
      end loop;
      gpu_event_ready <= '1';
      wait for 1 ns;
      assert gpu_cpu_complete = '0'
         report "posted CPU GPU write completed twice at sink acceptance"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert gpu_event_valid = '0' and gpu_cpu_complete = '0'
         report "CPU GPU event completed more than once" severity failure;
      gpu_event_ready <= '0';

      -- DMA uses the same posted credit but never generates CPU completion.
      -- Once ready is observed it removes valid, while the queued event may
      -- remain stalled at the sink for arbitrary time.
      gpu_source_address <= x"0000400";
      gpu_source_data <= x"55667788";
      gpu_source_is_cpu <= '0';
      gpu_source_valid <= '1';
      wait for 1 ns;
      assert gpu_source_ready = '1' and gpu_cpu_complete = '0'
         report "DMA GPU write did not receive posted credit cleanly"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      gpu_source_valid <= '0';
      for i in 0 to 3 loop
         wait until falling_edge(clk);
         assert gpu_event_valid = '1' and gpu_source_ready = '1' and
                gpu_cpu_complete = '0' and gpu_event_data = x"55667788"
            report "posted DMA GX request changed while sink-stalled"
            severity failure;
      end loop;
      gpu_event_ready <= '1';
      wait for 1 ns;
      assert gpu_event_valid = '1' and gpu_source_ready = '1' and
             gpu_cpu_complete = '0'
         report "DMA GX event acceptance used the CPU completion path"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      gpu_event_ready <= '0';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert gpu_event_valid = '0'
         report "DMA GX event was accepted more than once" severity failure;

      -- Fill every posted GPU slot while the sink is blocked. The 33rd
      -- one-cycle CPU pulse must survive in the skid slot without completing;
      -- the first downstream pop transfers it into the queue, completes the
      -- CPU exactly once, and preserves all 33 payloads in FIFO order.
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      gpu_event_ready <= '0';
      gpu_source_is_cpu <= '1';
      for i in 0 to 31 loop
         wait until falling_edge(clk);
         gpu_source_address <= std_logic_vector(
            to_unsigned(16#600# + i * 4, 28));
         gpu_source_data <= std_logic_vector(to_unsigned(i, 32));
         gpu_source_valid <= '1';
         wait for 1 ns;
         assert gpu_source_ready = '1' and gpu_cpu_complete = '1'
            report "posted GPU queue rejected an available slot"
            severity failure;
         wait until rising_edge(clk);
         gpu_source_valid <= '0';
      end loop;

      wait until falling_edge(clk);
      gpu_source_address <= std_logic_vector(to_unsigned(16#680#, 28));
      gpu_source_data <= x"00000020";
      gpu_source_valid <= '1';
      wait for 1 ns;
      assert gpu_source_ready = '0' and gpu_cpu_complete = '0'
         report "full GPU queue acknowledged before retaining the write"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      gpu_source_valid <= '0';
      gpu_source_address <= x"0000000";
      gpu_source_data <= x"DEADBEEF";
      gpu_event_ready <= '1';
      wait for 1 ns;
      assert gpu_event_valid = '1' and
             gpu_event_address = std_logic_vector(to_unsigned(16#600#, 28)) and
             gpu_event_data = x"00000000" and gpu_source_ready = '1' and
             gpu_cpu_complete = '1'
         report "GPU skid did not complete while the full queue popped"
         severity failure;
      wait until rising_edge(clk);

      for i in 1 to 32 loop
         wait until falling_edge(clk);
         assert gpu_event_valid = '1' and
                gpu_event_address = std_logic_vector(
                   to_unsigned(16#600# + i * 4, 28)) and
                gpu_event_data = std_logic_vector(to_unsigned(i, 32)) and
                gpu_cpu_complete = '0'
            report "posted GPU queue reordered, corrupted, or recompleted a write"
            severity failure;
         wait until rising_edge(clk);
      end loop;
      wait until falling_edge(clk);
      gpu_event_ready <= '0';
      assert gpu_event_valid = '0' and gpu_cpu_complete = '0'
         report "posted GPU queue did not drain exactly once" severity failure;

      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';

      -- VRAM9 and VRAM7 preserve pulse requests independently, then issue to
      -- nds_vram on the exact event-acceptance edge and exactly once.
      v9_source_address <= x"06000100";
      v9_source_data <= x"AABBCCDD";
      v9_source_access <= "10";
      v9_source_be <= "1111";
      v9_source_valid <= '1';
      v9_event_ready <= '0';
      v7_source_address <= x"06000200";
      v7_source_data <= x"000055AA";
      v7_source_valid <= '1';
      v7_event_ready <= '0';
      wait for 1 ns;
      assert v9_source_ready = '1' and v9_issue = '0'
         report "VRAM9 skid slot did not accept independently of sink ready"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert v9_source_ready = '0'
         report "VRAM9 skid slot accepted a second source while occupied"
         severity failure;
      v9_source_valid <= '0';
      v7_source_valid <= '0';
      v9_source_address <= x"06000300";
      v9_source_access <= "00";
      v9_source_be <= "0001";
      v9_source_data <= x"DEADBEEF";
      v7_source_address <= x"06000400";
      v7_source_access <= "10";
      v7_source_be <= "1111";
      v7_source_data <= x"CAFEBABE";
      for i in 0 to 4 loop
         wait until falling_edge(clk);
         assert v9_event_valid = '1' and v7_event_valid = '1' and
                v9_issue = '0' and v7_issue = '0' and
                v9_event_address = x"06000100" and
                v9_event_access = "10" and v9_event_be = "1111" and
                v9_event_data = x"AABBCCDD" and
                v7_event_address = x"06000200" and
                v7_event_access = "01" and v7_event_be = "0011" and
                v7_event_data = x"000055AA"
            report "VRAM event was lost, changed, or issued before acceptance"
            severity failure;
      end loop;
      v9_event_ready <= '1';
      v7_event_ready <= '1';
      wait for 1 ns;
      assert v9_issue = '1' and v7_issue = '1'
         report "VRAM issue did not coincide with event acceptance"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert v9_event_valid = '0' and v7_event_valid = '0' and
             v9_issue = '0' and v7_issue = '0'
         report "VRAM event issued more than once" severity failure;
      v9_event_ready <= '0';
      v7_event_ready <= '0';

      -- The registered ARM9 cut must retain full steady-state throughput: an
      -- accepted head and a new source replace one another on the same edge.
      v9_source_address <= x"06000500";
      v9_source_access <= "01";
      v9_source_be <= "0011";
      v9_source_data <= x"112255AA";
      v9_source_valid <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert v9_event_valid = '1' and v9_event_address = x"06000500" and
             v9_event_data = x"112255AA"
         report "VRAM9 registered stage did not capture the first source"
         severity failure;
      v9_event_ready <= '1';
      v9_source_address <= x"06000600";
      v9_source_access <= "10";
      v9_source_be <= "1111";
      v9_source_data <= x"33447788";
      wait for 1 ns;
      assert v9_source_ready = '1' and v9_issue = '1'
         report "VRAM9 registered stage could not pop and refill together"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      v9_source_valid <= '0';
      v9_event_ready <= '0';
      assert v9_event_valid = '1' and v9_event_address = x"06000600" and
             v9_event_access = "10" and v9_event_be = "1111" and
             v9_event_data = x"33447788"
         report "VRAM9 simultaneous refill lost or mutated the new source"
         severity failure;
      v9_event_ready <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      v9_event_ready <= '0';
      assert v9_event_valid = '0' and v9_issue = '0'
         report "VRAM9 simultaneous refill issued more than once"
         severity failure;

      -- Model the ordered queue's atomic batch ready. GPU posting is independent
      -- while VRAM issue and every queued event drain still wait for their sinks.
      gpu_source_is_cpu <= '1';
      gpu_source_address <= x"0000320";
      gpu_source_data <= x"CAFEBABE";
      gpu_source_valid <= '1';
      v9_source_valid <= '1';
      v7_source_valid <= '1';
      hblank_pulse <= '1';
      hblank_line <= std_logic_vector(to_unsigned(37, 9));
      frame_pulse <= '1';
      frame_event_ready <= '0';
      wait for 1 ns;
      assert gpu_source_ready = '1' and gpu_cpu_complete = '1'
         report "atomic batch GPU member did not post independently"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      gpu_source_valid <= '0';
      v9_source_valid <= '0';
      v7_source_valid <= '0';
      hblank_pulse <= '0';
      frame_pulse <= '0';
      wait for 1 ns;
      assert gpu_event_valid = '1' and v9_event_valid = '1' and
             v7_event_valid = '1' and hblank_event_valid = '1' and
             hblank_event_line = std_logic_vector(to_unsigned(37, 9)) and
             hblank_event_frame = x"00000000" and
             frame_event_valid = '1' and
             gpu_cpu_complete = '0' and v9_issue = '0' and v7_issue = '0'
         report "atomic five-source batch escaped before common ready"
         severity failure;
      gpu_event_ready <= '1';
      v9_event_ready <= '1';
      v7_event_ready <= '1';
      hblank_event_ready <= '1';
      frame_event_ready <= '1';
      wait for 1 ns;
      assert gpu_cpu_complete = '0' and v9_issue = '1' and v7_issue = '1'
         report "atomic four-source batch did not accept together"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert gpu_event_valid = '0' and v9_event_valid = '0' and
             v7_event_valid = '0' and hblank_event_valid = '0' and
             frame_event_valid = '0'
         report "atomic five-source batch repeated after acceptance"
         severity failure;

      -- Restore a zero frame epoch for the explicit current-vs-event identity
      -- test below.
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      gpu_event_ready <= '0';
      v9_event_ready <= '0';
      v7_event_ready <= '0';
      hblank_event_ready <= '0';
      frame_event_ready <= '0';

      -- A held frame boundary carries the post-VBlank frame number while the
      -- separate current_frame remains suitable for live descriptor matching.
      frame_event_ready <= '0';
      frame_pulse <= '1';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000001"
         report "frame boundary did not expose the next frame number"
         severity failure;
      wait until rising_edge(clk);
      held_time := frame_event_timestamp;
      wait until falling_edge(clk);
      frame_pulse <= '0';
      for i in 0 to 3 loop
         wait until falling_edge(clk);
         assert frame_event_valid = '1' and frame_event_number = x"00000001" and
                current_frame = x"00000001" and
                frame_event_timestamp = held_time
            report "stalled frame boundary payload/current frame mismatch"
            severity failure;
      end loop;
      frame_event_ready <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '0' and current_frame = x"00000001" and
             frame_event_number = x"00000002"
         report "accepted frame payload was confused with live current frame"
         severity failure;

      -- Two stalled boundaries fill the ordered elastic FIFO without fault.
      -- A simultaneous head retirement and third VBlank must refill the tail,
      -- preserving all three frame numbers and timestamps in order.
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      frame_event_ready <= '0';
      held_time := timestamp;
      frame_pulse <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      frame_pulse <= '0';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000001" and
             frame_event_timestamp = held_time and current_frame = x"00000001" and
             source_fault = '0'
         report "two-entry fixture did not hold its first frame" severity failure;

      wait until rising_edge(clk);
      wait until falling_edge(clk);
      second_time := timestamp;
      frame_pulse <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      frame_pulse <= '0';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000001" and
             frame_event_timestamp = held_time and current_frame = x"00000002" and
             source_fault = '0'
         report "second stalled frame changed the FIFO head or faulted"
         severity failure;
      for i in 0 to 1 loop
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         assert frame_event_valid = '1' and
                frame_event_number = x"00000001" and
                frame_event_timestamp = held_time and source_fault = '0'
            report "full two-entry FIFO did not hold its head stable"
            severity failure;
      end loop;

      frame_event_ready <= '1';
      refill_time := timestamp;
      frame_pulse <= '1';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000001" and
             frame_event_timestamp = held_time
         report "full-FIFO refill changed the retiring head" severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      frame_pulse <= '0';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000002" and
             frame_event_timestamp = second_time and current_frame = x"00000003" and
             source_fault = '0'
         report "full-FIFO pop/refill did not expose the second frame"
         severity failure;

      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '1' and frame_event_number = x"00000003" and
             frame_event_timestamp = refill_time and source_fault = '0'
         report "full-FIFO pop/refill did not retain the replacement frame"
         severity failure;

      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '0' and current_frame = x"00000003" and
             source_fault = '0'
         report "two-entry FIFO did not drain exactly once and in order"
         severity failure;

      -- The one-occupied case has the same elastic turnover contract: retire
      -- the held head and capture the live boundary into that slot.
      frame_event_ready <= '0';
      held_time := timestamp;
      frame_pulse <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      frame_pulse <= '0';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000004" and
             frame_event_timestamp = held_time and source_fault = '0'
         report "single-entry turnover fixture was not retained"
         severity failure;

      frame_event_ready <= '1';
      refill_time := timestamp;
      frame_pulse <= '1';
      wait for 1 ns;
      assert frame_event_number = x"00000004" and
             frame_event_timestamp = held_time
         report "single-entry turnover changed the retiring head"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      frame_pulse <= '0';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000005" and
             frame_event_timestamp = refill_time and current_frame = x"00000005" and
             source_fault = '0'
         report "single-entry pop/refill lost its replacement boundary"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '0' and source_fault = '0'
         report "single-entry replacement did not drain exactly once"
         severity failure;

      -- Four stalled boundaries fill the ordered holder without fault. A
      -- simultaneous head retirement and fifth VBlank must preserve all five
      -- boundaries in order, without changing the retiring head.
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      frame_event_ready <= '0';
      for expected_frame in 1 to 4 loop
         if expected_frame = 1 then
            held_time := timestamp;
         elsif expected_frame = 2 then
            second_time := timestamp;
         elsif expected_frame = 3 then
            third_time := timestamp;
         else
            fourth_time := timestamp;
         end if;
         frame_pulse <= '1';
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         frame_pulse <= '0';
         wait for 1 ns;
         assert source_fault = '0' and frame_event_valid = '1' and
                frame_event_number = x"00000001" and
                frame_event_timestamp = held_time and
                current_frame = std_logic_vector(to_unsigned(expected_frame, 32))
            report "four-entry holder faulted early or changed its head"
            severity failure;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
      end loop;

      frame_event_ready <= '1';
      refill_time := timestamp;
      frame_pulse <= '1';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000001" and
             frame_event_timestamp = held_time and source_fault = '0'
         report "full four-entry refill changed the retiring head"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      frame_pulse <= '0';
      wait for 1 ns;
      assert frame_event_valid = '1' and frame_event_number = x"00000002" and
             frame_event_timestamp = second_time and current_frame = x"00000005" and
             source_fault = '0'
         report "full four-entry pop/refill did not expose frame two"
         severity failure;

      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '1' and frame_event_number = x"00000003" and
             frame_event_timestamp = third_time and source_fault = '0'
         report "four-entry drain lost or reordered frame three"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '1' and frame_event_number = x"00000004" and
             frame_event_timestamp = fourth_time and source_fault = '0'
         report "four-entry drain lost or reordered frame four"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '1' and frame_event_number = x"00000005" and
             frame_event_timestamp = refill_time and source_fault = '0'
         report "four-entry drain lost the same-edge refill"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '0' and source_fault = '0'
         report "four-entry holder did not drain exactly once"
         severity failure;

      -- Service-off flushes an occupied holder and suppresses live pulses.
      frame_event_ready <= '0';
      frame_pulse <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      frame_pulse <= '0';
      service_ready <= '0';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '0' and source_fault = '0'
         report "service-off did not flush the occupied frame holder"
         severity failure;
      service_ready <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert frame_event_valid = '0' and source_fault = '0'
         report "service-off frame flush replayed a stale boundary"
         severity failure;

      -- Five stalled boundaries previously reproduced the production packet
      -- fault: the four-entry holder silently replaced frame four with frame
      -- five. Every VBlank is now retained and drains in exact order.
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      frame_event_ready <= '0';
      for expected_frame in 1 to 5 loop
         frame_pulse <= '1';
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         frame_pulse <= '0';
         wait for 1 ns;
         assert source_fault = '0' and frame_event_valid = '1' and
                frame_event_number = x"00000001" and
                unsigned(frame_pending_level) = to_unsigned(expected_frame, 9)
            report "full boundary holder faulted or changed its head"
            severity failure;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
      end loop;

      frame_event_ready <= '1';
      for expected_frame in 1 to 5 loop
         wait for 1 ns;
         assert frame_event_valid = '1' and
                frame_event_number =
                   std_logic_vector(to_unsigned(expected_frame, 32)) and
                source_fault = '0'
            report "deep boundary holder lost or reordered a frame"
            severity failure;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
      end loop;
      assert frame_event_valid = '0' and source_fault = '0' and
             unsigned(frame_pending_level) = to_unsigned(0, 9)
         report "deep boundary holder did not drain exactly once"
         severity failure;

      -- The bounded queue fails closed instead of dropping a VBlank. Its 256
      -- entries cover more than four seconds at 60 Hz; the 257th
      -- unconsumed boundary must raise the sticky source fault while leaving
      -- the oldest retained boundary unchanged.
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      frame_event_ready <= '0';
      for expected_frame in 1 to 256 loop
         frame_pulse <= '1';
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         frame_pulse <= '0';
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         assert source_fault = '0' and frame_event_valid = '1' and
                frame_event_number = x"00000001"
            report "deep boundary holder faulted before capacity"
            severity failure;
      end loop;
      assert unsigned(frame_pending_level) = to_unsigned(256, 9)
         report "boundary pressure level did not report full capacity"
         severity failure;
      frame_pulse <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      frame_pulse <= '0';
      wait for 1 ns;
      assert source_fault = '1' and frame_event_valid = '1' and
             unsigned(frame_pending_level) = to_unsigned(256, 9) and
             frame_event_number = x"00000001"
         report "deep boundary overflow did not fail closed"
         severity failure;

      -- The display-frame tag follows the 263-line LCD scan, independently
      -- of the 3D frame pulse. Retain a stalled line 262 and following line 0
      -- to prove the exact wrap survives queueing in order.
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      hblank_event_ready <= '0';
      hblank_line <= std_logic_vector(to_unsigned(262, 9));
      hblank_pulse <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      hblank_pulse <= '0';
      wait for 1 ns;
      assert hblank_event_valid = '1' and
             hblank_event_line = std_logic_vector(to_unsigned(262, 9)) and
             hblank_event_frame = x"00000000" and source_fault = '0'
         report "line 262 did not retain the old display-frame tag"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      hblank_line <= (others => '0');
      hblank_pulse <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      hblank_pulse <= '0';
      wait for 1 ns;
      assert hblank_event_valid = '1' and
             hblank_event_line = std_logic_vector(to_unsigned(262, 9)) and
             hblank_event_frame = x"00000000" and source_fault = '0'
         report "queued LCD wrap changed the retiring line"
         severity failure;
      hblank_event_ready <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      wait for 1 ns;
      assert hblank_event_valid = '1' and hblank_event_line = (hblank_event_line'range => '0') and
             hblank_event_frame = x"00000001" and source_fault = '0'
         report "line 0 did not advance the display-frame tag after line 262"
         severity failure;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert hblank_event_valid = '0' and source_fault = '0'
         report "LCD wrap fixture did not drain exactly once" severity failure;

      -- Timing cannot wait for the ordered sink. 512 LCD phases are retained
      -- exactly; a 513th while full raises the
      -- sticky loss indicator.
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      hblank_event_ready <= '0';
      for expected_line in 0 to 511 loop
         hblank_line <= std_logic_vector(to_unsigned(
            (247 + expected_line) mod 263, 9));
         hblank_pulse <= '1';
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         hblank_pulse <= '0';
         assert hblank_event_valid = '1' and
                hblank_event_line = std_logic_vector(to_unsigned(247, 9)) and
                source_fault = '0'
            report "HBlank queue lost order or faulted before capacity"
            severity failure;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
      end loop;
      hblank_line <= std_logic_vector(to_unsigned((247 + 512) mod 263, 9));
      hblank_pulse <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      hblank_pulse <= '0';
      assert hblank_event_valid = '1' and
             hblank_event_line = std_logic_vector(to_unsigned(247, 9)) and
             source_fault = '1'
         report "full HBlank queue did not fail closed on overflow"
         severity failure;
      reset <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      assert source_fault = '0' and current_frame = x"00000000" and
             frame_event_valid = '0'
         report "H3D source fault/FIFO/counters did not clear on reset"
         severity failure;

      report "PASS: console H3D gate posts 33 ordered GPU writes, preserves CPU/DMA pulses, VRAM/frame atomicity, lossless HBlank/frame stalls, service-off behavior, frame identity, deep boundary elasticity, and fail-closed overflow"
         severity note;
      finish;
      wait;
   end process;
end architecture;
