-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Focused product-local regression for a live DISPCNT BG-mode transition.
--
-- A mode-0 line starts BG3's text drawer.  On the very next clock -- the
-- clock on which that drawer presents its first map request -- DISPCNT changes
-- to mode 1, where BG3 belongs to the affine drawer.  The current line must
-- retain its text ownership until every accepted request and response drains;
-- the following line must start and complete through the affine drawer.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_nds_nitro_gpu2d_mode_race is
end entity;

architecture sim of tb_nds_nitro_gpu2d_mode_race is

   constant CLK_PERIOD : time := 10 ns;
   constant BG_LATENCY : positive := 4;
   constant LINE_BOUND : positive := 4096;

   signal clk        : std_logic := '0';
   signal reset      : std_logic := '1';
   signal tests_done : boolean := false;

   signal gb_bus : proc_bus_gb_type :=
      ((others => '0'), (others => '0'), '1', '0', ACCESS_32BIT,
       "0000", '0');

   signal linecounter       : integer range 0 to 191 := 0;
   signal linecounter_obj   : integer range 0 to 191 := 0;
   signal drawline          : std_logic := '0';
   signal drawObj           : std_logic := '0';
   signal line_trigger      : std_logic := '0';
   signal hblank_trigger    : std_logic := '0';
   signal vblank_trigger    : std_logic := '0';
   signal refpoint_update   : std_logic := '0';
   signal line_busy         : std_logic;
   signal epfill_busy       : std_logic;
   signal clr_busy          : std_logic;

   signal pal_we            : std_logic := '0';
   signal pal_addr          : integer range 0 to 255 := 0;
   signal pal_din           : std_logic_vector(31 downto 0) := (others => '0');
   signal oam_we            : std_logic := '0';
   signal oam_addr          : integer range 0 to 255 := 0;
   signal oam_din           : std_logic_vector(31 downto 0) := (others => '0');

   signal srv_bg_req        : std_logic;
   signal srv_bg_addr       : integer range 0 to 131071;
   signal srv_bg_data       : std_logic_vector(31 downto 0) := (others => '0');
   signal srv_bg_done       : std_logic := '0';
   signal srv_bg_accept     : std_logic;
   signal srv_obj_req       : std_logic;
   signal srv_obj_addr      : integer range 0 to 65535;
   signal srv_obj_data      : std_logic_vector(31 downto 0) := (others => '0');
   signal srv_obj_done      : std_logic := '0';
   signal srv_obj_accept    : std_logic;
   signal srv_bgep_req      : std_logic;
   signal srv_bgep_addr     : integer range 0 to 8191;
   signal srv_bgep_data     : std_logic_vector(31 downto 0) := (others => '0');
   signal srv_bgep_done     : std_logic := '0';
   signal srv_objep_req     : std_logic;
   signal srv_objep_addr    : integer range 0 to 2047;
   signal srv_objep_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal srv_objep_done    : std_logic := '0';

   signal pixel_out_x       : integer range 0 to 255;
   signal pixel_out_y       : integer range 0 to 191;
   signal pixel_out_data    : std_logic_vector(17 downto 0);
   signal pixel_out_we      : std_logic;
   signal h3d_pixel_valid   : std_logic := '0';
   signal h3d_pixel_data    : std_logic_vector(22 downto 0) := (others => '0');
   signal h3d_line_request  : std_logic;
   signal h3d_line_request_y : integer range 0 to 191;
   signal h3d_merge_line_start : std_logic;
   signal h3d_merge_line_end   : std_logic;
   signal h3d_merge_pixel_x    : integer range 0 to 255;
   signal h3d_merge_pixel_y    : integer range 0 to 191;
   signal h3d_reader_enable    : std_logic := '0';
   signal h3d_reader_selected  : std_logic := '0';
   signal h3d_check_enable     : std_logic := '0';
   signal h3d_output_count     : natural range 0 to 512 := 0;
   signal h3d_request_count    : natural := 0;
   signal dbg_bg_busy       : std_logic;
   signal dbg_obj_busy      : std_logic;
   signal dbg_bgmode        : std_logic_vector(2 downto 0);
   signal dbg_fblank        : std_logic;
   signal dbg_bg1_scroll_triplet : std_logic_vector(31 downto 0);

   type t_bg_rsp is record
      valid : std_logic;
      data  : std_logic_vector(31 downto 0);
   end record;
   type t_bg_pipe is array (0 to BG_LATENCY - 1) of t_bg_rsp;
   signal bg_pipe : t_bg_pipe :=
      (others => ('0', (others => '0')));
   signal bg_accept_count : natural := 0;
   signal bg_done_count   : natural := 0;

   function h3d_pattern(x : natural) return std_logic_vector is
      variable r, g, b : natural range 0 to 63;
   begin
      r := x mod 64;
      g := (x / 4) mod 64;
      b := 63 - (x mod 64);
      return std_logic_vector(to_unsigned(31, 5)) &
             std_logic_vector(to_unsigned(b, 6)) &
             std_logic_vector(to_unsigned(g, 6)) &
             std_logic_vector(to_unsigned(r, 6));
   end function;

begin

   clk <= not clk after CLK_PERIOD / 2 when not tests_done else '0';

   idut : entity work.nds_gpu2d
   generic map
   (
      is_engine_b => '0',
      is_simu     => '1'
   )
   port map
   (
      clk               => clk,
      reset             => reset,
      gb_bus            => gb_bus,
      wired_out         => open,
      wired_done        => open,
      linecounter       => linecounter,
      drawline          => drawline,
      linecounter_obj   => linecounter_obj,
      drawObj           => drawObj,
      line_trigger      => line_trigger,
      hblank_trigger    => hblank_trigger,
      vblank_trigger    => vblank_trigger,
      refpoint_update   => refpoint_update,
      line_busy         => line_busy,
      epfill_busy       => epfill_busy,
      clr_busy          => clr_busy,
      pal_we            => pal_we,
      pal_addr          => pal_addr,
      pal_din           => pal_din,
      pal_be            => "1111",
      oam_we            => oam_we,
      oam_addr          => oam_addr,
      oam_din           => oam_din,
      oam_be            => "1111",
      srv_bg_req        => srv_bg_req,
      srv_bg_addr       => srv_bg_addr,
      srv_bg_data       => srv_bg_data,
      srv_bg_done       => srv_bg_done,
      srv_bg_accept     => srv_bg_accept,
      srv_obj_req       => srv_obj_req,
      srv_obj_addr      => srv_obj_addr,
      srv_obj_data      => srv_obj_data,
      srv_obj_done      => srv_obj_done,
      srv_obj_accept    => srv_obj_accept,
      srv_bgep_req      => srv_bgep_req,
      srv_bgep_addr     => srv_bgep_addr,
      srv_bgep_data     => srv_bgep_data,
      srv_bgep_done     => srv_bgep_done,
      srv_objep_req     => srv_objep_req,
      srv_objep_addr    => srv_objep_addr,
      srv_objep_data    => srv_objep_data,
      srv_objep_done    => srv_objep_done,
      h3d_pixel_valid   => h3d_pixel_valid,
      h3d_pixel_data    => h3d_pixel_data,
      h3d_line_request  => h3d_line_request,
      h3d_line_request_y => h3d_line_request_y,
      h3d_merge_line_start => h3d_merge_line_start,
      h3d_merge_line_end => h3d_merge_line_end,
      h3d_merge_pixel_x => h3d_merge_pixel_x,
      h3d_merge_pixel_y => h3d_merge_pixel_y,
      pixel_out_x       => pixel_out_x,
      pixel_out_y       => pixel_out_y,
      pixel_out_data    => pixel_out_data,
      pixel_out_we      => pixel_out_we,
      dbg_bg_busy       => dbg_bg_busy,
      dbg_obj_busy      => dbg_obj_busy,
      dbg_bgmode        => dbg_bgmode,
      dbg_fblank        => dbg_fblank,
      dbg_bg1_scroll_triplet => dbg_bg1_scroll_triplet
   );

   -- The focused server accepts one request per cycle and returns responses in
   -- order after a fixed, non-zero latency.  All-zero map/tile words are
   -- sufficient for both drawers to walk and finish a complete line.
   srv_bg_accept <= srv_bg_req;
   srv_obj_accept <= srv_obj_req;

   p_bg_server : process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            bg_pipe        <= (others => ('0', (others => '0')));
            srv_bg_done    <= '0';
            srv_bg_data    <= (others => '0');
            bg_accept_count <= 0;
            bg_done_count   <= 0;
         else
            for k in BG_LATENCY - 1 downto 1 loop
               bg_pipe(k) <= bg_pipe(k - 1);
            end loop;
            bg_pipe(0).valid <= '0';
            if (srv_bg_req = '1' and srv_bg_accept = '1') then
               bg_pipe(0).valid <= '1';
               bg_pipe(0).data  <= (others => '0');
               bg_accept_count  <= bg_accept_count + 1;
            end if;
            srv_bg_done <= bg_pipe(BG_LATENCY - 1).valid;
            srv_bg_data <= bg_pipe(BG_LATENCY - 1).data;
            if (bg_pipe(BG_LATENCY - 1).valid = '1') then
               bg_done_count <= bg_done_count + 1;
            end if;
         end if;
      end if;
   end process;

   -- Cycle-accurate model of nds_h3d_plane_reader's registered pixel port.
   -- It accepts x=0 on line_start, returns that pixel after the same rising
   -- edge, and keeps the x=255 result valid after line_end releases the bank.
   p_h3d_reader : process (clk)
   begin
      if rising_edge(clk) then
         h3d_pixel_valid <= '0';
         if (reset = '1' or h3d_reader_enable = '0') then
            h3d_reader_selected <= '0';
            h3d_pixel_data <= (others => '0');
         else
            h3d_pixel_data <= h3d_pattern(h3d_merge_pixel_x);
            if (h3d_merge_line_start = '1') then
               h3d_reader_selected <= '1';
               h3d_pixel_valid <= '1';
            elsif (h3d_reader_selected = '1') then
               h3d_pixel_valid <= '1';
            end if;
            if (h3d_merge_line_end = '1') then
               h3d_reader_selected <= '0';
            end if;
         end if;
      end if;
   end process;

   p_h3d_contract : process (clk)
      variable expected : std_logic_vector(22 downto 0);
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            h3d_request_count <= 0;
            h3d_output_count <= 0;
         else
            if (h3d_line_request = '1') then
               h3d_request_count <= h3d_request_count + 1;
               assert h3d_line_request_y = linecounter
                  report "H3D request y did not accompany the accepted drawline"
                  severity failure;
            end if;
            if (h3d_check_enable = '1' and pixel_out_we = '1') then
               expected := h3d_pattern(h3d_output_count mod 256);
               assert pixel_out_x = h3d_output_count mod 256
                  report "registered H3D reader is misaligned with merge x"
                  severity failure;
               assert pixel_out_y = 2 + h3d_output_count / 256
                  report "registered H3D reader is misaligned with merge y"
                  severity failure;
               assert pixel_out_data = expected(17 downto 0)
                  report "registered H3D pixel data is shifted from merge x"
                  severity failure;
               assert h3d_output_count < 512
                  report "H3D merge emitted more than two complete lines"
                  severity failure;
               h3d_output_count <= h3d_output_count + 1;
            end if;
         end if;
      end if;
   end process;

   -- No OBJ line or vblank palette fill is requested in this regression.
   -- Treat any such traffic as an immediate scope failure.
   p_unused_channels : process (clk)
   begin
      if rising_edge(clk) and reset = '0' then
         assert srv_obj_req = '0'
            report "unexpected OBJ request in BG mode-race regression"
            severity failure;
         assert srv_bgep_req = '0' and srv_objep_req = '0'
            report "unexpected ext-palette request in BG mode-race regression"
            severity failure;
      end if;
   end process;

   p_drive : process
      variable cycles           : natural;
      variable accept_base      : natural;
      variable done_base        : natural;
      variable text_req_count   : natural;
      variable affine_req_count : natural;
      variable first_seen       : boolean;
      variable request_base     : natural;

      procedure regwrite(a : natural; d : std_logic_vector(31 downto 0)) is
      begin
         gb_bus.Adr  <= std_logic_vector(to_unsigned(a, gb_bus.Adr'length));
         gb_bus.Din  <= d;
         gb_bus.rnw  <= '0';
         gb_bus.bEna <= "1111";
         gb_bus.ena  <= '1';
         wait until rising_edge(clk);
         gb_bus.ena  <= '0';
         gb_bus.rnw  <= '1';
         gb_bus.bEna <= "0000";
         wait until falling_edge(clk);
      end procedure;

      procedure renderline(y : natural) is
      begin
         linecounter <= y;
         drawline <= '1';
         wait until rising_edge(clk);
         drawline <= '0';
         wait until rising_edge(clk) and line_busy = '0';
         wait until falling_edge(clk);
      end procedure;

   begin
      -- The palette/OAM clear deliberately runs while reset is asserted.
      wait until falling_edge(clk) and clr_busy = '0';
      reset <= '0';
      wait until falling_edge(clk);

      -- The compact hardware diagnostic captures the full nine-bit BG1HOFS
      -- accepted by the renderer on the exact hardware-observed problem row.
      -- Exercise bit 8 explicitly: losing it would reproduce the observed
      -- 256-pixel cloud/hill jump. Since the write completes before the line
      -- starts, the write/latch mismatch bit must remain clear.
      regwrite(16#014#, x"00000134");
      renderline(30);
      assert dbg_bg1_scroll_triplet(31 downto 28) = x"F" and
             dbg_bg1_scroll_triplet(27) = '1' and
             dbg_bg1_scroll_triplet(26) = '0' and
             dbg_bg1_scroll_triplet(25) = '0' and
             dbg_bg1_scroll_triplet(24) = '1' and
             dbg_bg1_scroll_triplet(23 downto 15) =
                std_logic_vector(to_unsigned(16#134#, 9))
         report "BG1 line-30 receipt did not preserve the accepted full-width HOFS"
         severity failure;

      -- Give BG3 a unique 8-KB map base while BG0-2 remain at base zero.  The
      -- public BG server has no owner tag, so these addresses identify BG3
      -- without relying on global arbitration order.  BG3PA advances one
      -- source pixel per output pixel.  BG3RefX is 32.0 in 20.8 format:
      -- text begins at word 2048, affine at word (8192 + 4) / 4 = 2049.
      regwrite(16#00C#, x"04000000");
      regwrite(16#030#, x"00000100");
      regwrite(16#038#, x"00002000");

      -- DISPCNT: mode 0, graphics display mode, only BG3 enabled for
      -- composition.
      regwrite(16#000#, x"00010800");
      assert dbg_bgmode = "000"
         report "failed to program initial mode 0" severity failure;

      accept_base    := bg_accept_count;
      done_base      := bg_done_count;
      text_req_count := 0;

      linecounter <= 0;
      drawline <= '1';
      wait until rising_edge(clk);
      drawline <= '0';
      wait for 1 ns;
      assert line_busy = '1' and dbg_bg_busy = '1'
         report "mode-0 BG3 text drawline was not accepted" severity failure;

      -- This is deliberately not the regwrite helper.  Keeping the DISPCNT
      -- write asserted for exactly this next edge makes the register switch on
      -- the same edge on which the freshly started text drawer creates its
      -- first map request.  The arbiter cannot have accepted that request yet.
      gb_bus.Adr  <= (others => '0');
      gb_bus.Din  <= x"00010801";
      gb_bus.rnw  <= '0';
      gb_bus.bEna <= "1111";
      gb_bus.ena  <= '1';
      wait until rising_edge(clk);
      gb_bus.ena  <= '0';
      gb_bus.rnw  <= '1';
      gb_bus.bEna <= "0000";
      wait for 1 ns;

      assert dbg_bgmode = "001"
         report "DISPCNT did not switch to mode 1 on request-creation edge"
         severity failure;

      -- Observe only the public line-server contract.  All four BG drawers
      -- run and arbitrate on this channel, so search the whole line for BG3's
      -- unique map address rather than assuming it wins first.  With the
      -- fixed per-line owner, the text request created on the mode-write edge
      -- remains visible.  A live-mode ownership mux loses it.
      first_seen := false;
      cycles := 0;
      while line_busy = '1' and cycles < LINE_BOUND loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         if (srv_bg_req = '1') then
            assert srv_bg_accept = '1'
               report "public BG server backpressured unexpectedly"
               severity failure;
            text_req_count := text_req_count + 1;
            if (srv_bg_addr = 2048 and not first_seen) then
               first_seen := true;
               report "MODE_RACE_TEXT_MARKER addr=" &
                      integer'image(srv_bg_addr) & " cycles=" &
                      integer'image(cycles)
                  severity note;
            end if;
         end if;
      end loop;
      assert line_busy = '0'
         report "mode-0 text line failed to clear within bound"
         severity failure;
      assert first_seen
         report "mode-0 BG3 text request was lost across live mode switch"
         severity failure;
      for k in 1 to BG_LATENCY + 4 loop
         wait until falling_edge(clk);
      end loop;
      assert dbg_bg_busy = '0' and srv_bg_req = '0'
         report "public BG interface retained work after text line completion"
         severity failure;
      assert text_req_count > 0 and
             bg_accept_count = accept_base + text_req_count and
             bg_done_count = done_base + text_req_count
         report "text-line public request/accept/done counts did not match exactly"
         severity failure;
      report "MODE_RACE_TEXT_CLEAR cycles=" & integer'image(cycles) &
             " requests=" & integer'image(text_req_count)
         severity note;

      -- The next accepted line must observe the already-live mode 1 and use
      -- affine BG3.  Pulse the drawer's public line trigger before drawline so
      -- it samples BG3RefX=32.0; BG3's unique map request is word 2049.
      linecounter <= 1;
      line_trigger <= '1';
      wait until rising_edge(clk);
      line_trigger <= '0';
      wait until falling_edge(clk);

      accept_base      := bg_accept_count;
      done_base        := bg_done_count;
      affine_req_count := 0;

      drawline <= '1';
      wait until rising_edge(clk);
      drawline <= '0';
      wait for 1 ns;
      assert line_busy = '1' and dbg_bg_busy = '1'
         report "mode-1 affine BG3 drawline was not accepted"
         severity failure;

      first_seen := false;
      cycles := 0;
      while line_busy = '1' and cycles < LINE_BOUND loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         if (srv_bg_req = '1') then
            assert srv_bg_accept = '1'
               report "public BG server backpressured affine line unexpectedly"
               severity failure;
            affine_req_count := affine_req_count + 1;
            if (srv_bg_addr = 2049 and not first_seen) then
               first_seen := true;
               report "MODE_RACE_AFFINE_MARKER addr=" &
                      integer'image(srv_bg_addr) & " cycles=" &
                      integer'image(cycles)
                  severity note;
            end if;
         end if;
      end loop;
      assert line_busy = '0'
         report "mode-1 affine line failed to clear within bound"
         severity failure;
      assert first_seen
         report "mode-1 BG3 affine request did not reach public server"
         severity failure;
      for k in 1 to BG_LATENCY + 4 loop
         wait until falling_edge(clk);
      end loop;
      assert dbg_bg_busy = '0' and srv_bg_req = '0'
         report "public BG interface retained work after affine line completion"
         severity failure;
      assert affine_req_count > 0 and
             bg_accept_count = accept_base + affine_req_count and
             bg_done_count = done_base + affine_req_count
         report "affine-line public request/accept/done counts did not match exactly"
         severity failure;

      -- Switch to engine-A 3D-as-BG0, then drive the H3D input from the
      -- one-cycle registered reader model above.  Every output x must match
      -- the address launched one clock before nds_drawer_merge sampled it.
      regwrite(16#000#, x"00010108");
      -- BG3 is not composed in this phase, but it still walks its text map.
      -- Give the held line a distinct tile-aligned scroll so its first map
      -- word proves that the raw-drawline configuration was preserved.
      regwrite(16#01C#, x"00000010");
      hblank_trigger <= '1';
      wait until rising_edge(clk);
      hblank_trigger <= '0';
      wait until falling_edge(clk);

      linecounter <= 2;
      h3d_reader_enable <= '1';
      h3d_check_enable <= '1';
      request_base := h3d_request_count;
      drawline <= '1';
      wait until rising_edge(clk);
      drawline <= '0';
      wait for 1 ns;
      assert line_busy = '1'
         report "H3D alignment drawline was not accepted" severity failure;

      -- A second architectural drawline while the renderer is busy must be
      -- retained and rendered after the first line, while still launching its
      -- independent H3D prefetch at the original raster pulse.
      linecounter <= 3;
      drawline <= '1';
      wait until rising_edge(clk);
      drawline <= '0';

      -- Model the following HBlank DMA changing BG3HOFS after the raw pulse.
      -- The queued line must retain 16 (first map word 2049), not sample the
      -- new 32-pixel scroll (first map word 2050) when it starts later.
      regwrite(16#01C#, x"00000020");

      cycles := 0;
      while h3d_output_count < 256 loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert cycles < LINE_BOUND
            report "first H3D line did not finish before held-line snapshot check"
            severity failure;
      end loop;

      first_seen := false;
      cycles := 0;
      while not first_seen loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         if (srv_bg_req = '1' and srv_bg_addr >= 2048) then
            assert srv_bg_addr = 2049
               report "held text line sampled the following HBlank scroll value"
               severity failure;
            first_seen := true;
         end if;
         assert cycles < LINE_BOUND
            report "held text line did not issue its BG3 map request"
            severity failure;
      end loop;

      cycles := 0;
      while line_busy = '1' and cycles < LINE_BOUND loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
      end loop;
      assert line_busy = '0'
         report "H3D alignment line failed to clear within bound"
         severity failure;
      wait until rising_edge(clk);
      wait for 1 ns;
      assert h3d_request_count = request_base + 2
         report "architectural drawlines did not each produce an H3D request"
         severity failure;
      assert h3d_output_count = 512
         report "held drawline did not render both H3D rows in order"
         severity failure;
      assert h3d_pixel_valid = '0'
         report "H3D reader did not release validity after final registered read"
         severity failure;
      h3d_check_enable <= '0';
      h3d_reader_enable <= '0';

      report "MODE_RACE_PASS text_requests=" & integer'image(text_req_count) &
             " affine_requests=" & integer'image(affine_req_count) &
             " h3d_pixels=" & integer'image(h3d_output_count)
         severity note;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for 200 us;
      if not tests_done then
         report "tb_nds_nitro_gpu2d_mode_race: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
