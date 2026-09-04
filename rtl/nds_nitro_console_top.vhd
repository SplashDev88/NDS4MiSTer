-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Product-adapted console top derived from Nitro_DarkSide nds_top at pinned
-- commit d2dabe03344c0a685cd0f00e42b1a89606710dee. It terminates only the
-- console execution interfaces inside nds_nitro_console_island; it is not the
-- donor NDS.sv MiSTer shell.
-- NDS console top level — clk1x (33.514 MHz) + ce domain, GBA_MiSTfits pacing model.
-- Fast memory lives in the product island behind ena/done handshakes.
--
-- M5 integration: the M4 dual-CPU fabric (nds_cpu9 + gba_cpu, membuses, shared
-- WRAM, main RAM, IPC, IRQ, timers, syscnt) plus the engine-A render path
-- (nds_vram + nds_gpu_timing + nds_gpu2d). Boot is the card-header HLE loader:
-- an FSM starts nds_loader once reset drops with nds_on high, presets both
-- boot PCs through the savestate buses, then releases the CPUs — the flow
-- tb_dual_boot proved, made synthesizable.
--
-- Current scope/simplifications (see docs/ROADMAP.md):
--   * both CPUs run at the full clk1x rate (ce='1'); the ARM9 2x / ARM7 1x
--     pacing model is the M9 hardware milestone
--   * the GPU renders one dot per clk1x, i.e. at the real frame rate. This
--     used to be ce-paced at 1-of-GPU_CE_DIV (3 fabric clocks per dot), a
--     scaffold from when the v1 line server could not make the 2,130-cycle
--     line budget and dropped ~110 lines/frame on an affine scene. Successive
--     drawer reworks removed the need for it: OBJ took 1-of-1 lines from 3302
--     to 1750, and pipelining the affine and extended BG drawers took the
--     worst BG case from 4641 to 1680. With nothing left that needs the slack,
--     the divider, its runtime override and the OSD item that selected it are
--     gone - a 3x-too-slow frame was never a mode anyone wanted to ship.
--   * TCMs, ARM7-private WRAM: SyncRamDualByteEnable (M10K; the membus
--     presents addresses combinationally in the accept cycle, the BRAM's
--     internal address register replaces the old registered-address idiom)
--   * ARM9 DMA (nds_dma9): immediate/vblank/hblank, functional timing;
--     card/RTC/sound-regs/ARM7-DMA exist (sound mixer DSP pending); KEYINPUT/EXTKEYIN are
--     wired directly so samples polling keys see released state
--   * ARM7 SPI bus (nds_spi): PMIC + firmware flash + TSC; the flash serves
--     the fw_* image port (melonDS default firmware in sim; touch/mic not
--     wired into the TSC yet)
--   * Redistributable melonDS FreeBIOS for ARM7 and ARM9. The registered
--     product ROMs provide the direct-boot SWIs used by the initial game
--     target without Nintendo BIOS data or a run-time BIOS loader.
--   * both 2D engines render (engine B via the 0x1000 register window,
--     palette/OAM upper halves and the C/D/H/I VRAM roles); POWCNT routes
--     the screens (swap bit; B-off shows white, palette/OAM writes gated
--     by engine power) and MASTER_BRIGHT applies per engine in nds_gpu2d.
--     Still open: LCDC/FIFO display modes, the DDR3 compose stage

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

use work.pProc_bus_gba.all;
use work.pexport.all;

entity nds_nitro_console_top is
   generic
   (
      is_simu                  : std_logic := '0';
      Softmap_NDS_MAINRAM_ADDR : integer   := 8388608; -- byte offset of the 4 MB window in SDRAM
      -- 1 = run both 2D engines on clkMem (3x clk1x) instead of clk1x, giving
      -- the renderer 6390 cycles per scanline instead of 2130. A rendered line
      -- measures 5829 cycles, so it only fits the former. See nds_gpu2d_fast.
      GPU_FAST                 : integer   := 0;
      -- Diagnostic area split: 0 removes engine B and mirrors engine A onto
      -- both physical screens.  This keeps NSMB's main-screen BG2/HDMA and
      -- the ARM 3D merge in FPGA while measuring whether one 2D engine fits.
      -- Production/default remains both engines.
      GPU2D_B_ENABLE           : integer   := 1;
      -- clkMem : clk1x ratio (NDS.sv CLKMEM_RATIO, moved by NDS_CLKMEM_4X).
      -- Only reaches nds_gpu2d_fast's phase gates, which exist only when
      -- GPU_FAST /= 0 - so nds_port_wrap deliberately leaves this at its
      -- default, as it does every other generic. If GPU_FAST is ever switched
      -- on in a 4x build, this has to be raised with it.
      CLKMEM_RATIO             : integer   := 3;
      -- 0 = compile nds_sound out entirely. It is 10,032 combinational ALUTs,
      -- 16% of the design's logic and as much as a whole 2D engine, so this is
      -- the cheapest way to get a FITTING image while main is over the device
      -- (see FITTING.md; the fitter is short by ~470 ALMs). Diagnostic images
      -- only - there is no audio at all with this off.
      SOUND_ENABLE             : integer   := 1;
      -- DEBUG_ENABLE = 0 compiles nds_debug (the IS-NITRO-style halt/step/peek
      -- unit) out: 474 ALMs, ~47 LABs. That is enough to close the 27-LAB gap
      -- that SOUND_ENABLE=1 opens, which is the only reason to turn it off.
      --
      -- What is LOST: halt/step/breakpoints, register read-back, and PEEK - i.e.
      -- every hardware bisect tool. What SURVIVES: mailbox op 0x0B (FORCE_CART),
      -- because NDS.sv answers that one itself rather than nds_debug (see the
      -- cart_force assign there), so deploy -> declare -> softreset still boots
      -- a staged card image with nobody at the OSD. Other mailbox ops stop
      -- answering and fall to NDS.sv's outer timeout rather than hanging.
      DEBUG_ENABLE             : integer   := 1;
      -- simulation only: the testbench has staged the ARM9/ARM7 main-RAM sections
      -- itself, so nds_loader may skip copying them (see nds_loader.skip_copy)
      skip_copy                : std_logic := '0'
   );
   port
   (
      clk1x            : in  std_logic;   -- 33.513982 MHz system clock
      -- The ARM9 island clock, PLL outclk_3, 50.270973 MHz = VCO/16 = 1.5x clk1x
      -- from the same VCO at 0 ps. Clocks only the ARM9 island (icpu9 + imembus9
      -- + cache9 + ITCM/DTCM).
      --
      -- Historically this was outclk_1 at 67.027964 MHz, "EXACTLY 2x clk1x", and
      -- the comment here said having both on clk1x "breaks the NitroSDK IPCSYNC
      -- boot handshake". Both parts of that are now known to be wrong:
      --   * 67.028 MHz was the VIDEO pixel clock, which the island merely shared.
      --     It was never an ARM9 requirement.
      --   * The handshake imposes no speed ratio at all. Both sides are unbounded
      --     waits (ARM7 spins at 0x0238FEA8/0x0238FEC8 with no timeout; the ARM9's
      --     1000-poll budget at 0x0214FF50 restores its counter and retries on
      --     expiry), so either CPU may be arbitrarily slower than the other.
      -- The bridge handshakes below are ratio-independent by construction - the
      -- request path is a toggle held until the transaction completes, and the
      -- done paths are edge detectors - so a non-integer 1.5x is fine.
      --
      -- ISLAND=0 (tie to clk1x) still does NOT work, but for an unrelated reason:
      -- a bridge completion is lost at 1:1 and the ARM9 parks after ~90 accepts
      -- with main RAM IDLE. That is a bug to fix, not a ratio requirement.
      clk2x            : in  std_logic;
      clkMem           : in  std_logic;   -- 100.542 MHz (3x clk1x, phase-locked)
      clkMemIndex      : in  unsigned(1 downto 0);  -- clkMem phase, 0 on clk1x rising edge
      reset            : in  std_logic;
      nds_on           : in  std_logic;
      direct_boot      : in  std_logic := '0';  -- synthesize the firmware boot env (stock ROMs)
      -- '1' = FIRMWARE BOOT. The loader clears memory and derives the cartridge
      -- chip ID, then stops: no image staging, no direct-boot env block. The boot
      -- FSM then releases both CPUs WITHOUT presetting their PCs, so they start at
      -- their architectural reset vectors and the retail BIOSes run - the ARM7 BIOS
      -- pulls the firmware over SPI and the firmware reads the cartridge itself,
      -- as real hardware does.
      --
      -- This exists because every "leftover memory" bug in this core has been the
      -- same shape: direct boot skips the firmware, so something is uninitialised.
      -- Main RAM (SWP cart-lock wedge), VRAM/palette/OAM (stale screen) and ARM7
      -- WRAM were each fixed by hand-reimplementing one thing the firmware does.
      -- Booting the firmware addresses the cause rather than the symptoms.
      fw_boot          : in  std_logic := '0';
      -- keys (active high) — X/Y/lid are NDS additions routed via ARM7 side
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

      -- touchscreen (framework analog -> TSC samples and EXTKEYIN pen-down)
      touch_active     : in  std_logic;
      touch_x          : in  std_logic_vector(7 downto 0);
      touch_y          : in  std_logic_vector(7 downto 0);

      -- boot status (HLE loader)
      boot_done        : out std_logic;
      boot_error       : out std_logic;

      -- card image read port (word addressed into the staged .nds, via nds_wrap)
      card_ena         : out std_logic;
      card_addr        : out std_logic_vector(26 downto 2);
      card_din         : in  std_logic_vector(31 downto 0);
      card_done        : in  std_logic;

      -- Cartridge backup-memory byte port.  Storage is instantiated in the
      -- SystemVerilog island so its second port can connect directly to the
      -- MiSTer mounted-save interface.
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

      -- SPI firmware flash image read port (256 KB, word addressed; req/done
      -- handshake — hex array in sim answers next cycle, the DDR3 pager on
      -- hardware answers in tens of cycles, both inside the SPI byte window)
      fw_addr          : out unsigned(17 downto 2);
      fw_req           : out std_logic;
      fw_done          : in  std_logic;
      fw_data          : in  std_logic_vector(31 downto 0);
      -- SPI firmware write-back. Pokemon Pearl page-programs the flash during
      -- boot (0x06/0x0A/0x04) and hangs if the write is discarded, so the
      -- backing store has to be writable, not a ROM.
      -- No separate write address: the 0x0A path drives fw_addr above, so the
      -- store reuses one decode. A second one costs ~163 ALMs and will not
      -- route on this 98%-full device.
      fw_wr            : out std_logic;
      fw_wlane         : out unsigned(1 downto 0);
      fw_wdata         : out std_logic_vector(7 downto 0);

      -- Legacy hot-BIOS boundary retained for entity compatibility. The
      -- compact product instantiates built-in FreeBIOS ROMs and ignores these
      -- ports; donor and simulation variants can still use this interface.
      bios7_load_addr  : in unsigned(13 downto 2) := (others => '0');
      bios7_load_data  : in std_logic_vector(31 downto 0) := (others => '0');
      bios7_load_be    : in std_logic_vector(3 downto 0) := (others => '0');
      bios7_load_we    : in std_logic := '0';
      bios7_load_done  : in std_logic := '0';
      bios9_load_addr  : in unsigned(11 downto 2) := (others => '0');
      bios9_load_data  : in std_logic_vector(31 downto 0) := (others => '0');
      bios9_load_be    : in std_logic_vector(3 downto 0) := (others => '0');
      bios9_load_we    : in std_logic := '0';
      bios9_load_done  : in std_logic := '0';

      -- main RAM: nds_mainram SDRAM request port + scheduler handshake
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

      -- VRAM banks A..D backing store (CPU r/w + renderer read channels;
      -- SDRAM guest clients in nds_wrap, behavioral models in sim)
      vsrv_req         : out std_logic;
      vsrv_rnw         : out std_logic;
      vsrv_bank        : out std_logic_vector(1 downto 0);
      vsrv_addr        : out unsigned(16 downto 2);
      vsrv_be          : out std_logic_vector(3 downto 0);
      vsrv_din         : out std_logic_vector(31 downto 0);
      vsrv_dout        : in  std_logic_vector(31 downto 0);
      vsrv_done        : in  std_logic;
      vrsrv_req        : out std_logic;
      vrsrv_bank       : out std_logic_vector(1 downto 0);
      vrsrv_addr       : out unsigned(16 downto 3);
      vrsrv_dout       : in  std_logic_vector(63 downto 0);
      vrsrv_done       : in  std_logic;
      -- back-pressure for the renderer VRAM feed. nds_vram's renderer server
      -- now issues A..D reads PIPELINED, so the channel has to say when it can
      -- take one; without this a platform that serves one op at a time drops
      -- every request that arrives while it is busy. Defaults high for models
      -- that are always ready.
      vrsrv_ready      : in  std_logic := '1';

      -- ARM9 DIV/SQRT registers are kept in the compact iterative SystemVerilog
      -- unit from our design.  These scalar taps let that unit participate in
      -- the donor's clk1x IO wired-OR without importing a VHDL record across
      -- the mixed-language boundary.
      math_request     : out std_logic;
      math_address     : out std_logic_vector(31 downto 0);
      math_rnw         : out std_logic;
      math_access      : out std_logic_vector(1 downto 0);
      math_write_data  : out std_logic_vector(31 downto 0);
      math_read_data   : in  std_logic_vector(31 downto 0) := (others => '0');
      math_selected    : in  std_logic := '0';

      -- HPS-rendered engine-A 3D plane and the exact registered-reader seam.
      -- Pixel packing is A5:B6:G6:R6.  The request pulse belongs to an
      -- accepted drawline; merge line_start/line_end launch reads for x=0/255.
      -- The reader returns that pixel one clk1x later on h3d_pixel_*.
      h3d_pixel_valid      : in  std_logic := '0';
      h3d_pixel_data       : in  std_logic_vector(22 downto 0) := (others => '0');
      h3d_line_request     : out std_logic := '0';
      h3d_line_request_y   : out integer range 0 to 191 := 0;
      h3d_merge_line_start : out std_logic := '0';
      h3d_merge_line_end   : out std_logic := '0';
      h3d_merge_pixel_x    : out integer range 0 to 255 := 0;
      h3d_merge_pixel_y    : out integer range 0 to 191 := 0;

      -- Lossless clk1x hybrid-3D event boundary.  Each valid and its payload
      -- remain stable until the matching ready is sampled high.  GPU addresses
      -- are normalized ARM9 IO offsets; VRAM addresses are aligned virtual DS
      -- addresses in the 0x06xxxxxx aperture.  All timestamps use the single
      -- ARM7-rate DS system clock, including ARM9-originated events.
      h3d_service_ready       : in  std_logic := '0';
      h3d_gx_fifo_level       : in  std_logic_vector(8 downto 0) := (others => '0');
      h3d_timestamp           : out std_logic_vector(63 downto 0) := (others => '0');
      h3d_current_frame       : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_source_fault        : out std_logic := '0';

      h3d_gpu_write_valid       : out std_logic := '0';
      h3d_gpu_write_ready       : in  std_logic := '1';
      h3d_gpu_write_address     : out std_logic_vector(27 downto 0) := (others => '0');
      h3d_gpu_write_access      : out std_logic_vector(1 downto 0) := (others => '0');
      h3d_gpu_write_byte_enable : out std_logic_vector(3 downto 0) := (others => '0');
      h3d_gpu_write_data        : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_gpu_write_frame       : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_gpu_write_timestamp   : out std_logic_vector(63 downto 0) := (others => '0');

      h3d_vram9_write_valid       : out std_logic := '0';
      h3d_vram9_write_ready       : in  std_logic := '1';
      h3d_vram9_write_address     : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_vram9_write_access      : out std_logic_vector(1 downto 0) := (others => '0');
      h3d_vram9_write_byte_enable : out std_logic_vector(3 downto 0) := (others => '0');
      h3d_vram9_write_data        : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_vram9_write_frame       : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_vram9_write_timestamp   : out std_logic_vector(63 downto 0) := (others => '0');

      h3d_vram7_write_valid       : out std_logic := '0';
      h3d_vram7_write_ready       : in  std_logic := '1';
      h3d_vram7_write_address     : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_vram7_write_access      : out std_logic_vector(1 downto 0) := (others => '0');
      h3d_vram7_write_byte_enable : out std_logic_vector(3 downto 0) := (others => '0');
      h3d_vram7_write_data        : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_vram7_write_frame       : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_vram7_write_timestamp   : out std_logic_vector(63 downto 0) := (others => '0');

      h3d_hblank_valid       : out std_logic := '0';
      h3d_hblank_ready       : in  std_logic := '1';
      h3d_hblank_line        : out std_logic_vector(8 downto 0) := (others => '0');
      h3d_hblank_frame       : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_hblank_timestamp   : out std_logic_vector(63 downto 0) := (others => '0');

      h3d_frame_valid       : out std_logic := '0';
      h3d_frame_ready       : in  std_logic := '1';
      h3d_frame_number      : out std_logic_vector(31 downto 0) := (others => '0');
      h3d_frame_timestamp   : out std_logic_vector(63 downto 0) := (others => '0');

      -- video out: TOP and BOTTOM screen lines after POWCNT routing,
      -- BGR666 (the NDS 18-bit LCD format; B in [17:12])
      pixel_out_x      : out integer range 0 to 255;
      pixel_out_y      : out integer range 0 to 191;
      pixel_out_data   : out std_logic_vector(17 downto 0);
      pixel_out_we     : out std_logic;
      pixelb_out_x     : out integer range 0 to 255;
      pixelb_out_y     : out integer range 0 to 191;
      pixelb_out_data  : out std_logic_vector(17 downto 0);
      pixelb_out_we    : out std_logic;
      vblank_out       : out std_logic;

      -- sound
      sound_out_left   : out std_logic_vector(15 downto 0);
      sound_out_right  : out std_logic_vector(15 downto 0);

      -- debug (sim monitors; unconnected in synthesis). The record-typed
      -- exports are sim-only, pragma-stripped like the CPUs' own ports
      -- (donor gba_cpu idiom); keep plain ports after them so stripping
      -- never leaves a dangling ';' before the closing paren.
-- synthesis translate_off
      dbg_export9_done : out std_logic;   -- ARM9 retired-instruction export (is_simu only)
      dbg_export9      : out cpu_export_type;
      dbg_export7_done : out std_logic;   -- ARM7 retired-instruction export (is_simu only)
      dbg_export7      : out cpu_export_type;
-- synthesis translate_on
      dbg_line_drop    : out std_logic;   -- drawline landed while gpu2d was still busy
      dbg_line_drop_a  : out std_logic;   -- ... engine A specifically
      dbg_line_drop_b  : out std_logic;   -- ... engine B specifically
      dbg_line_busy    : out std_logic;
      dbg_bg1_scroll_triplet : out std_logic_vector(31 downto 0);
      dbg_cpu_err9     : out std_logic;
      dbg_cpu_err7     : out std_logic;
      dbg_pc9          : out std_logic_vector(31 downto 0);
      dbg_pc7          : out std_logic_vector(31 downto 0);
      dbg_r0_9         : out std_logic_vector(31 downto 0);
      dbg_lr9          : out std_logic_vector(31 downto 0);
      dbg_cpsr9        : out std_logic_vector(31 downto 0);
      -- Public crash capture: a bounded external hold from the H3D control
      -- block. This remains available when the 474-ALM nds_debug unit is off.
      diagnostic_hold9 : in  std_logic := '0';
      diagnostic_hold7 : in  std_logic := '0';
      diagnostic_release9 : in std_logic := '0';
      diagnostic_release7 : in std_logic := '0';
      -- main-RAM verify results from nds_loader (see its port comment)
      dbg_vfy_bad      : out std_logic_vector(17 downto 0);
      dbg_vfy_addr     : out std_logic_vector(31 downto 0);
      -- nds_debug mailbox, driven by the ddram ch4 pager in NDS.sv
      dbg_cmd_stb      : in  std_logic := '0';
      dbg_cmd_op       : in  std_logic_vector(7 downto 0) := (others => '0');
      dbg_cmd_arg      : in  std_logic_vector(31 downto 0) := (others => '0');
      dbg_rsp_data     : out std_logic_vector(31 downto 0);
      dbg_rsp_stb      : out std_logic;
      dbg_hwstat       : out std_logic_vector(17 downto 0)
   );
end entity;

architecture arch of nds_nitro_console_top is

   component nds_nitro_save_profile is
      generic
      (
         PREFIX_COUNT: integer := 368
      );
      port
      (
         clk       : in  std_logic;
         reset     : in  std_logic;
         start     : in  std_logic;
         game_code : in  std_logic_vector(31 downto 0);
         busy      : out std_logic;
         valid     : out std_logic;
         save_type : out std_logic_vector(3 downto 0)
      );
   end component;

   signal resetCpu : std_logic := '1';   -- both CPUs, held until the loader finished

   -- ================= boot FSM + loader =================
   type t_boot is
   (
      B_RESET,             -- fabric in reset / waiting for nds_on
      B_SETTLE,            -- fabric out of reset, let it settle
      B_LDSTART, B_LDWAIT, -- run nds_loader
      B_S9RST, B_S9GAP, B_S9WR, B_S9POST,   -- preset ARM9 PC via savestate bus
      B_S7RST, B_S7GAP, B_S7WR, B_S7POST,   -- preset ARM7 PC
      B_RUN,
      B_ERROR
   );
   signal boot_state : t_boot := B_RESET;
   signal boot_cnt   : integer range 0 to 7 := 0;

   signal ld_start, ld_busy, ld_done, ld_error : std_logic;
   signal preset_direct : std_logic := '0';
   signal arm9_entry, arm7_entry : std_logic_vector(31 downto 0);
   -- Effective boot PCs. Firmware boot enters each BIOS at its reset vector
   -- instead of the cart's entry point: the ARM9 at 0xFFFF0000 (the NDS ties
   -- VINITHI high, so exception vectors are high from reset) and the ARM7 at
   -- 0x00000000. This core does not model the ARM reset exception at all -
   -- both CPUs take their initial fetch_PC from the savestate write in
   -- B_S9GAP/B_S7GAP - so simply releasing reset without presetting a PC
   -- starts the ARM9 at 0x00000000 and retires nothing at all.
   signal arm9_entry_eff, arm7_entry_eff : std_logic_vector(31 downto 0);

   -- ---- direct-boot register preset ------------------------------------
   -- Presetting only the PC is not enough. The loader's env block was specced
   -- against calico homebrew, whose bootstubs set up their own CP15 and stacks;
   -- a NitroSDK-built cart never sets its own SP, it inherits one from the boot
   -- ROM. With SP=0 its first function prologue pushes into ITCM at address 0
   -- and the cart is dead long before it touches a display register - see
   -- docs/NTR_EVA_TESTER.md, where that is the whole of the failure.
   --
   -- Values are the GBATEK default stack pointers. melonDS banks with std::swap
   -- while this core saves/restores per mode (the CPUMODE_* case in
   -- gba_cpu.vhd), so its R[13]/R_SVC[0] pair does NOT copy across literally.
   --
   -- Translating melonDS's swap model into this one is not a field-by-field
   -- copy, and getting it wrong costs a whole sim cycle to notice:
   --
   --   melonDS R[13]     -> the ACTIVE bank. Boot CPSR reads supervisor but the
   --                        value there is the USER stack (0x03002F7C).
   --   melonDS R_SVC[0]  -> the USER/SYSTEM bank. Under swap, while supervisor
   --                        is active R_SVC holds the stack that swaps in when
   --                        LEAVING supervisor - so despite the name it is the
   --                        outer stack, not the supervisor one.
   --   melonDS R_IRQ[0]  -> the IRQ bank directly (IRQ is not the active mode,
   --                        so it really is holding IRQ's own stack).
   --
   -- Reading R_SVC[0] as "the supervisor bank" diverges at the ROM's first
   -- MSR CPSR out of supervisor - instruction 69 of this cart, with every other
   -- column still matching. Matching the oracle exactly is the point:
   -- sim/tests/compare_trace.py had to document "--ignore cpsr,r13,r14 against
   -- a melonDS trace" only because this preset was missing, and those ignores
   -- mask real divergences.
   --
   -- Savestate addresses come from rtl/reg_savestates.vhd: REG_SAVESTATE_PC is
   -- 0, and REG_SAVESTATE_REGS is a size-18 block based at 1, so rN is at 1+N.
   -- REGS_0_13 = 24 (user/system bank), REGS_2_13 = 34 (IRQ), REGS_3_13 = 37
   -- (supervisor). Both CPUs come out of reset in supervisor mode
   -- (SAVESTATE_cpu_mode defaults to CPUMODE_SUPERVISOR), so the plain REGS r13
   -- at address 14 IS the supervisor stack.
   constant PRESET_LAST : integer := 6;
   signal   preset_idx  : integer range 0 to 7 := 0;

   function preset_adr(idx : integer) return integer is
   begin
      case idx is
         when 0      => return  0;   -- fetch PC
         when 1      => return 13;   -- r12
         when 2      => return 14;   -- r13, active (supervisor) bank
         when 3      => return 15;   -- r14
         when 4      => return 24;   -- r13 user/system bank
         when 5      => return 34;   -- r13 IRQ bank
         when others => return 37;   -- r13 supervisor bank
      end case;
   end function;

   function preset_val(idx : integer; entry_pc : std_logic_vector(31 downto 0);
                       is_arm9 : boolean) return std_logic_vector is
   begin
      case idx is
         when 0 | 1 | 3 => return entry_pc;
         when 2         => if is_arm9 then return x"03002F7C"; else return x"0380FD80"; end if;
         when 5         => if is_arm9 then return x"03003F80"; else return x"0380FF80"; end if;
         when others    => if is_arm9 then return x"03003FC0"; else return x"0380FFC0"; end if;
      end case;
   end function;

   function h3d_access_from_be(be : std_logic_vector(3 downto 0))
      return std_logic_vector is
   begin
      if (be = "1111") then
         return ACCESS_32BIT;
      elsif (be = "0011" or be = "1100") then
         return ACCESS_16BIT;
      else
         return ACCESS_8BIT;
      end if;
   end function;

   -- Match nds_h3d_gpu_event_capture's width-aware decode.  The product gate
   -- needs the same qualification so only GPU writes delay CPU IO completion;
   -- the SystemVerilog capture remains the event-format authority.
   function h3d_gpu_write_hit(
      address : std_logic_vector(27 downto 0);
      be      : std_logic_vector(3 downto 0)) return boolean is
      variable low, lane : integer;
   begin
      if (address(27 downto 12) /= x"0000") then
         return false;
      end if;
      case be is
         when "0010"          => lane := 1;
         when "0100" | "1100" => lane := 2;
         when "1000"          => lane := 3;
         when others          => lane := 0;
      end case;
      low := to_integer(unsigned(address(11 downto 2))) * 4 + lane;
      return (low >= 16#060# and low <= 16#063#) or
             (low >= 16#240# and low <= 16#249#) or
             (low >= 16#304# and low <= 16#307#) or
             (low >= 16#320# and low <= 16#3BF#) or
             (low >= 16#400# and low <= 16#5CB#) or
             (low >= 16#600# and low <= 16#613#);
   end function;

   signal ld_cartid  : std_logic_vector(31 downto 0);  -- header-size chip ID -> nds_card B8
   signal ld_save_is_64k : std_logic;
   signal ld_save_gamecode : std_logic_vector(31 downto 0);
   signal ld_save_gamecode_valid : std_logic;
   signal save_profile_busy : std_logic;
   signal save_profile_valid_s : std_logic;
   signal save_profile_type_s : std_logic_vector(3 downto 0);
   signal save_ir_enable_s : std_logic := '0';
   -- on-FPGA debug unit (nds_debug): CPU hold/release, register read-back and
   -- a main-RAM peek muxed onto the ARM9 channel the same way the loader is
   signal pc9_s, pc7_s         : std_logic_vector(31 downto 0);
   signal dbg_hold9, dbg_rel9  : std_logic;
   signal dbg_hold7, dbg_rel7  : std_logic;
   signal dbg_boot_rst         : std_logic;   -- debugger-requested boot restart
   signal dbg_regsel_s         : unsigned(4 downto 0);
   signal dbg_regval9, dbg_regval7 : std_logic_vector(31 downto 0);
   signal dbg_pk_ena, dbg_pk_act, dbg_pk_sel : std_logic;
   signal dbg_card_s : std_logic_vector(31 downto 0);
   signal dbg_ipc_s  : std_logic_vector(31 downto 0);
   signal dbg_perf_s   : std_logic_vector(31 downto 0);
   signal dbg_perf_idx : std_logic_vector(2 downto 0);

   -- Everything the CPUs' resetCpu does not cover, but which a from-reset probe
   -- must still start clean. nds_mainram in particular latches req9/req7_pending
   -- and lock_pair: a SOFTRESET landing mid-op leaves the arbiter waiting on a
   -- request no one will re-issue, which kills the ARM9's main-RAM channel from
   -- t=0 while the ARM7 keeps running out of its private WRAM. These three
   -- cannot take resetCpu instead - the loader stages main RAM through them
   -- while resetCpu is still asserted.
   signal reset_boot : std_logic;

   -- Reset clear passes: VRAM (nds_vram) and palette/OAM (both gpu2d engines)
   -- zero themselves out of reset, the way nds_loader's CLR_WR zeroes main RAM
   -- - a MiSTer ROM change does not reconfigure the FPGA, so without this the
   -- new game renders the previous game's leftovers. The CPU release waits on
   -- all three so no game write can race a clear (VRAM's pass runs concurrently
   -- with the loader and is by far the longest, ~660 KB; measured ordering is in
   -- the bench, not assumed).
   signal vclr_busy   : std_logic;
   signal pclr_busy_a : std_logic;
   signal pclr_busy_b : std_logic;

   -- ARM9 clk2x island <-> clk1x world bridge (see the process block below)
   signal cdc_req_wsh, cdc_req_vram, cdc_req_mr   : std_logic := '0';
   signal cdc_req_io,  cdc_req_pal,  cdc_req_oam  : std_logic := '0';
   signal cdc_req_wsh_d, cdc_req_vram_d, cdc_req_mr_d  : std_logic := '0';
   signal cdc_req_io_d,  cdc_req_pal_d,  cdc_req_oam_d : std_logic := '0';
   signal cdc_wsh_done_d, cdc_vram_done_d         : std_logic := '0';
   signal cdc_mr_done_d                           : std_logic := '0';
   -- island side (clk2x): membus9's raw request pulses / narrowed dones
   signal i9_wsh_ena, i9_vram_ena, i9_mr_ena, i9_io_ena : std_logic;
   signal i9_pal_we,  i9_oam_we                         : std_logic;
   signal i9_wsh_done, i9_vram_done, i9_mr_done, i9_io_done : std_logic;
   -- island-side copy of the IO bus record: nds_top rebuilds io_bus9 from it with
   -- the stretched enable substituted, since only .ena needs to cross
   signal i9_io_bus : proc_bus_gb_type;
   -- island-side capture of the IO request payload, held across the bridge,
   -- and its clk1x re-registration (see io_bus9 below)
   signal io9_lat    : proc_bus_gb_type;
   signal io9_lat_1x : proc_bus_gb_type;
   -- island-side capture of the main-RAM request's SWP lock bit (see mr9_lock)
   signal mr9_lock  : std_logic := '0';
   signal io9_ena   : std_logic := '0';   -- stretched io_bus9.ena, clk1x domain
   signal cdc_dmab_ena_d, dmab_ena_i9   : std_logic := '0';
   signal cdc_cpudone_tgl, cdc_cpudone_tgl_d, cpu9_done_1x : std_logic := '0';
   -- per-transaction IO completion, clk1x -> island (see i9_io_done below)
   signal cdc_io_cpl, cdc_io_cpl_d : std_logic := '0';
   signal dbg_mb9, dbg_cache9, dbg_mr_s      : std_logic_vector(7 downto 0);
   signal dbg_probe                          : std_logic_vector(31 downto 0);
   signal dbg_pk_addr_s        : std_logic_vector(31 downto 0);
   signal dbg_pk_done_s        : std_logic;

   signal ld_wr_ena  : std_logic;
   signal ld_wr_rnw  : std_logic;
   signal ld_wr_addr, ld_wr_data : std_logic_vector(31 downto 0);
   signal ld_wr_done : std_logic;
   signal ld_w7_done : std_logic := '0';

   signal ss_bus9 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal ss_bus7 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

   -- ================= ARM9 side =================
   signal cpu9_adr      : std_logic_vector(31 downto 0);
   signal cpu9_rnw, cpu9_ena, cpu9_code, cpu9_done, cpu9_lock : std_logic;
   signal cpu9_acc      : std_logic_vector(1 downto 0);
   signal cpu9_dout, cpu9_din, cpu9_lastread : std_logic_vector(31 downto 0);
   signal cpu9_lowbits  : std_logic_vector(1 downto 0);
   signal error_cpu9    : std_logic;
   signal cpu9_irq, cpu9_unhalt, cpu9_halt : std_logic;
   signal cpu9_dbg_r0, cpu9_dbg_lr, cpu9_dbg_cpsr : std_logic_vector(31 downto 0);

   signal cp15_itcm_ena, cp15_itcm_load : std_logic;
   signal cp15_dtcm_ena, cp15_dtcm_load : std_logic;
   signal cp15_dtcm_base : std_logic_vector(31 downto 12);
   signal cp15_dtcm_size, cp15_itcm_size : std_logic_vector(4 downto 0);
   signal bus_cacheable_i, bus_cacheable_d : std_logic;
   signal cache_op_ena, cache_op_busy : std_logic;
   signal cache_op      : std_logic_vector(3 downto 0);
   signal cache_op_addr : std_logic_vector(31 downto 0);

   -- TCM stores (M10K, see iitcm/idtcm instances)
   signal itcm_addr : unsigned(14 downto 2);
   signal itcm_we   : std_logic;
   signal itcm_be   : std_logic_vector(3 downto 0);
   signal itcm_writedata, itcm_readdata : std_logic_vector(31 downto 0);
   -- DTCM port A is the read port; the store is deferred onto port B (dtcm_*_b)
   signal dtcm_addr : unsigned(13 downto 2);
   signal dtcm_readdata : std_logic_vector(31 downto 0);
   signal dtcm_addr_b : unsigned(13 downto 2);
   signal dtcm_we_b   : std_logic;
   signal dtcm_be_b   : std_logic_vector(3 downto 0);
   signal dtcm_writedata_b : std_logic_vector(31 downto 0);

   signal brom_addr : unsigned(14 downto 2);
   signal brom_data : std_logic_vector(31 downto 0);

   signal wsh9_ena, wsh9_rnw, wsh9_done, wsh9_mapped : std_logic;
   signal wsh9_addr : unsigned(14 downto 2);
   signal wsh9_be   : std_logic_vector(3 downto 0);
   signal wsh9_din, wsh9_dout : std_logic_vector(31 downto 0);

   signal vram9_ena, vram9_rnw, vram9_done : std_logic;
   signal vram9_addr : unsigned(23 downto 2);
   signal vram9_be   : std_logic_vector(3 downto 0);
   signal vram9_din, vram9_dout : std_logic_vector(31 downto 0);

   -- what nds_vram's cpu9 port actually sees: the island's request, or the DMA's
   -- while it holds the bus
   signal vr9_src_ena, vr9_ena, vr9_rnw : std_logic;
   signal vr9_addr : unsigned(23 downto 2);
   signal vr9_be   : std_logic_vector(3 downto 0);
   signal vr9_din  : std_logic_vector(31 downto 0);
   signal vr7_addr : unsigned(23 downto 2);
   signal vr7_be   : std_logic_vector(3 downto 0);
   signal vr7_din  : std_logic_vector(31 downto 0);

   signal dma_vr_ena, dma_vr_rnw : std_logic;
   signal dma_vr_addr : unsigned(23 downto 2);
   signal dma_vr_be   : std_logic_vector(3 downto 0);
   signal dma_vr_din  : std_logic_vector(31 downto 0);
   -- posted-write handshake. wpost is only ever asked for by the DMA, so it is
   -- gated on dma_bus_on: a CPU store to VRAM keeps its ordinary timing and none
   -- of the posted window's coherency rules apply to it.
   signal dma_vr_wpost, dma_vram_write_valid : std_logic;
   signal vr9_wpost, vr9_welig, vr9_wok, dma_vr_wok_safe : std_logic;

   signal h3d_gpu_source_valid, h3d_gpu_source_is_cpu : std_logic;
   signal h3d_gpu_source_ready, h3d_gpu_cpu_complete : std_logic;
   signal h3d_gpu_source_address : std_logic_vector(27 downto 0);
   signal h3d_gpu_source_access : std_logic_vector(1 downto 0);
   signal h3d_gpu_source_be : std_logic_vector(3 downto 0);
   signal h3d_gpu_source_data : std_logic_vector(31 downto 0);
   signal dma_gx_write_valid, dma_gx_write_ready : std_logic;
   signal h3d_vram9_source_valid, h3d_vram9_source_ready : std_logic;
   signal h3d_vram9_needed_by_h3d : std_logic;
   signal h3d_vram9_issue : std_logic;
   signal h3d_vram9_source_address : std_logic_vector(31 downto 0);
   signal h3d_vram9_source_access : std_logic_vector(1 downto 0);
   signal h3d_vram9_source_be : std_logic_vector(3 downto 0);
   signal h3d_vram9_source_data : std_logic_vector(31 downto 0);

   signal gx_wired_out, gx_wired_out_eff : std_logic_vector(31 downto 0);
   signal gx_wired_done, gx_wired_done_eff : std_logic;
   signal gx_trig, gx_irq, gx_irq_eff : std_logic;

   signal pal_we, oam_we : std_logic;
   signal pal_addr, oam_addr : integer range 0 to 511;
   signal pal_din, oam_din : std_logic_vector(31 downto 0);
   signal pal_be, oam_be : std_logic_vector(3 downto 0);
   signal pal_we_a, pal_we_b, oam_we_a, oam_we_b : std_logic;
   signal pal_addr_lo, oam_addr_lo : integer range 0 to 255;

   signal mr9_ena, mr9_rnw, mr9_done : std_logic;
   signal mr9_addr : std_logic_vector(21 downto 2);
   signal mr9_be   : std_logic_vector(3 downto 0);
   signal mr9_writedata, mr9_readdata : std_logic_vector(31 downto 0);
   -- ARM9 cache line fills fetch an aligned 8-byte pair per request instead of
   -- a word, halving the round trips through nds_mainram. mr9_readdata_hi
   -- crosses the island/clk1x boundary exactly as mr9_readdata does - stable
   -- for the whole transaction, qualified by the same mr9_done.
   signal mr9_pair : std_logic;
   signal mr9_readdata_hi : std_logic_vector(31 downto 0);

   signal io_bus9 : proc_bus_gb_type;
   signal io_wired_out9, irq_wired_out9, timer_wired_out9 : std_logic_vector(31 downto 0);
   signal io_wired_done9, irq_wired_done9, timer_wired_done9 : std_logic;
   signal ipc_wired_out9, sys_wired_out9 : std_logic_vector(31 downto 0);
   signal ipc_wired_done9, sys_wired_done9 : std_logic;
   signal tim_wired_out9, g2d_wired_out, g2db_wired_out : std_logic_vector(31 downto 0);
   signal tim_wired_done9, g2d_wired_done, g2db_wired_done : std_logic;
   signal dma_wired_out : std_logic_vector(31 downto 0);
   signal dma_wired_done : std_logic;
   signal io_bus9b : proc_bus_gb_type;

   -- ARM9 DMA bus mastering
   signal cpu9_bus_idle, cpu9_retire : std_logic;
   signal dma_on, dma_bus_on : std_logic;
   signal dma9_dbg_active_channel : std_logic_vector(1 downto 0);
   signal dma9_dbg_active_timing : std_logic_vector(2 downto 0);
   signal dma9_dbg_pending : std_logic_vector(3 downto 0);
   signal dma9_dbg_state : std_logic_vector(3 downto 0);

   -- nds_dma9's clk1x fast lane into the IO fabric (see the io_bus9 mux)
   signal dma_io_ena  : std_logic;
   signal dma_io_rnw  : std_logic;
   signal dma_io_adr  : std_logic_vector(27 downto 0);
   signal dma_io_acc  : std_logic_vector(1 downto 0);
   signal dma_io_be   : std_logic_vector(3 downto 0);
   signal dma_io_dout : std_logic_vector(31 downto 0);
   signal dmab_ena, dmab_rnw : std_logic;
   signal dmab_adr  : std_logic_vector(31 downto 0);
   signal dmab_acc  : std_logic_vector(1 downto 0);
   signal dmab_low  : std_logic_vector(1 downto 0);
   signal dmab_dout : std_logic_vector(31 downto 0);
   signal irq_dma9  : std_logic_vector(3 downto 0);
   signal mbus_adr, mbus_dout : std_logic_vector(31 downto 0);
   signal mbus_rnw, mbus_ena, mbus_code : std_logic;
   signal mbus_acc, mbus_low : std_logic_vector(1 downto 0);
   signal key_wired_out9 : std_logic_vector(31 downto 0);
   signal key_wired_done9 : std_logic;
   signal irq_in9    : std_logic_vector(31 downto 0);
   signal irq9_dbg_ime, irq9_dbg_ie, irq9_dbg_if : std_logic_vector(31 downto 0);
   signal irq7_dbg_ime, irq7_dbg_ie, irq7_dbg_if : std_logic_vector(31 downto 0);
   signal irq9_any : std_logic;
   signal irp_timer9 : std_logic_vector(3 downto 0);
   signal ipc9_irq_sync, ipc9_irq_sendempty, ipc9_irq_recv : std_logic;

   -- game-card slot
   signal card_wired_out9, card_wired_out7   : std_logic_vector(31 downto 0);
   signal card_wired_done9, card_wired_done7 : std_logic;

   -- RTC
   signal rtc_wired_out7  : std_logic_vector(31 downto 0);
   signal rtc_wired_done7 : std_logic;

   -- sound
   signal snd_wired_out7  : std_logic_vector(31 downto 0);
   signal snd_wired_done7 : std_logic;
   signal snd_bus_req     : std_logic;
   signal snd_bus_ok      : std_logic;
   signal snd_bus_own     : std_logic;
   signal sndb7_ena       : std_logic;
   signal sndb7_adr       : std_logic_vector(31 downto 0);
   signal cpu7_pause      : std_logic;
   signal dma7_idle_ok    : std_logic;

   -- ARM7 DMA (mux onto the membus7 CPU port, ARM9 dmab idiom)
   signal cpu7_bus_idle   : std_logic;
   signal dma7_on, dma7_bus_on : std_logic;
   signal dmab7_ena, dmab7_rnw : std_logic;
   signal dmab7_adr       : std_logic_vector(31 downto 0);
   signal dmab7_acc       : std_logic_vector(1 downto 0);
   signal dmab7_low       : std_logic_vector(1 downto 0);
   signal dmab7_dout      : std_logic_vector(31 downto 0);
   signal mbus7_adr, mbus7_dout : std_logic_vector(31 downto 0);
   signal mbus7_rnw, mbus7_ena  : std_logic;
   signal mbus7_acc       : std_logic_vector(1 downto 0);
   signal mbus7_low       : std_logic_vector(1 downto 0);
   signal dma7_wired_out  : std_logic_vector(31 downto 0);
   signal dma7_wired_done : std_logic;
   signal irq_dma7        : std_logic_vector(3 downto 0);
   signal irq9_card, irq7_card               : std_logic;
   signal dma9_card_trig, dma7_card_trig     : std_logic;
   signal exmem_card7_s                      : std_logic;
   signal cardm_ena                          : std_logic;
   signal cardm_addr                         : std_logic_vector(26 downto 2);
   signal ld_card_ena                        : std_logic;
   signal ld_card_addr                       : std_logic_vector(26 downto 2);
   signal irq9_vblank, irq9_hblank, irq9_vcount : std_logic;
   signal dbg_vbl_ena9 : std_logic;

   -- ================= ARM7 side =================
   signal cpu7_adr      : std_logic_vector(31 downto 0);
   signal cpu7_rnw, cpu7_ena, cpu7_done, cpu7_lock : std_logic;
   -- MEASURED 2026-07-25: the DS clocks the ARM9 at 67.028 MHz and the ARM7 at
   -- 33.514 - a 2:1 ratio. Both cores here run on clk1x with ce='1', so the ARM9
   -- is at HALF its correct relative speed. That skew breaks the NitroSDK
   -- IPCSYNC boot handshake: the ARM7 writes its nibble, delays 593
   -- instructions, and reads back before the ARM9 reaches its echo loop, so the
   -- countdown runs one step offset forever. Proven by slowing the ARM7: the
   -- ARM9's echo-loop poll count went 8 -> 237 (melonDS oracle: 158).
   -- Do NOT "fix" this by gating cpu7's ce alone: membus7 has no ce port and its
   -- cpu_done is a state level, so the core misses done and dies after 2
   -- instructions (measured). Gating the whole ARM7 subsystem would also
   -- desynchronise it from its own timers, and nds_ipc/nds_wram are shared with
   -- the ARM9. The correct fix is to clock the ARM9 domain at 2x; clk_sys Fmax
   -- is currently 37.68 MHz, so that needs timing work in this domain first.
   signal cpu7_acc      : std_logic_vector(1 downto 0);
   signal cpu7_dout, cpu7_din, cpu7_lastread : std_logic_vector(31 downto 0);
   signal cpu7_lowbits  : std_logic_vector(1 downto 0);
   signal error_cpu7    : std_logic;
   signal cpu7_irq, cpu7_unhalt : std_logic;
   signal cpu7_newhalt : std_logic;

   signal bios_addr  : unsigned(13 downto 2);
   signal bios7_data : std_logic_vector(31 downto 0);

   -- ARM7-private WRAM (64 KB, M10K - see iwram7 instance)
   signal w7p_addr      : unsigned(15 downto 2);
   signal w7p_we        : std_logic;
   signal w7p_be        : std_logic_vector(3 downto 0);
   signal w7p_writedata, w7p_readdata : std_logic_vector(31 downto 0);
   signal w7m_addr      : unsigned(15 downto 2);   -- membus/loader mux
   signal w7m_we        : std_logic;
   signal w7m_be        : std_logic_vector(3 downto 0);
   signal w7m_writedata : std_logic_vector(31 downto 0);

   signal wsh7_ena, wsh7_rnw, wsh7_done, wsh7_mapped : std_logic;
   signal wsh7_addr : unsigned(14 downto 2);
   signal wsh7_be   : std_logic_vector(3 downto 0);
   signal wsh7_din, wsh7_dout : std_logic_vector(31 downto 0);

   signal vram7_ena, vram7_rnw, vram7_done : std_logic;
   signal vram7_addr : unsigned(23 downto 2);
   signal vram7_be   : std_logic_vector(3 downto 0);
   signal vram7_din, vram7_dout : std_logic_vector(31 downto 0);
   signal vr7_ena : std_logic;
   signal h3d_vram7_source_valid, h3d_vram7_source_ready : std_logic;
   signal h3d_vram7_issue : std_logic;
   signal h3d_vram7_source_address : std_logic_vector(31 downto 0);
   signal h3d_vram7_source_access : std_logic_vector(1 downto 0);

   signal mr7_ena, mr7_rnw, mr7_done : std_logic;
   signal mr7_addr : std_logic_vector(21 downto 2);
   signal mr7_be   : std_logic_vector(3 downto 0);
   signal mr7_writedata, mr7_readdata : std_logic_vector(31 downto 0);

   signal io_bus7 : proc_bus_gb_type;
   signal io_wired_out7, irq_wired_out7, timer_wired_out7 : std_logic_vector(31 downto 0);
   signal io_wired_done7, irq_wired_done7, timer_wired_done7 : std_logic;
   signal spi_wired_out7 : std_logic_vector(31 downto 0);
   signal spi_wired_done7 : std_logic;
   signal irq7_spi : std_logic;
   signal ipc_wired_out7, sys_wired_out7 : std_logic_vector(31 downto 0);
   signal ipc_wired_done7, sys_wired_done7 : std_logic;
   signal tim_wired_out7 : std_logic_vector(31 downto 0);
   signal tim_wired_done7 : std_logic;
   signal key_wired_out7 : std_logic_vector(31 downto 0);
   signal key_wired_done7 : std_logic;
   signal irq_in7    : std_logic_vector(31 downto 0);
   signal irp_timer7 : std_logic_vector(3 downto 0);
   signal ipc7_irq_sync, ipc7_irq_sendempty, ipc7_irq_recv : std_logic;
   signal irq7_vblank, irq7_hblank, irq7_vcount : std_logic;

   -- ================= shared fabric =================
   signal wramcnt : std_logic_vector(1 downto 0);
   signal vramcnt : std_logic_vector(71 downto 0);
   signal exmem_prio7 : std_logic;

   -- main RAM port 9 = loader (while busy) / membus9 mux
   signal mem9_ena, mem9_rnw, mem9_done : std_logic;
   signal mem9_addr : std_logic_vector(21 downto 2);
   signal mem9_be   : std_logic_vector(3 downto 0);
   signal mem9_writedata, mem9_readdata : std_logic_vector(31 downto 0);
   signal mem9_pair_s : std_logic;
   signal mem9_readdata_hi_s : std_logic_vector(31 downto 0);
   signal ld_to_main, ld_to_wram7 : std_logic;

   -- ================= GPU =================
   signal keyinput : std_logic_vector(9 downto 0);
   signal extkeyin : std_logic_vector(7 downto 0);

   -- renderer channels between nds_vram and nds_gpu2d. *_accept pulses when
   -- the line server takes a request; the BG channels use it so a drawer may
   -- keep several fetches in flight (see nds_vram's pipeline comment).
   signal r_bg_accept, rb_bg_accept : std_logic;
   signal r_obj_accept, rb_obj_accept : std_logic;
   signal r_bg_req, r_bg_done       : std_logic;
   signal r_bg_addr                 : unsigned(18 downto 2);
   signal r_bg_dout                 : std_logic_vector(31 downto 0);
   signal r_obj_req, r_obj_done     : std_logic;
   signal r_obj_addr                : unsigned(17 downto 2);
   signal r_obj_dout                : std_logic_vector(31 downto 0);
   signal r_bgep_req, r_bgep_done   : std_logic;
   signal r_bgep_addr               : unsigned(14 downto 2);
   signal r_bgep_dout               : std_logic_vector(31 downto 0);
   signal r_objep_req, r_objep_done : std_logic;
   signal r_objep_addr              : unsigned(12 downto 2);
   signal r_objep_dout              : std_logic_vector(31 downto 0);

   signal g_bg_addr    : integer range 0 to 131071;
   signal g_obj_addr   : integer range 0 to 65535;
   signal g_bgep_addr  : integer range 0 to 8191;
   signal g_objep_addr : integer range 0 to 2047;

   signal rb_bg_req, rb_bg_done       : std_logic;
   signal rb_bg_addr                  : unsigned(16 downto 2);
   signal rb_bg_dout                  : std_logic_vector(31 downto 0);
   signal rb_obj_req, rb_obj_done     : std_logic;
   signal rb_obj_addr                 : unsigned(16 downto 2);
   signal rb_obj_dout                 : std_logic_vector(31 downto 0);
   signal rb_bgep_req, rb_bgep_done   : std_logic;
   signal rb_bgep_addr                : unsigned(14 downto 2);
   signal rb_bgep_dout                : std_logic_vector(31 downto 0);
   signal rb_objep_req, rb_objep_done : std_logic;
   signal rb_objep_addr               : unsigned(12 downto 2);
   signal rb_objep_dout               : std_logic_vector(31 downto 0);

   signal gb_bg_addr    : integer range 0 to 131071;
   signal gb_obj_addr   : integer range 0 to 65535;
   signal gb_bgep_addr  : integer range 0 to 8191;
   signal gb_objep_addr : integer range 0 to 2047;

   -- timing -> gpu2d line control
   signal linecounter     : integer range 0 to 191;
   signal linecounter_obj : integer range 0 to 191;
   signal drawline, drawObj, line_trigger, hblank_trigger, lcd_phase, gpu_vblank, refpoint_update : std_logic;
   signal h3d_frame_pending_level : std_logic_vector(8 downto 0);
   -- Exact renderer-side receipt for the NSMB BG1 parallax problem row.
   signal bg1_scroll_renderer_diag : std_logic_vector(31 downto 0) := (others => '0');
   signal bg1_scroll_sample_toggle_d : std_logic := '0';
   -- Behavior-neutral ARM9 membus telemetry. The accepted address is latched
   -- separately from the CPU's live/pending address so a DMA-grant snapshot
   -- identifies the transaction actually owning the bus.
   signal cpu_access_active : std_logic := '0';
   signal cpu_access_age : unsigned(6 downto 0) := (others => '0');
   signal cpu_access_rnw : std_logic := '1';
   signal cpu_access_addr : std_logic_vector(11 downto 0) := (others => '0');
   signal line_busy, epfill_busy : std_logic;
   signal dbg_rbusy_s : std_logic;
   signal line_busy_b, epfill_busy_b : std_logic;

   -- engine streams pre-routing
   signal pow_2da, pow_2db, pow_swap : std_logic;
   signal pxa_x, pxb_x       : integer range 0 to 255;
   signal pxa_y, pxb_y       : integer range 0 to 191;
   signal pxa_data, pxb_data : std_logic_vector(17 downto 0);
   signal pxa_we, pxb_we     : std_logic;
   signal pxb_data_eff       : std_logic_vector(17 downto 0);
   signal vcount_out : unsigned(8 downto 0);
   signal math_write_low : std_logic_vector(1 downto 0);

begin

   math_request    <= io_bus9.ena;
   -- nds_membus9 normalizes 0x04000000 IO addresses to a 28-bit offset.
   -- Restore the full ARM9 address expected by the retained math MMIO ABI.
   -- Adr is word-aligned, so recover a write's original lane from bEna. Reads
   -- remain aligned because membus9 owns their saved-low-bit rotation.
   with io_bus9.bEna select math_write_low <=
      "01" when "0010",
      "10" when "0100" | "1100",
      "11" when "1000",
      "00" when others;
   math_address <= x"04" & io_bus9.Adr(23 downto 2) & "00"
      when io_bus9.rnw = '1' else
      x"04" & io_bus9.Adr(23 downto 2) & math_write_low;
   math_rnw        <= io_bus9.rnw;
   -- The membus also aligns Adr and applies its saved-low-bit read rotation
   -- after the wired-OR response.  Return a raw 32-bit register image on reads
   -- so byte/halfword lanes are selected exactly once; writes keep their real
   -- access size and already lane-placed data.
   math_access     <= ACCESS_32BIT when io_bus9.rnw = '1' else io_bus9.acc;
   math_write_data <= io_bus9.Din;

   -- ================= lossless hybrid-3D event boundary =================
   -- CPU IO requests are one-cycle pulses; DMA GXFIFO valid is deliberately
   -- independent of its acceptance enable.  dma_bus_on makes the sources
   -- mutually exclusive, and both buses hold their payload until completion.
   -- The ARM service owns only 3D. Palette/OAM and 2D registers remain local
   -- to the FPGA renderer and therefore cannot inherit HPS backpressure.
   h3d_gpu_source_is_cpu <= not dma_bus_on;
   h3d_gpu_source_valid <= dma_gx_write_valid when dma_bus_on = '1' else
      '1' when (io9_ena = '1' and io9_lat_1x.rnw = '0' and
                h3d_gpu_write_hit(io9_lat_1x.Adr, io9_lat_1x.bEna)) else '0';
   h3d_gpu_source_address <= io_bus9.Adr;
   h3d_gpu_source_access <= io_bus9.acc;
   h3d_gpu_source_be <= io_bus9.bEna;
   h3d_gpu_source_data <= io_bus9.Din;

   h3d_vram9_source_address <=
      x"06" & std_logic_vector(dma_vr_addr) & "00" when dma_bus_on = '1' else
      x"06" & std_logic_vector(vram9_addr) & "00";
   h3d_vram9_source_be <= dma_vr_be when dma_bus_on = '1' else vram9_be;
   h3d_vram9_source_data <= dma_vr_din when dma_bus_on = '1' else vram9_din;
   h3d_vram9_source_access <= h3d_access_from_be(h3d_vram9_source_be);
   -- The HPS 3D model needs uploads through the LCDC aperture while a
   -- texture/palette bank is CPU-visible. BG/OBJ writes are consumed by the
   -- FPGA 2D engines and stay off the HPS event stream.
   h3d_vram9_needed_by_h3d <= '1'
      when h3d_vram9_source_address(27 downto 20) = x"68" else '0';
   -- A posted DMA write becomes an event source only when nds_vram can accept
   -- it on the same edge.  `vram_write_valid` remains held independently, so
   -- a full local write queue cannot deadlock valid behind event ready; wok is
   -- local architectural credit and does not depend on the H3D queue.
   h3d_vram9_source_valid <=
      dma_vram_write_valid and ((not vr9_welig) or vr9_wok) and
         h3d_vram9_needed_by_h3d
         when dma_bus_on = '1' else
      vram9_ena and not vram9_rnw and h3d_vram9_needed_by_h3d;

   h3d_vram7_source_address <= x"06" & std_logic_vector(vram7_addr) & "00";
   h3d_vram7_source_access <= h3d_access_from_be(vram7_be);
   h3d_vram7_source_valid <= vram7_ena and not vram7_rnw;
   vr7_ena <= vram7_ena
      when (vram7_rnw = '1' or h3d_service_ready = '0') else
      h3d_vram7_issue;

   ih3d_events : entity work.nds_h3d_console_event_gate
   port map
   (
      clk => clk1x,
      reset => reset_boot,
      service_ready => h3d_service_ready,
      timestamp => h3d_timestamp,
      current_frame => h3d_current_frame,
      source_fault => h3d_source_fault,

      gpu_source_valid => h3d_gpu_source_valid,
      gpu_source_is_cpu => h3d_gpu_source_is_cpu,
      gpu_source_address => h3d_gpu_source_address,
      gpu_source_access => h3d_gpu_source_access,
      gpu_source_be => h3d_gpu_source_be,
      gpu_source_data => h3d_gpu_source_data,
      gpu_source_ready => h3d_gpu_source_ready,
      gpu_cpu_complete => h3d_gpu_cpu_complete,
      gpu_event_valid => h3d_gpu_write_valid,
      gpu_event_ready => h3d_gpu_write_ready,
      gpu_event_address => h3d_gpu_write_address,
      gpu_event_access => h3d_gpu_write_access,
      gpu_event_be => h3d_gpu_write_byte_enable,
      gpu_event_data => h3d_gpu_write_data,
      gpu_event_frame => h3d_gpu_write_frame,
      gpu_event_timestamp => h3d_gpu_write_timestamp,

      vram9_source_valid => h3d_vram9_source_valid,
      vram9_source_address => h3d_vram9_source_address,
      vram9_source_access => h3d_vram9_source_access,
      vram9_source_be => h3d_vram9_source_be,
      vram9_source_data => h3d_vram9_source_data,
      vram9_source_ready => h3d_vram9_source_ready,
      vram9_issue => h3d_vram9_issue,
      vram9_event_valid => h3d_vram9_write_valid,
      vram9_event_ready => h3d_vram9_write_ready,
      vram9_event_address => h3d_vram9_write_address,
      vram9_event_access => h3d_vram9_write_access,
      vram9_event_be => h3d_vram9_write_byte_enable,
      vram9_event_data => h3d_vram9_write_data,
      vram9_event_frame => h3d_vram9_write_frame,
      vram9_event_timestamp => h3d_vram9_write_timestamp,

      vram7_source_valid => h3d_vram7_source_valid,
      vram7_source_address => h3d_vram7_source_address,
      vram7_source_access => h3d_vram7_source_access,
      vram7_source_be => vram7_be,
      vram7_source_data => vram7_din,
      vram7_source_ready => h3d_vram7_source_ready,
      vram7_issue => h3d_vram7_issue,
      vram7_event_valid => h3d_vram7_write_valid,
      vram7_event_ready => h3d_vram7_write_ready,
      vram7_event_address => h3d_vram7_write_address,
      vram7_event_access => h3d_vram7_write_access,
      vram7_event_be => h3d_vram7_write_byte_enable,
      vram7_event_data => h3d_vram7_write_data,
      vram7_event_frame => h3d_vram7_write_frame,
      vram7_event_timestamp => h3d_vram7_write_timestamp,

      -- HBlank is an FPGA-local 2D/HDMA deadline in 3D-plane mode.
      hblank_pulse => '0',
      hblank_line => std_logic_vector(vcount_out),
      hblank_event_valid => h3d_hblank_valid,
      hblank_event_ready => h3d_hblank_ready,
      hblank_event_line => h3d_hblank_line,
      hblank_event_frame => h3d_hblank_frame,
      hblank_event_timestamp => h3d_hblank_timestamp,

      frame_pulse => gpu_vblank,
      frame_event_valid => h3d_frame_valid,
      frame_event_ready => h3d_frame_ready,
      frame_event_number => h3d_frame_number,
      frame_event_timestamp => h3d_frame_timestamp,
      frame_pending_level => h3d_frame_pending_level
   );

   -- =====================================================================
   -- boot: fabric out of reset -> loader copies both sections -> preset
   -- both boot PCs through the savestate buses -> release the CPUs
   -- =====================================================================
   p_boot : process (clk1x)
   begin
      if rising_edge(clk1x) then
         ld_start      <= '0';
         preset_direct <= '0';
         -- dbg_boot_rst is the debugger's SOFTRESET: it re-enters the same
         -- sequence as a real reset (loader, PC presets, CPU release) while the
         -- cart image stays staged in DDR3, so a from-reset differential can be
         -- repeated without reloading the core or the ROM.
         if (reset = '1' or dbg_boot_rst = '1') then
            boot_state <= B_RESET;
            boot_cnt   <= 0;
            resetCpu   <= '1';
            ss_bus9    <= ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
            ss_bus7    <= ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
         else
            case boot_state is

               when B_RESET =>
                  resetCpu <= '1';
                  boot_cnt <= 0;
                  if (nds_on = '1') then
                     boot_state <= B_SETTLE;
                  end if;

               when B_SETTLE =>
                  if (boot_cnt = 7) then
                     boot_state <= B_LDSTART;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_LDSTART =>
                  ld_start   <= '1';
                  boot_state <= B_LDWAIT;

               when B_LDWAIT =>
                  if (ld_error = '1') then
                     boot_state <= B_ERROR;
                  elsif (ld_done = '1' and ld_busy = '0' and
                         vclr_busy = '0' and pclr_busy_a = '0' and pclr_busy_b = '0' and
                         backup_run_ready = '1') then
                     boot_state  <= B_S9RST;
                     boot_cnt    <= 0;
                     ss_bus9.rst <= '1';
                  end if;

               when B_S9RST =>
                  if (boot_cnt = 2) then
                     ss_bus9.rst <= '0';
                     boot_cnt    <= 0;
                     preset_idx  <= 0;
                     boot_state  <= B_S9GAP;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_S9GAP =>
                  ss_bus9.Adr  <= std_logic_vector(to_unsigned(preset_adr(preset_idx), ss_bus9.Adr'length));
                  -- Firmware boot enters the ARM9 BIOS at its reset vector instead
                  -- of the cart's entry point. This core does not model the ARM
                  -- reset exception at all - both CPUs start from whatever this
                  -- savestate write puts in fetch_PC - so "just release reset and
                  -- let it vector" boots from 0x00000000 and retires nothing.
                  ss_bus9.Din  <= preset_val(preset_idx, arm9_entry_eff, true);
                  ss_bus9.rnw  <= '0';
                  ss_bus9.bEna <= "1111";
                  ss_bus9.ena  <= '1';
                  boot_state   <= B_S9WR;

               when B_S9WR =>
                  ss_bus9.ena <= '0';
                  ss_bus9.rnw <= '1';
                  boot_cnt    <= 0;
                  -- Firmware boot gets the PC and nothing else: the ARM9 BIOS
                  -- sets up its own stacks, and presetting them here would mask
                  -- a BIOS that never reached that point.
                  if (preset_idx < PRESET_LAST and fw_boot = '0') then
                     preset_idx <= preset_idx + 1;
                     boot_state <= B_S9GAP;
                  else
                     boot_state <= B_S9POST;
                  end if;

               when B_S9POST =>
                  if (boot_cnt = 2) then
                     boot_cnt    <= 0;
                     ss_bus7.rst <= '1';
                     boot_state  <= B_S7RST;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_S7RST =>
                  if (boot_cnt = 2) then
                     ss_bus7.rst <= '0';
                     boot_cnt    <= 0;
                     preset_idx  <= 0;
                     boot_state  <= B_S7GAP;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_S7GAP =>
                  ss_bus7.Adr  <= std_logic_vector(to_unsigned(preset_adr(preset_idx), ss_bus7.Adr'length));
                  ss_bus7.Din  <= preset_val(preset_idx, arm7_entry_eff, false);
                  ss_bus7.rnw  <= '0';
                  ss_bus7.bEna <= "1111";
                  ss_bus7.ena  <= '1';
                  boot_state   <= B_S7WR;

               when B_S7WR =>
                  ss_bus7.ena <= '0';
                  ss_bus7.rnw <= '1';
                  boot_cnt    <= 0;
                  if (preset_idx < PRESET_LAST and fw_boot = '0') then
                     preset_idx <= preset_idx + 1;
                     boot_state <= B_S7GAP;
                  else
                     boot_state <= B_S7POST;
                  end if;

               when B_S7POST =>
                  if (boot_cnt = 2) then
                     boot_cnt   <= 0;
                     boot_state <= B_RUN;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_RUN =>
                  resetCpu <= '0';
                  -- firmware-left registers: pulsed WITH the reset release, not at
                  -- ld_done - nds_syscnt resets on resetCpu, which swallows any
                  -- earlier preset (WRAMCNT=0 then let the calico crt0 section copy
                  -- to 0x037F8000 mirror into WRAM7 over the ARM7 stack)
                  if (boot_cnt = 0) then
                     boot_cnt      <= 1;
                     preset_direct <= direct_boot;
                  end if;

               when B_ERROR =>
                  null;

            end case;
         end if;
      end if;
   end process;

   boot_done  <= '1' when boot_state = B_RUN else '0';
   boot_error <= '1' when boot_state = B_ERROR else '0';

   iloader : entity work.nds_loader
   generic map ( is_simu => is_simu, skip_copy => skip_copy )
   port map
   (
      clk => clk1x, reset => reset_boot,
      start => ld_start, direct => direct_boot, fw_boot => fw_boot,
      busy => ld_busy, done => ld_done, load_error => ld_error,
      arm9_entry => arm9_entry, arm7_entry => arm7_entry, cart_id => ld_cartid,
      save_is_64k => ld_save_is_64k,
      save_gamecode => ld_save_gamecode,
      save_gamecode_valid => ld_save_gamecode_valid,
      card_ena => ld_card_ena, card_addr => ld_card_addr,
      card_done => card_done, card_rdata => card_din,
      wr_ena => ld_wr_ena, wr_rnw => ld_wr_rnw,
      wr_addr => ld_wr_addr, wr_data => ld_wr_data,
      wr_done => ld_wr_done, rd_data => mem9_readdata,
      vfy_bad => dbg_vfy_bad, vfy_addr => dbg_vfy_addr
   );

   isaveprofile : nds_nitro_save_profile
   generic map
   (
      PREFIX_COUNT => 368
   )
   port map
   (
      clk => clk1x,
      reset => reset_boot,
      start => ld_save_gamecode_valid,
      game_code => ld_save_gamecode,
      busy => save_profile_busy,
      valid => save_profile_valid_s,
      save_type => save_profile_type_s
   );

   arm9_entry_eff <= x"FFFF0000" when (fw_boot = '1') else arm9_entry;
   arm7_entry_eff <= x"00000000" when (fw_boot = '1') else arm7_entry;

   -- card image port: the loader owns it during boot, the slot module after
   -- (the CPUs are in reset while ld_busy, so no ROMCTRL transfer can overlap)
   card_ena  <= ld_card_ena  when ld_busy = '1' else cardm_ena;
   card_addr <= ld_card_addr when ld_busy = '1' else cardm_addr;

   icard : entity work.nds_card
   generic map
   (
      -- 4x the cart bus. Not hardware-faithful and deliberately so: see the
      -- Timing note in nds_card.vhd. Set to 0 to get NTR pacing back.
      CARDSPEED_SHIFT => 2
   )
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      card7 => exmem_card7_s,
      fw_boot => fw_boot,
      chipid => ld_cartid,
      bus9 => io_bus9, wired_out9 => card_wired_out9, wired_done9 => card_wired_done9,
      bus7 => io_bus7, wired_out7 => card_wired_out7, wired_done7 => card_wired_done7,
      irq9_xfer => irq9_card, irq7_xfer => irq7_card,
      dma9_card => dma9_card_trig, dma7_card => dma7_card_trig,
      dbg_card => dbg_card_s,
      backup_addr => backup_addr,
      backup_write_data => backup_write_data,
      backup_write_enable => backup_write_enable,
      backup_read_data => backup_read_data,
      backup_write_toggle => backup_write_toggle,
      backup_save_type => save_profile_type_s,
      backup_ir_enable => save_ir_enable_s,
      backup_access_active => backup_access_active,
      backup_cache_ready => backup_cache_ready,
      card_ena => cardm_ena, card_addr => cardm_addr,
      card_din => card_din, card_done => card_done
   );

   -- Cartridge IR transceiver: present when the game code's first character
   -- is 'I' (melonDS NDSCart.cpp -- (gamecode & 0xFF) == 'I' selects
   -- CartRetailIR).  ld_save_gamecode is little-endian, so that character is
   -- bits 7..0.  Latched because ld_save_gamecode_valid is a single pulse.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset_boot = '1') then
            save_ir_enable_s <= '0';
         elsif (ld_save_gamecode_valid = '1') then
            if (ld_save_gamecode(7 downto 0) = x"49") then
               save_ir_enable_s <= '1';
            else
               save_ir_enable_s <= '0';
            end if;
         end if;
      end if;
   end process;

   backup_is_64k <= '1' when save_profile_type_s = "0011" else '0';
   backup_save_type <= save_profile_type_s;
   backup_profile_valid <= save_profile_valid_s;

   -- loader writes route by target: main RAM (0x02xxxxxx) via main-RAM port 9,
   -- ARM7-private WRAM (0x037xxxxx) straight into the store (CPUs are in reset)
   ld_to_main  <= '1' when (ld_busy = '1' and ld_wr_addr(31 downto 24) = x"02") else '0';
   ld_to_wram7 <= '1' when (ld_busy = '1' and ld_wr_addr(31 downto 24) = x"03") else '0';

   -- ARM9 main-RAM channel has three possible owners, in priority order: the
   -- loader (boot copy + its verify pass), the debug unit's peek, then the CPU.
   -- dbg_pk_sel stays asserted for the whole peek so address/rnw hold until the
   -- op completes; the CPU's own done is suppressed for both borrowed cases.
   idbgpk : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset = '1') then
            dbg_pk_act <= '0';
         elsif (dbg_pk_ena = '1') then
            dbg_pk_act <= '1';
         elsif (mem9_done = '1') then
            dbg_pk_act <= '0';
         end if;
      end if;
   end process;
   dbg_pk_sel <= dbg_pk_ena or dbg_pk_act;

   mem9_ena       <= (ld_wr_ena and ld_to_main) when ld_busy = '1' else
                     dbg_pk_ena                 when dbg_pk_sel = '1' else mr9_ena;
   mem9_rnw       <= ld_wr_rnw                  when ld_busy = '1' else
                     '1'                        when dbg_pk_sel = '1' else mr9_rnw;
   mem9_addr      <= ld_wr_addr(21 downto 2)    when ld_busy = '1' else
                     dbg_pk_addr_s(21 downto 2) when dbg_pk_sel = '1' else mr9_addr;
   mem9_be        <= "1111"                     when ld_busy = '1' else
                     "1111"                     when dbg_pk_sel = '1' else mr9_be;
   mem9_writedata <= ld_wr_data                 when ld_busy = '1' else mr9_writedata;
   -- Pair mode belongs to the cache alone. The loader writes and the debugger's
   -- peek both borrow this port, and neither wants two words back - forcing it
   -- low here means a peek issued mid-fill cannot make nds_mainram wait on a
   -- done64 that its 32-bit op will never produce.
   mem9_pair_s    <= mr9_pair when (ld_busy = '0' and dbg_pk_sel = '0') else '0';
   mr9_done       <= mem9_done and not ld_busy and not dbg_pk_sel;
   mr9_readdata   <= mem9_readdata;
   mr9_readdata_hi <= mem9_readdata_hi_s;
   dbg_pk_done_s  <= mem9_done and dbg_pk_sel;

   reset_boot <= reset or dbg_boot_rst;

   -- ================= ARM9 67 MHz island: clk1x <-> clk2x bridge =================
   -- clk2x is exactly 2x clk1x from one VCO at 0 ps, so this is a *related*-clock
   -- crossing, not an asynchronous one - no metastability, but the pulse widths
   -- still have to be reconciled: a 1-clk2x pulse is half a clk1x period and
   -- clk1x would miss it, and a 1-clk1x pulse is two clk2x cycles and the island
   -- would count it twice.
   --
   -- Only the pulses cross. membus9 holds address/data/byte-enables stable for the
   -- whole transaction (nds_cache9's own comment relies on this: "the membus holds
   -- them until resp_done"), and it has at most ONE external access in flight, so
   -- the level signals are wired straight through.
   --
   -- Request handshake, clk2x -> clk1x, TOGGLE based. A sticky-bit stretch is
   -- phase-dependent and silently drops half the requests: ph1x is high on the
   -- island cycle right after a clk1x edge, so a sticky set in the *second* half
   -- of a clk1x period is cleared before clk1x ever samples it. A toggle has no
   -- such window - the island flips it once per request and it then sits stable
   -- until the transaction completes (membus9 issues at most one external access
   -- at a time and waits), so the clk1x edge-detector fires exactly once.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (resetCpu = '1') then
            cdc_req_wsh  <= '0'; cdc_req_vram <= '0'; cdc_req_mr <= '0';
            cdc_req_io   <= '0'; cdc_req_pal  <= '0'; cdc_req_oam <= '0';
         else
            if (i9_wsh_ena  = '1') then cdc_req_wsh  <= not cdc_req_wsh;  end if;
            if (i9_vram_ena = '1') then cdc_req_vram <= not cdc_req_vram; end if;
            if (i9_mr_ena   = '1') then cdc_req_mr   <= not cdc_req_mr;   end if;
            -- membus9's IO request is a record field, not the (never-driven)
            -- standalone signal this used to test - which silently killed every
            -- ARM9 IO access across the bridge, IPCSYNC included.
            if (i9_io_bus.ena = '1') then cdc_req_io <= not cdc_req_io; end if;
            if (i9_pal_we   = '1') then cdc_req_pal  <= not cdc_req_pal;  end if;
            if (i9_oam_we   = '1') then cdc_req_oam  <= not cdc_req_oam;  end if;
         end if;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         cdc_req_wsh_d  <= cdc_req_wsh;
         cdc_req_vram_d <= cdc_req_vram;
         cdc_req_mr_d   <= cdc_req_mr;
         cdc_req_io_d   <= cdc_req_io;
         cdc_req_pal_d  <= cdc_req_pal;
         cdc_req_oam_d  <= cdc_req_oam;
         wsh9_ena  <= cdc_req_wsh  xor cdc_req_wsh_d;
         vram9_ena <= cdc_req_vram xor cdc_req_vram_d;
         mr9_ena   <= cdc_req_mr   xor cdc_req_mr_d;
         io9_ena   <= cdc_req_io   xor cdc_req_io_d;
         pal_we    <= cdc_req_pal  xor cdc_req_pal_d;
         oam_we    <= cdc_req_oam  xor cdc_req_oam_d;
      end if;
   end process;

   -- everything except .ena is a stable level for the whole transaction
   -- IO payload latch, island -> clk1x. Only `ena` was synchronised across the
   -- bridge; Adr/Din/bEna/rnw were taken live from the island signal. membus9
   -- asserts io_bus.ena for ONE island cycle and then enters FINISH, where
   -- accept_now is already true - so it can accept the next request and overwrite
   -- the payload on the following island cycle, a full clk1x edge before the IO
   -- fabric samples it. The write then landed with whatever had replaced it.
   --
   -- This is why the screen was white. The ARM9 wrote IPCSYNC 59 times and
   -- nds_ipc applied every one of them with a data nibble of 0, so sync9_out never
   -- left 0, the ARM7 read 0x0800 instead of 0x0808 and the boot handshake never
   -- completed; DISPCNT was programmed with garbage for the same reason. None of it
   -- was visible in the ARM9's instruction trace, which stayed byte-identical to
   -- melonDS for 1.29M instructions - a store that goes astray does not touch the
   -- CPU's registers.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (i9_io_bus.ena = '1') then
            io9_lat <= i9_io_bus;
         end if;
      end if;
   end process;

   -- ...and then re-registered onto clk1x before it reaches the peripherals.
   -- io9_lat is a clk2x flop, so driving the IO fabric straight from it left
   -- every peripheral's address decode inside a clk2x -> clk1x crossing with
   -- only 14.915 ns. That was the whole remaining clk1x failing family once
   -- mem9_lock was fixed - `io9_lat.Adr[5] -> nds_card|delay_cnt[*]` at
   -- -1.959 ns, the card's cycle-count decode hanging off the bridge.
   --
   -- Unconditional, and it costs no latency. io9_lat is written on the island
   -- edge that toggles cdc_req_io, and io9_ena cannot rise before the clk1x
   -- edge that first sees that toggle - the same edge this captures on - so the
   -- payload is already valid in the cycle the enable is asserted. It also
   -- cannot move underneath the access: membus9 has one IO transaction in
   -- flight at a time and waits in W_IO_RESP for cdc_io_cpl, which is not
   -- toggled until the end of the enable cycle.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         io9_lat_1x <= io9_lat;
      end if;
   end process;

   -- ...and while the ARM9 DMA holds the bus it drives the fabric itself, from
   -- clk1x, skipping this bridge entirely. That is worth 4 clk1x cycles on every
   -- IO access (measured 5 -> 1) and it is safe without arbitration: dma_on pauses
   -- the CPU and nds_dma9 does not raise dma_bus_on until cpu_bus_idle, which only
   -- returns to '1' on gb_bus_done - so the island has no IO transaction in flight
   -- for the whole window. io9_ena cannot pulse here either, since it is generated
   -- from cdc_req_io toggles and the paused CPU makes none.
   io_bus9 <= (Din  => dma_io_dout,      Adr  => dma_io_adr,
               rnw  => dma_io_rnw,       ena  => dma_io_ena,
               acc  => dma_io_acc,       bEna => dma_io_be,
               rst  => i9_io_bus.rst)
              when dma_bus_on = '1' else
              (Din  => io9_lat_1x.Din,  Adr  => io9_lat_1x.Adr,
               rnw  => io9_lat_1x.rnw,  ena  => io9_ena,
               acc  => io9_lat_1x.acc,  bEna => io9_lat_1x.bEna,
               rst  => i9_io_bus.rst);

   -- Main-RAM SWP lock, island -> clk1x. Same payload-latch reasoning as io9_lat
   -- above, but this one was a *timing* bug rather than a functional one, and it
   -- was the whole worst-path family: `cpu9_lock and not bus_cacheable_d` was
   -- wired live into nds_mainram's mem9_lock, so nds_mainram's clk1x req9_lock
   -- flop closed a combinational path that started at the ARM9's register file
   -- and ran through the shifter, the ALU, the writeback mux, the address mux
   -- and the CP15 PU region compare - 18.48 ns into a 14.915 ns clk2x->clk1x
   -- relationship. All 50 paths in the global -npaths 50 report ended here.
   --
   -- Nothing about that was necessary. req9_lock only samples mem9_lock in the
   -- clk1x cycle where mem9_ena is high, and mem9_ena is mr9_ena - the toggle
   -- edge-detect above, which cannot fire until at least one clk1x edge AFTER
   -- the island raised i9_mr_ena. Latching the term in the island at the instant
   -- the request is launched therefore delivers the identical value with a full
   -- clk1x period of settling, and turns the crossing into flop -> flop.
   --
   -- dma_bus_on / ld_busy stay live at the port: both are clk1x registers that
   -- hold for the whole burst, so they cost one LUT and no cross-domain cone.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (resetCpu = '1') then
            mr9_lock <= '0';
         elsif (i9_mr_ena = '1') then
            mr9_lock <= cpu9_lock and not bus_cacheable_d;
         end if;
      end if;
   end process;

   -- Done narrow, clk1x -> clk2x. A 1-clk1x done is high for two clk2x cycles;
   -- edge-detect so the island's FSM sees exactly one.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cdc_wsh_done_d  <= wsh9_done;
         cdc_vram_done_d <= vram9_done;
         cdc_mr_done_d   <= mr9_done;
      end if;
   end process;
   -- DMA9 masters the ARM9 membus while dma_bus_on, but nds_dma9 is a clk1x unit
   -- talking to a clk2x membus, so its request pulse is two island cycles wide
   -- (membus9 would accept it twice) and membus9's one-island-cycle done is only
   -- half a clk1x period (nds_dma9 would miss it). Narrow one, stretch the other.
   -- The CPU's own path needs neither: cpu9 is inside the island.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cdc_dmab_ena_d <= dmab_ena;
      end if;
   end process;
   dmab_ena_i9 <= dmab_ena and not cdc_dmab_ena_d;

   -- membus9's cpu_done is one ISLAND cycle - half a clk1x period - so a clk1x
   -- process sampling it directly would miss it half the time (the same defect
   -- the request path had). Toggle in the island, edge-detect in clk1x.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (cpu9_done = '1') then cdc_cpudone_tgl <= not cdc_cpudone_tgl; end if;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         cdc_cpudone_tgl_d <= cdc_cpudone_tgl;
         cpu9_done_1x      <= cdc_cpudone_tgl xor cdc_cpudone_tgl_d;
      end if;
   end process;

   i9_wsh_done  <= wsh9_done       and not cdc_wsh_done_d;
   i9_vram_done <= vram9_done      and not cdc_vram_done_d;
   i9_mr_done   <= mr9_done        and not cdc_mr_done_d;

   -- IO/palette/OAM completion, clk1x -> island. io_wired_done9 is a pure address decode
   -- ("some peripheral claims this address"), not a per-transaction event, so
   -- edge-detecting it fires once and then never again across back-to-back IO
   -- accesses to claimed addresses. Generate an explicit completion one clk1x
   -- after the access was presented: by then the peripheral has seen io_bus9.ena
   -- and its wired_out is stable (the payload latch holds Adr), so the island can
   -- sample the read data in the cycle it retires the access.
   --
   -- Unconditional for every access except a service-active GPU write: reads
   -- and unclaimed addresses still complete with the legacy timing and data.
   -- A GPU write completes only when its raw event enters the lossless H3D
   -- source gate. The peripheral consumed io9_ena on its original edge; the
   -- held event never reasserts the local enable, so a stalled write cannot be
   -- executed twice.
   -- Palette/OAM stay local to the FPGA 2D engine and retain legacy timing.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (pal_we = '1' or oam_we = '1') then
            cdc_io_cpl <= not cdc_io_cpl;
         elsif (io9_ena = '1') then
            if (h3d_service_ready = '1' and io9_lat_1x.rnw = '0' and
                h3d_gpu_write_hit(io9_lat_1x.Adr, io9_lat_1x.bEna)) then
               if (h3d_gpu_cpu_complete = '1') then
                  cdc_io_cpl <= not cdc_io_cpl;
               end if;
            else
               cdc_io_cpl <= not cdc_io_cpl;
            end if;
         elsif (h3d_gpu_cpu_complete = '1') then
            cdc_io_cpl <= not cdc_io_cpl;
         end if;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cdc_io_cpl_d <= cdc_io_cpl;
      end if;
   end process;

   i9_io_done   <= cdc_io_cpl xor cdc_io_cpl_d;

   -- Track the transaction the ARM9 membus actually accepts. Beta 67 proved
   -- that the live 0x04000600 CPU address seen on missed HBlank updates had not
   -- entered the I/O bridge: GXSTAT read age/count/active were all zero. The
   -- live address was therefore only the next pending request, not evidence of
   -- the current bus owner. This tracker follows acceptance through cpu9_done
   -- and exposes its state/age/address without participating in arbitration.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (resetCpu = '1') then
            cpu_access_active <= '0';
            cpu_access_age <= (others => '0');
            cpu_access_rnw <= '1';
            cpu_access_addr <= (others => '0');
         elsif (cpu9_ena = '1' and dbg_mb9(6) = '1') then
            cpu_access_active <= '1';
            cpu_access_age <= (others => '0');
            cpu_access_rnw <= cpu9_rnw;
            cpu_access_addr <= cpu9_adr(11 downto 0);
         elsif (cpu_access_active = '1') then
            if (cpu9_done = '1') then
               cpu_access_active <= '0';
            elsif (cpu_access_age /= "1111111") then
               cpu_access_age <= cpu_access_age + 1;
            end if;
         end if;
      end if;
   end process;


   -- out ports are write-only in VHDL-93; nds_debug reads the internals
   dbg_pc9 <= pc9_s;
   dbg_pc7 <= pc7_s;

   -- PROBE word (mailbox op 0x0A). Byte 3 is the top-level mux state, which is
   -- what decides whether a cache request ever reaches nds_mainram at all.
   -- Bit 18 is nds_mainram's spare '0' in dbg_mr_s(2); it now carries the ARM9's
   -- persistent DISPSTAT bit 3 (VBlank IRQ enable). Diagnostic only.
   --
   -- WHY: Kirby freezes on hardware with the ARM9 asleep in the NitroSDK idle
   -- thread's WFI at 0x0214FC08, IE9 VBlank enabled, and IF9 bit 0 NEVER latching
   -- - while the ARM7 does receive VBlank. reach9 proves Kirby's DISPSTAT-writing
   -- code IS executed (0x02143A4C, 0x02143AF0), and the sim sees the write land on
   -- the bus as `VIDREG A +004 = 0000000B bEna=3`, bit 3 set. So the open question
   -- is exactly whether R_vbl_irq_ena(0) holds that bit, and nothing readable
   -- answered it: the earlier dbg_vbl_ena9 probe was never exported, and the DDR3
   -- telemetry lane is clobbered by the framebuffer on a white screen. The mailbox
   -- probe is the one channel that returns clean data.
   dbg_probe <= dma_bus_on & ld_busy & dbg_pk_sel & mem9_done &
                mem9_ena & mr9_ena & mr9_done & cpu9_ena &
                dbg_mr_s(7 downto 3) & dbg_vbl_ena9 & dbg_mr_s(1 downto 0) &
                dbg_mb9 & dbg_cache9;

   gdebug : if DEBUG_ENABLE /= 0 generate
   idebug : entity work.nds_debug
   generic map
   (
      -- '0' = play image: the cores boot on their own. Set to `not is_simu` for a
      -- diagnostic image, which leaves both cores held out of reset so a
      -- debugger can arm breakpoints before the first instruction retires
      -- (without it the boot FSM's B_RUN drops resetCpu and the game is millions
      -- of instructions in before a host can attach). Simulation must never
      -- hold: it is the golden reference for that differential, and holding
      -- there yields a boot_done with zero retired instructions and an empty
      -- trace. The mailbox itself stays usable either way.
      BOOT_HOLD => '0'
   )
   port map
   (
      clk      => clk1x,
      reset    => reset,
      cmd_stb  => dbg_cmd_stb,
      cmd_op   => dbg_cmd_op,
      cmd_arg  => dbg_cmd_arg,
      rsp_data => dbg_rsp_data,
      rsp_stb  => dbg_rsp_stb,
      hold9    => dbg_hold9,
      rel9     => dbg_rel9,
      hold7    => dbg_hold7,
      rel7     => dbg_rel7,
      boot_rst => dbg_boot_rst,
      regsel   => dbg_regsel_s,
      regval9  => dbg_regval9,
      regval7  => dbg_regval7,
      pc9      => pc9_s,
      pc7      => pc7_s,
      probe    => dbg_probe,
      cardstat => dbg_card_s,
      ipcstat  => dbg_ipc_s,
      perfstat => dbg_perf_s,
      perf_index => dbg_perf_idx,
      irq9_ime => irq9_dbg_ime, irq9_ie => irq9_dbg_ie, irq9_if => irq9_dbg_if,
      irq7_ime => irq7_dbg_ime, irq7_ie => irq7_dbg_ie, irq7_if => irq7_dbg_if,
      pk_ena   => dbg_pk_ena,
      pk_addr  => dbg_pk_addr_s,
      pk_done  => dbg_pk_done_s,
      pk_data  => mem9_readdata
   );
   end generate;

   -- DEBUG_ENABLE = 0: drive every nds_debug OUTPUT to its inactive value. This
   -- is the whole list - an undriven one here does not fail elaboration, it
   -- quietly becomes 'U'/'X' and takes a build to find (see the domain-split
   -- driver audit). dbg_pk_act/dbg_pk_sel are NOT in this list on purpose: they
   -- are derived from dbg_pk_ena by the process above, so pinning pk_ena low
   -- settles both and hands the ARM9 main-RAM mux straight back to mr9_*.
   gnodebug : if DEBUG_ENABLE = 0 generate
      dbg_rsp_data  <= (others => '0');
      dbg_rsp_stb   <= '0';    -- never answers; NDS.sv's outer timeout covers it
      dbg_hold9     <= '0';    -- -> cpu9 new_halt: never hold a core
      dbg_rel9      <= '0';    -- -> cpu9 unhalt (OR'd with cpu9_unhalt)
      dbg_hold7     <= '0';
      dbg_rel7      <= '0';
      dbg_boot_rst  <= '0';    -- -> boot FSM restart AND reset_boot
      dbg_regsel_s  <= (others => '0');
      dbg_pk_ena    <= '0';
      dbg_pk_addr_s <= (others => '0');
      -- perf_index is an OUTPUT of nds_debug, so with the mailbox compiled out
      -- it has no driver at all. nvc will not complain and Quartus will infer
      -- something; drive it here for the same reason every signal above is
      -- driven here.
      dbg_perf_idx  <= (others => '0');
   end generate;

   -- Renderer pace counters, read back through mailbox op 0x0F. Tied to
   -- DEBUG_ENABLE because that is what compiles the mailbox in - counters with
   -- no way to read them would be pure area. Both engines' line_busy come from
   -- the two nds_gpu2d_fast instances below; a drawline landing on a busy
   -- engine is the drop condition tb_gpu2d_timed counts.
   iperf : entity work.nds_perf
   generic map ( ENABLE => DEBUG_ENABLE )
   port map
   (
      clk         => clk1x,
      reset       => reset,
      vblank      => gpu_vblank,
      drawline    => drawline,
      drawObj     => drawObj,
      line_busy_a => line_busy,
      line_busy_b => line_busy_b,
      index       => dbg_perf_idx,
      value       => dbg_perf_s
   );

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         ld_w7_done <= ld_wr_ena and ld_to_wram7;
      end if;
   end process;
   ld_wr_done <= ld_w7_done when ld_to_wram7 = '1' else mem9_done;

   -- ================= ARM9 CPU + membus =================
   -- The product uses redistributable melonDS FreeBIOS. It provides CpuSet,
   -- CpuFastSet, wait, decompression, and other direct-boot SWIs without
   -- Nintendo BIOS data. It is not a claim of full retail-BIOS equivalence.
   -- Quartus may infer block memory or logic for this registered constant ROM;
   -- the fit report, not the source form, is the resource authority.
   ibios9 : entity work.nds_nitro_freebios9
   port map
   (
      -- clk2x, NOT clk1x. The membus presents the accepted BIOS address and
      -- consumes the registered word on the following clk2x cycle. This keeps
      -- the same one-cycle read contract as the previous registered BIOS RAM.
      clk       => clk2x,
      brom_addr => brom_addr,
      brom_data => brom_data
   );

   icpu9 : entity work.nds_cpu9
   generic map ( is_simu => is_simu )
   port map
   (
      clk             => clk2x,
      ce              => '1',
      reset           => resetCpu,
-- synthesis translate_off
      cpu_export_done => dbg_export9_done,
      cpu_export      => dbg_export9,
-- synthesis translate_on
      error_cpu       => error_cpu9,
      dbg_pc          => pc9_s,
      dbg_r0          => cpu9_dbg_r0,
      dbg_lr          => cpu9_dbg_lr,
      dbg_cpsr        => cpu9_dbg_cpsr,
      dbg_regsel      => dbg_regsel_s,
      dbg_regval      => dbg_regval9,
      savestate_bus   => ss_bus9,
      ss_wired_out    => open,
      ss_wired_done   => open,
      gb_bus_Adr      => cpu9_adr,
      gb_bus_rnw      => cpu9_rnw,
      gb_bus_ena      => cpu9_ena,
      gb_bus_seq      => open,
      gb_bus_code     => cpu9_code,
      gb_bus_acc      => cpu9_acc,
      gb_bus_dout     => cpu9_dout,
      gb_bus_din      => cpu9_din,
      gb_bus_done     => cpu9_done,
      gb_bus_lock     => cpu9_lock,
      bus_lowbits     => cpu9_lowbits,
      dma_on          => dma_on,
      done            => cpu9_retire,
      CPU_bus_idle    => cpu9_bus_idle,
      PC_in_BIOS      => open,
      cpu_halt        => cpu9_halt,
      lastread        => cpu9_lastread,
      jump_out        => open,
      IRQ_in          => cpu9_irq,
      unhalt          => cpu9_unhalt or dbg_rel9 or diagnostic_release9,
      new_halt        => dbg_hold9 or diagnostic_hold9,
      cp15_vector_hi  => open,
      cp15_pu_enable  => open,
      cp15_icache_ena => open,
      cp15_dcache_ena => open,
      cp15_itcm_ena   => cp15_itcm_ena,
      cp15_itcm_load  => cp15_itcm_load,
      cp15_dtcm_ena   => cp15_dtcm_ena,
      cp15_dtcm_load  => cp15_dtcm_load,
      cp15_dtcm_base  => cp15_dtcm_base,
      cp15_dtcm_size  => cp15_dtcm_size,
      cp15_itcm_size  => cp15_itcm_size,
      bus_cacheable_i => bus_cacheable_i,
      bus_cacheable_d => bus_cacheable_d,
      cache_op_ena    => cache_op_ena,
      cache_op        => cache_op,
      cache_op_addr   => cache_op_addr,
      cache_op_busy   => cache_op_busy
   );

   imembus9 : entity work.nds_membus9
   generic map ( is_simu => is_simu )
   port map
   (
      clk => clk2x, reset => resetCpu,
      bus_cacheable_i => bus_cacheable_i, bus_cacheable_d => bus_cacheable_d,
      cache_op_ena => cache_op_ena, cache_op => cache_op,
      cache_op_addr => cache_op_addr, cache_op_busy => cache_op_busy,
      itcm_ena => cp15_itcm_ena, itcm_load => cp15_itcm_load, itcm_size => cp15_itcm_size,
      dtcm_ena => cp15_dtcm_ena, dtcm_load => cp15_dtcm_load,
      dtcm_base => cp15_dtcm_base, dtcm_size => cp15_dtcm_size,
      dma_bus => dma_bus_on,
      cpu_adr => mbus_adr, cpu_rnw => mbus_rnw, cpu_ena => mbus_ena, cpu_code => mbus_code,
      cpu_acc => mbus_acc, cpu_dout => mbus_dout, cpu_lowbits => mbus_low,
      -- cpu_done stays island-native: membus9 and icpu9 are both on clk2x, so the
      -- CPU's own handshake needs no crossing. The clk1x stretch below is only for
      -- nds_dma9, which lives outside the island.
      cpu_lastread => cpu9_lastread, cpu_din => cpu9_din, cpu_done => cpu9_done,
      itcm_addr => itcm_addr, itcm_we => itcm_we, itcm_be => itcm_be,
      itcm_writedata => itcm_writedata, itcm_readdata => itcm_readdata,
      dtcm_addr => dtcm_addr, dtcm_readdata => dtcm_readdata,
      dtcm_addr_b => dtcm_addr_b, dtcm_we_b => dtcm_we_b,
      dtcm_be_b => dtcm_be_b, dtcm_writedata_b => dtcm_writedata_b,
      brom_addr => brom_addr, brom_data => brom_data,
      wsh_ena => i9_wsh_ena, wsh_rnw => wsh9_rnw, wsh_addr => wsh9_addr, wsh_be => wsh9_be,
      wsh_din => wsh9_din, wsh_dout => wsh9_dout, wsh_done => i9_wsh_done, wsh_mapped => wsh9_mapped,
      vram_ena => i9_vram_ena, vram_rnw => vram9_rnw, vram_addr => vram9_addr, vram_be => vram9_be,
      vram_din => vram9_din, vram_dout => vram9_dout, vram_done => i9_vram_done,
      pal_we => i9_pal_we, pal_addr => pal_addr, pal_din => pal_din, pal_be => pal_be,
      oam_we => i9_oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => oam_be,
      mr_ena => i9_mr_ena, mr_rnw => mr9_rnw, mr_addr => mr9_addr, mr_be => mr9_be,
      mr_writedata => mr9_writedata, mr_done => i9_mr_done, mr_readdata => mr9_readdata,
      mr_pair => mr9_pair, mr_readdata_hi => mr9_readdata_hi,
      io_ce_next => '1',
      io_bus => i9_io_bus, io_wired_out => io_wired_out9, io_wired_done => i9_io_done,
      dbg_mb => dbg_mb9, dbg_cache => dbg_cache9
   );

   -- ARM9 bus mux: the DMA owns the membus while dma_bus_on (CPU paused
   -- via dma_on and drained via CPU_bus_idle before the grant)
   mbus_adr  <= dmab_adr  when dma_bus_on = '1' else cpu9_adr;
   mbus_rnw  <= dmab_rnw  when dma_bus_on = '1' else cpu9_rnw;
   mbus_ena  <= dmab_ena_i9 when dma_bus_on = '1' else cpu9_ena;
   mbus_code <= '0'       when dma_bus_on = '1' else cpu9_code;
   mbus_acc  <= dmab_acc  when dma_bus_on = '1' else cpu9_acc;
   mbus_dout <= dmab_dout when dma_bus_on = '1' else cpu9_dout;
   mbus_low  <= dmab_low  when dma_bus_on = '1' else cpu9_lowbits;

   idma9 : entity work.nds_dma9
   port map
   (
      clk          => clk1x,
      reset        => resetCpu,
      gb_bus       => io_bus9,
      wired_out    => dma_wired_out,
      wired_done   => dma_wired_done,
      trig_vblank  => gpu_vblank,
      -- melonDS/DS ordering at HBlank is PreDraw -> DrawScanline -> HDMA.
      -- The GPU-facing hblank_trigger intentionally lands before drawline so
      -- merge state can latch, but feeding that early pulse to DMA lets an
      -- unusually fast transfer change BGxHOFS before the renderer snapshots
      -- the completed line.  The raw drawline pulse is the same visible-line
      -- cadence and is sampled by the renderer and DMA on one edge; the
      -- renderer therefore sees the pre-HDMA registers, and DMA updates the
      -- following scanline.
      trig_hblank  => drawline,
      trig_card    => dma9_card_trig,
      gx_supported => h3d_service_ready,
      trig_gx      => gx_trig,
      gx_write_ready => dma_gx_write_ready,
      gx_write_valid => dma_gx_write_valid,
      cpu_bus_idle => cpu9_bus_idle,
      dma_on       => dma_on,
      dma_bus_on   => dma_bus_on,
      dbg_active_channel => dma9_dbg_active_channel,
      dbg_active_timing => dma9_dbg_active_timing,
      dbg_pending => dma9_dbg_pending,
      dbg_state => dma9_dbg_state,
      mb_ena       => dmab_ena,
      mb_rnw       => dmab_rnw,
      mb_adr       => dmab_adr,
      mb_acc       => dmab_acc,
      mb_lowbits   => dmab_low,
      mb_dout      => dmab_dout,
      mb_din       => cpu9_din,
      -- nds_dma9 is outside the island (clk1x), so it needs the stretched form of
      -- membus9's one-island-cycle done, not the raw signal.
      mb_done      => cpu9_done_1x,
      -- clk1x fast lane: io_wired_out9 is the clk1x wired-OR the peripherals
      -- already drive, so the DMA reads it in the cycle it presents the address
      io_fast_ena  => dma_io_ena,
      io_fast_rnw  => dma_io_rnw,
      io_fast_adr  => dma_io_adr,
      io_fast_acc  => dma_io_acc,
      io_fast_be   => dma_io_be,
      io_fast_dout => dma_io_dout,
      io_fast_din  => io_wired_out9,
      -- clk1x fast lane into nds_vram, muxed onto its cpu9 port below
      vram_fast_ena  => dma_vr_ena,
      vram_fast_rnw  => dma_vr_rnw,
      vram_fast_addr => dma_vr_addr,
      vram_fast_be   => dma_vr_be,
      vram_fast_din  => dma_vr_din,
      vram_fast_dout => vram9_dout,
      vram_fast_done => vram9_done,
      vram_fast_wpost => dma_vr_wpost,
      vram_fast_welig => vr9_welig,
      vram_fast_wok   => dma_vr_wok_safe,
      vram_write_valid => dma_vram_write_valid,
      irq_dma      => irq_dma9
   );

   -- TCM stores: M10K. The membus presents address/write combinationally in
   -- the accept cycle; the BRAM registers the address, so read data is valid
   -- in the FINISH cycle - same bus timing as the old asynchronous arrays.
   iitcm : entity MEM.SyncRamDualByteEnable
   generic map
   (
      is_simu     => is_simu,
      is_cyclone5 => '1',
      BYTE_WIDTH  => 8,
      ADDR_WIDTH  => 13,
      BYTES       => 4
   )
   port map
   (
      clk       => clk2x,
      ce_a      => '1',
      addr_a    => to_integer(itcm_addr),
      datain_a0 => itcm_writedata( 7 downto  0),
      datain_a1 => itcm_writedata(15 downto  8),
      datain_a2 => itcm_writedata(23 downto 16),
      datain_a3 => itcm_writedata(31 downto 24),
      dataout_a => itcm_readdata,
      we_a      => itcm_we,
      be_a      => itcm_be,
      ce_b      => '0',
      addr_b    => 0,
      datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
      dataout_b => open,
      we_b      => '0',
      be_b      => "0000"
   );

   idtcm : entity MEM.SyncRamDualByteEnable
   generic map
   (
      is_simu     => is_simu,
      is_cyclone5 => '1',
      BYTE_WIDTH  => 8,
      ADDR_WIDTH  => 12,
      BYTES       => 4
   )
   port map
   (
      clk       => clk2x,
      -- Port A: READ ONLY. The write moved to port B so its enable comes off a
      -- flop instead of off the CPU's address - see the "DTCM deferred store"
      -- comment in nds_membus9. Tying the port-A write inputs off (rather than
      -- leaving them driven with we_a = '0') is what lets Quartus prune the
      -- shifter -> datain_a cone, which is half the point of the change.
      ce_a      => '1',
      addr_a    => to_integer(dtcm_addr),
      datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
      dataout_a => dtcm_readdata,
      we_a      => '0',
      be_a      => "0000",
      -- Port B: the deferred store, one cycle behind the accept.
      ce_b      => '1',
      addr_b    => to_integer(dtcm_addr_b),
      datain_b0 => dtcm_writedata_b( 7 downto  0),
      datain_b1 => dtcm_writedata_b(15 downto  8),
      datain_b2 => dtcm_writedata_b(23 downto 16),
      datain_b3 => dtcm_writedata_b(31 downto 24),
      dataout_b => open,
      we_b      => dtcm_we_b,
      be_b      => dtcm_be_b
   );

   -- ================= ARM7 CPU + membus =================
   icpu7 : entity work.gba_cpu
   generic map ( is_simu => is_simu )
   port map
   (
      clk             => clk1x,
      ce              => '1',
      reset           => resetCpu,
-- synthesis translate_off
      cpu_export_done => dbg_export7_done,
      cpu_export      => dbg_export7,
-- synthesis translate_on
      error_cpu       => error_cpu7,
      dbg_pc          => pc7_s,
      dbg_regsel      => dbg_regsel_s,
      dbg_regval      => dbg_regval7,
      savestate_bus   => ss_bus7,
      ss_wired_out    => open,
      ss_wired_done   => open,
      gb_bus_Adr      => cpu7_adr,
      gb_bus_rnw      => cpu7_rnw,
      gb_bus_ena      => cpu7_ena,
      gb_bus_seq      => open,
      gb_bus_code     => open,
      gb_bus_acc      => cpu7_acc,
      gb_bus_dout     => cpu7_dout,
      gb_bus_din      => cpu7_din,
      gb_bus_done     => cpu7_done,
      gb_bus_lock     => cpu7_lock,
      bus_lowbits     => cpu7_lowbits,
      dma_on          => cpu7_pause,
      done            => open,
      CPU_bus_idle    => cpu7_bus_idle,
      PC_in_BIOS      => open,
      cpu_halt        => open,
      lastread        => cpu7_lastread,
      jump_out        => open,
      IRQ_in          => cpu7_irq,
      unhalt          => cpu7_unhalt or dbg_rel7 or diagnostic_release7,
      new_halt        => cpu7_newhalt or dbg_hold7 or diagnostic_hold7
   );

   ibios7 : entity work.nds_nitro_freebios7
   port map
   (
      clk       => clk1x,
      bios_addr => bios_addr,
      bios_data => bios7_data
   );

   -- ARM7 bus mux: the DMA owns the membus while dma7_bus_on (CPU paused
   -- via cpu7_pause and drained via cpu7_bus_idle before the grant); the
   -- sound fetch unit is a second, lower-priority guest - it pauses the
   -- CPU the same way (snd_bus_req -> cpu7_pause) but only gets the bus
   -- when DMA7 neither holds nor wants it, and DMA7's grant is held off
   -- while a sound word is in flight (dma7_idle_ok)
   cpu7_pause   <= dma7_on or snd_bus_req;
   dma7_idle_ok <= cpu7_bus_idle and not snd_bus_own;
   snd_bus_ok   <= cpu7_bus_idle and not dma7_on and not dma7_bus_on;

   mbus7_adr  <= dmab7_adr  when dma7_bus_on = '1' else
                 sndb7_adr  when snd_bus_own = '1' else cpu7_adr;
   mbus7_rnw  <= dmab7_rnw  when dma7_bus_on = '1' else
                 '1'        when snd_bus_own = '1' else cpu7_rnw;
   mbus7_ena  <= dmab7_ena  when dma7_bus_on = '1' else
                 sndb7_ena  when snd_bus_own = '1' else cpu7_ena;
   mbus7_acc  <= dmab7_acc  when dma7_bus_on = '1' else
                 ACCESS_32BIT when snd_bus_own = '1' else cpu7_acc;
   mbus7_dout <= dmab7_dout when dma7_bus_on = '1' else
                 (others => '0') when snd_bus_own = '1' else cpu7_dout;
   mbus7_low  <= dmab7_low  when dma7_bus_on = '1' else
                 "00"       when snd_bus_own = '1' else cpu7_lowbits;

   idma7 : entity work.nds_dma7
   port map
   (
      clk          => clk1x,
      reset        => resetCpu,
      gb_bus       => io_bus7,
      wired_out    => dma7_wired_out,
      wired_done   => dma7_wired_done,
      trig_vblank  => gpu_vblank,
      trig_card    => dma7_card_trig,
      cpu_bus_idle => dma7_idle_ok,
      dma_on       => dma7_on,
      dma_bus_on   => dma7_bus_on,
      mb_ena       => dmab7_ena,
      mb_rnw       => dmab7_rnw,
      mb_adr       => dmab7_adr,
      mb_acc       => dmab7_acc,
      mb_lowbits   => dmab7_low,
      mb_dout      => dmab7_dout,
      mb_din       => cpu7_din,
      mb_done      => cpu7_done,
      irq_dma      => irq_dma7
   );

   imembus7 : entity work.nds_membus7
   port map
   (
      clk => clk1x, reset => resetCpu,
      cpu_adr => mbus7_adr, cpu_rnw => mbus7_rnw, cpu_ena => mbus7_ena, cpu_acc => mbus7_acc,
      cpu_dout => mbus7_dout, cpu_lowbits => mbus7_low, cpu_lastread => cpu7_lastread,
      cpu_din => cpu7_din, cpu_done => cpu7_done,
      bios_addr => bios_addr, bios_data => bios7_data,
      w7p_addr => w7p_addr, w7p_we => w7p_we, w7p_be => w7p_be,
      w7p_writedata => w7p_writedata, w7p_readdata => w7p_readdata,
      wsh_ena => wsh7_ena, wsh_rnw => wsh7_rnw, wsh_addr => wsh7_addr, wsh_be => wsh7_be,
      wsh_din => wsh7_din, wsh_dout => wsh7_dout, wsh_done => wsh7_done, wsh_mapped => wsh7_mapped,
      vram_ena => vram7_ena, vram_rnw => vram7_rnw, vram_addr => vram7_addr, vram_be => vram7_be,
      vram_din => vram7_din, vram_dout => vram7_dout, vram_done => vram7_done,
      mr_ena => mr7_ena, mr_rnw => mr7_rnw, mr_addr => mr7_addr, mr_be => mr7_be,
      mr_writedata => mr7_writedata, mr_done => mr7_done, mr_readdata => mr7_readdata,
      io_ce_next => '1',
      io_bus => io_bus7, io_wired_out => io_wired_out7, io_wired_done => io_wired_done7
   );

   -- ARM7-private WRAM store (loader can preload it; CPUs are in reset then)
   w7m_we        <= (ld_wr_ena and ld_to_wram7) when ld_busy = '1' else w7p_we;
   w7m_addr      <= unsigned(ld_wr_addr(15 downto 2)) when ld_busy = '1' else w7p_addr;
   w7m_be        <= "1111"                     when ld_busy = '1' else w7p_be;
   w7m_writedata <= ld_wr_data                 when ld_busy = '1' else w7p_writedata;

   -- M10K store: write capture at the w7m_we edge is identical to the old
   -- clocked array write; the read side registers the (combinational) membus
   -- address, so read data lands in the FINISH cycle as before.
   iwram7 : entity MEM.SyncRamDualByteEnable
   generic map
   (
      is_simu     => is_simu,
      is_cyclone5 => '1',
      BYTE_WIDTH  => 8,
      ADDR_WIDTH  => 14,
      BYTES       => 4
   )
   port map
   (
      clk       => clk1x,
      ce_a      => '1',
      addr_a    => to_integer(w7m_addr),
      datain_a0 => w7m_writedata( 7 downto  0),
      datain_a1 => w7m_writedata(15 downto  8),
      datain_a2 => w7m_writedata(23 downto 16),
      datain_a3 => w7m_writedata(31 downto 24),
      dataout_a => w7p_readdata,
      we_a      => w7m_we,
      be_a      => w7m_be,
      ce_b      => '0',
      addr_b    => 0,
      datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
      dataout_b => open,
      we_b      => '0',
      be_b      => "0000"
   );

   -- ================= IO register banks =================
   io_wired_out9  <= irq_wired_out9 or timer_wired_out9 or ipc_wired_out9 or sys_wired_out9 or
                     tim_wired_out9 or g2d_wired_out or g2db_wired_out or dma_wired_out or
                     key_wired_out9 or card_wired_out9 or math_read_data or gx_wired_out_eff;
   io_wired_done9 <= irq_wired_done9 or timer_wired_done9 or ipc_wired_done9 or sys_wired_done9 or
                     tim_wired_done9 or g2d_wired_done or g2db_wired_done or dma_wired_done or
                     key_wired_done9 or card_wired_done9 or math_selected or gx_wired_done_eff;
   io_wired_out7  <= irq_wired_out7 or timer_wired_out7 or ipc_wired_out7 or sys_wired_out7 or
                     tim_wired_out7 or key_wired_out7 or spi_wired_out7 or card_wired_out7 or
                     rtc_wired_out7 or snd_wired_out7 or dma7_wired_out;
   io_wired_done7 <= irq_wired_done7 or timer_wired_done7 or ipc_wired_done7 or sys_wired_done7 or
                     tim_wired_done7 or key_wired_done7 or spi_wired_done7 or card_wired_done7 or
                     rtc_wired_done7 or snd_wired_done7 or dma7_wired_done;

   irq_in9 <= (0 => irq9_vblank, 1 => irq9_hblank, 2 => irq9_vcount,
               3 => irp_timer9(0), 4 => irp_timer9(1), 5 => irp_timer9(2), 6 => irp_timer9(3),
               8 => irq_dma9(0), 9 => irq_dma9(1), 10 => irq_dma9(2), 11 => irq_dma9(3),
               16 => ipc9_irq_sync, 17 => ipc9_irq_sendempty, 18 => ipc9_irq_recv,
               19 => irq9_card,
               21 => gx_irq_eff,
               others => '0');
   irq_in7 <= (0 => irq7_vblank, 1 => irq7_hblank, 2 => irq7_vcount,
               3 => irp_timer7(0), 4 => irp_timer7(1), 5 => irp_timer7(2), 6 => irp_timer7(3),
               8 => irq_dma7(0), 9 => irq_dma7(1), 10 => irq_dma7(2), 11 => irq_dma7(3),
               16 => ipc7_irq_sync, 17 => ipc7_irq_sendempty, 18 => ipc7_irq_recv,
               19 => irq7_card, 23 => irq7_spi,
               others => '0');

   irq9_any <= '1' when irq_in9 /= x"00000000" else '0';
   dbg_r0_9   <= cpu9_dbg_r0;
   dbg_lr9    <= cpu9_dbg_lr;
   dbg_cpsr9  <= cpu9_dbg_cpsr;

   -- KEYINPUT (0x130, both CPUs) + EXTKEYIN (0x136, ARM7): wired directly
   -- until a keypad module (KEYCNT/key IRQ) exists; active low, released = 1
   keyinput <= not (KeyL & KeyR & KeyDown & KeyUp & KeyLeft & KeyRight &
                    KeyStart & KeySelect & KeyB & KeyA);
   extkeyin <= lid_closed & (not touch_active) & "11" & "11" & (not KeyY) & (not KeyX);

   key_wired_out9  <= x"0000" & "000000" & keyinput when (io_bus9.Adr = x"0000130") else (others => '0');
   key_wired_done9 <= '1' when (io_bus9.Adr = x"0000130") else '0';
   key_wired_out7  <= x"0000" & "000000" & keyinput when (io_bus7.Adr = x"0000130") else
                      x"00" & extkeyin & x"0000"    when (io_bus7.Adr = x"0000134") else
                      (others => '0');
   key_wired_done7 <= '1' when (io_bus7.Adr = x"0000130" or io_bus7.Adr = x"0000134") else '0';

   iirq9 : entity work.nds_irq
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      gb_bus => io_bus9, wired_out => irq_wired_out9, wired_done => irq_wired_done9,
      irq_in => irq_in9, cpu_irq => cpu9_irq, cpu_unhalt => cpu9_unhalt,
      dbg_ime => irq9_dbg_ime, dbg_ie => irq9_dbg_ie, dbg_if => irq9_dbg_if
   );

   iirq7 : entity work.nds_irq
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      gb_bus => io_bus7, wired_out => irq_wired_out7, wired_done => irq_wired_done7,
      irq_in => irq_in7, cpu_irq => cpu7_irq, cpu_unhalt => cpu7_unhalt,
      dbg_ime => irq7_dbg_ime, dbg_ie => irq7_dbg_ie, dbg_if => irq7_dbg_if
   );

   -- Minimal coherent GXSTAT owner for the hybrid renderer.  It is removed
   -- from the visible wired-OR while the HPS service is unavailable, restoring
   -- the exact pre-3D open-IO behavior at 0x04000600 and suppressing timing-7
   -- DMA startup.  IRQ mode is reset with the CPUs between sessions.
   ih3d_gx : entity work.nds_h3d_gx_status
   port map
   (
      clk => clk1x,
      reset => resetCpu,
      service_ready => h3d_service_ready,
      fifo_level => h3d_gx_fifo_level,
      gb_bus => io_bus9,
      wired_out => gx_wired_out,
      wired_done => gx_wired_done,
      trig_gx => gx_trig,
      irq_gxfifo => gx_irq
   );
   gx_wired_out_eff <= gx_wired_out when h3d_service_ready = '1' else
                       (others => '0');
   gx_wired_done_eff <= gx_wired_done and h3d_service_ready;
   gx_irq_eff <= gx_irq and h3d_service_ready;

   -- First playable island deliberately has no wall-clock service.  Keep the
   -- donor nds_rtc entity in the analyzed closure for provenance, but remove it
   -- from the product cone.  The serial RTC register still decodes and reads
   -- zero so ARM7 firmware cannot fall through to an unrelated IO responder.
   rtc_wired_out7  <= (others => '0');
   rtc_wired_done7 <= '1' when io_bus7.Adr = x"0000138" else '0';

   gsound : if SOUND_ENABLE /= 0 generate
      isound : entity work.nds_sound
      generic map ( is_simu => is_simu )
      port map
      (
         clk => clk1x, ce => '1', reset => resetCpu,
         bus7 => io_bus7, wired_out7 => snd_wired_out7, wired_done7 => snd_wired_done7,
         snd_bus_req => snd_bus_req,
         snd_bus_ok  => snd_bus_ok,
         snd_bus_own => snd_bus_own,
         mb_ena      => sndb7_ena,
         mb_adr      => sndb7_adr,
         mb_din      => cpu7_din,
         mb_done     => cpu7_done,
         sample_l     => sound_out_left,
         sample_r     => sound_out_right,
         sample_valid => open,
         snd_enable => open, snd_active => open
      );
   end generate;

   -- SOUND_ENABLE = 0: the stub is NOT optional decoration. wired_done7 on this
   -- bus is a combinational ADDRESS CLAIM, not a handshake - key_wired_done7 two
   -- screens up is literally `'1' when Adr = ...` - and io_wired_done7 is the OR
   -- of every peripheral's claim. With nothing claiming 0x400-0x5FF the ARM7's
   -- first sound-register access would never complete and the CPU would hang
   -- forever, which would look like a boot bug rather than a missing peripheral.
   -- So claim exactly the range nds_sound claims and read back zero.
   gnosound : if SOUND_ENABLE = 0 generate
      snd_wired_done7 <= '1' when (io_bus7.Adr(27 downto 9) = "0000000000000000010") else '0';
      snd_wired_out7  <= (others => '0');
      -- never ask for the ARM7 membus, so cpu7_pause/dma7_idle_ok are unaffected
      snd_bus_req     <= '0';
      snd_bus_own     <= '0';
      sndb7_ena       <= '0';
      sndb7_adr       <= (others => '0');
      sound_out_left  <= (others => '0');
      sound_out_right <= (others => '0');
   end generate;

   -- Product-local derivative: adds the firmware write-back path the donor
   -- lacks (its image is a read-only fixture). See rtl/nds_nitro_spi.vhd.
   ispi : entity work.nds_nitro_spi
   port map
   (
      clk => clk1x, reset => resetCpu,
      bus7 => io_bus7, wired_out7 => spi_wired_out7, wired_done7 => spi_wired_done7,
      irq_spi => irq7_spi,
      touch_active => touch_active, touch_x => touch_x, touch_y => touch_y,
      fw_addr => fw_addr, fw_req => fw_req, fw_done => fw_done, fw_data => fw_data,
      fw_wr => fw_wr, fw_wlane => fw_wlane, fw_wdata => fw_wdata
   );

   itimer9 : entity work.gba_timer
   generic map ( is_simu => '0' )
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      savestate_bus => ss_bus9, ss_wired_out => open, ss_wired_done => open,
      loading_savestate => '0',
      gb_bus => io_bus9, wired_out => timer_wired_out9, wired_done => timer_wired_done9,
      IRP_Timer => irp_timer9,
      timer0_tick => open, timer1_tick => open,
      debugout0 => open, debugout1 => open, debugout2 => open, debugout3 => open
   );

   itimer7 : entity work.gba_timer
   generic map ( is_simu => '0' )
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      savestate_bus => ss_bus7, ss_wired_out => open, ss_wired_done => open,
      loading_savestate => '0',
      gb_bus => io_bus7, wired_out => timer_wired_out7, wired_done => timer_wired_done7,
      IRP_Timer => irp_timer7,
      timer0_tick => open, timer1_tick => open,
      debugout0 => open, debugout1 => open, debugout2 => open, debugout3 => open
   );

   iipc : entity work.nds_ipc
   port map
   (
      clk => clk1x, reset => resetCpu,
      bus7 => io_bus7, wired_out7 => ipc_wired_out7, wired_done7 => ipc_wired_done7,
      irq7_sync => ipc7_irq_sync, irq7_sendempty => ipc7_irq_sendempty, irq7_recv => ipc7_irq_recv,
      bus9 => io_bus9, wired_out9 => ipc_wired_out9, wired_done9 => ipc_wired_done9,
      irq9_sync => ipc9_irq_sync, irq9_sendempty => ipc9_irq_sendempty, irq9_recv => ipc9_irq_recv,
      dbg_ipc => dbg_ipc_s
   );

   isyscnt : entity work.nds_syscnt
   port map
   (
      clk => clk1x, reset => resetCpu,
      bus9 => io_bus9, wired_out9 => sys_wired_out9, wired_done9 => sys_wired_done9,
      bus7 => io_bus7, wired_out7 => sys_wired_out7, wired_done7 => sys_wired_done7,
      preset_direct => preset_direct,
      wramcnt => wramcnt, vramcnt => vramcnt,
      pow_2da => pow_2da, pow_2db => pow_2db, pow_swap => pow_swap,
      exmem_gba7 => open, exmem_card7 => exmem_card7_s, exmem_prio7 => exmem_prio7,
      halt7 => cpu7_newhalt
   );

   -- ================= shared memory fabric =================
   iwram : entity work.nds_wram
   generic map ( is_simu => is_simu )
   port map
   (
      clk => clk1x, wramcnt => wramcnt,
      arm9_ena => wsh9_ena, arm9_rnw => wsh9_rnw, arm9_addr => wsh9_addr, arm9_be => wsh9_be,
      arm9_din => wsh9_din, arm9_dout => wsh9_dout, arm9_done => wsh9_done, arm9_mapped => wsh9_mapped,
      arm7_ena => wsh7_ena, arm7_rnw => wsh7_rnw, arm7_addr => wsh7_addr, arm7_be => wsh7_be,
      arm7_din => wsh7_din, arm7_dout => wsh7_dout, arm7_done => wsh7_done, arm7_mapped => wsh7_mapped
   );

   imainram : entity work.nds_mainram
   generic map ( Softmap_NDS_MAINRAM_ADDR => Softmap_NDS_MAINRAM_ADDR )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => reset_boot,
      arm7_priority => exmem_prio7,
      mem9_ena => mem9_ena,
      mem9_lock => mr9_lock and not dma_bus_on and not ld_busy,
      mem9_rnw => mem9_rnw, mem9_addr => mem9_addr, mem9_be => mem9_be,
      mem9_writedata => mem9_writedata, mem9_done => mem9_done, mem9_readdata => mem9_readdata,
      mem7_ena => mr7_ena,
      mem7_lock => cpu7_lock and not dma7_bus_on and not snd_bus_own,
      mem7_rnw => mr7_rnw, mem7_addr => mr7_addr, mem7_be => mr7_be,
      mem7_writedata => mr7_writedata, mem7_done => mr7_done, mem7_readdata => mr7_readdata,
      mainram_allow => mainram_allow, mainram_active => mainram_active, mainram_busy => mainram_busy,
      mr_sdram_ena => sdram_ena, mr_sdram_rnw => sdram_rnw, mr_sdram_Adr => sdram_Adr,
      mr_sdram_Din => sdram_Din, mr_sdram_be => sdram_be,
      sdram_Dout => sdram_Dout, sdram_done32 => sdram_done32,
      sdram_Dout_hi => sdram_Dout_hi, sdram_done64 => sdram_done64,
      mem9_pair => mem9_pair_s, mem9_readdata_hi => mem9_readdata_hi_s,
      dbg_mr => dbg_mr_s
   );

   -- ARM9 VRAM mux, same shape and the same safety argument as the io_bus9 one:
   -- while dma_bus_on is held the island has no transaction in flight (the grant
   -- waited for CPU_bus_idle, which only returns on gb_bus_done), so vram9_ena
   -- cannot pulse - it comes from cdc_req_vram toggles that a paused CPU never
   -- makes. That also satisfies nds_vram's "cpu9 request overrun" assert: only
   -- one of the two sides can ever have an op outstanding.
   vr9_src_ena <= dma_vr_ena when dma_bus_on = '1' else vram9_ena;
   -- Reads and FPGA-only BG/OBJ writes retain the legacy request pulse. LCDC
   -- texture uploads are presented when their H3D event is accepted.
   vr9_ena  <= vr9_src_ena
      when (vr9_rnw = '1' or h3d_service_ready = '0' or
            h3d_vram9_needed_by_h3d = '0') else
      h3d_vram9_issue;
   vr9_rnw  <= dma_vr_rnw  when dma_bus_on = '1' else vram9_rnw;
   -- When H3D backpressures a write, the event gate owns an atomic copy of
   -- its complete payload. Feed that same accepted payload to local VRAM so
   -- the FPGA and melonDS observe one identical architectural write even if
   -- the shared source bus has already moved on.
   vr9_addr <= unsigned(h3d_vram9_write_address(23 downto 2))
      when (h3d_service_ready = '1' and h3d_vram9_issue = '1') else
      dma_vr_addr when dma_bus_on = '1' else vram9_addr;
   vr9_be <= h3d_vram9_write_byte_enable
      when (h3d_service_ready = '1' and h3d_vram9_issue = '1') else
      dma_vr_be when dma_bus_on = '1' else vram9_be;
   vr9_din <= h3d_vram9_write_data
      when (h3d_service_ready = '1' and h3d_vram9_issue = '1') else
      dma_vr_din when dma_bus_on = '1' else vram9_din;
   vr7_addr <= unsigned(h3d_vram7_write_address(23 downto 2))
      when (h3d_service_ready = '1' and vram7_rnw = '0') else vram7_addr;
   vr7_be <= h3d_vram7_write_byte_enable
      when (h3d_service_ready = '1' and vram7_rnw = '0') else vram7_be;
   vr7_din <= h3d_vram7_write_data
      when (h3d_service_ready = '1' and vram7_rnw = '0') else vram7_din;
   vr9_wpost <= dma_vr_wpost and dma_bus_on;
   dma_vr_wok_safe <= vr9_wok
      when (h3d_service_ready = '0' or h3d_vram9_needed_by_h3d = '0') else
                       vr9_wok and h3d_vram9_source_ready;
   -- Macro-off is byte-for-byte legacy acceptance: an immediate DMA to the
   -- GXFIFO aperture still retires even though timing-7 startup is disabled.
   dma_gx_write_ready <= (not h3d_service_ready) or h3d_gpu_source_ready;

   -- ================= VRAM + engine A render path =================
   ivram : entity work.nds_vram
   -- POSTED_WRITES is what buys NITRO [04-02]'s 2-cycle DMA cadence, and it is
   -- ~10 LABs this image does not currently have. See the generic's own comment
   -- in nds_vram; set it false to get the fitting configuration back at the cost
   -- of that test.
   generic map ( is_simu => is_simu, POSTED_WRITES => true )
   port map
   (
      clk => clk1x, reset => reset_boot, vramcnt => vramcnt,
      cpu9_ena => vr9_ena, cpu9_rnw => vr9_rnw, cpu9_addr => vr9_addr,
      cpu9_be => vr9_be, cpu9_din => vr9_din, cpu9_dout => vram9_dout, cpu9_done => vram9_done,
      cpu9_wpost => vr9_wpost, cpu9_welig => vr9_welig, cpu9_wok => vr9_wok,
      cpu7_ena => vr7_ena, cpu7_rnw => vram7_rnw, cpu7_addr => vr7_addr,
      cpu7_be => vr7_be, cpu7_din => vr7_din, cpu7_dout => vram7_dout, cpu7_done => vram7_done,
      srv_req => vsrv_req, srv_rnw => vsrv_rnw, srv_bank => vsrv_bank, srv_addr => vsrv_addr,
      srv_be => vsrv_be, srv_din => vsrv_din, srv_dout => vsrv_dout, srv_done => vsrv_done,
      rdr_bg_req => r_bg_req, rdr_bg_addr => r_bg_addr,
      rdr_bg_dout => r_bg_dout, rdr_bg_done => r_bg_done,
      rdr_bg_accept => r_bg_accept,
      rdr_obj_req => r_obj_req, rdr_obj_addr => r_obj_addr,
      rdr_obj_dout => r_obj_dout, rdr_obj_done => r_obj_done,
      rdr_obj_accept => r_obj_accept,
      rdr_bgep_req => r_bgep_req, rdr_bgep_addr => r_bgep_addr,
      rdr_bgep_dout => r_bgep_dout, rdr_bgep_done => r_bgep_done,
      rdr_objep_req => r_objep_req, rdr_objep_addr => r_objep_addr,
      rdr_objep_dout => r_objep_dout, rdr_objep_done => r_objep_done,
      rdr_bgb_req => rb_bg_req, rdr_bgb_addr => rb_bg_addr,
      rdr_bgb_dout => rb_bg_dout, rdr_bgb_done => rb_bg_done,
      rdr_bgb_accept => rb_bg_accept,
      rdr_objb_req => rb_obj_req, rdr_objb_addr => rb_obj_addr,
      rdr_objb_dout => rb_obj_dout, rdr_objb_done => rb_obj_done,
      rdr_objb_accept => rb_obj_accept,
      rdr_bgepb_req => rb_bgep_req, rdr_bgepb_addr => rb_bgep_addr,
      rdr_bgepb_dout => rb_bgep_dout, rdr_bgepb_done => rb_bgep_done,
      rdr_objepb_req => rb_objep_req, rdr_objepb_addr => rb_objep_addr,
      rdr_objepb_dout => rb_objep_dout, rdr_objepb_done => rb_objep_done,
      clr_busy => vclr_busy,
      rsrv_req => vrsrv_req, rsrv_bank => vrsrv_bank, rsrv_addr => vrsrv_addr,
      rsrv_dout => vrsrv_dout, rsrv_done => vrsrv_done,
      rsrv_ready => vrsrv_ready
      ,
      dbg_rbusy => dbg_rbusy_s
   );

   -- Dot pace is 1-of-1: one dot per clk1x, the real frame rate. The divider
   -- that used to sit here (and the OSD item that switched it) is gone - see
   -- the header. A line is 2,130 clk1x cycles and the renderer fits it.
   itiming : entity work.nds_gpu_timing
   port map
   (
      clk             => clk1x,
      -- Preserve the beta93 real-time raster. Frame-event pressure describes
      -- HPS input admission, not completion of a visible 3D plane; using it
      -- as a clock-enable made beta95/beta96 hide 3D for seconds.
      ce              => '1',
      reset           => resetCpu,
      gb_bus9         => io_bus9,
      wired_out9      => tim_wired_out9,
      wired_done9     => tim_wired_done9,
      gb_bus7         => io_bus7,
      wired_out7      => tim_wired_out7,
      wired_done7     => tim_wired_done7,
      irq9_vblank     => irq9_vblank,
      irq9_hblank     => irq9_hblank,
      irq9_vcount     => irq9_vcount,
      irq7_vblank     => irq7_vblank,
      irq7_hblank     => irq7_hblank,
      irq7_vcount     => irq7_vcount,
      linecounter     => linecounter,
      drawline        => drawline,
      linecounter_obj => linecounter_obj,
      drawObj         => drawObj,
      line_trigger    => line_trigger,
      hblank_trigger  => hblank_trigger,
      lcd_phase       => lcd_phase,
      vblank_trigger  => gpu_vblank,
      refpoint_update => refpoint_update,
      vcount_out      => vcount_out,
      dbg_vbl_ena9    => dbg_vbl_ena9
   );

   r_bg_addr    <= to_unsigned(g_bg_addr, 17);
   r_obj_addr   <= to_unsigned(g_obj_addr, 16);
   r_bgep_addr  <= to_unsigned(g_bgep_addr, 13);
   r_objep_addr <= to_unsigned(g_objep_addr, 11);

   -- Shipping uses GPU_FAST=0.  Instantiate the product-local renderer
   -- directly in that branch so its registered H3D seam stays in clk1x.  The
   -- superseded experimental fast branch is retained for diagnostic builds;
   -- it intentionally receives no H3D plane and exports an idle seam.
   g_gpu2d_a_slow : if GPU_FAST = 0 generate
   begin
      igpu2d_a : entity work.nds_gpu2d
      generic map ( is_simu => is_simu )
      port map
      (
         clk => clk1x, reset => resetCpu,
         gb_bus => io_bus9, wired_out => g2d_wired_out, wired_done => g2d_wired_done,
         linecounter => linecounter, drawline => drawline,
         linecounter_obj => linecounter_obj, drawObj => drawObj,
         line_trigger => line_trigger, hblank_trigger => hblank_trigger,
         vblank_trigger => gpu_vblank, refpoint_update => refpoint_update,
         line_busy => line_busy, epfill_busy => epfill_busy, clr_busy => pclr_busy_a,
         pal_we => pal_we_a, pal_addr => pal_addr_lo, pal_din => pal_din, pal_be => pal_be,
         oam_we => oam_we_a, oam_addr => oam_addr_lo, oam_din => oam_din, oam_be => oam_be,
         srv_bg_req => r_bg_req, srv_bg_addr => g_bg_addr,
         srv_bg_data => r_bg_dout, srv_bg_done => r_bg_done,
         srv_bg_accept => r_bg_accept,
         srv_obj_req => r_obj_req, srv_obj_addr => g_obj_addr,
         srv_obj_data => r_obj_dout, srv_obj_done => r_obj_done,
         srv_obj_accept => r_obj_accept,
         srv_bgep_req => r_bgep_req, srv_bgep_addr => g_bgep_addr,
         srv_bgep_data => r_bgep_dout, srv_bgep_done => r_bgep_done,
         srv_objep_req => r_objep_req, srv_objep_addr => g_objep_addr,
         srv_objep_data => r_objep_dout, srv_objep_done => r_objep_done,
         h3d_pixel_valid => h3d_pixel_valid,
         h3d_pixel_data => h3d_pixel_data,
         h3d_line_request => h3d_line_request,
         h3d_line_request_y => h3d_line_request_y,
         h3d_merge_line_start => h3d_merge_line_start,
         h3d_merge_line_end => h3d_merge_line_end,
         h3d_merge_pixel_x => h3d_merge_pixel_x,
         h3d_merge_pixel_y => h3d_merge_pixel_y,
         pixel_out_x => pxa_x, pixel_out_y => pxa_y,
         pixel_out_data => pxa_data, pixel_out_we => pxa_we,
         dbg_bg_busy => open, dbg_obj_busy => open,
         dbg_bgmode => open, dbg_fblank => open,
         dbg_bg1_scroll_triplet => bg1_scroll_renderer_diag
      );
   end generate;

   g_gpu2d_a_fast : if GPU_FAST /= 0 generate
   begin
      h3d_line_request <= '0';
      h3d_line_request_y <= 0;
      h3d_merge_line_start <= '0';
      h3d_merge_line_end <= '0';
      h3d_merge_pixel_x <= 0;
      h3d_merge_pixel_y <= 0;
      igpu2d_a : entity work.nds_gpu2d_fast
      generic map ( is_simu => is_simu, GPU_FAST => GPU_FAST, CLKMEM_RATIO => CLKMEM_RATIO )
      port map
      (
         clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => resetCpu,
         gb_bus => io_bus9, wired_out => g2d_wired_out, wired_done => g2d_wired_done,
         linecounter => linecounter, drawline => drawline,
         linecounter_obj => linecounter_obj, drawObj => drawObj,
         line_trigger => line_trigger, hblank_trigger => hblank_trigger,
         vblank_trigger => gpu_vblank, refpoint_update => refpoint_update,
         line_busy => line_busy, epfill_busy => epfill_busy, clr_busy => pclr_busy_a,
         pal_we => pal_we_a, pal_addr => pal_addr_lo, pal_din => pal_din, pal_be => pal_be,
         oam_we => oam_we_a, oam_addr => oam_addr_lo, oam_din => oam_din, oam_be => oam_be,
         srv_bg_req => r_bg_req, srv_bg_addr => g_bg_addr,
         srv_bg_data => r_bg_dout, srv_bg_done => r_bg_done,
         srv_bg_accept => r_bg_accept,
         srv_obj_req => r_obj_req, srv_obj_addr => g_obj_addr,
         srv_obj_data => r_obj_dout, srv_obj_done => r_obj_done,
         srv_obj_accept => r_obj_accept,
         srv_bgep_req => r_bgep_req, srv_bgep_addr => g_bgep_addr,
         srv_bgep_data => r_bgep_dout, srv_bgep_done => r_bgep_done,
         srv_objep_req => r_objep_req, srv_objep_addr => g_objep_addr,
         srv_objep_data => r_objep_dout, srv_objep_done => r_objep_done,
         pixel_out_x => pxa_x, pixel_out_y => pxa_y,
         pixel_out_data => pxa_data, pixel_out_we => pxa_we,
         dbg_bg1_scroll_triplet => bg1_scroll_renderer_diag
      );
   end generate;

   -- The previous product tap stopped at the CPU table and DMA source. Latch
   -- the renderer's exact line-30 acceptance/output receipt together with the
   -- geometry FIFO and DMA ownership on the same sample boundary. On a normal
   -- frame [14:6] remains the row fingerprint. On a frame with no BG1HOFS write
   -- since VBlank, replace the old scroll/fingerprint payload with the exact
   -- actual ARM9 membus owner rather than the CPU's next pending address:
   --   [23:21] membus FSM state, [20] accepted transaction active,
   --   [19:13] transaction age, [12] read/write,
   --   [11:0] accepted address offset.
   -- The preceding trace established that missed NSMB parallax updates are
   -- DMA1 HBlank transfers stuck in GRANT with CPU_bus_idle low. This identifies
   -- the real outstanding access, or proves the idle flag is stale, without
   -- changing bus arbitration or timing.
   p_bg1_line30_dma_receipt : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (resetCpu = '1') then
            bg1_scroll_sample_toggle_d <= '0';
            dbg_bg1_scroll_triplet <= (others => '0');
         elsif (bg1_scroll_renderer_diag(31 downto 28) = x"F" and
                bg1_scroll_renderer_diag(27) /= bg1_scroll_sample_toggle_d) then
            bg1_scroll_sample_toggle_d <= bg1_scroll_renderer_diag(27);
            if (bg1_scroll_renderer_diag(24) = '0') then
               dbg_bg1_scroll_triplet <=
                  bg1_scroll_renderer_diag(31 downto 24) &
                  dbg_mb9(2 downto 0) & cpu_access_active &
                  std_logic_vector(cpu_access_age) & cpu_access_rnw &
                  cpu_access_addr;
            else
               dbg_bg1_scroll_triplet <=
                  bg1_scroll_renderer_diag(31 downto 3) &
                  dma_on & dma_bus_on & gx_trig;
            end if;
         end if;
      end if;
   end process;

   -- ================= engine B =================
   -- register window 0x1000-0x106C: engine B sees the bus with bit 12
   -- stripped so the shared register map decodes; outside the window the
   -- address is forced unmatchable so its wired-or stays silent
   io_bus9b.Din  <= io_bus9.Din;
   io_bus9b.Adr  <= (io_bus9.Adr(27 downto 13) & '0' & io_bus9.Adr(11 downto 0))
                    when io_bus9.Adr(27 downto 12) = x"0001" else (others => '1');
   io_bus9b.rnw  <= io_bus9.rnw;
   io_bus9b.ena  <= io_bus9.ena;
   io_bus9b.acc  <= io_bus9.acc;
   io_bus9b.bEna <= io_bus9.bEna;
   io_bus9b.rst  <= io_bus9.rst;

   -- palette/OAM 2 KB mirrors: low half engine A, high half engine B;
   -- writes are dropped while the owning engine is powered off (melonDS)
   pal_we_a    <= pal_we when (pal_addr < 256 and pow_2da = '1') else '0';
   pal_we_b    <= pal_we when (pal_addr >= 256 and pow_2db = '1') else '0';
   pal_addr_lo <= pal_addr mod 256;
   oam_we_a    <= oam_we when (oam_addr < 256 and pow_2da = '1') else '0';
   oam_we_b    <= oam_we when (oam_addr >= 256 and pow_2db = '1') else '0';
   oam_addr_lo <= oam_addr mod 256;

   -- engine B flat spaces are 128 KB: wrap the drawer addresses
   rb_bg_addr    <= to_unsigned(gb_bg_addr mod 32768, 15);
   rb_obj_addr   <= to_unsigned(gb_obj_addr mod 32768, 15);
   rb_bgep_addr  <= to_unsigned(gb_bgep_addr, 13);
   rb_objep_addr <= to_unsigned(gb_objep_addr, 11);

   g_gpu2d_b : if GPU2D_B_ENABLE /= 0 generate
   begin
      igpu2d_b : entity work.nds_gpu2d_fast
      generic map ( is_engine_b => '1', is_simu => is_simu, GPU_FAST => GPU_FAST, CLKMEM_RATIO => CLKMEM_RATIO )
      port map
      (
         clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => resetCpu,
         gb_bus => io_bus9b, wired_out => g2db_wired_out, wired_done => g2db_wired_done,
         linecounter => linecounter, drawline => drawline,
         linecounter_obj => linecounter_obj, drawObj => drawObj,
         line_trigger => line_trigger, hblank_trigger => hblank_trigger,
         vblank_trigger => gpu_vblank, refpoint_update => refpoint_update,
         line_busy => line_busy_b, epfill_busy => epfill_busy_b, clr_busy => pclr_busy_b,
         pal_we => pal_we_b, pal_addr => pal_addr_lo, pal_din => pal_din, pal_be => pal_be,
         oam_we => oam_we_b, oam_addr => oam_addr_lo, oam_din => oam_din, oam_be => oam_be,
         srv_bg_req => rb_bg_req, srv_bg_addr => gb_bg_addr,
         srv_bg_data => rb_bg_dout, srv_bg_done => rb_bg_done,
         srv_bg_accept => rb_bg_accept,
         srv_obj_req => rb_obj_req, srv_obj_addr => gb_obj_addr,
         srv_obj_data => rb_obj_dout, srv_obj_done => rb_obj_done,
         srv_obj_accept => rb_obj_accept,
         srv_bgep_req => rb_bgep_req, srv_bgep_addr => gb_bgep_addr,
         srv_bgep_data => rb_bgep_dout, srv_bgep_done => rb_bgep_done,
         srv_objep_req => rb_objep_req, srv_objep_addr => gb_objep_addr,
         srv_objep_data => rb_objep_dout, srv_objep_done => rb_objep_done,
         pixel_out_x => pxb_x, pixel_out_y => pxb_y,
         pixel_out_data => pxb_data, pixel_out_we => pxb_we,
         dbg_bg1_scroll_triplet => open
      );
   end generate;

   -- One-engine diagnostic: remove the complete engine-B register/drawer/
   -- merge cone and its VRAM clients.  Mirroring A keeps both HDMI panels
   -- visibly useful without introducing a second video transport mode.
   g_no_gpu2d_b : if GPU2D_B_ENABLE = 0 generate
   begin
      g2db_wired_out <= (others => '0');
      g2db_wired_done <= '0';
      line_busy_b <= '0';
      epfill_busy_b <= '0';
      pclr_busy_b <= '0';
      rb_bg_req <= '0';
      rb_obj_req <= '0';
      rb_bgep_req <= '0';
      rb_objep_req <= '0';
      gb_bg_addr <= 0;
      gb_obj_addr <= 0;
      gb_bgep_addr <= 0;
      gb_objep_addr <= 0;
      pxb_x <= pxa_x;
      pxb_y <= pxa_y;
      pxb_data <= pxa_data;
      pxb_we <= pxa_we;
   end generate;

   -- POWCNT display routing: engine B disabled shows raw white (melonDS-
   -- documented hardware quirk: engine A keeps rendering with its bit off);
   -- swap ('1') puts engine A on the top screen
   pxb_data_eff <= pxb_data when pow_2db = '1' else (others => '1');

   pixel_out_x     <= pxa_x        when pow_swap = '1' else pxb_x;
   pixel_out_y     <= pxa_y        when pow_swap = '1' else pxb_y;
   pixel_out_data  <= pxa_data     when pow_swap = '1' else pxb_data_eff;
   pixel_out_we    <= pxa_we       when pow_swap = '1' else pxb_we;
   pixelb_out_x    <= pxb_x        when pow_swap = '1' else pxa_x;
   pixelb_out_y    <= pxb_y        when pow_swap = '1' else pxa_y;
   pixelb_out_data <= pxb_data_eff when pow_swap = '1' else pxa_data;
   pixelb_out_we   <= pxb_we       when pow_swap = '1' else pxa_we;

   vblank_out <= gpu_vblank;

   -- Per-engine drop exports. The combined `drawline and (busy_a or busy_b)`
   -- below is kept because callers use it as "a line was dropped at all", but on
   -- its own it cannot say WHICH engine was behind - and engine B runs the
   -- simpler configuration in Kirby's mode (no ext palettes), so attributing a
   -- combined +7 drops/frame to the wrong engine sizes the renderer work wrong.
   -- Debug-only signals: behaviourally inert.
   dbg_line_drop_a <= drawline and line_busy;
   dbg_line_drop_b <= drawline and line_busy_b;
   dbg_line_drop <= drawline and (line_busy or line_busy_b);
   dbg_line_busy <= line_busy or line_busy_b;
   dbg_cpu_err9  <= error_cpu9;
   dbg_cpu_err7  <= error_cpu7;
   dbg_hwstat    <= std_logic_vector(to_unsigned(t_boot'pos(boot_state), 4)) &
                    resetCpu & ld_busy & ld_done & ld_error &
                    error_cpu9 & error_cpu7 &
                    cpu9_ena & cpu9_done & cpu7_ena & cpu7_done &
                    gpu_vblank & line_busy & line_busy_b & preset_direct;


end architecture;
