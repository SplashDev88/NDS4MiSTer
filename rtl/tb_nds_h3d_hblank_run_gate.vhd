library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_nds_h3d_hblank_run_gate is
   generic (COMPRESS_TEST : boolean := true);
end entity;

architecture sim of tb_nds_h3d_hblank_run_gate is
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
   generic map (COMPRESS_HBLANK => COMPRESS_TEST)
   port map
   (
      clk => clk, reset => reset, service_ready => service_ready,
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
      constant EVENTS : natural := 4096;
      type time_array is array(0 to EVENTS-1) of std_logic_vector(63 downto 0);
      variable times, frame_times : time_array;
      variable frames : natural := 0;
   begin
      reset <= '1';
      wait until rising_edge(clk); wait until rising_edge(clk);
      wait until falling_edge(clk); reset <= '0'; service_ready <= '1';
      -- Use the production 2,130-cycle cadence. Retain more than the former
      -- 512-line queue, including real independent VBlank frame tokens.
      for i in 0 to EVENTS-1 loop
         for c in 1 to 2129 loop wait until rising_edge(clk); end loop;
         wait until falling_edge(clk);
         hblank_line <= std_logic_vector(to_unsigned(i mod 263, 9));
         hblank_pulse <= '1';
         if i mod 263 = 192 then frame_pulse <= '1'; end if;
         wait for 1 ns;
         times(i) := timestamp;
         if i mod 263 = 192 then
            frame_times(frames) := timestamp; frames := frames+1;
         end if;
         wait until rising_edge(clk); wait for 1 ns;
         assert source_fault = '0'
            report "REGULAR_HBLANK_BACKLOG_OVERFLOW index=" & integer'image(i) severity failure;
         hblank_pulse <= '0'; frame_pulse <= '0';
      end loop;
      assert to_integer(unsigned(frame_pending_level)) = frames severity failure;
      for i in 0 to EVENTS-1 loop
         wait until falling_edge(clk); hblank_event_ready <= '1'; wait for 1 ns;
         assert hblank_event_valid = '1' severity failure;
         assert unsigned(hblank_event_line) = i mod 263 and
                unsigned(hblank_event_frame) = i / 263 and
                hblank_event_timestamp = times(i)
            report "expanded event mismatch index=" & integer'image(i) severity failure;
         wait until rising_edge(clk); wait for 1 ns;
      end loop;
      assert hblank_event_valid = '0' severity failure;
      hblank_event_ready <= '0';
      for i in 0 to frames-1 loop
         wait until falling_edge(clk); frame_event_ready <= '1'; wait for 1 ns;
         assert frame_event_valid = '1' and unsigned(frame_event_number) = i+1 and
                frame_event_timestamp = frame_times(i)
            report "independent VBlank token changed" severity failure;
         wait until rising_edge(clk); wait for 1 ns;
      end loop;
      assert frame_event_valid = '0' and source_fault_reason = "00" severity failure;
      frame_event_ready <= '0';
      -- One-cycle timestamps force discontinuities. Even the compressed path
      -- must expose an exhausted descriptor ring through the original reason
      -- bit, retain that fault across service stop, and clear it on reset.
      for i in 0 to 513 loop
         wait until falling_edge(clk); hblank_pulse <= '1';
         hblank_line <= std_logic_vector(to_unsigned(i mod 263, 9));
         wait until rising_edge(clk); wait for 1 ns;
         if i < 513 then
            assert source_fault = '0' severity failure;
         else
            assert source_fault = '1' and source_fault_reason = "01"
               report "compressed HBlank overflow reason missing" severity failure;
         end if;
      end loop;
      hblank_pulse <= '0'; service_ready <= '0';
      wait until rising_edge(clk); wait for 1 ns;
      assert hblank_event_valid = '0' and source_fault_reason = "01" severity failure;
      reset <= '1'; wait until rising_edge(clk); wait for 1 ns;
      assert source_fault_reason = "00" severity failure;
      report "HBLANK_RUN_GATE_PASS exact_events=4096 separate_vblank_tokens=" & integer'image(frames);
      stop; wait;
   end process;
end architecture;
