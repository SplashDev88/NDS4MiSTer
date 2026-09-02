-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Clock-domain adapter that runs nds_gpu2d on clkMem (100.542 MHz) instead of
-- clk1x (33.514 MHz), giving the renderer 3x the cycles per scanline.
--
-- WHY, measured (2026-07-29, sim/tests/nds_2dk.hex, both engines, GPUCEDIV=1,
-- clean steady-state frames):
--
--   cycles per RENDERED line   5829   line budget at clk1x   2130   -> 2.74x over
--   of which any_bg_busy       5563   (95%)
--   of which obj_busy          1051   (overlapping)
--   VRAM-blocked                 9%   renderer VRAM ops   1.06 per dot
--   lines rendered            66 of 192  (126 dropped)
--
-- The renderer is compute-bound inside the drawers, not memory-bound: the VRAM
-- arbiter sits ~88% idle, so its deferred parallelism pass would buy nothing.
-- A line has 63.55 us, which is 2130 clk1x cycles or 6390 clkMem cycles, and
-- 5829 fits the latter with 9% margin. This is also the ORIGINAL intent - see
-- nds_top's header, "fabric 100.5 MHz, dots 33.5, with clk1x standing in for
-- the fabric" - so this completes a placeholder rather than inventing a scheme.
--
-- BUDGET - THE FIRST VERSION OF THIS ARITHMETIC WAS WRONG, twice over. It read:
--   LDRAW 5563/3 = 1855, LMERGE 768, LFLUSH 24, total 2647 of 6390, fits.
-- Scaling the whole 5829 by 3 is invalid, because ONLY THE COMPUTE SCALES. The
-- VRAM-wait component is served by nds_vram, which is still on clk1x, so it
-- costs the same wall-clock time however fast the renderer runs:
--   compute    5320 clk1x -> 5320 clkMem   (scales)
--   VRAM wait   509 clk1x -> 1528 clkMem   (does NOT scale)
--                            6848 vs 6390  -> 7% OVER
-- and this adapter adds per-request latency on top (up to 3 clkMem cycles to
-- republish req at clkMemIndex=2, plus done narrowing): at 271 ops/line that is
-- another ~1084, so ~7932 vs 6390, 24% over.
--
-- BUT that is NOT why GPU_FAST=1 currently fails. Measured: ops=20480 (vs 71316
-- baseline), blocked%=3, renders=0, and frames 2 and 3 BIT-IDENTICAL. Only 3%
-- blocked means the renderer is barely waiting on memory, so this is a
-- FUNCTIONAL STALL in the adaptation, not a timing overrun - a budget overrun
-- would show ~271 ops/line and a high blocked%. Do not "fix" the budget and
-- expect this to work.
--
-- The budget error is still real and still has to be fixed, and the fix for both
-- is the same: move nds_vram's renderer read channels to clkMem too, so the
-- service rate scales AND srv_* stops crossing domains at all (which deletes the
-- req-republish hazard below). Estimated ~5320 + ~500 of 6390 - TO BE MEASURED,
-- not trusted; that is exactly the reasoning that produced the error above.
--
-- CAVEAT, stated because it decides how far this gets us: 5829 is Kirby's mode,
-- which enables BG3 only plus sprites - ONE BG layer. A four-layer scene with
-- heavy sprites costs more and may not fit even at 3x. This is sized for the
-- target title, not proven for everything. Re-measure with VRAMOPS=1 before
-- assuming it generalises.
--
-- nds_gpu2d IS NOT MODIFIED. It renders pixel-exact against the melonDS oracle
-- on both engines and is the last thing that should be touched to buy speed;
-- everything here is domain adaptation around it.
--
-- GPU_FAST = 0 instantiates it on clk1x and wires straight through, which is
-- bit-identical to instantiating nds_gpu2d directly. That keeps this change
-- inert until switched on, and makes the two configurations A/B measurable in
-- one build.
--
-- CROSSING RULES. clkMem is an exact 3x of clk1x from the same VCO and is
-- phase-locked, so this is synchronous multi-rate, NOT asynchronous CDC - no
-- synchronisers, no metastability. Three rules cover everything:
--
--  1. INBOUND LEVELS (linecounter, addresses, data, bus payload) are stable for
--     three clkMem cycles. Sample directly.
--  2. INBOUND PULSES are three clkMem cycles wide and must be narrowed to one,
--     by rising-edge detection in clkMem. Edge detection is used rather than
--     gating on clkMemIndex because it does not depend on the index contract
--     holding, and NDS.sv's VRAM channels already do it this way.
--     This is REQUIRED, not cosmetic, for gb_bus.ena: eProcReg_gba's write path
--     is fully combinational on proc_bus.ena, so a three-cycle-wide ena writes
--     the register three times. Idempotent for a plain register, wrong for any
--     register with a write side effect.
--  3. OUTBOUND PULSES must be CAPTURED, not sampled. gpu2d emits srv_*_req as a
--     one-cycle pulse (nds_gpu2d clears it every cycle and sets it only in
--     ARB_IDLE), which is safe at clk1x only because nds_vram latches it into
--     rpend. Sampling such a pulse at clkMemIndex=2 misses it two times in
--     three. Capture it on any clkMem cycle and hold until done - holding until
--     done is nds_vram's documented protocol, and its rpend guard stops it
--     re-latching the request already being served.
--     Outbound LEVELS (line_busy, epfill_busy, clr_busy, wired_*) need nothing:
--     clk1x samples them at its own edge, at most one clk1x period late.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;
use work.pProc_bus_gba.all;

entity nds_gpu2d_fast is
   generic
   (
      is_engine_b : std_logic := '0';
      is_simu     : std_logic := '0';
      -- 1 = render on clkMem (3x). 0 = render on clk1x, pass-through.
      GPU_FAST    : integer := 0;
      -- clkMem : clk1x ratio, so the phase gates below stay right if clkMem
      -- moves (NDS.sv CLKMEM_RATIO / the NDS_CLKMEM_4X macro). Only the
      -- GPU_FAST branch uses it; the pass-through branch has no phase gate.
      CLKMEM_RATIO : integer := 3
   );
   port
   (
      clk1x             : in  std_logic;
      clkMem            : in  std_logic;
      clkMemIndex       : in  unsigned(1 downto 0);
      reset             : in  std_logic;

      gb_bus            : in  proc_bus_gb_type;
      wired_out         : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done        : out std_logic;

      linecounter       : in  integer range 0 to 191;
      drawline          : in  std_logic;
      linecounter_obj   : in  integer range 0 to 191;
      drawObj           : in  std_logic;
      line_trigger      : in  std_logic;
      hblank_trigger    : in  std_logic;
      vblank_trigger    : in  std_logic;
      refpoint_update   : in  std_logic;

      line_busy         : out std_logic;
      epfill_busy       : out std_logic;
      clr_busy          : out std_logic := '1';

      pal_we            : in  std_logic;
      pal_addr          : in  integer range 0 to 255;
      pal_din           : in  std_logic_vector(31 downto 0);
      pal_be            : in  std_logic_vector(3 downto 0);
      oam_we            : in  std_logic;
      oam_addr          : in  integer range 0 to 255;
      oam_din           : in  std_logic_vector(31 downto 0);
      oam_be            : in  std_logic_vector(3 downto 0);

      srv_bg_req        : out std_logic := '0';
      srv_bg_addr       : out integer range 0 to 131071;
      srv_bg_data       : in  std_logic_vector(31 downto 0);
      srv_bg_done       : in  std_logic;
      srv_bg_accept     : in  std_logic := '1';
      srv_obj_req       : out std_logic := '0';
      srv_obj_addr      : out integer range 0 to 65535;
      srv_obj_data      : in  std_logic_vector(31 downto 0);
      srv_obj_done      : in  std_logic;
      srv_obj_accept    : in  std_logic := '1';
      srv_bgep_req      : out std_logic := '0';
      srv_bgep_addr     : out integer range 0 to 8191;
      srv_bgep_data     : in  std_logic_vector(31 downto 0);
      srv_bgep_done     : in  std_logic;
      srv_objep_req     : out std_logic := '0';
      srv_objep_addr    : out integer range 0 to 2047;
      srv_objep_data    : in  std_logic_vector(31 downto 0);
      srv_objep_done    : in  std_logic;

      pixel_out_x       : out integer range 0 to 255;
      pixel_out_y       : out integer range 0 to 191;
      pixel_out_data    : out std_logic_vector(17 downto 0);
      pixel_out_we      : out std_logic;

      -- forwarded straight from nds_gpu2d; the path through this wrapper is the
      -- same whichever generate branch is elaborated, which is the point
      dbg_bg_busy       : out std_logic;
      dbg_obj_busy      : out std_logic;
      dbg_bgmode        : out std_logic_vector(2 downto 0);
      dbg_fblank        : out std_logic;
      dbg_bg1_scroll_triplet : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of nds_gpu2d_fast is

   -- inner (renderer-domain) copies of everything gpu2d touches
   signal i_bus        : proc_bus_gb_type;
   signal i_drawline   : std_logic;
   signal i_drawObj    : std_logic;
   signal i_linetrig   : std_logic;
   signal i_hbltrig    : std_logic;
   signal i_vbltrig    : std_logic;
   signal i_refupd     : std_logic;
   signal i_pal_we     : std_logic;
   signal i_oam_we     : std_logic;
   signal i_bg_done    : std_logic;
   signal i_obj_done   : std_logic;
   signal i_bgep_done  : std_logic;
   signal i_objep_done : std_logic;

   signal i_bg_req     : std_logic;
   signal i_obj_req    : std_logic;
   signal i_bgep_req   : std_logic;
   signal i_objep_req  : std_logic;
   signal i_bg_addr    : integer range 0 to 131071;
   signal i_obj_addr   : integer range 0 to 65535;
   signal i_bgep_addr  : integer range 0 to 8191;
   signal i_objep_addr : integer range 0 to 2047;

   signal i_px_x       : integer range 0 to 255;
   signal i_px_y       : integer range 0 to 191;
   signal i_px_data    : std_logic_vector(17 downto 0);
   signal i_px_we      : std_logic;

   signal i_line_busy  : std_logic;
   signal i_epfill     : std_logic;
   signal i_clr_busy   : std_logic;
   signal i_wired_out  : std_logic_vector(31 downto 0);
   signal i_wired_done : std_logic;

begin

   -- ==================================================================
   -- GPU_FAST = 0: renderer on clk1x, straight through.
   -- ==================================================================
   gslow : if GPU_FAST = 0 generate
   begin
      igpu : entity work.nds_gpu2d
      generic map ( is_engine_b => is_engine_b, is_simu => is_simu )
      port map
      (
         clk => clk1x, reset => reset,
         gb_bus => gb_bus, wired_out => wired_out, wired_done => wired_done,
         linecounter => linecounter, drawline => drawline,
         linecounter_obj => linecounter_obj, drawObj => drawObj,
         line_trigger => line_trigger, hblank_trigger => hblank_trigger,
         vblank_trigger => vblank_trigger, refpoint_update => refpoint_update,
         line_busy => line_busy, epfill_busy => epfill_busy, clr_busy => clr_busy,
         pal_we => pal_we, pal_addr => pal_addr, pal_din => pal_din, pal_be => pal_be,
         oam_we => oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => oam_be,
         srv_bg_req => srv_bg_req, srv_bg_addr => srv_bg_addr,
         srv_bg_data => srv_bg_data, srv_bg_done => srv_bg_done,
         srv_bg_accept => srv_bg_accept,
         srv_obj_req => srv_obj_req, srv_obj_addr => srv_obj_addr,
         srv_obj_data => srv_obj_data, srv_obj_done => srv_obj_done,
         srv_obj_accept => srv_obj_accept,
         srv_bgep_req => srv_bgep_req, srv_bgep_addr => srv_bgep_addr,
         srv_bgep_data => srv_bgep_data, srv_bgep_done => srv_bgep_done,
         srv_objep_req => srv_objep_req, srv_objep_addr => srv_objep_addr,
         srv_objep_data => srv_objep_data, srv_objep_done => srv_objep_done,
         pixel_out_x => pixel_out_x, pixel_out_y => pixel_out_y,
         pixel_out_data => pixel_out_data, pixel_out_we => pixel_out_we,
         dbg_bg_busy => dbg_bg_busy, dbg_obj_busy => dbg_obj_busy,
         dbg_bgmode => dbg_bgmode, dbg_fblank => dbg_fblank,
         dbg_bg1_scroll_triplet => dbg_bg1_scroll_triplet
      );
   end generate;

   -- ==================================================================
   -- GPU_FAST = 1: renderer on clkMem, with the three crossing rules.
   -- ==================================================================
   gfast : if GPU_FAST /= 0 generate
      -- rule 2: one-clkMem-cycle pulses from three-cycle-wide clk1x pulses
      signal d_draw, d_obj, d_lt, d_hb, d_vb, d_ru : std_logic := '0';
      signal d_palwe, d_oamwe                      : std_logic := '0';
      signal d_bgd, d_objd, d_bgepd, d_objepd      : std_logic := '0';
      signal d_bga, d_obja                         : std_logic := '0';
      signal i_bg_accept, i_obj_accept             : std_logic;
      -- rule 3: clk1x-aligned outbound request levels
      signal o_bg_req, o_obj_req, o_bgep_req, o_objep_req : std_logic := '0';
      signal o_bg_addr    : integer range 0 to 131071 := 0;
      signal o_obj_addr   : integer range 0 to 65535 := 0;
      signal o_bgep_addr  : integer range 0 to 8191 := 0;
      signal o_objep_addr : integer range 0 to 2047 := 0;
      -- pixel rate adaptation
      constant PXW : integer := 18 + 8 + 8;   -- data + x + y
      signal fifo_din, fifo_dout : std_logic_vector(PXW - 1 downto 0);
      signal fifo_rd, fifo_empty, fifo_full : std_logic;
      signal px_x_r  : integer range 0 to 255 := 0;
      signal px_y_r  : integer range 0 to 191 := 0;
      signal px_d_r  : std_logic_vector(17 downto 0) := (others => '0');
      signal px_we_r : std_logic := '0';
   begin

      -- ---------- inbound: rule 1 (levels) + rule 2 (pulse narrowing) ----------
      p_in : process (clkMem)
      begin
         if rising_edge(clkMem) then
            d_draw   <= drawline;
            d_obj    <= drawObj;
            d_lt     <= line_trigger;
            d_hb     <= hblank_trigger;
            d_vb     <= vblank_trigger;
            d_ru     <= refpoint_update;
            d_palwe  <= pal_we;
            d_oamwe  <= oam_we;
            d_bgd    <= srv_bg_done;
            d_objd   <= srv_obj_done;
            d_bgepd  <= srv_bgep_done;
            d_objepd <= srv_objep_done;
            d_bga    <= srv_bg_accept;
            d_obja   <= srv_obj_accept;
         end if;
      end process;

      i_drawline   <= drawline        and not d_draw;
      i_drawObj    <= drawObj         and not d_obj;
      i_linetrig   <= line_trigger    and not d_lt;
      i_hbltrig    <= hblank_trigger  and not d_hb;
      i_vbltrig    <= vblank_trigger  and not d_vb;
      i_refupd     <= refpoint_update and not d_ru;
      i_pal_we     <= pal_we          and not d_palwe;
      i_oam_we     <= oam_we          and not d_oamwe;
      i_bg_done    <= srv_bg_done     and not d_bgd;
      i_obj_done   <= srv_obj_done    and not d_objd;
      i_bgep_done  <= srv_bgep_done   and not d_bgepd;
      i_objep_done <= srv_objep_done  and not d_objepd;
      i_bg_accept  <= srv_bg_accept   and not d_bga;
      i_obj_accept <= srv_obj_accept  and not d_obja;

      -- gb_bus: payload is a stable level, ena must be one cycle (see rule 2 -
      -- eProcReg_gba's write path is combinational on ena)
      i_bus.Din  <= gb_bus.Din;
      i_bus.Adr  <= gb_bus.Adr;
      i_bus.rnw  <= gb_bus.rnw;
      i_bus.acc  <= gb_bus.acc;
      i_bus.bEna <= gb_bus.bEna;
      i_bus.rst  <= gb_bus.rst;
      p_ena : process (clkMem)
         variable prev : std_logic := '0';
      begin
         if rising_edge(clkMem) then
            i_bus.ena <= gb_bus.ena and not prev;
            prev      := gb_bus.ena;
         end if;
      end process;

      -- ---------- outbound: rule 3 ----------
      -- Republish the request level only on the clkMem cycle that ends a clk1x
      -- period, so nds_vram always sees a full clk1x period of a stable value
      -- and any clkMem-rate deassert/reassert cannot hide a request boundary.
      -- gpu2d drives srv_*_req as a ONE-CYCLE PULSE, not a held level:
      -- nds_gpu2d.vhd's arbiter does `srv_bg_req <= '0'` at the top of every
      -- cycle and only sets it in ARB_IDLE. At clk1x that is fine because
      -- nds_vram latches the pulse into rpend - "requests landing while the FSM
      -- serves another channel are latched in rpend" - so the producer never had
      -- to hold it.
      --
      -- So this must CAPTURE the pulse, not sample it. The first version sampled
      -- the level at clkMemIndex=2 and therefore missed a one-cycle pulse two
      -- times in three; the very first BG request was lost, gpu2d sat in ARB_WAIT
      -- forever, and the whole renderer stalled with ops=0. That was my error
      -- twice over: I read nds_vram's documented EXPECTATION ("hold req with
      -- stable addr until done") and assumed the producer complied, then wrote
      -- that assumption into this file's header as if it were verified.
      --
      -- Capture on any clkMem cycle, hold until done. Holding until done IS
      -- nds_vram's documented protocol, so one dispatch per request; and its
      -- rpend guard already prevents re-latching the request being served.
      -- The set is placed after the clear so that a done arriving in the same
      -- cycle as the next request still leaves the new request pending.
      p_out : process (clkMem)
      begin
         if rising_edge(clkMem) then
            if (reset = '1') then
               o_bg_req    <= '0';
               o_obj_req   <= '0';
               o_bgep_req  <= '0';
               o_objep_req <= '0';
            else
               -- release on ACCEPT, not done: the server takes one request per
               -- accept and may hold several in flight, so done is no longer
               -- the signal that it is ready for the next one
               if (srv_bg_accept  = '1') then o_bg_req    <= '0'; end if;
               -- OBJ releases on accept too now that its drawer pipelines
               if (srv_obj_accept = '1') then o_obj_req   <= '0'; end if;
               if (srv_bgep_done  = '1') then o_bgep_req  <= '0'; end if;
               if (srv_objep_done = '1') then o_objep_req <= '0'; end if;

               if (i_bg_req = '1') then
                  o_bg_req  <= '1';
                  o_bg_addr <= i_bg_addr;
               end if;
               if (i_obj_req = '1') then
                  o_obj_req  <= '1';
                  o_obj_addr <= i_obj_addr;
               end if;
               if (i_bgep_req = '1') then
                  o_bgep_req  <= '1';
                  o_bgep_addr <= i_bgep_addr;
               end if;
               if (i_objep_req = '1') then
                  o_objep_req  <= '1';
                  o_objep_addr <= i_objep_addr;
               end if;
            end if;
         end if;
      end process;

      srv_bg_req     <= o_bg_req;
      srv_obj_req    <= o_obj_req;
      srv_bgep_req   <= o_bgep_req;
      srv_objep_req  <= o_objep_req;
      srv_bg_addr    <= o_bg_addr;
      srv_obj_addr   <= o_obj_addr;
      srv_bgep_addr  <= o_bgep_addr;
      srv_objep_addr <= o_objep_addr;

      -- levels: clk1x samples them at its own edge, at most one clk1x period late
      line_busy   <= i_line_busy;
      epfill_busy <= i_epfill;
      clr_busy    <= i_clr_busy;
      -- combinational register decode of a stable address, so directly usable
      wired_out   <= i_wired_out;
      wired_done  <= i_wired_done;

      -- ---------- pixel rate adaptation ----------
      -- LMERGE emits up to one pixel per clkMem cycle; the consumer downstream of
      -- nds_top takes one per clk1x. A plain synchronous FIFO on clkMem is enough
      -- because the clocks are phase-locked - this is rate adaptation, not CDC.
      -- Worst case a line pushes 256 while 85 drain, so 171 must be held; 256
      -- entries is one M10K per engine and drains during the next line's LDRAW.
      fifo_din <= i_px_data &
                  std_logic_vector(to_unsigned(i_px_x, 8)) &
                  std_logic_vector(to_unsigned(i_px_y, 8));

      ififo : entity mem.SyncFifo
      generic map ( SIZE => 256, DATAWIDTH => PXW, NEARFULLDISTANCE => 16 )
      port map
      (
         clk => clkMem, reset => reset,
         Din => fifo_din, Wr => i_px_we, Full => fifo_full, NearFull => open,
         Dout => fifo_dout, Rd => fifo_rd, Empty => fifo_empty
      );

      -- one pixel per clk1x period, presented for the whole period
      fifo_rd <= '1' when (fifo_empty = '0' and clkMemIndex = CLKMEM_RATIO - 1) else '0';

      p_px : process (clkMem)
      begin
         if rising_edge(clkMem) then
            if (clkMemIndex = CLKMEM_RATIO - 1) then
               px_we_r <= '0';
               if (fifo_empty = '0') then
                  px_d_r  <= fifo_dout(PXW - 1 downto 16);
                  px_x_r  <= to_integer(unsigned(fifo_dout(15 downto 8)));
                  px_y_r  <= to_integer(unsigned(fifo_dout(7 downto 0)));
                  px_we_r <= '1';
               end if;
            end if;
         end if;
      end process;

      pixel_out_x    <= px_x_r;
      pixel_out_y    <= px_y_r;
      pixel_out_data <= px_d_r;
      pixel_out_we   <= px_we_r;

      -- synthesis translate_off
      -- First-occurrence probe. GPUFAST=1 came back with ops=0 and both drawers
      -- busy forever, which is either "gpu2d never asked for VRAM" or "this
      -- adapter swallowed the request" - and those want completely different
      -- fixes, so distinguish them rather than guess.
      p_gfdbg : process (clkMem)
         variable s_idx2, s_draw, s_ireq, s_oreq, s_done : boolean := false;
      begin
         if rising_edge(clkMem) then
            if (clkMemIndex = CLKMEM_RATIO - 1 and not s_idx2) then
               report "GF: clkMemIndex reached last phase at " & time'image(now) severity note;
               s_idx2 := true;
            end if;
            if (i_drawline = '1' and not s_draw) then
               report "GF: first narrowed drawline at " & time'image(now) severity note;
               s_draw := true;
            end if;
            if (i_bg_req = '1' and not s_ireq) then
               report "GF: gpu2d asserted srv_bg_req at " & time'image(now) severity note;
               s_ireq := true;
            end if;
            if (o_bg_req = '1' and not s_oreq) then
               report "GF: republished srv_bg_req to clk1x at " & time'image(now) severity note;
               s_oreq := true;
            end if;
            if (i_bg_done = '1' and not s_done) then
               report "GF: first narrowed srv_bg_done at " & time'image(now) severity note;
               s_done := true;
            end if;
         end if;
      end process;
      -- synthesis translate_on

      igpu : entity work.nds_gpu2d
      generic map ( is_engine_b => is_engine_b, is_simu => is_simu )
      port map
      (
         clk => clkMem, reset => reset,
         gb_bus => i_bus, wired_out => i_wired_out, wired_done => i_wired_done,
         linecounter => linecounter, drawline => i_drawline,
         linecounter_obj => linecounter_obj, drawObj => i_drawObj,
         line_trigger => i_linetrig, hblank_trigger => i_hbltrig,
         vblank_trigger => i_vbltrig, refpoint_update => i_refupd,
         line_busy => i_line_busy, epfill_busy => i_epfill, clr_busy => i_clr_busy,
         pal_we => i_pal_we, pal_addr => pal_addr, pal_din => pal_din, pal_be => pal_be,
         oam_we => i_oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => oam_be,
         srv_bg_req => i_bg_req, srv_bg_addr => i_bg_addr,
         srv_bg_data => srv_bg_data, srv_bg_done => i_bg_done,
         srv_bg_accept => i_bg_accept,
         srv_obj_req => i_obj_req, srv_obj_addr => i_obj_addr,
         srv_obj_data => srv_obj_data, srv_obj_done => i_obj_done,
         srv_obj_accept => i_obj_accept,
         srv_bgep_req => i_bgep_req, srv_bgep_addr => i_bgep_addr,
         srv_bgep_data => srv_bgep_data, srv_bgep_done => i_bgep_done,
         srv_objep_req => i_objep_req, srv_objep_addr => i_objep_addr,
         srv_objep_data => srv_objep_data, srv_objep_done => i_objep_done,
         pixel_out_x => i_px_x, pixel_out_y => i_px_y,
         pixel_out_data => i_px_data, pixel_out_we => i_px_we,
         dbg_bg_busy => dbg_bg_busy, dbg_obj_busy => dbg_obj_busy,
         dbg_bgmode => dbg_bgmode, dbg_fblank => dbg_fblank,
         dbg_bg1_scroll_triplet => dbg_bg1_scroll_triplet
      );
   end generate;

end architecture;
