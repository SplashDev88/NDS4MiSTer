-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Product mixed-language shim between nds_nitro_console_island.sv and the
-- adapted nds_nitro_console_top. Derived from Nitro_DarkSide nds_port_wrap at
-- pinned commit d2dabe03344c0a685cd0f00e42b1a89606710dee. This is not the
-- donor NDS.sv shell. Quartus can't carry VHDL record ports (dbg_export9/7,
-- cpu_export_type) or ranged-integer ports (pixel_out_x/y) across the
-- language boundary, so this wrapper terminates the debug records (is_simu
-- only anyway), converts the pixel coordinates to plain vectors, and exposes
-- everything else 1:1 as std_logic/std_logic_vector.
--
-- No logic lives here. Generics keep their nds_top defaults (is_simu='0', main
-- RAM at SDRAM byte offset 8 MB) except the four set explicitly
-- on the generic map below - GPU_FAST, GPU2D_B_ENABLE, SOUND_ENABLE and
-- DEBUG_ENABLE - each
-- with its reason written out there. SOUND_ENABLE and DEBUG_ENABLE are the two
-- that select the deliberately pruned first-beta product cone.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_nitro_console_wrap is
   generic
   (
      -- Must match the SystemVerilog island's clkMem phase counter.  The
      -- product currently keeps GPU_FAST off, but carrying the exact ratio
      -- through the mixed-language boundary prevents a future fast-engine
      -- build from silently using the 3x phase gate under a 4x PLL.
      CLKMEM_RATIO     : integer := 3
   );
   port
   (
      clk1x            : in  std_logic;   -- 33.513982 MHz system clock
      clk2x            : in  std_logic;   -- 67.027964 MHz (2x clk1x, same VCO): ARM9 island
      clkMem           : in  std_logic;   -- 3x/4x clk1x, phase-locked
      clkMemIndex      : in  std_logic_vector(1 downto 0);  -- clkMem phase, 0 on clk1x rising edge
      reset            : in  std_logic;
      nds_on           : in  std_logic;
      direct_boot      : in  std_logic;
      -- '1' = boot the real firmware from the retail BIOSes' reset vectors
      -- instead of HLE direct boot. See the header note on ARCHITECTURE.md.
      fw_boot          : in  std_logic;
      -- keys (active high)
      KeyA             : in  std_logic;
      KeyB             : in  std_logic;
      KeySelect        : in  std_logic;
      KeyStart         : in  std_logic;
      KeyRight         : in  std_logic;
      KeyLeft          : in  std_logic;
      KeyUp            : in  std_logic;
      KeyDown          : in  std_logic;
      KeyR             : in  std_logic;
      KeyL             : in  std_logic;
      KeyX             : in  std_logic;
      KeyY             : in  std_logic;
      lid_closed       : in  std_logic;

      -- touchscreen
      touch_active     : in  std_logic;
      touch_x          : in  std_logic_vector(7 downto 0);
      touch_y          : in  std_logic_vector(7 downto 0);

      -- boot status (HLE loader)
      boot_done        : out std_logic;
      boot_error       : out std_logic;

      -- card image read port (word addressed into the staged .nds)
      card_ena         : out std_logic;
      card_addr        : out std_logic_vector(24 downto 0);  -- word address (byte addr 26:2)
      card_din         : in  std_logic_vector(31 downto 0);
      card_done        : in  std_logic;

      -- Cartridge backup-memory byte port.  The island terminates this on one
      -- side of a mixed-width M10K; MiSTer's mounted .sav channel owns the
      -- other side.
      backup_addr         : out std_logic_vector(19 downto 0);
      backup_write_data   : out std_logic_vector(7 downto 0);
      backup_write_enable : out std_logic;
      backup_read_data    : in  std_logic_vector(7 downto 0);
      backup_write_toggle : out std_logic;
      backup_is_64k       : out std_logic;
      backup_save_type    : out std_logic_vector(3 downto 0);
      backup_profile_valid: out std_logic;
      backup_access_active: out std_logic;
      backup_cache_ready  : in  std_logic := '1';
      backup_run_ready    : in  std_logic := '1';

      -- SPI firmware flash image read port (128 KB, word addressed)
      fw_addr          : out std_logic_vector(15 downto 0);  -- word address (byte addr 17:2)
      fw_req           : out std_logic;
      fw_done          : in  std_logic;
      fw_data          : in  std_logic_vector(31 downto 0);
      -- Firmware write-back. Like every port here these are plain zero-based
      -- vectors: the island is SystemVerilog, so the console's unsigned ranges
      -- are converted on this side of the mixed-language boundary.
      fw_wr            : out std_logic;
      fw_wlane         : out std_logic_vector(1 downto 0);
      fw_wdata         : out std_logic_vector(7 downto 0);

      -- hot-loadable ARM7/ARM9 BIOS RAM write ports
      bios7_load_addr  : in std_logic_vector(13 downto 2);
      bios7_load_data  : in std_logic_vector(31 downto 0);
      bios7_load_be    : in std_logic_vector(3 downto 0);
      bios7_load_we    : in std_logic;
      bios7_load_done  : in std_logic;
      bios9_load_addr  : in std_logic_vector(11 downto 2);
      bios9_load_data  : in std_logic_vector(31 downto 0);
      bios9_load_be    : in std_logic_vector(3 downto 0);
      bios9_load_we    : in std_logic;
      bios9_load_done  : in std_logic;

      -- main RAM SDRAM request port + scheduler handshake
      mainram_allow    : in  std_logic;
      mainram_active   : out std_logic;
      mainram_busy     : out std_logic;
      sdram_ena        : out std_logic;
      sdram_rnw        : out std_logic;
      sdram_Adr        : out std_logic_vector(26 downto 0);
      sdram_Din        : out std_logic_vector(31 downto 0);
      sdram_be         : out std_logic_vector(3 downto 0);
      sdram_Dout       : in  std_logic_vector(31 downto 0);
      sdram_done32     : in  std_logic;
      -- upper half of the same ch2 burst + its later done, for nds_mainram's
      -- ARM9 pair reads (rtl/sdram.sv ch2_dout_hi)
      sdram_Dout_hi    : in  std_logic_vector(31 downto 0) := (others => '0');
      sdram_done64     : in  std_logic := '0';

      -- VRAM banks A..D backing store
      vsrv_req         : out std_logic;
      vsrv_rnw         : out std_logic;
      vsrv_bank        : out std_logic_vector(1 downto 0);
      vsrv_addr        : out std_logic_vector(14 downto 0);  -- word address (byte addr 16:2)
      vsrv_be          : out std_logic_vector(3 downto 0);
      vsrv_din         : out std_logic_vector(31 downto 0);
      vsrv_dout        : in  std_logic_vector(31 downto 0);
      vsrv_done        : in  std_logic;
      vrsrv_req        : out std_logic;
      vrsrv_bank       : out std_logic_vector(1 downto 0);
      vrsrv_addr       : out std_logic_vector(13 downto 0);
      vrsrv_dout       : in  std_logic_vector(63 downto 0);
      vrsrv_done       : in  std_logic;
      vrsrv_ready      : in  std_logic := '1';

      math_request     : out std_logic;
      math_address     : out std_logic_vector(31 downto 0);
      math_rnw         : out std_logic;
      math_access      : out std_logic_vector(1 downto 0);
      math_write_data  : out std_logic_vector(31 downto 0);
      math_read_data   : in  std_logic_vector(31 downto 0) := (others => '0');
      math_selected    : in  std_logic := '0';

      -- Engine-A H3D plane and registered line-reader timing seam.  Pixels
      -- are packed A5:B6:G6:R6; coordinate integers are flattened here for
      -- the mixed-language SystemVerilog boundary.
      h3d_pixel_valid      : in  std_logic := '0';
      h3d_pixel_data       : in  std_logic_vector(22 downto 0) := (others => '0');
      h3d_line_request     : out std_logic;
      h3d_line_request_y   : out std_logic_vector(7 downto 0);
      h3d_merge_line_start : out std_logic;
      h3d_merge_line_end   : out std_logic;
      h3d_merge_pixel_x    : out std_logic_vector(7 downto 0);
      h3d_merge_pixel_y    : out std_logic_vector(7 downto 0);
      h3d_line_drop        : out std_logic;
      h3d_bg1_scroll_triplet : out std_logic_vector(31 downto 0);

      -- Lossless raw H3D event streams, all in the clk1x domain.
      h3d_service_ready       : in  std_logic := '0';
      h3d_gx_fifo_level       : in  std_logic_vector(8 downto 0) := (others => '0');
      h3d_timestamp           : out std_logic_vector(63 downto 0);
      h3d_current_frame       : out std_logic_vector(31 downto 0);
      h3d_source_fault        : out std_logic;

      h3d_gpu_write_valid       : out std_logic;
      h3d_gpu_write_ready       : in  std_logic := '1';
      h3d_gpu_write_address     : out std_logic_vector(27 downto 0);
      h3d_gpu_write_access      : out std_logic_vector(1 downto 0);
      h3d_gpu_write_byte_enable : out std_logic_vector(3 downto 0);
      h3d_gpu_write_data        : out std_logic_vector(31 downto 0);
      h3d_gpu_write_frame       : out std_logic_vector(31 downto 0);
      h3d_gpu_write_timestamp   : out std_logic_vector(63 downto 0);

      h3d_vram9_write_valid       : out std_logic;
      h3d_vram9_write_ready       : in  std_logic := '1';
      h3d_vram9_write_address     : out std_logic_vector(31 downto 0);
      h3d_vram9_write_access      : out std_logic_vector(1 downto 0);
      h3d_vram9_write_byte_enable : out std_logic_vector(3 downto 0);
      h3d_vram9_write_data        : out std_logic_vector(31 downto 0);
      h3d_vram9_write_frame       : out std_logic_vector(31 downto 0);
      h3d_vram9_write_timestamp   : out std_logic_vector(63 downto 0);

      h3d_vram7_write_valid       : out std_logic;
      h3d_vram7_write_ready       : in  std_logic := '1';
      h3d_vram7_write_address     : out std_logic_vector(31 downto 0);
      h3d_vram7_write_access      : out std_logic_vector(1 downto 0);
      h3d_vram7_write_byte_enable : out std_logic_vector(3 downto 0);
      h3d_vram7_write_data        : out std_logic_vector(31 downto 0);
      h3d_vram7_write_frame       : out std_logic_vector(31 downto 0);
      h3d_vram7_write_timestamp   : out std_logic_vector(63 downto 0);

      h3d_hblank_valid       : out std_logic;
      h3d_hblank_ready       : in  std_logic := '1';
      h3d_hblank_line        : out std_logic_vector(8 downto 0);
      h3d_hblank_frame       : out std_logic_vector(31 downto 0);
      h3d_hblank_timestamp   : out std_logic_vector(63 downto 0);

      h3d_frame_valid       : out std_logic;
      h3d_frame_ready       : in  std_logic := '1';
      h3d_frame_number      : out std_logic_vector(31 downto 0);
      h3d_frame_timestamp   : out std_logic_vector(63 downto 0);

      -- video out, per-screen pixel writes, BGR666 (B in [17:12])
      pixel_out_x      : out std_logic_vector(7 downto 0);
      pixel_out_y      : out std_logic_vector(7 downto 0);
      pixel_out_data   : out std_logic_vector(17 downto 0);
      pixel_out_we     : out std_logic;
      pixelb_out_x     : out std_logic_vector(7 downto 0);
      pixelb_out_y     : out std_logic_vector(7 downto 0);
      pixelb_out_data  : out std_logic_vector(17 downto 0);
      pixelb_out_we    : out std_logic;
      vblank_out       : out std_logic;

      -- sound
      sound_out_left   : out std_logic_vector(15 downto 0);
      sound_out_right  : out std_logic_vector(15 downto 0);

      -- Temporary live-hardware telemetry, flattened for SystemVerilog.
      dbg_pc9           : out std_logic_vector(31 downto 0);
      dbg_pc7           : out std_logic_vector(31 downto 0);
      dbg_r0_9          : out std_logic_vector(31 downto 0);
      dbg_lr9           : out std_logic_vector(31 downto 0);
      dbg_cpsr9         : out std_logic_vector(31 downto 0);
      diagnostic_hold9  : in  std_logic := '0';
      diagnostic_hold7  : in  std_logic := '0';
      diagnostic_release9 : in std_logic := '0';
      diagnostic_release7 : in std_logic := '0';
      dbg_vfy_bad       : out std_logic_vector(17 downto 0);
      dbg_vfy_addr      : out std_logic_vector(31 downto 0);

      -- IS-NITRO-style debug mailbox (ddram ch4 pager lives in NDS.sv)
      dbg_cmd_stb       : in  std_logic := '0';
      dbg_cmd_op        : in  std_logic_vector(7 downto 0) := (others => '0');
      dbg_cmd_arg       : in  std_logic_vector(31 downto 0) := (others => '0');
      dbg_rsp_data      : out std_logic_vector(31 downto 0);
      dbg_rsp_stb       : out std_logic;

      dbg_hwstat        : out std_logic_vector(17 downto 0)
   );
end entity;

architecture arch of nds_nitro_console_wrap is

   signal pix_x_i, pix_y_i   : integer range 0 to 255;
   signal pixb_x_i, pixb_y_i : integer range 0 to 255;
   signal h3d_line_y_i       : integer range 0 to 191;
   signal h3d_merge_x_i      : integer range 0 to 255;
   signal h3d_merge_y_i      : integer range 0 to 191;
   signal fw_addr_u          : unsigned(17 downto 2);
   signal fw_wlane_u         : unsigned(1 downto 0);
   signal vsrv_addr_u        : unsigned(16 downto 2);
   signal vrsrv_addr_u       : unsigned(16 downto 3);

begin

   pixel_out_x  <= std_logic_vector(to_unsigned(pix_x_i, 8));
   pixel_out_y  <= std_logic_vector(to_unsigned(pix_y_i, 8));
   pixelb_out_x <= std_logic_vector(to_unsigned(pixb_x_i, 8));
   pixelb_out_y <= std_logic_vector(to_unsigned(pixb_y_i, 8));
   h3d_line_request_y <= std_logic_vector(to_unsigned(h3d_line_y_i, 8));
   h3d_merge_pixel_x <= std_logic_vector(to_unsigned(h3d_merge_x_i, 8));
   h3d_merge_pixel_y <= std_logic_vector(to_unsigned(h3d_merge_y_i, 8));
   fw_addr      <= std_logic_vector(fw_addr_u);
   fw_wlane     <= std_logic_vector(fw_wlane_u);
   vsrv_addr    <= std_logic_vector(vsrv_addr_u);
   vrsrv_addr   <= std_logic_vector(vrsrv_addr_u);

   inds : entity work.nds_nitro_console_top
   -- GPU_FAST stays 0: SUPERSEDED, and currently incompatible.
   --
   -- It runs both 2D engines on clkMem for 3x the cycles per scanline, and it
   -- works - verified transparent (fbdiff: 0 partial-row differences) and it took
   -- a rendered line from 5,829 to 3,996 clk1x cycles against a 2,130 budget.
   -- But the pipelined text drawer does far better on its own: 1,027 cycles per
   -- line, UNDER budget with ~50% headroom, at GPUCEDIV=1. clkMem bought 31%;
   -- the drawer buys 5.7x, so the extra clock domain earns nothing.
   --
   -- It is also incompatible as written: nds_gpu2d_fast adapts the OLD done-based
   -- VRAM protocol, and the drawer rework replaced it with an accept-based one, so
   -- GPU_FAST=1 now stalls the renderer (ops=3965, renders=1, bg busy 1.2M cycles).
   -- Fixing that means teaching the adapter the accept handshake - not worth doing
   -- unless a heavier scene turns out to need the headroom.
   --
   -- SOUND_ENABLE = 0 compiles nds_sound out. It is 10,032 combinational ALUTs -
   -- 16% of the design's logic, as much as a whole 2D engine - and main is
   -- currently OVER the device: the fitter wants 4238 LABs against 4191, so it is
   -- short by only ~470 ALMs (1.1%) and nothing can be built at all, at either
   -- clkMem ratio. Dropping sound is by far the cheapest way to a fitting image,
   -- and it is what makes the 134 MHz switch measurable instead of theoretical.
   --
   -- THERE IS NO AUDIO with this at 0.
   --
   -- 2026-08-06: SOUND_ENABLE=1 now BUILDS AND SHIPS. The audit this comment
   -- asked for has been done (FITTING.md "Sound area, measured"): nds_sound is
   -- 10,060 ALUTs / 4,909 registers, and the ADPCM_STEP table alone is 2,348 of
   -- them. Nothing has been cut yet - what made it fit was area elsewhere plus
   -- FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION.
   --
   -- THE TWO SHIPPING CONFIGURATIONS - this generic map plus two QSF macros:
   --   audio : SOUND_ENABLE=>1, DEBUG_ENABLE=>0, MISTER_DEBUG_NOHDMI=1,
   --           FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS
   --           -> 41,024 ALMs (98%), all slack positive. NO HDMI OUT.
   --   hdmi  : SOUND_ENABLE=>0, DEBUG_ENABLE=>1, NOHDMI commented out, SEED 3
   --           -> 38,176 ALMs (91%), all slack positive. NO AUDIO.
   -- They do not combine; see the HDMI note in NDS.qsf for the arithmetic.
   --
   -- 2026-08-08: which is why the SPU is being moved to the HPS - only a full
   -- farm-out frees enough (~4-5k ALMs) to have HDMI and sound at once, and the
   -- decode-only split that keeps this module's timers and fetch does not
   -- (docs/HPS_AUDIO.md). The transport half of that is built and on by default
   -- (NDS_HPS_AUDIO in NDS.qsf), so SOUND_ENABLE=0 no longer means "there is no
   -- audio" - it means the fabric SPU is gone and audio comes from the ring.
   -- Nothing above this line has moved yet: this generic still switches the
   -- whole of nds_sound, and it stays the reference the daemon is judged
   -- against until 1-4 in that document are proved.
   generic map (
      GPU_FAST => 0, GPU2D_B_ENABLE => 0,
      SOUND_ENABLE => 1, DEBUG_ENABLE => 0,
      CLKMEM_RATIO => CLKMEM_RATIO
   )
   port map
   (
      clk1x            => clk1x,
      clk2x            => clk2x,
      clkMem           => clkMem,
      clkMemIndex      => unsigned(clkMemIndex),
      reset            => reset,
      nds_on           => nds_on,
      direct_boot      => direct_boot,
      fw_boot          => fw_boot,

      KeyA             => KeyA,
      KeyB             => KeyB,
      KeySelect        => KeySelect,
      KeyStart         => KeyStart,
      KeyRight         => KeyRight,
      KeyLeft          => KeyLeft,
      KeyUp            => KeyUp,
      KeyDown          => KeyDown,
      KeyR             => KeyR,
      KeyL             => KeyL,
      KeyX             => KeyX,
      KeyY             => KeyY,
      lid_closed       => lid_closed,

      touch_active     => touch_active,
      touch_x          => touch_x,
      touch_y          => touch_y,

      boot_done        => boot_done,
      boot_error       => boot_error,

      card_ena         => card_ena,
      card_addr        => card_addr,
      card_din         => card_din,
      card_done        => card_done,

      backup_addr         => backup_addr,
      backup_write_data   => backup_write_data,
      backup_write_enable => backup_write_enable,
      backup_read_data    => backup_read_data,
      backup_write_toggle => backup_write_toggle,
      backup_is_64k       => backup_is_64k,
      backup_save_type    => backup_save_type,
      backup_profile_valid=> backup_profile_valid,
      backup_access_active=> backup_access_active,
      backup_cache_ready  => backup_cache_ready,
      backup_run_ready    => backup_run_ready,

      fw_addr          => fw_addr_u,
      fw_wr            => fw_wr,
      fw_wlane         => fw_wlane_u,
      fw_wdata         => fw_wdata,
      fw_req           => fw_req,
      fw_done          => fw_done,
      fw_data          => fw_data,

      bios7_load_addr  => unsigned(bios7_load_addr),
      bios7_load_data  => bios7_load_data,
      bios7_load_be    => bios7_load_be,
      bios7_load_we    => bios7_load_we,
      bios7_load_done  => bios7_load_done,
      bios9_load_addr  => unsigned(bios9_load_addr),
      bios9_load_data  => bios9_load_data,
      bios9_load_be    => bios9_load_be,
      bios9_load_we    => bios9_load_we,
      bios9_load_done  => bios9_load_done,

      mainram_allow    => mainram_allow,
      mainram_active   => mainram_active,
      mainram_busy     => mainram_busy,
      sdram_ena        => sdram_ena,
      sdram_rnw        => sdram_rnw,
      sdram_Adr        => sdram_Adr,
      sdram_Din        => sdram_Din,
      sdram_be         => sdram_be,
      sdram_Dout       => sdram_Dout,
      sdram_done32     => sdram_done32,
      sdram_Dout_hi    => sdram_Dout_hi,
      sdram_done64     => sdram_done64,

      vsrv_req         => vsrv_req,
      vsrv_rnw         => vsrv_rnw,
      vsrv_bank        => vsrv_bank,
      vsrv_addr        => vsrv_addr_u,
      vsrv_be          => vsrv_be,
      vsrv_din         => vsrv_din,
      vsrv_dout        => vsrv_dout,
      vsrv_done        => vsrv_done,
      vrsrv_req        => vrsrv_req,
      vrsrv_bank       => vrsrv_bank,
      vrsrv_addr       => vrsrv_addr_u,
      vrsrv_dout       => vrsrv_dout,
      vrsrv_done       => vrsrv_done,
      vrsrv_ready      => vrsrv_ready,

      math_request     => math_request,
      math_address     => math_address,
      math_rnw         => math_rnw,
      math_access      => math_access,
      math_write_data  => math_write_data,
      math_read_data   => math_read_data,
      math_selected    => math_selected,

      h3d_pixel_valid      => h3d_pixel_valid,
      h3d_pixel_data       => h3d_pixel_data,
      h3d_line_request     => h3d_line_request,
      h3d_line_request_y   => h3d_line_y_i,
      h3d_merge_line_start => h3d_merge_line_start,
      h3d_merge_line_end   => h3d_merge_line_end,
      h3d_merge_pixel_x    => h3d_merge_x_i,
      h3d_merge_pixel_y    => h3d_merge_y_i,

      h3d_service_ready       => h3d_service_ready,
      h3d_gx_fifo_level       => h3d_gx_fifo_level,
      h3d_timestamp           => h3d_timestamp,
      h3d_current_frame       => h3d_current_frame,
      h3d_source_fault        => h3d_source_fault,
      h3d_gpu_write_valid       => h3d_gpu_write_valid,
      h3d_gpu_write_ready       => h3d_gpu_write_ready,
      h3d_gpu_write_address     => h3d_gpu_write_address,
      h3d_gpu_write_access      => h3d_gpu_write_access,
      h3d_gpu_write_byte_enable => h3d_gpu_write_byte_enable,
      h3d_gpu_write_data        => h3d_gpu_write_data,
      h3d_gpu_write_frame       => h3d_gpu_write_frame,
      h3d_gpu_write_timestamp   => h3d_gpu_write_timestamp,
      h3d_vram9_write_valid       => h3d_vram9_write_valid,
      h3d_vram9_write_ready       => h3d_vram9_write_ready,
      h3d_vram9_write_address     => h3d_vram9_write_address,
      h3d_vram9_write_access      => h3d_vram9_write_access,
      h3d_vram9_write_byte_enable => h3d_vram9_write_byte_enable,
      h3d_vram9_write_data        => h3d_vram9_write_data,
      h3d_vram9_write_frame       => h3d_vram9_write_frame,
      h3d_vram9_write_timestamp   => h3d_vram9_write_timestamp,
      h3d_vram7_write_valid       => h3d_vram7_write_valid,
      h3d_vram7_write_ready       => h3d_vram7_write_ready,
      h3d_vram7_write_address     => h3d_vram7_write_address,
      h3d_vram7_write_access      => h3d_vram7_write_access,
      h3d_vram7_write_byte_enable => h3d_vram7_write_byte_enable,
      h3d_vram7_write_data        => h3d_vram7_write_data,
      h3d_vram7_write_frame       => h3d_vram7_write_frame,
      h3d_vram7_write_timestamp   => h3d_vram7_write_timestamp,
      h3d_hblank_valid       => h3d_hblank_valid,
      h3d_hblank_ready       => h3d_hblank_ready,
      h3d_hblank_line        => h3d_hblank_line,
      h3d_hblank_frame       => h3d_hblank_frame,
      h3d_hblank_timestamp   => h3d_hblank_timestamp,
      h3d_frame_valid       => h3d_frame_valid,
      h3d_frame_ready       => h3d_frame_ready,
      h3d_frame_number      => h3d_frame_number,
      h3d_frame_timestamp   => h3d_frame_timestamp,

      pixel_out_x      => pix_x_i,
      pixel_out_y      => pix_y_i,
      pixel_out_data   => pixel_out_data,
      pixel_out_we     => pixel_out_we,
      pixelb_out_x     => pixb_x_i,
      pixelb_out_y     => pixb_y_i,
      pixelb_out_data  => pixelb_out_data,
      pixelb_out_we    => pixelb_out_we,
      vblank_out       => vblank_out,

      sound_out_left   => sound_out_left,
      sound_out_right  => sound_out_right,

      -- the record-typed exports only exist in simulation (pragma-stripped
      -- in nds_top, donor gba_cpu idiom); plain debug taps stay last so the
      -- stripped list keeps valid comma placement
-- synthesis translate_off
      dbg_export9_done => open,
      dbg_export9      => open,
      dbg_export7_done => open,
      dbg_export7      => open,
-- synthesis translate_on
      dbg_line_drop    => h3d_line_drop,
      dbg_line_drop_a  => open,
      dbg_line_drop_b  => open,
      dbg_line_busy    => open,
      dbg_bg1_scroll_triplet => h3d_bg1_scroll_triplet,
      dbg_cpu_err9     => open,
      dbg_cpu_err7     => open,
      dbg_pc9          => dbg_pc9,
      dbg_pc7          => dbg_pc7,
      dbg_r0_9         => dbg_r0_9,
      dbg_lr9          => dbg_lr9,
      dbg_cpsr9        => dbg_cpsr9,
      diagnostic_hold9 => diagnostic_hold9,
      diagnostic_hold7 => diagnostic_hold7,
      diagnostic_release9 => diagnostic_release9,
      diagnostic_release7 => diagnostic_release7,
      dbg_vfy_bad      => dbg_vfy_bad,
      dbg_vfy_addr     => dbg_vfy_addr,
      dbg_cmd_stb      => dbg_cmd_stb,
      dbg_cmd_op       => dbg_cmd_op,
      dbg_cmd_arg      => dbg_cmd_arg,
      dbg_rsp_data     => dbg_rsp_data,
      dbg_rsp_stb      => dbg_rsp_stb,
      dbg_hwstat       => dbg_hwstat
   );

end architecture;
