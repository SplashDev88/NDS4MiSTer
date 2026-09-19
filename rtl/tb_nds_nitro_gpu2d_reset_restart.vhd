-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Session reset during an accepted BG read must not strand an inactive drawer.
-- Exercise real text/affine drawers, their shared arbiter and merge output.
-- Same-mode restart and reset after completion are independent passing controls.
-- The memory owner discards its old response pipeline when reset is asserted.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_nds_nitro_gpu2d_reset_restart is
   generic (OLD_MODE : natural := 0; NEW_MODE : natural := 1; INTERRUPT_LINE : boolean := true; NEW_3D : boolean := false);
end entity;

architecture sim of tb_nds_nitro_gpu2d_reset_restart is

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
   signal srv_bg_lcdc       : std_logic;
   signal lcdc_check       : std_logic := '0';
   signal lcdc_count       : natural := 0;
   signal lcdc_expected_y  : natural := 0;
   signal lcdc_expected_base : natural := 0;
   signal lcdc_read_count  : natural := 0;
   signal lcdc_bright      : natural range 0 to 16 := 0;
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
      srv_bg_lcdc       => srv_bg_lcdc,
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
               if srv_bg_lcdc='1' then bg_pipe(0).data <= x"801F7C00";
               else bg_pipe(0).data <= (others=>'0'); end if;
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

   p_lcdc_check : process(clk)
      variable r,g,b : natural;
   begin
      if rising_edge(clk) then
         if lcdc_check='0' then lcdc_count<=0;lcdc_read_count<=0;
         else
            if srv_bg_req='1' and srv_bg_accept='1' then
               assert srv_bg_lcdc='1' and srv_bg_addr=lcdc_expected_base+lcdc_read_count
                  report "LCDC channel/address switched during a pending line" severity failure;
               lcdc_read_count<=lcdc_read_count+1;
            end if;
            if pixel_out_we='1' then
               assert pixel_out_x=lcdc_count and pixel_out_y=lcdc_expected_y
                  report "LCDC integrated pixel order" severity failure;
               r:=0;g:=0;b:=62;
               if lcdc_count mod 2=1 then r:=62;b:=0;end if;
               r:=r+(63-r)*lcdc_bright/16;
               g:=g+(63-g)*lcdc_bright/16;
               b:=b+(63-b)*lcdc_bright/16;
               assert pixel_out_data=std_logic_vector(to_unsigned(b*4096+g*64+r,18))
                  report "LCDC integrated brightness/color/blank handling" severity failure;
               lcdc_count<=lcdc_count+1;
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
      variable pixels : natural := 0;
      variable ends : natural := 0;
      procedure regwrite(a : natural; d : std_logic_vector(31 downto 0)) is
      begin
         gb_bus.Adr <= std_logic_vector(to_unsigned(a, gb_bus.Adr'length));
         gb_bus.Din <= d; gb_bus.rnw <= '0'; gb_bus.bEna <= "1111"; gb_bus.ena <= '1';
         wait until rising_edge(clk);
         gb_bus.ena <= '0'; gb_bus.rnw <= '1'; gb_bus.bEna <= "0000";
         wait until falling_edge(clk);
      end procedure;
      procedure configure(mode : natural) is
      begin
         regwrite(16#00C#, x"04000000");
         regwrite(16#030#, x"00000100");
         regwrite(16#038#, x"00002000");
         regwrite(16#000#, std_logic_vector(to_unsigned(16#10800# + mode,32)));
      end procedure;
   begin
      gb_bus.rst <= '1';
      wait until falling_edge(clk) and clr_busy='0';
      reset <= '0';gb_bus.rst <= '0';
      wait until falling_edge(clk);
      configure(OLD_MODE);
      if NEW_3D then regwrite(16#008#, x"00000400"); regwrite(16#000#, x"00010100");end if;
      linecounter <= 42; drawline <= '1';
      wait until rising_edge(clk);drawline <= '0';
      if INTERRUPT_LINE then
         -- Cancel a real accepted memory transaction from the old BG3 drawer.
         -- The reset model cancels its delayed response, as the production
         -- VRAM request owner does at the cartridge/session boundary.
         wait until rising_edge(clk) and srv_bg_req='1' and srv_bg_accept='1' and srv_bg_addr>=2048;
         wait until falling_edge(clk);
         assert dbg_bg_busy='1' report "old drawer not busy at reset" severity failure;
         assert bg_accept_count > bg_done_count report "no accepted read outstanding at reset" severity failure;
      else
         wait until rising_edge(clk) and line_busy='0';
         wait until falling_edge(clk);
      end if;
      reset<='1';gb_bus.rst<='1';
      for i in 0 to 270 loop wait until falling_edge(clk);end loop;
      assert clr_busy='0' report "palette reset failed to complete" severity failure;
      reset<='0';gb_bus.rst<='0';wait until falling_edge(clk);
      configure(NEW_MODE);
      if NEW_3D then regwrite(16#000#, std_logic_vector(to_unsigned(16#10808# + NEW_MODE,32)));end if;
      linecounter<=191;drawline<='1';
      wait until rising_edge(clk);drawline<='0';
      for i in 0 to 8191 loop
         wait until rising_edge(clk);
         if pixel_out_we='1' then
            assert pixel_out_y=191 and pixel_out_x=pixels report "post-reset line pixel order" severity failure;
            pixels:=pixels+1;
         end if;
         if h3d_merge_line_end='1' then ends:=ends+1;end if;
         exit when pixels=256 and line_busy='0';
      end loop;
      assert pixels=256 and ends=1 and line_busy='0'
         report "RESET_RESTART_FAIL old_mode=" & integer'image(OLD_MODE) & " new_mode=" & integer'image(NEW_MODE) & " new_3d=" & boolean'image(NEW_3D) & " interrupted=" & boolean'image(INTERRUPT_LINE) & " pixels=" & integer'image(pixels) & " bg_busy=" & std_logic'image(dbg_bg_busy) & " obj_busy=" & std_logic'image(dbg_obj_busy)
         severity failure;
      report "RESET_RESTART_PASS old_mode=" & integer'image(OLD_MODE) & " new_mode=" & integer'image(NEW_MODE) & " new_3d=" & boolean'image(NEW_3D) & " interrupted=" & boolean'image(INTERRUPT_LINE) severity note;
      tests_done<=true;wait;
   end process;
   p_timeout : process
   begin
      wait for 500 us;
      assert tests_done report "RESET_RESTART_TIMEOUT" severity failure;
      wait;
   end process;
end architecture;
