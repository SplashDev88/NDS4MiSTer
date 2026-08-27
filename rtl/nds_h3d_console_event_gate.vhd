-- SPDX-License-Identifier: GPL-3.0-or-later
-- Lossless clk1x-side retirement gate for the hybrid-3D event stream.
--
-- The console buses use one-cycle request pulses, while the H3D queue uses
-- held ready/valid records. This block posts complete GPU writes into a small
-- ordered queue before granting architectural retirement; VRAM sources retain
-- their dedicated held stages. Frame and timestamp are copied at posting time
-- because those clocks continue to advance during downstream backpressure.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_h3d_console_event_gate is
   port
   (
      clk           : in  std_logic;
      reset         : in  std_logic;
      service_ready : in  std_logic;

      timestamp     : out std_logic_vector(63 downto 0);
      current_frame : out std_logic_vector(31 downto 0);
      source_fault  : out std_logic;

      -- Unified ARM9 GPU-I/O source. gpu_source_is_cpu distinguishes the
      -- bridged CPU request (which needs an IO-completion toggle) from the
      -- clk1x DMA fast lane (which observes gpu_source_ready directly).
      gpu_source_valid    : in  std_logic;
      gpu_source_is_cpu   : in  std_logic;
      gpu_source_address  : in  std_logic_vector(27 downto 0);
      gpu_source_access   : in  std_logic_vector(1 downto 0);
      gpu_source_be       : in  std_logic_vector(3 downto 0);
      gpu_source_data     : in  std_logic_vector(31 downto 0);
      gpu_source_ready    : out std_logic;
      gpu_cpu_complete    : out std_logic;

      gpu_event_valid     : out std_logic;
      gpu_event_ready     : in  std_logic;
      gpu_event_address   : out std_logic_vector(27 downto 0);
      gpu_event_access    : out std_logic_vector(1 downto 0);
      gpu_event_be        : out std_logic_vector(3 downto 0);
      gpu_event_data      : out std_logic_vector(31 downto 0);
      gpu_event_frame     : out std_logic_vector(31 downto 0);
      gpu_event_timestamp : out std_logic_vector(63 downto 0);

      -- Virtual-VRAM write sources. *_issue is the only enable that may be
      -- presented to nds_vram while H3D is active.  With H3D off it is the
      -- unmodified source pulse, preserving the proven 2D-only path.
      vram9_source_valid   : in  std_logic;
      vram9_source_address : in  std_logic_vector(31 downto 0);
      vram9_source_access  : in  std_logic_vector(1 downto 0);
      vram9_source_be      : in  std_logic_vector(3 downto 0);
      vram9_source_data    : in  std_logic_vector(31 downto 0);
      vram9_source_ready   : out std_logic;
      vram9_issue          : out std_logic;

      vram9_event_valid     : out std_logic;
      vram9_event_ready     : in  std_logic;
      vram9_event_address   : out std_logic_vector(31 downto 0);
      vram9_event_access    : out std_logic_vector(1 downto 0);
      vram9_event_be        : out std_logic_vector(3 downto 0);
      vram9_event_data      : out std_logic_vector(31 downto 0);
      vram9_event_frame     : out std_logic_vector(31 downto 0);
      vram9_event_timestamp : out std_logic_vector(63 downto 0);

      vram7_source_valid   : in  std_logic;
      vram7_source_address : in  std_logic_vector(31 downto 0);
      vram7_source_access  : in  std_logic_vector(1 downto 0);
      vram7_source_be      : in  std_logic_vector(3 downto 0);
      vram7_source_data    : in  std_logic_vector(31 downto 0);
      vram7_source_ready   : out std_logic;
      vram7_issue          : out std_logic;

      vram7_event_valid     : out std_logic;
      vram7_event_ready     : in  std_logic;
      vram7_event_address   : out std_logic_vector(31 downto 0);
      vram7_event_access    : out std_logic_vector(1 downto 0);
      vram7_event_be        : out std_logic_vector(3 downto 0);
      vram7_event_data      : out std_logic_vector(31 downto 0);
      vram7_event_frame     : out std_logic_vector(31 downto 0);
      vram7_event_timestamp : out std_logic_vector(63 downto 0);

      -- Visible-line HBlank is an architectural ordering point for HDMA.
      -- Timing itself cannot be backpressured, so retain a short ordered
      -- queue and fail closed instead of silently losing a scanline marker.
      hblank_pulse           : in  std_logic;
      hblank_line            : in  std_logic_vector(8 downto 0);
      hblank_event_valid     : out std_logic;
      hblank_event_ready     : in  std_logic;
      hblank_event_line      : out std_logic_vector(8 downto 0);
      hblank_event_frame     : out std_logic_vector(31 downto 0);
      hblank_event_timestamp : out std_logic_vector(63 downto 0);

      -- VBlank closes the command list for the next numbered frame. The token
      -- remains held until the ordered packet-record CDC accepts it.
      frame_pulse           : in  std_logic;
      frame_event_valid     : out std_logic;
      frame_event_ready     : in  std_logic;
      frame_event_number    : out std_logic_vector(31 downto 0);
      frame_event_timestamp : out std_logic_vector(63 downto 0);
      frame_pending_level   : out std_logic_vector(8 downto 0)
   );
end entity;

architecture arch of nds_h3d_console_event_gate is
   signal timestamp_counter : unsigned(63 downto 0) := (others => '0');
   signal frame_counter     : unsigned(31 downto 0) := (others => '0');
   -- The 2D scan epoch is independent of the 3D SWAP/VBlank frame epoch.
   -- Advance it at the architectural 263-line LCD wrap so line 0 following
   -- line 262 is never tagged with the preceding display frame.
   signal hblank_frame_counter : unsigned(31 downto 0) := (others => '0');

   signal gpu_pending, gpu_pending_cpu : std_logic := '0';
   signal gpu_pending_address : std_logic_vector(27 downto 0) := (others => '0');
   signal gpu_pending_access  : std_logic_vector(1 downto 0) := (others => '0');
   signal gpu_pending_be      : std_logic_vector(3 downto 0) := (others => '0');
   signal gpu_pending_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal gpu_pending_frame : std_logic_vector(31 downto 0) := (others => '0');
   signal gpu_pending_time  : std_logic_vector(63 downto 0) := (others => '0');

   -- Posted GPU-write queue. The old single skid slot did retain a stalled
   -- request losslessly, but it did not retire the CPU until the record reached
   -- the final ordered sink. A GX command backlog therefore held ordinary
   -- GXSTAT/DISP3DCNT writes in ARM9 W_IO_RESP for hundreds of cycles, blocking
   -- HBlank DMA and making NSMB BG2 reuse stale scroll values. This queue is the
   -- architectural posting point: acceptance is completion for CPU/DMA, while
   -- the complete payload/frame/timestamp remains ordered for the HPS shadow.
   constant GPU_QUEUE_DEPTH : natural := 32;
   type gpu_queue_type is array (0 to GPU_QUEUE_DEPTH - 1) of
      std_logic_vector(161 downto 0);
   signal gpu_queue : gpu_queue_type;
   attribute ramstyle : string;
   attribute ramstyle of gpu_queue : signal is "MLAB, no_rw_check";
   signal gpu_queue_read : std_logic_vector(161 downto 0);
   signal gpu_read_pointer : unsigned(4 downto 0) := (others => '0');
   signal gpu_write_pointer : unsigned(4 downto 0) := (others => '0');
   signal gpu_pending_count : unsigned(5 downto 0) := (others => '0');
   signal gpu_queue_pop, gpu_queue_push, gpu_queue_space : std_logic;
   signal gpu_source_take, gpu_bypass_fire, gpu_pending_move : std_logic;

   signal vram9_pending : std_logic := '0';
   signal vram9_pending_address : std_logic_vector(31 downto 0) := (others => '0');
   signal vram9_pending_access  : std_logic_vector(1 downto 0) := (others => '0');
   signal vram9_pending_be      : std_logic_vector(3 downto 0) := (others => '0');
   signal vram9_pending_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal vram9_pending_frame : std_logic_vector(31 downto 0) := (others => '0');
   signal vram9_pending_time  : std_logic_vector(63 downto 0) := (others => '0');

   signal vram7_pending : std_logic := '0';
   signal vram7_pending_address : std_logic_vector(31 downto 0) := (others => '0');
   signal vram7_pending_access  : std_logic_vector(1 downto 0) := (others => '0');
   signal vram7_pending_be      : std_logic_vector(3 downto 0) := (others => '0');
   signal vram7_pending_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal vram7_pending_frame : std_logic_vector(31 downto 0) := (others => '0');
   signal vram7_pending_time  : std_logic_vector(63 downto 0) := (others => '0');

   -- 512 scanlines absorb bounded packet/render arbitration stalls without
   -- turning the 63.5 us scanline cadence into a backpressure
   -- path through GPU timing. Overflow remains a sticky source fault: the ARM
   -- shadow must never continue after an unobserved HDMA ordering point.
   type hblank_queue_type is array (0 to 511) of
      std_logic_vector(104 downto 0);
   signal hblank_queue : hblank_queue_type;
   attribute ramstyle of hblank_queue : signal is "MLAB, no_rw_check";
   signal hblank_queue_read : std_logic_vector(104 downto 0);
   signal hblank_read_pointer : unsigned(8 downto 0) := (others => '0');
   signal hblank_write_pointer : unsigned(8 downto 0) := (others => '0');
   signal hblank_pending_count : unsigned(9 downto 0) := (others => '0');

   -- VBlank boundaries are packet ownership markers and therefore may never
   -- be coalesced: doing so leaves records for the removed frame in front of a
   -- newer boundary.  A real NSMB map transition filled the former 32-entry
   -- queue while the packet path later recovered completely.  Keep 256 exact
   -- boundaries (over four seconds at 60 Hz) in block RAM so that transient
   -- scene bursts remain lossless without consuming scarce ALMs. Overflow is
   -- still fail-closed. The memory is not reset: count=0 makes stale words
   -- unreachable after reset/service stop.
   constant FRAME_QUEUE_DEPTH : natural := 256;
   type frame_queue_type is array (0 to FRAME_QUEUE_DEPTH - 1) of
      std_logic_vector(95 downto 0);
   signal frame_queue : frame_queue_type;
   attribute ramstyle of frame_queue : signal is "M10K, no_rw_check";
   signal frame_queue_read : std_logic_vector(95 downto 0);
   signal frame_read_pointer : unsigned(7 downto 0) := (others => '0');
   signal frame_write_pointer : unsigned(7 downto 0) := (others => '0');
   signal frame_pending_count : unsigned(8 downto 0) := (others => '0');

   signal gpu_valid_i, vram9_valid_i, vram7_valid_i : std_logic;
   signal hblank_valid_i, frame_valid_i : std_logic;
   signal source_fault_i : std_logic := '0';
begin
   timestamp     <= std_logic_vector(timestamp_counter);
   current_frame <= std_logic_vector(frame_counter);
   source_fault  <= source_fault_i;
   frame_pending_level <= std_logic_vector(frame_pending_count);

   gpu_queue_read <= gpu_queue(to_integer(gpu_read_pointer));
   gpu_queue_pop <= '1' when service_ready = '1' and
                             gpu_pending_count /= to_unsigned(0, gpu_pending_count'length) and
                             gpu_event_ready = '1' else '0';
   -- A pop may refill a full queue on the same edge with no bubble.
   gpu_queue_space <= '1' when
      gpu_pending_count < to_unsigned(GPU_QUEUE_DEPTH, gpu_pending_count'length) or
      gpu_queue_pop = '1' else '0';
   gpu_pending_move <= gpu_pending and gpu_queue_space;
   gpu_source_take <= '1' when service_ready = '1' and gpu_pending = '0' and
                              gpu_source_valid = '1' and gpu_queue_space = '1'
                      else '0';
   -- Preserve the old zero-latency path when both stages are empty. If the
   -- ordered sink stalls, the same source is posted instead.
   gpu_bypass_fire <= '1' when gpu_source_take = '1' and
                              gpu_pending_count = to_unsigned(0, gpu_pending_count'length) and
                              gpu_event_ready = '1' else '0';
   gpu_queue_push <= gpu_pending_move or
      (gpu_source_take and not gpu_bypass_fire);

   gpu_valid_i <= '1' when service_ready = '1' and
                           (gpu_pending_count /= to_unsigned(0, gpu_pending_count'length) or
                            (gpu_pending = '0' and gpu_source_valid = '1')) else '0';
   gpu_source_ready <= '1' when service_ready = '0' else gpu_queue_space;
   -- CPU completion is tied to durable local posting, not downstream drain.
   -- A pulse captured in the overflow skid slot completes when that slot can
   -- move into the queue; DMA observes the same edge through source_ready.
   gpu_cpu_complete <= '1' when service_ready = '1' and
      ((gpu_pending = '1' and gpu_pending_move = '1' and
        gpu_pending_cpu = '1') or
       (gpu_pending = '0' and gpu_source_take = '1' and
        gpu_source_is_cpu = '1')) else '0';

   gpu_event_valid     <= gpu_valid_i;
   gpu_event_address   <= gpu_queue_read(27 downto 0)
                           when gpu_pending_count /= to_unsigned(0, gpu_pending_count'length) else
                          gpu_source_address;
   gpu_event_access    <= gpu_queue_read(29 downto 28)
                           when gpu_pending_count /= to_unsigned(0, gpu_pending_count'length) else
                          gpu_source_access;
   gpu_event_be        <= gpu_queue_read(33 downto 30)
                           when gpu_pending_count /= to_unsigned(0, gpu_pending_count'length) else
                          gpu_source_be;
   gpu_event_data      <= gpu_queue_read(65 downto 34)
                           when gpu_pending_count /= to_unsigned(0, gpu_pending_count'length) else
                          gpu_source_data;
   gpu_event_frame     <= gpu_queue_read(97 downto 66)
                           when gpu_pending_count /= to_unsigned(0, gpu_pending_count'length) else
                          std_logic_vector(frame_counter);
   gpu_event_timestamp <= gpu_queue_read(161 downto 98)
                           when gpu_pending_count /= to_unsigned(0, gpu_pending_count'length) else
                          std_logic_vector(timestamp_counter);

   -- ARM9 VRAM events always cross a registered stage.  The DMA fast lane is
   -- combinational from channel state through nds_vram's posted-write credit;
   -- allowing an empty-stage source to bypass directly to the ordered sink
   -- closes a loop through sink arbitration, local VRAM acceptance, and source
   -- valid.  A simultaneous sink pop and source push refills the stage on the
   -- same edge, so this cut adds one cycle of latency but no steady-state bubble.
   vram9_valid_i <= '1' when service_ready = '1' and
                             vram9_pending = '1' else '0';
   vram9_source_ready <= '1' when service_ready = '0' or
                                 vram9_pending = '0' or
                                 vram9_event_ready = '1' else '0';
   vram9_issue <= vram9_source_valid when service_ready = '0' else
                  vram9_pending and vram9_event_ready;
   vram9_event_valid     <= vram9_valid_i;
   vram9_event_address   <= vram9_pending_address;
   vram9_event_access    <= vram9_pending_access;
   vram9_event_be        <= vram9_pending_be;
   vram9_event_data      <= vram9_pending_data;
   vram9_event_frame     <= vram9_pending_frame;
   vram9_event_timestamp <= vram9_pending_time;

   vram7_valid_i <= '1' when service_ready = '1' and
                             (vram7_pending = '1' or vram7_source_valid = '1') else '0';
   vram7_source_ready <= '1' when service_ready = '0' else vram7_event_ready;
   vram7_issue <= vram7_source_valid when service_ready = '0' else
                  vram7_valid_i and vram7_event_ready;
   vram7_event_valid     <= vram7_valid_i;
   vram7_event_address   <= vram7_pending_address when vram7_pending = '1' else
                            vram7_source_address;
   vram7_event_access    <= vram7_pending_access when vram7_pending = '1' else
                            vram7_source_access;
   vram7_event_be        <= vram7_pending_be when vram7_pending = '1' else
                            vram7_source_be;
   vram7_event_data      <= vram7_pending_data when vram7_pending = '1' else
                            vram7_source_data;
   vram7_event_frame     <= vram7_pending_frame when vram7_pending = '1' else
                            std_logic_vector(frame_counter);
   vram7_event_timestamp <= vram7_pending_time when vram7_pending = '1' else
                            std_logic_vector(timestamp_counter);

   hblank_valid_i <= '1' when service_ready = '1' and
                              (hblank_pending_count /= to_unsigned(0, hblank_pending_count'length) or
                               hblank_pulse = '1') else '0';
   hblank_event_valid <= hblank_valid_i;
   hblank_queue_read <= hblank_queue(to_integer(hblank_read_pointer));
   hblank_event_line <= hblank_queue_read(104 downto 96)
                         when hblank_pending_count /= to_unsigned(0, hblank_pending_count'length) else
                         hblank_line;
   hblank_event_frame <= hblank_queue_read(95 downto 64)
                          when hblank_pending_count /= to_unsigned(0, hblank_pending_count'length) else
                          std_logic_vector(hblank_frame_counter);
   hblank_event_timestamp <= hblank_queue_read(63 downto 0)
                              when hblank_pending_count /= to_unsigned(0, hblank_pending_count'length) else
                              std_logic_vector(timestamp_counter);

   frame_valid_i <= '1' when service_ready = '1' and
                             (frame_pending_count /=
                                to_unsigned(0, frame_pending_count'length) or
                              frame_pulse = '1') else '0';
   frame_event_valid <= frame_valid_i;
   frame_queue_read <= frame_queue(to_integer(frame_read_pointer));
   frame_event_number <= frame_queue_read(95 downto 64)
                         when frame_pending_count /=
                            to_unsigned(0, frame_pending_count'length) else
                         std_logic_vector(frame_counter + 1);
   frame_event_timestamp <= frame_queue_read(63 downto 0)
                            when frame_pending_count /=
                               to_unsigned(0, frame_pending_count'length) else
                            std_logic_vector(timestamp_counter);

   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            timestamp_counter <= (others => '0');
            frame_counter <= (others => '0');
            hblank_frame_counter <= (others => '0');
            source_fault_i <= '0';
            gpu_pending <= '0';
            gpu_pending_cpu <= '0';
            gpu_read_pointer <= (others => '0');
            gpu_write_pointer <= (others => '0');
            gpu_pending_count <= (others => '0');
            vram9_pending <= '0';
            vram7_pending <= '0';
            hblank_pending_count <= (others => '0');
            hblank_read_pointer <= (others => '0');
            hblank_write_pointer <= (others => '0');
            frame_pending_count <= (others => '0');
            frame_read_pointer <= (others => '0');
            frame_write_pointer <= (others => '0');
         else
            timestamp_counter <= timestamp_counter + 1;

            if (service_ready = '0') then
               gpu_pending <= '0';
               gpu_read_pointer <= (others => '0');
               gpu_write_pointer <= (others => '0');
               gpu_pending_count <= (others => '0');
               vram9_pending <= '0';
               vram7_pending <= '0';
               hblank_pending_count <= (others => '0');
               hblank_read_pointer <= (others => '0');
               hblank_write_pointer <= (others => '0');
               frame_pending_count <= (others => '0');
               frame_read_pointer <= (others => '0');
               frame_write_pointer <= (others => '0');
            else
               if (gpu_queue_push = '1') then
                  if (gpu_pending = '1') then
                     gpu_queue(to_integer(gpu_write_pointer)) <=
                        gpu_pending_time & gpu_pending_frame &
                        gpu_pending_data & gpu_pending_be &
                        gpu_pending_access & gpu_pending_address;
                  else
                     gpu_queue(to_integer(gpu_write_pointer)) <=
                        std_logic_vector(timestamp_counter) &
                        std_logic_vector(frame_counter) & gpu_source_data &
                        gpu_source_be & gpu_source_access & gpu_source_address;
                  end if;
                  gpu_write_pointer <= gpu_write_pointer + 1;
               end if;

               if (gpu_queue_pop = '1') then
                  gpu_read_pointer <= gpu_read_pointer + 1;
               end if;

               case std_logic_vector'(gpu_queue_push & gpu_queue_pop) is
                  when "10" => gpu_pending_count <= gpu_pending_count + 1;
                  when "01" => gpu_pending_count <= gpu_pending_count - 1;
                  when others => null;
               end case;

               if (gpu_pending = '1') then
                  if (gpu_pending_move = '1') then
                     gpu_pending <= '0';
                  end if;
               elsif (gpu_source_valid = '1' and gpu_queue_space = '0') then
                  gpu_pending <= '1';
                  gpu_pending_cpu <= gpu_source_is_cpu;
                  gpu_pending_address <= gpu_source_address;
                  gpu_pending_access <= gpu_source_access;
                  gpu_pending_be <= gpu_source_be;
                  gpu_pending_data <= gpu_source_data;
                  gpu_pending_frame <= std_logic_vector(frame_counter);
                  gpu_pending_time <= std_logic_vector(timestamp_counter);
               end if;

               if (vram9_source_valid = '1' and
                   (vram9_pending = '0' or vram9_event_ready = '1')) then
                  vram9_pending <= '1';
                  vram9_pending_address <= vram9_source_address;
                  vram9_pending_access <= vram9_source_access;
                  vram9_pending_be <= vram9_source_be;
                  vram9_pending_data <= vram9_source_data;
                  vram9_pending_frame <= std_logic_vector(frame_counter);
                  vram9_pending_time <= std_logic_vector(timestamp_counter);
               elsif (vram9_pending = '1' and vram9_event_ready = '1') then
                  vram9_pending <= '0';
               end if;

               if (vram7_pending = '1') then
                  if (vram7_event_ready = '1') then
                     vram7_pending <= '0';
                  end if;
               elsif (vram7_source_valid = '1' and vram7_event_ready = '0') then
                  vram7_pending <= '1';
                  vram7_pending_address <= vram7_source_address;
                  vram7_pending_access <= vram7_source_access;
                  vram7_pending_be <= vram7_source_be;
                  vram7_pending_data <= vram7_source_data;
                  vram7_pending_frame <= std_logic_vector(frame_counter);
                  vram7_pending_time <= std_logic_vector(timestamp_counter);
               end if;

               if (hblank_pending_count = to_unsigned(0, hblank_pending_count'length)) then
                  if (hblank_pulse = '1' and hblank_event_ready = '0') then
                     hblank_queue(to_integer(hblank_write_pointer)) <=
                        hblank_line & std_logic_vector(hblank_frame_counter) &
                        std_logic_vector(timestamp_counter);
                     hblank_write_pointer <= hblank_write_pointer + 1;
                     hblank_pending_count <= to_unsigned(1, hblank_pending_count'length);
                  end if;
               elsif (hblank_event_ready = '1') then
                  hblank_read_pointer <= hblank_read_pointer + 1;
                  if (hblank_pulse = '1') then
                     hblank_queue(to_integer(hblank_write_pointer)) <=
                        hblank_line & std_logic_vector(hblank_frame_counter) &
                        std_logic_vector(timestamp_counter);
                     hblank_write_pointer <= hblank_write_pointer + 1;
                  else
                     hblank_pending_count <= hblank_pending_count - 1;
                  end if;
               elsif (hblank_pulse = '1') then
                  if (hblank_pending_count /= to_unsigned(512, hblank_pending_count'length)) then
                     hblank_queue(to_integer(hblank_write_pointer)) <=
                        hblank_line & std_logic_vector(hblank_frame_counter) &
                        std_logic_vector(timestamp_counter);
                     hblank_write_pointer <= hblank_write_pointer + 1;
                     hblank_pending_count <= hblank_pending_count + 1;
                  else
                     source_fault_i <= '1';
                  end if;
               end if;

               if (frame_pending_count =
                   to_unsigned(0, frame_pending_count'length)) then
                  if (frame_pulse = '1' and frame_event_ready = '0') then
                     frame_queue(to_integer(frame_write_pointer)) <=
                        std_logic_vector(frame_counter + 1) &
                        std_logic_vector(timestamp_counter);
                     frame_write_pointer <= frame_write_pointer + 1;
                     frame_pending_count <=
                        to_unsigned(1, frame_pending_count'length);
                  end if;
               elsif (frame_event_ready = '1') then
                  frame_read_pointer <= frame_read_pointer + 1;
                  if (frame_pulse = '1') then
                     -- Retire the old head and append the current VBlank on
                     -- the same edge, preserving occupancy and FIFO order.
                     frame_queue(to_integer(frame_write_pointer)) <=
                        std_logic_vector(frame_counter + 1) &
                        std_logic_vector(timestamp_counter);
                     frame_write_pointer <= frame_write_pointer + 1;
                  else
                     frame_pending_count <= frame_pending_count - 1;
                  end if;
               elsif (frame_pulse = '1') then
                  if (frame_pending_count /=
                      to_unsigned(FRAME_QUEUE_DEPTH,
                                  frame_pending_count'length)) then
                     frame_queue(to_integer(frame_write_pointer)) <=
                        std_logic_vector(frame_counter + 1) &
                        std_logic_vector(timestamp_counter);
                     frame_write_pointer <= frame_write_pointer + 1;
                     frame_pending_count <= frame_pending_count + 1;
                  else
                     -- A timing boundary cannot be backpressured. Never
                     -- replace an older ownership marker with a newer one;
                     -- expose the capacity failure before corrupting order.
                     source_fault_i <= '1';
                  end if;
               end if;
            end if;

            if (frame_pulse = '1') then
               frame_counter <= frame_counter + 1;
            end if;
            if (hblank_pulse = '1' and
                unsigned(hblank_line) = to_unsigned(262, hblank_line'length)) then
               hblank_frame_counter <= hblank_frame_counter + 1;
            end if;
         end if;
      end if;
   end process;
end architecture;
