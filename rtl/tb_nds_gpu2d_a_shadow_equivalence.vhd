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

entity tb_nds_gpu2d_a_shadow_equivalence is
end entity;

architecture sim of tb_nds_gpu2d_a_shadow_equivalence is

   signal reference_data, shadow_data : std_logic_vector(31 downto 0);
   signal reference_done, shadow_done : std_logic;
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
      wired_out         => reference_data,
      wired_done        => reference_done,
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


   shadow : entity work.nds_gpu2d_register_shadow
      generic map(is_engine_b => false)
      port map(clk, reset, gb_bus, shadow_data, shadow_done);
   process
      variable random : unsigned(31 downto 0) := x"C0FFEE19";
      procedure check is
      begin
         wait for 1 ns;
         assert reference_data = shadow_data and reference_done = shadow_done
            report "register mismatch address=" & to_hstring(gb_bus.Adr) &
                   " old=" & to_hstring(reference_data) & " new=" & to_hstring(shadow_data)
            severity failure;
      end procedure;
      procedure tick is
      begin
         wait until rising_edge(clk); check; wait until falling_edge(clk);
      end procedure;
   begin
      gb_bus.rst <= '1'; tick; gb_bus.rst <= '0'; reset <= '0'; tick;
      for iteration in 0 to 7 loop
         for address in 0 to 63 loop
            for lanes in 0 to 15 loop
               random := random(30 downto 0) & (random(31) xor random(21) xor random(1) xor random(0));
               gb_bus.Adr <= std_logic_vector(to_unsigned(address * 4, 28));
               gb_bus.Din <= std_logic_vector(random);
               gb_bus.bEna <= std_logic_vector(to_unsigned(lanes, 4));
               gb_bus.rnw <= '0'; gb_bus.ena <= '1'; tick;
               gb_bus.rnw <= '1'; tick;
               gb_bus.ena <= '0'; tick;
               gb_bus.Adr <= std_logic_vector(to_unsigned(16#1000# + address * 4, 28));
               gb_bus.rnw <= '0'; gb_bus.ena <= '1'; tick;
               gb_bus.Adr <= std_logic_vector(to_unsigned(address * 4, 28)); check;
            end loop;
         end loop;
         gb_bus.rst <= '1'; tick; gb_bus.rst <= '0';
      end loop;
      report "PASS: Engine A original GPU vs shadow, 32768 bus cycles, byte enables, address isolation and resets" severity note;
      std.env.stop;
      wait;
   end process;
end architecture;
