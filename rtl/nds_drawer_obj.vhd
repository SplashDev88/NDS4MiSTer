-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS OBJ drawer (fork of gba_drawer_obj). One instance renders all 128
-- sprites of one line into the OBJ line buffer (color + settings planes).
-- Deltas vs the GBA donor:
--
--   * 256-pixel line, ypos 0..191, 256 KB OBJ char space (18-bit addresses)
--   * 1D tile mapping boundary: base = tileno * (32 << tile_boundary)
--     (DISPCNT 21:20); 2D unchanged (tileno*32, 1 KB row stride). NDS does
--     NOT force even tile numbers for 256-color 2D sprites (melonDS).
--   * OBJ extended palette (obj_extpal, DISPCNT.31): 256-color sprites
--     look up palno*256+color in the engine's 8 KB OBJ ext-pal slot;
--     without it the palette number is ignored (GBA behavior).
--   * bitmap sprites (OBJ mode "11"): direct-color pixels, opaque iff
--     bit15; attr2 palette field is the blend alpha - alpha=0 hides the
--     sprite. Addressing per GBATEK/melonDS:
--       1D (bitmap_1d='1'): base = tileno << (7 + bitmap_1d_boundary),
--          row stride = sprite width * 2   (bitmap_2d_wide='1' + 1D is
--          'reserved', draws nothing)
--       2D: wide: base = (tileno&1F)*16 + (tileno&3E0)*128, stride 512
--           narrow: base = (tileno&0F)*16 + (tileno&3F0)*128, stride 256
--     Affine bitmap sprites fetch base + yyy*stride + xxx*2.
--   * settings plane widened to 8 bits:
--     [1:0] priority, [2] semi-transparent (mode 01), [3] bitmap sprite,
--     [7:4] bitmap alpha (attr2 palette field)
--   * the hardware per-line OBJ time budget IS enforced (HW_TIME_LIMIT):
--     1210 cycles with the H-Blank interval free, 954 without, charged as
--     1 cycle per field pixel for a normal sprite and 10 + 2 per pixel for
--     a rot/scal one. melonDS does not model this, so the golden models do
--     not either - see the generic's comment for why that is still safe.
--
-- OAM layout, affine pipeline and the priority merge into the double
-- line buffer are unchanged from the donor. H-mosaic follows NDS hardware
-- (melonDS ApplySpriteMosaicX): the repeat grid is screen-aligned
-- (restart where x mod (size+1) = 0) and restarts at each sprite's first
-- emitted pixel - the donor counted relative to the sprite edge instead.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_obj is
   generic
   (
      -- Hardware OBJ per-line time budget, per GBATEK. Hardware gives OBJ
      -- rendering 1210 cycles per line when DISPCNT.23 (H-Blank interval
      -- free) is set and 954 when it is not, and charges:
      --
      --    normal sprite   : 1 cycle per pixel of the sprite's field width
      --    rot/scal sprite : 10 cycles of setup + 2 cycles per field pixel
      --
      -- A line that asks for more than that loses its LAST sprites - OAM
      -- order is priority order, so running out of budget drops the lowest
      -- priority ones, which is what this walk does too.
      --
      -- This is counted in HARDWARE cycles, not ours. Charging our own clock
      -- against 1210 would be wrong by whatever the drawer's cycles-per-pixel
      -- happens to be, and would drop sprites hardware keeps.
      --
      -- Set to '0' to render every sprite regardless. melonDS does not model
      -- the limit, so the generated golden models expect '0' behaviour on any
      -- scene that would exceed the budget.
      HW_TIME_LIMIT : std_logic := '1'
   );
   port
   (
      clk                  : in  std_logic;

      drawline             : in  std_logic;
      busy                 : out std_logic := '0';
      ypos                 : in  integer range 0 to 191;
      ypos_mosaic          : in  integer range 0 to 191;

      one_dim_mapping      : in  std_logic;                    -- DISPCNT.4
      tile_boundary        : in  unsigned(1 downto 0);         -- DISPCNT.21:20
      bitmap_1d            : in  std_logic;                    -- DISPCNT.6
      bitmap_2d_wide       : in  std_logic;                    -- DISPCNT.5
      bitmap_1d_boundary   : in  std_logic;                    -- DISPCNT.22
      obj_extpal           : in  std_logic;                    -- DISPCNT.31
      Mosaic_H_Size        : in  unsigned(3 downto 0);

      hblankfree           : in  std_logic;

      pixel_we_color       : out std_logic := '0';
      pixeldata_color      : out std_logic_vector(15 downto 0) := (others => '0');
      pixel_we_settings    : out std_logic := '0';
      pixeldata_settings   : out std_logic_vector(7 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 255;
      pixel_objwnd         : out std_logic := '0';

      -- OAM is addressed by SPRITE, not by word: one read returns the whole
      -- 8-byte entry (attr0/1/2 in 47..0; attr3 is the affine-param slot and
      -- belongs to a group, not to this sprite, so it is not used here).
      -- The two halves are two identical RAMs written in lockstep on the CPU
      -- side - see nds_gpu2d - which is what buys the width without a copy or
      -- a fill pass.
      OAMRAM_Drawer_addr   : buffer integer range 0 to 127;
      OAMRAM_Drawer_data   : in  std_logic_vector(63 downto 0);

      -- The 32 rot/scal parameter groups, write-through shadows of the attr3
      -- fields, all four params of a group readable in one cycle:
      -- 15..0 = PA (dx), 31..16 = PB, 47..32 = PC (dy), 63..48 = PD.
      OAMAFF_Drawer_addr   : out integer range 0 to 31;
      OAMAFF_Drawer_data   : in  std_logic_vector(63 downto 0);

      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);

      EXTPAL_Drawer_addr   : out integer range 0 to 2047;      -- 8 KB OBJ ext-pal slot
      EXTPAL_Drawer_data   : in  std_logic_vector(31 downto 0);

      -- SEVERAL requests may be in flight: present req with addr, the arbiter
      -- pulses accept when it takes it, and done pulses once per answer IN
      -- ISSUE ORDER (nds_gpu2d's arbiter and nds_vram's server both retire in
      -- order, which is what lets the word queue below be a plain FIFO).
      -- accept defaults to '1' so a bench that does not model it still works.
      VRAM_Drawer_req      : out std_logic := '0';
      VRAM_Drawer_addr     : out integer range 0 to 65535;     -- 256 KB OBJ space
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_done     : in  std_logic;
      VRAM_Drawer_accept   : in  std_logic := '1'
   );
end entity;

architecture arch of nds_drawer_obj is

   -- Atr0
   constant OAM_Y_HI         : integer := 7;
   constant OAM_Y_LO         : integer := 0;
   constant OAM_AFFINE       : integer := 8;
   constant OAM_DBLSIZE      : integer := 9;
   constant OAM_OFF_HI       : integer := 9;
   constant OAM_OFF_LO       : integer := 8;
   constant OAM_MODE_HI      : integer := 11;
   constant OAM_MODE_LO      : integer := 10;
   constant OAM_MOSAIC       : integer := 12;
   constant OAM_HICOLOR      : integer := 13;
   constant OAM_OBJSHAPE_HI  : integer := 15;
   constant OAM_OBJSHAPE_LO  : integer := 14;

   -- Atr1
   constant OAM_X_HI         : integer := 8;
   constant OAM_X_LO         : integer := 0;
   constant OAM_AFF_HI       : integer := 13;
   constant OAM_AFF_LO       : integer := 9;
   constant OAM_HFLIP        : integer := 12;
   constant OAM_VFLIP        : integer := 13;
   constant OAM_OBJSIZE_HI   : integer := 15;
   constant OAM_OBJSIZE_LO   : integer := 14;

   -- Atr2
   constant OAM_TILE_HI      : integer := 9;
   constant OAM_TILE_LO      : integer := 0;
   constant OAM_PRIO_HI      : integer := 11;
   constant OAM_PRIO_LO      : integer := 10;
   constant OAM_PALETTE_HI   : integer := 15;
   constant OAM_PALETTE_LO   : integer := 12;

   type t_OAMFetch is
   (
      IDLE,
      WAITFIRST,
      WAITAFF,
      DONE
   );
   -- v2 walked READFIRST -> WAITFIRST -> READSECOND -> WAITSECOND and then,
   -- for a rot/scal sprite, four more READ/WAIT pairs to collect the affine
   -- params one 16-bit field at a time: 12 cycles for an affine sprite, 4 for
   -- a plain one. OAM is 1 KB and only the CPU writes it, so none of that had
   -- to be serial - both layouts are now write-through shadows maintained on
   -- the write side (nds_gpu2d), and the whole entry, or a whole group of
   -- affine params, arrives in one read. WAITAFF is the single remaining
   -- cycle, and only rot/scal sprites pay it: the shadow address comes from
   -- attr1, which is not known until the entry itself lands.
   --
   -- READFIRST is gone with them. It existed only to re-present the sprite
   -- address that READSECOND had clobbered; nothing clobbers it now, so the
   -- scan-ahead address stands untouched all the way through DONE and the
   -- next entry is already on the data bus when DONE hands off.
   --
   -- SIZE THIS HONESTLY. The obvious arithmetic - 128 affine sprites times 10
   -- saved cycles against a 2,130-cycle line - is wrong, and tb_gpu_obj says
   -- so. Sprite N+1's fetch runs CONCURRENTLY with sprite N's pixel walk (the
   -- walk starts the cycle DONE hands off, and the fetch FSM re-enters
   -- WAITFIRST in that same cycle), so the fetch only ever costs what it
   -- exceeds the previous sprite's walk by. Even 16-wide sprites walk longer
   -- than the old 12-cycle fetch, so it was nearly always fully hidden.
   -- Measured, cases 32/33 - 24 dense 16x16 sprites, identical but for the
   -- affine bit, busy_cyc from tb_gpu_obj:
   --                       normal      rot/scal
   --      before             542          554
   --      after              520          521
   -- i.e. the affine premium over 24 sprites went from 12 cycles to 1. What
   -- is actually recovered is a per-LINE constant - the first drawn sprite
   -- has no previous walk to hide behind - worth ~3 cycles on a plain line
   -- and ~13 if the first drawn sprite is rot/scal (cases 6/7/8/14/26-29,
   -- all -10). Over the 34 cases that existed when this was compared, every
   -- one got faster or stayed level and none regressed; 34-36 are the screen
   -- clip's own cases and postdate that sweep. The larger prize is
   -- structural: 13 states became 4, and the LAB count is what this design
   -- is short of.
   --
   -- The `after` row is the whole change measured together, NOT this state
   -- machine on its own. A/B'd against the only other knob that moves these
   -- two cases (they sit at x 0..108, so the screen clip never fires on
   -- them), holding everything else:
   --      PQ_DEPTH = 8    541   544      <- what an earlier draft recorded
   --      PQ_DEPTH = 16   520   521
   -- so ~21 of the 22 cycles is the deeper queue and the fetch rework's own
   -- share of THESE cases is the affine premium, 3 cycles down to 1. Both
   -- depths pass all 37 cases, so PQ_DEPTH is a throughput knob only.
   --
   -- DO NOT READ "521 vs 544" AS "PQ_DEPTH IS WORTH 4%". It is worth far more
   -- than that, and this bench cannot see it: one drawer, no second engine, no
   -- CPU, and a VRAM model that answers immediately. Run-ahead only pays when
   -- something else is holding the bus. Measured 2026-08-09 on tb_top_frame,
   -- which has both engines, both CPUs and VRSRV_ONE=1 (one op in flight, the
   -- hardware behaviour) - nds_2dk, DIRECT=1 GPUCEDIV=1, frame 4, engine A:
   --
   --                        PQ_DEPTH=8   =12    =16
   --   OBJ line total (y=1)     2930      2140   1722
   --   stall, all pqfull        1822      1005    582
   --   wordwait                 2065      1277    832
   --   cyc/render A             1943      1954   1931
   --   lines DROPPED              24        24     16
   --
   -- 12 IS NOT A COMPROMISE, IT IS THE WORST OPTION. It halves the stall and
   -- takes 27% off the OBJ line, and drops exactly as many scanlines as 8 -
   -- the drop threshold is somewhere between 12 and 16, and nothing below it
   -- reaches the screen. It costs ~12 LABs more than 8 for a picture that is
   -- identical. If 16 will not fit, go to 8, not 12. (Measured, after
   -- predicting the opposite from the stall numbers - do not re-derive this
   -- from cycles, the only metric that matters here is the drop count.)
   --
   -- Eight scanlines per frame, i.e. visible on a screen, not a profiler
   -- curiosity. wqfull and unacc are flat zero at both depths, so it is purely
   -- room to run ahead. The area temptation is real - the queue is 26 bits x
   -- PQ_DEPTH per engine plus its read mux, x2 engines - and it was nearly
   -- traded away for the SOUND_ENABLE=1 fit on the strength of the 4% figure
   -- above. It is not the knob to cut; find the ALMs elsewhere.
   signal OAMFetch : t_OAMFetch := IDLE;

   signal output_ok : std_logic := '0';
   signal overdraw  : std_logic := '0';

   signal OAM_currentobj : integer range 0 to 127;

   -- The sprite whose OAM address is ON THE BUS. OAM reads are registered, so
   -- the data arriving this cycle belongs to whatever address went out last
   -- cycle - i.e. OAM_currentobj always trails OAM_scanptr by one.
   --
   -- Keeping the two apart is what lets a skipped sprite cost ONE cycle. The
   -- walk used to be READFIRST (present address) -> WAITFIRST (consume it) ->
   -- READFIRST, so every one of the 128 entries cost two cycles whether or not
   -- it drew anything: a dead-constant 255 cycles per line, measured, on a
   -- 2130-cycle budget. Presenting sprite N+1's address while N's data is
   -- being consumed halves that.
   --
   -- Only the first-word scan pipelines. READSECOND and the affine reads still
   -- address off OAM_currentobj, because those are reads for the sprite being
   -- processed, not the one being scanned ahead.
   signal OAM_scanptr    : integer range 0 to 127 := 0;

   signal OAM_data0 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data1 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data2 : std_logic_vector(15 downto 0) := (others => '0');

   signal OAM_attr2 : std_logic_vector(15 downto 0);

   signal OAM_data_aff0 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff1 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff2 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff3 : std_logic_vector(15 downto 0) := (others => '0');

   signal OAM_sizeX     : integer range 8 to 64;
   signal OAM_sizeY     : integer range 8 to 64;
   signal OAM_sizeX2    : integer range 8 to 128;
   signal OAM_sizeY2    : integer range 8 to 128;
   signal OAM_posy      : integer range -256 to 255;
   signal OAM_posyMos   : integer range -512 to 511;
   signal OAM_isbitmap  : std_logic;

   signal OAMfetch_sizeX         : integer range 8 to 64;
   signal OAMfetch_sizeY         : integer range 8 to 64;
   signal OAMfetch_fieldX        : integer range 8 to 128;
   signal OAMfetch_fieldY        : integer range 8 to 128;
   signal OAMfetch_ty            : integer range -256 to 255;
   signal OAMfetch_sizemult      : integer range 16 to 1024;   -- bytes per sprite tile-row / bitmap row
   signal OAMfetch_x_flip_offset : integer range 3 to 7;
   signal OAMfetch_y_flip_offset : integer range 28 to 56;
   signal OAMfetch_x_size        : integer range 4 to 8;
   signal OAMfetch_addrbase      : integer range 0 to 262143;

   -- AFF_SUM is gone: the affine address sum now runs as a stage BESIDE the
   -- walk (see the aff_pend block) rather than as a state the walk alternates
   -- into. It used to cost rot/scal sprites a second cycle per pixel -
   -- measured at +63% on a line of eight 64x64 sprites (646 -> 1054 cycles for
   -- the same 227 pixels, tb_gpu_obj cases 30/31).
   type t_PIXELGen is
   (
      WAITOAM,
      NEXTADDR
   );
   signal PIXELGen : t_PIXELGen := WAITOAM;

   signal Pixel_data0       : std_logic_vector(15 downto 0) := (others => '0');
   signal Pixel_data1       : std_logic_vector(15 downto 0) := (others => '0');
   signal Pixel_data2       : std_logic_vector(15 downto 0) := (others => '0');
   signal dx                : integer range -32768 to 32767;
   signal dy                : integer range -32768 to 32767;

   signal posx              : integer range -512 to 511;
   signal sizeX             : integer range 8 to 64;
   signal sizeY             : integer range 8 to 64;
   -- the CLIPPED end of the walk, not the sprite's field width: an off-screen
   -- sprite clips to first = last, so this reaches 0
   signal fieldX            : integer range 0 to 128;
   signal pixeladdr_base    : integer range 0 to 262143;
   signal pixeladdr         : integer range -262144 to 262143;
   signal is_bitmap         : std_logic := '0';

   signal sizemult          : integer range 16 to 1024;

   signal x_flip_offset     : integer range 3 to 7;
   signal x_size            : integer range 4 to 8;

   signal x                 : integer range 0 to 255;
   signal realX             : integer range -8388608 to 8388607;
   signal realY             : integer range -8388608 to 8388607;
   signal target            : integer range 0 to 255;
   signal second_pix        : std_logic := '0';

   -- ==========================================================================
   -- DECOUPLED PIXEL QUEUE
   -- ==========================================================================
   -- v1 walked NEXTADDR -> (reuse | fetch -> PIXELWAIT) -> NEXTADDR one pixel
   -- at a time and STOPPED DEAD in PIXELWAIT on every fetch, so a fetched pixel
   -- cost 1 + the whole VRAM round trip. Measured 3,036 cycles on a
   -- sprite-bearing line against a 2,130 budget - the drops the owner can see.
   --
   -- The address stream is predictable, so the walk now runs AHEAD of the
   -- pixels. Each walked pixel is pushed onto a queue carrying everything the
   -- pixel pipeline needs (byte lane, screen x, half-byte select, first-of-
   -- sprite), tagged either "reuses the word before it" or "consumes the next
   -- word to come back". Fetches are issued as the walk passes them, several
   -- outstanding at once, and a drain stage pops one pixel per cycle - stalling
   -- only when the head pixel's word has not landed yet.
   --
   -- Two consequences worth naming:
   --   * the reuse compare is now on the WORD (bits 17..2), not the halfword
   --     v1 used. One fetched word serves every address sharing those bits -
   --     v1's own AFF_SUM comment says so - which halves the fetches for
   --     4bpp tile sprites.
   --   * it is guarded on walk_seen ("a word for THIS sprite is queued")
   --     rather than v1's firstpix. firstpix was cleared by the first
   --     NEXTADDR whether or not that pixel drew anything, so a sprite whose
   --     first pixels were all skipped compared against the PREVIOUS sprite's
   --     address. That was a live bug on the non-affine path; AFF_SUM already
   --     guarded against it and said why.

   -- PQ_DEPTH is the walk's RUN-AHEAD, and run-ahead is how VRAM latency gets
   -- hidden: the drain stalls the moment it catches up to a pixel whose word
   -- has not come back. At 8 the drain was starved for a large part of every
   -- sprite-bearing line, and that back-pressure showed up at the walk as a
   -- full pixel queue - measured on the frame bench, per line:
   --     stall=49 (affsum=0 pqfull=48 wqfull=0 unacc=0) wordwait=89
   -- pqfull was the entire stall, wqfull and unacc were flat zero, so the
   -- walk was never short of request slots. It was short of ROOM TO RUN.
   --
   -- 16 recovered 43% of the stall (frame-bench totals, stall 2056 -> 1177,
   -- drawer time 17485 -> 16629). 32 was worth another 2% and was not taken.
   -- WQ_DEPTH is deliberately NOT raised with it: measured at 4/5/6 the
   -- numbers are identical, so the extra in-flight slots buy nothing, and
   -- the gpu2d arbiter only tracks 8 ops across ALL FOUR drawers - OBJ
   -- taking more of them would come straight out of the BGs.
   --
   -- 2026-08-10: CUT BACK 16 -> 4, because the reason 16 paid has gone. That
   -- measurement was taken while the affine and extended BG drawers were still
   -- serial; they held the arbiter and starved this drawer, so run-ahead was
   -- the only way to hide the wait. Pipelining them (v2, since merged into
   -- nds_drawer_affext) halved BG VRAM traffic - engine-A frame bench,
   -- renderer busy 2586 -> 1221 cycles/line on the affine case - and OBJ now
   -- gets the request slots it used to queue for. Re-measured on the frame
   -- bench at 16 / 8 / 4, WITH those drawers in:
   --     cycles/line   1218 / 1218 / 1216      dropped lines   0 / 0 / 0
   --     OBJ stall/line  ~33 / 64.6 / 147
   -- The stall still grows as the queue shrinks, but it is ABSORBED - it no
   -- longer moves the line, because the line is not bounded here any more.
   -- Area is the binding constraint on this device and cycles/line are not, so
   -- the trade runs the other way now: 16 -> 4 gives back 1,208 ALMs across the
   -- two instances for a measured 2 cycles per line. That is what pays for the
   -- two BG drawers' queues.
   --
   -- WQ_DEPTH 4 -> 2 for the same reason and at the same price: identical line
   -- time (1215) and identical stall, because the walk was never short of
   -- REQUEST slots - the original note above already said wqfull was flat zero
   -- at 4/5/6, and that holds going down as well as up.
   --
   -- PQ_DEPTH 2 also measures nearly free (1218, +3 cycles) but takes stall
   -- 147 -> 212. Held in reserve rather than taken: it is the next thing to
   -- spend if the image needs a last few LABs, and the first thing to give
   -- back if a scene ever bounds here again.
   --
   -- If a future scene DOES bound on this drawer again, the diagnostic is
   -- OBJPROF's stall breakdown: pqfull rising while wqfull and unacc stay zero
   -- is this constant, and nothing else, being too small.
   constant PQ_DEPTH : integer := 4;   -- pixels queued between walk and pixels
   constant WQ_DEPTH : integer := 2;   -- VRAM words tracked in flight

   -- Everything the pixel pipeline needs to know about the SPRITE a queued
   -- pixel came from. These used to be read live off Pixel_data* at drain
   -- time, which is why a sprite's settings had to stay current until its last
   -- pixel had drained - the `pq_cnt = 0` term in settings_go. That term cost
   -- a bubble the size of the VRAM round trip once per sprite: measured 390 to
   -- 655 cycles per line on a 128-sprite line, 20-34% of the drawer's time,
   -- with the walk sitting idle for all of it.
   --
   -- Carrying them WITH the pixel is the same fix already applied to the
   -- fetched word (see drain_word): the next sprite can start walking while
   -- the previous one's pixels are still draining, because those pixels no
   -- longer depend on any live register.
   type t_pq_set is record
      prio    : std_logic_vector(1 downto 0);
      mode    : std_logic_vector(1 downto 0);
      hicolor : std_logic;
      affine  : std_logic;
      hflip   : std_logic;
      palette : std_logic_vector(3 downto 0);
      mosaic  : std_logic;
      bitmap  : std_logic;
   end record;
   constant PQ_SET_INIT : t_pq_set := ("00", "00", '0', '0', '0', "0000", '0', '0');

   type t_pq_entry is record
      newword : std_logic;                 -- consumes the next word to arrive
      lane    : unsigned(1 downto 0);      -- byte lane within that word
      target  : integer range 0 to 255;    -- screen x
      second  : std_logic;                 -- odd source pixel (4bpp nibble)
      first   : std_logic;                 -- sprite's first emitted pixel
      set     : t_pq_set;                  -- the sprite this pixel belongs to
   end record;
   constant PQ_INIT : t_pq_entry := ('0', "00", 0, '0', '0', PQ_SET_INIT);
   type t_pq is array (0 to PQ_DEPTH-1) of t_pq_entry;
   signal pq       : t_pq := (others => PQ_INIT);
   signal pq_head  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pq_tail  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pq_cnt   : integer range 0 to PQ_DEPTH := 0;

   type t_wq is array (0 to WQ_DEPTH-1) of std_logic_vector(31 downto 0);
   signal wq       : t_wq := (others => (others => '0'));
   signal wq_head  : integer range 0 to WQ_DEPTH-1 := 0;
   signal wq_tail  : integer range 0 to WQ_DEPTH-1 := 0;
   signal wq_cnt   : integer range 0 to WQ_DEPTH := 0;
   signal inflight : integer range 0 to WQ_DEPTH := 0;   -- asked for, not back

   -- AFFINE ADDRESS PIPELINE
   -- The rot/scal address is a sum of six partial terms, too slow to fold into
   -- the cycle that computes them - which is why it had its own state. But the
   -- sum for pixel N and the partial-term compute for pixel N+1 are on
   -- INDEPENDENT data, so they belong in the same cycle on different pixels,
   -- not in consecutive cycles on the same one. The critical path is
   -- max(sum, compute), not sum + compute, so this is a pipeline stage rather
   -- than a longer combinational path.
   --
   -- aff_pend means "the partial registers hold a pixel whose sum has not been
   -- queued yet". The walk may not overwrite them while it is set, so it also
   -- provides the backpressure when the queue is full.
   signal aff_pend   : std_logic := '0';
   signal aff_target : integer range 0 to 255 := 0;
   signal aff_second : std_logic := '0';

   signal unaccepted : std_logic := '0';   -- request presented, not yet taken
   signal walk_seen  : std_logic := '0';   -- a word for this sprite is queued
   signal last_addr  : unsigned(17 downto 0) := (others => '0');
   signal req_word   : unsigned(15 downto 0) := (others => '0');

   -- drain -> pixel pipeline, all valid the cycle after issue_pixel
   signal issue_pixel  : std_logic := '0';
   signal issue_lane   : unsigned(1 downto 0) := "00";
   signal issue_target : integer range 0 to 255 := 0;
   signal issue_second : std_logic := '0';
   -- the drained pixel's sprite settings, published with it
   signal issue_set    : t_pq_set := PQ_SET_INIT;
   -- the settings of the sprite currently being WALKED, i.e. what gets stamped
   -- into each entry as it is queued
   signal cur_set      : t_pq_set;
   -- the word this pixel reads. It must travel WITH the pixel: a single
   -- "last word fetched" register works only while the FSM stalls per fetch,
   -- and back-to-back drains would overwrite it before the pipeline read it.
   signal drain_word   : std_logic_vector(31 downto 0) := (others => '0');
   signal word_eval    : std_logic_vector(31 downto 0) := (others => '0');

   signal pixeladdr_x_aff0  : unsigned(17 downto 0);
   signal pixeladdr_x_aff1  : unsigned(17 downto 0);
   signal pixeladdr_x_aff2  : unsigned(17 downto 0);
   signal pixeladdr_x_aff3  : unsigned(17 downto 0);
   signal pixeladdr_x_aff4  : unsigned(17 downto 0);
   signal pixeladdr_x_aff5  : unsigned(17 downto 0);

   -- Pixel Pipeline
   signal consumeSettings  : std_logic := '0';
   signal PALETTE_byteaddr : std_logic_vector(8 downto 0);
   signal EXTPAL_byteaddr  : std_logic_vector(12 downto 0);

   type tpixel is record
      transparent : std_logic;
      prio        : std_logic_vector(1 downto 0);
      alpha       : std_logic;
      objwnd      : std_logic;
   end record;

   type t_pixelarray is array(0 to 255) of tpixel;
   signal pixelarray : t_pixelarray;

   signal Pixel_wait        : tpixel;
   signal Pixel_readback    : tpixel;
   signal Pixel_merge       : tpixel;

   signal target_eval       : integer range 0 to 255;
   signal target_wait       : integer range 0 to 255;
   signal target_merge      : integer range 0 to 255;

   signal enable_eval       : std_logic;
   signal enable_wait       : std_logic;
   signal enable_merge      : std_logic;

   signal second_pix_eval   : std_logic;

   signal readaddr_mux_eval : unsigned(1 downto 0);

   -- (the per-sprite *_issue registers that used to sit here are gone: those
   -- values now ride in the pixel queue as t_pq_set, see issue_set)

   signal prio_eval         : std_logic_vector(1 downto 0);
   signal mode_eval         : std_logic_vector(1 downto 0);
   signal hicolor_eval      : std_logic;
   signal affine_eval       : std_logic;
   signal hflip_eval        : std_logic;
   signal palette_eval      : std_logic_vector(3 downto 0);
   signal mosaic_eval       : std_logic;
   signal bitmap_eval       : std_logic;
   signal mosaic_wait       : std_logic;

   signal bitmap_wait       : std_logic;
   signal bitmap_merge      : std_logic;
   signal bmpalpha_wait     : std_logic_vector(3 downto 0);
   signal bmpalpha_merge    : std_logic_vector(3 downto 0);
   signal bmpcolor_wait     : std_logic_vector(15 downto 0);
   signal bmpcolor_merge    : std_logic_vector(15 downto 0);
   signal extpal_wait       : std_logic;
   signal extpal_merge      : std_logic;

   -- H-mosaic screen grid: MOSTAB0(m, x) is true where x mod (m+1) = 0
   type t_mostab is array (0 to 15, 0 to 255) of boolean;
   function init_mostab return t_mostab is
      variable t : t_mostab;
   begin
      for m in 0 to 15 loop
         for x in 0 to 255 loop
            t(m, x) := (x mod (m + 1)) = 0;
         end loop;
      end loop;
      return t;
   end function;
   constant MOSTAB0 : t_mostab := init_mostab;

   signal mos_prevx         : integer range 0 to 256 := 256;  -- last opaque x (256 = none)
   signal issue_first       : std_logic := '0';
   signal sprfirst_eval     : std_logic := '0';
   signal sprfirst_wait     : std_logic := '0';
   signal mosaik_merge      : std_logic;

   signal PALETTE_addrlow   : std_logic;
   signal EXTPAL_addrlow    : std_logic;

   -- Runaway guard, in OUR clock cycles. This is not the hardware budget -
   -- it only exists so a pathological line cannot render forever; the real
   -- limit is hwtime below.
   signal pixeltime         : integer range 0 to 8191;
   signal maxpixeltime      : integer range 0 to 8191;

   -- The hardware OBJ budget, in HARDWARE cycles (see the generic).
   signal hwtime            : integer range 0 to 2047 := 0;
   signal maxhwtime         : integer range 0 to 2047 := 1210;
   -- field pixels clipped off the RIGHT edge, charged to the budget when the
   -- walk ends rather than at setup - see the screen-clip block
   signal hw_tail           : integer range 0 to 256 := 0;
   signal hw_over           : std_logic;

   -- Why the walk did not advance this cycle, for the profiler below. Driven
   -- unconditionally but read only from a translate_off process, so synthesis
   -- prunes it - no pragma around the walk itself, which is where this file
   -- already carries one risky translate_off too many.
   --   0 advanced   1 affine sum stage busy   2 pixel queue full
   --   3 word queue full   4 request not yet accepted
   signal dbg_stall_why     : integer range 0 to 4 := 0;
   signal time_up           : std_logic;
   signal settings_go       : std_logic;

begin

   hw_over <= '1' when (HW_TIME_LIMIT = '1' and hwtime >= maxhwtime) else '0';
   time_up <= '1' when (pixeltime >= maxpixeltime or hw_over = '1') else '0';

   -- The OAM walk hands a sprite to the pixel walk. BOTH sides must agree on
   -- the cycle it happens, so it is one condition, used twice.
   --
   -- v1 let the OAM side leave DONE on `PIXELGen = WAITOAM` alone, which was
   -- safe only because the pixel side took the sprite unconditionally in that
   -- same cycle. It no longer does - it also waits for the pixel queue to
   -- drain - so the two could disagree, and the OAM side would step to the
   -- next sprite while the pixel side was still waiting: the sprite in between
   -- was silently dropped. That showed up as every MULTI-sprite test case
   -- losing its later sprites.
   -- No pq_cnt term: a queued pixel carries its own sprite's settings (see
   -- t_pq_set), so the next sprite may start walking while the previous one is
   -- still draining. Waiting for the queue to empty here was costing 390-655
   -- cycles per line - 20-34% of the drawer's own time - with the walk idle
   -- throughout. The pixel pipeline stays correct across the boundary because
   -- every sprite's first pixel is tagged `first`, which the mosaic block in
   -- the merge stage already uses to restart, so no gap between sprites is
   -- required.
   settings_go <= '1' when (OAMFetch = DONE and PIXELGen = WAITOAM)
                  else '0';

   -- the settings stamped into each queue entry as the walk pushes it
   cur_set <= (prio    => Pixel_data2(OAM_PRIO_HI downto OAM_PRIO_LO),
               mode    => Pixel_data0(OAM_MODE_HI downto OAM_MODE_LO),
               hicolor => Pixel_data0(OAM_HICOLOR),
               affine  => Pixel_data0(OAM_AFFINE),
               hflip   => Pixel_data1(OAM_HFLIP),
               palette => Pixel_data2(OAM_PALETTE_HI downto OAM_PALETTE_LO),
               mosaic  => Pixel_data0(OAM_MOSAIC),
               bitmap  => is_bitmap);

   -- pq_cnt matters here: the walk reaches WAITOAM while queued pixels are
   -- still draining, and a line that reports itself done early would let the
   -- orchestrator retrigger on top of pixels still in flight
   busy <= '1' when (OAMFetch /= IDLE or PIXELGen /= WAITOAM or pq_cnt /= 0
                     or enable_eval = '1' or enable_wait = '1' or enable_merge = '1'
                     or issue_pixel = '1') else '0';

   VRAM_Drawer_addr    <= to_integer(req_word);
   PALETTE_Drawer_addr <= to_integer(unsigned(PALETTE_byteaddr(8 downto 2)));
   EXTPAL_Drawer_addr  <= to_integer(unsigned(EXTPAL_byteaddr(12 downto 2)));

   -- One address, always: the sprite the scan is running ahead to. Nothing
   -- else reads this port any more.
   OAMRAM_Drawer_addr <= OAM_scanptr;

   -- The affine group of whatever entry is ON THE DATA BUS this cycle, taken
   -- live rather than from OAM_data1 - the shadow read is registered, so
   -- presenting it a cycle earlier is what makes WAITAFF a single cycle
   -- instead of two. During WAITAFF and DONE this follows the scan-ahead
   -- entry instead, which is harmless: WAITAFF has already latched.
   OAMAFF_Drawer_addr <= to_integer(unsigned(OAMRAM_Drawer_data(16 + OAM_AFF_HI downto 16 + OAM_AFF_LO)));

   OAM_sizeX <=  8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- square size 0
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- square size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- square size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- square size 3
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Hor size 0
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Hor size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Hor size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Hor size 3
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Vert size 0
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Vert size 1
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Vert size 2
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Vert size 3
                 8;

   OAM_sizeY <=  8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- square size 0
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- square size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- square size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- square size 3
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Hor size 0
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Hor size 1
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Hor size 2
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Hor size 3
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Vert size 0
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Vert size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Vert size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Vert size 3
                 8;

   OAM_sizeX2 <= 2 * OAM_sizeX when (OAMRAM_Drawer_data(OAM_AFFINE) = '1' and OAMRAM_Drawer_data(OAM_DBLSIZE) = '1') else OAM_sizeX;
   OAM_sizeY2 <= 2 * OAM_sizeY when (OAMRAM_Drawer_data(OAM_AFFINE) = '1' and OAMRAM_Drawer_data(OAM_DBLSIZE) = '1') else OAM_sizeY;

   OAM_posy <= to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO))) - 16#100# when (to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO))) > (16#100# - OAM_sizeY2)) else
               to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO)));

   OAM_posyMos <= ypos_mosaic - OAM_posy when (OAMRAM_Drawer_data(OAM_MOSAIC) = '1') else ypos - OAM_posy;

   OAM_isbitmap <= '1' when (OAMRAM_Drawer_data(OAM_MODE_HI downto OAM_MODE_LO) = "11") else '0';

   -- attr0/attr1 keep their old bit positions in the widened read, so every
   -- expression using them is untouched; only attr2 moved, and it gets a name
   -- rather than a +32 on each of its constants.
   OAM_attr2 <= OAMRAM_Drawer_data(47 downto 32);

   -- OAM Fetch
   process (clk)
   begin
      if rising_edge(clk) then

         -- hblankfree costs OBJ the H-Blank interval, so it gets LESS time,
         -- not more. Same direction as the runaway guard beside it, which is
         -- the donor's 954/1210 pair scaled up.
         --
         -- POLARITY, VERIFIED 2026-08-16 against GBATEK. The NDS's DISPCNT.23
         -- is "OBJ Processing during H-Blank (was located in Bit5 on GBA)":
         -- SET = the OBJ engine gets the HBlank interval = 1210 cycles, and
         -- CLEAR = only the visible part = 954. That reads the other way
         -- round from the GBA's bit 5 "H-Blank Interval Free" (SET = the CPU
         -- takes the interval = 954), which is the meaning this port kept
         -- from the donor - so the integration feeds `not DISPCNT.23` into
         -- it (nds_gpu2d.vhd). melonDS models neither budget.
         if (hblankfree = '1') then
            maxpixeltime <= 6400;
            maxhwtime    <= 954;
         else
            maxpixeltime <= 8191;
            maxhwtime    <= 1210;
         end if;

         case (OAMFetch) is

            when IDLE =>
               OAM_currentobj     <= 0;
               OAM_scanptr        <= 0;
               if (drawline = '1') then
                  OAMFetch           <= WAITFIRST;
                  -- sprite 0's address went out during IDLE, so the scan is
                  -- already one ahead when WAITFIRST consumes it
                  OAM_scanptr        <= 1;
                  output_ok          <= '1';
                  overdraw           <= '0';
               end if;

            when WAITFIRST =>
               -- the whole entry lands at once: no second read, so attr2 and
               -- everything derived from it are available here too
               OAM_data0 <= OAMRAM_Drawer_data(15 downto 0);
               OAM_data1 <= OAMRAM_Drawer_data(31 downto 16);
               OAM_data2 <= OAMRAM_Drawer_data(47 downto 32);

               OAMfetch_sizeX    <= OAM_sizeX;
               OAMfetch_sizeY    <= OAM_sizeY;
               OAMfetch_fieldX   <= OAM_sizeX2;
               OAMfetch_fieldY   <= OAM_sizeY2;

               if (OAM_isbitmap = '1') then
                  if (bitmap_1d = '1') then
                     OAMfetch_sizemult <= OAM_sizeX * 2;          -- bytes per bitmap row
                  elsif (bitmap_2d_wide = '1') then
                     OAMfetch_sizemult <= 512;
                  else
                     OAMfetch_sizemult <= 256;
                  end if;
               elsif (OAMRAM_Drawer_data(OAM_HICOLOR) = '0') then
                  OAMfetch_sizemult <= OAM_sizeX * 4;
               else
                  OAMfetch_sizemult <= OAM_sizeX * 8;
               end if;

               if (OAMRAM_Drawer_data(OAM_HICOLOR) = '0') then
                  OAMfetch_x_flip_offset <= 3;
                  OAMfetch_y_flip_offset <= 28;
                  OAMfetch_x_size        <= 4;
               else
                  OAMfetch_x_flip_offset <= 7;
                  OAMfetch_y_flip_offset <= 56;
                  OAMfetch_x_size        <= 8;
               end if;

               -- char/bitmap base address (byte, in the 256 KB OBJ space).
               -- Was computed in WAITSECOND off the second read; attr2 is here
               -- now, so it is computed here.
               if (OAMRAM_Drawer_data(OAM_MODE_HI downto OAM_MODE_LO) = "11") then
                  if (bitmap_1d = '1') then
                     if (bitmap_1d_boundary = '1') then
                        OAMfetch_addrbase <= 256 * to_integer(unsigned(OAM_attr2(OAM_TILE_HI downto OAM_TILE_LO)));
                     else
                        OAMfetch_addrbase <= 128 * to_integer(unsigned(OAM_attr2(OAM_TILE_HI downto OAM_TILE_LO)));
                     end if;
                  elsif (bitmap_2d_wide = '1') then
                     OAMfetch_addrbase <= 16 * to_integer(unsigned(OAM_attr2(OAM_TILE_LO + 4 downto OAM_TILE_LO)))
                                        + 128 * (to_integer(unsigned(OAM_attr2(OAM_TILE_HI downto OAM_TILE_LO + 5))) * 32);
                  else
                     OAMfetch_addrbase <= 16 * to_integer(unsigned(OAM_attr2(OAM_TILE_LO + 3 downto OAM_TILE_LO)))
                                        + 128 * (to_integer(unsigned(OAM_attr2(OAM_TILE_HI downto OAM_TILE_LO + 4))) * 16);
                  end if;
               elsif (one_dim_mapping = '1') then
                  OAMfetch_addrbase <= (32 * (2 ** to_integer(tile_boundary))) * to_integer(unsigned(OAM_attr2(OAM_TILE_HI downto OAM_TILE_LO)));
               else
                  OAMfetch_addrbase <= 32 * to_integer(unsigned(OAM_attr2(OAM_TILE_HI downto OAM_TILE_LO)));
               end if;

               -- skip: off-line, disabled, prohibited shape, the reserved
               -- 1D+wide combination, or a bitmap sprite with alpha=0. The
               -- alpha test lived in WAITSECOND and cost such a sprite four
               -- cycles; it is an attr2 field, so it now costs one like every
               -- other skip.
               if (OAM_posyMos < 0 or OAM_posyMos >= OAM_sizeY2
                   or OAMRAM_Drawer_data(OAM_OFF_HI downto OAM_OFF_LO) = "10"
                   or OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "11"
                   or (OAM_isbitmap = '1' and bitmap_1d = '1' and bitmap_2d_wide = '1')
                   or (OAM_isbitmap = '1' and OAM_attr2(OAM_PALETTE_HI downto OAM_PALETTE_LO) = "0000")) then
                  if (OAM_currentobj = 127) then
                     OAMFetch      <= IDLE;
                  else
                     -- STAY here: the next sprite's address is already on the
                     -- bus, so its data lands next cycle and a skipped entry
                     -- costs one cycle instead of two. currentobj follows the
                     -- scan pointer, which is exactly the sprite that data
                     -- will belong to.
                     OAMFetch       <= WAITFIRST;
                     OAM_currentobj <= OAM_scanptr;
                     if (OAM_scanptr < 127) then
                        OAM_scanptr <= OAM_scanptr + 1;
                     end if;
                  end if;
               else
                  OAMfetch_ty <= OAM_posyMos;
                  if (OAMRAM_Drawer_data(OAM_AFFINE) = '1') then
                     -- OAMAFF_Drawer_addr is already presenting this entry's
                     -- group (it is driven off the live bus), so the params
                     -- land next cycle
                     OAMFetch <= WAITAFF;
                  else
                     OAMFetch <= DONE;
                  end if;
               end if;

            when WAITAFF =>
               OAM_data_aff0 <= OAMAFF_Drawer_data(15 downto  0);   -- PA / dx
               OAM_data_aff1 <= OAMAFF_Drawer_data(31 downto 16);   -- PB
               OAM_data_aff2 <= OAMAFF_Drawer_data(47 downto 32);   -- PC / dy
               OAM_data_aff3 <= OAMAFF_Drawer_data(63 downto 48);   -- PD
               OAMFetch      <= DONE;

            when DONE =>
               if (settings_go = '1' or consumeSettings = '1') then
                  if (OAM_currentobj = 127) then
                     OAMFetch      <= IDLE;
                  else
                     -- the scan-ahead address stood untouched through this
                     -- sprite, so the next entry is already on the data bus
                     OAMFetch       <= WAITFIRST;
                     OAM_currentobj <= OAM_scanptr;
                     if (OAM_scanptr < 127) then
                        OAM_scanptr <= OAM_scanptr + 1;
                     end if;
                  end if;
               end if;

         end case;

         if (time_up = '1' and OAMFetch /= IDLE) then
            OAMFetch <= IDLE;
            overdraw <= '1';
         end if;

      end if;
   end process;

   -- Pixelgen
   process (clk)
      variable applyNextSettings : std_logic := '0';
      variable pixeladdr_pre_a0  : integer range -8388608 to 8388607; -- 24 bit
      variable pixeladdr_pre_a1  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a2  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a3  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a4  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a5  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a6  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a7  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_0   : integer range -262144 to 262143;
      variable pixeladdr_pre_1   : integer range -262144 to 262143;
      variable pixeladdr_pre_2   : integer range -262144 to 262143;
      variable pixeladdr_pre_3   : integer range -262144 to 262143;
      variable pixeladdr_pre_4   : integer range -262144 to 262143;
      variable pixeladdr_pre_5   : integer range -262144 to 262143;
      variable pixeladdr_pre_6   : integer range -262144 to 262143;
      variable pixeladdr_pre_7   : integer range -262144 to 262143;
      variable xxx               : integer range 0 to 63;
      variable yyy               : integer range 0 to 63;
      variable pixeladdr_calc    : integer;
      variable skip_var          : std_logic;
      variable v_hw              : integer range 0 to 2047;
      -- AFF_SUM needs the summed address as a value before it can decide whether
      -- to fetch it, so it can no longer assign straight into an address signal
      variable v_affaddr         : integer range 0 to 262143;
      -- queue state, taken into variables so a word can arrive and be consumed
      -- in the same cycle (the text drawer's v_tq pattern)
      variable v_pq    : t_pq;
      variable v_pcnt  : integer range 0 to PQ_DEPTH;
      variable v_phead : integer range 0 to PQ_DEPTH-1;
      variable v_ptail : integer range 0 to PQ_DEPTH-1;
      variable v_wq    : t_wq;
      variable v_wcnt  : integer range 0 to WQ_DEPTH;
      variable v_whead : integer range 0 to WQ_DEPTH-1;
      variable v_wtail : integer range 0 to WQ_DEPTH-1;
      variable v_infl  : integer range 0 to WQ_DEPTH;
      variable v_una   : std_logic;
      variable v_affpend : std_logic;
      variable v_addr  : unsigned(17 downto 0);
      variable v_reuse : boolean;
      variable ent     : t_pq_entry;
      variable v_second : std_logic;
      -- screen clip, all resolved at sprite setup
      variable v_posx   : integer range -512 to 511;
      variable v_xfirst : integer range 0 to 128;   -- first on-screen x
      variable v_xlast  : integer range 0 to 128;   -- one past the last
      variable v_skipn  : integer range 0 to 256;   -- field pixels elided
   begin
      if rising_edge(clk) then

         consumeSettings   <= '0';
         issue_pixel       <= '0';
         VRAM_Drawer_req   <= '0';
         applyNextSettings := '0';

         v_pq    := pq;
         v_pcnt  := pq_cnt;
         v_phead := pq_head;
         v_ptail := pq_tail;
         v_wq    := wq;
         v_wcnt  := wq_cnt;
         v_whead := wq_head;
         v_wtail := wq_tail;
         v_infl  := inflight;
         v_una   := unaccepted;
         v_affpend := aff_pend;

         if (VRAM_Drawer_accept = '1') then
            v_una := '0';
         end if;

         -- a fetched word lands, in issue order
         if (VRAM_Drawer_done = '1') then
            v_wq(v_wtail) := VRAM_Drawer_data;
            v_wtail := (v_wtail + 1) mod WQ_DEPTH;
            v_wcnt  := v_wcnt + 1;
            v_infl  := v_infl - 1;
         end if;

         v_hw := hwtime;

         if (drawline = '1') then
            pixeltime <= 0;
            v_hw      := 0;
         elsif (pixeltime < maxpixeltime) then
            pixeltime <= pixeltime + 1;
         end if;

         -- ------------------------------------------------------------------
         -- AFFINE SUM: queues the pixel whose partial terms were computed last
         -- cycle. Runs BEFORE the walk below on purpose - the walk may then
         -- refill the partial registers in this same cycle, which is what
         -- makes a rot/scal pixel cost one cycle instead of two.
         --
         -- Reading the partial registers here is safe against the walk's
         -- writes: both are in this one clocked process, so the walk's
         -- assignments land at the next edge and this sees the previous
         -- pixel's values.
         -- ------------------------------------------------------------------
         if (v_affpend = '1') then
            if (is_bitmap = '1') then
               v_affaddr := (pixeladdr_base
                              + to_integer(pixeladdr_x_aff0)
                              + to_integer(pixeladdr_x_aff4)) mod 262144;
            elsif (one_dim_mapping = '1') then
               v_affaddr := (pixeladdr_base
                              + to_integer(pixeladdr_x_aff0) + to_integer(pixeladdr_x_aff1)
                              + to_integer(pixeladdr_x_aff4) + to_integer(pixeladdr_x_aff5)) mod 262144;
            else
               v_affaddr := (pixeladdr_base
                              + to_integer(pixeladdr_x_aff2) + to_integer(pixeladdr_x_aff3)
                              + to_integer(pixeladdr_x_aff4) + to_integer(pixeladdr_x_aff5)) mod 262144;
            end if;
            -- Word reuse, same rule as the non-affine path: one fetched word
            -- serves every address sharing bits 17..2, because the lane is
            -- bits 1..0. Rotation just makes consecutive pixels land in
            -- different words, and then this falls back to fetching exactly
            -- as before - never wrong, only less effective.
            v_addr  := to_unsigned(v_affaddr, 18);
            v_reuse := (walk_seen = '1') and
                       (v_addr(17 downto 2) = last_addr(17 downto 2));

            if (v_pcnt < PQ_DEPTH and
                (v_reuse or (v_wcnt + v_infl < WQ_DEPTH and v_una = '0'))) then
               ent := ('0', v_addr(1 downto 0), aff_target, aff_second,
                       not walk_seen, cur_set);
               if (not v_reuse) then
                  ent.newword     := '1';
                  req_word        <= v_addr(17 downto 2);
                  VRAM_Drawer_req <= '1';
                  v_una           := '1';
                  v_infl          := v_infl + 1;
                  last_addr       <= v_addr;
                  walk_seen       <= '1';
               end if;
               v_pq(v_ptail) := ent;
               v_ptail := (v_ptail + 1) mod PQ_DEPTH;
               v_pcnt  := v_pcnt + 1;
               v_affpend := '0';
            end if;
         end if;

         case (PIXELGen) is

            when WAITOAM =>
               -- The next sprite's settings may only be latched once the queue
               -- has drained: the pixel pipeline captures the LIVE Pixel_data*
               -- one cycle after each drain, so a sprite has to stay current
               -- until its last queued pixel has been issued.
               if (settings_go = '1') then
                  PIXELGen          <= NEXTADDR;
                  applyNextSettings := '1';
               end if;

            when NEXTADDR =>
               skip_var  := '0';
               v_second  := '0';
               if ((x + posX) < 256 and (x + posX) >= 0) then
                  target    <= x + posX;
               else
                  skip_var := '1';
               end if;

               pixeladdr_calc := pixeladdr;

               if (Pixel_data0(OAM_AFFINE) = '1') then
                  if (realX < 0 or (realX / 256) >= sizeX or realY < 0 or (realY / 256) >= sizeY) then
                     skip_var := '1';
                  end if;

                  -- synthesis translate_off
                  if (realX >= 0 and (realX / 256) < sizeX and realY >= 0 and (realY / 256) < sizeY) then
                  -- synthesis translate_on

                     xxx := realX / 256;
                     yyy := realY / 256;
                     if (xxx mod 2 = 1) then v_second := '1'; else v_second := '0'; end if;

                     -- ONLY when the sum stage is free. While it still holds a
                     -- pixel - queue full, or flushing at the end of a sprite -
                     -- this state keeps running, and writing here would replace
                     -- the very partial terms it has not summed yet. That
                     -- corrupts the pending pixel, and only for ROTATED
                     -- sprites: with pb/pc = 0 realY is constant along the
                     -- line, so the overwrite is a no-op and pure-scale cases
                     -- pass while rotated ones come out wrong.
                     --
                     -- The in-bounds `if` above cannot stand in for this: it is
                     -- translate_off, i.e. simulation-only, so it guards
                     -- nothing in hardware.
                     if (v_affpend = '0') then

                     if (is_bitmap = '1') then
                        -- bitmap: base + yyy*rowstride + xxx*2
                        pixeladdr_x_aff0 <= to_unsigned(yyy * sizemult, 18);
                        pixeladdr_x_aff1 <= (others => '0');
                        pixeladdr_x_aff2 <= to_unsigned(yyy * sizemult, 18);
                        pixeladdr_x_aff3 <= (others => '0');
                        pixeladdr_x_aff4 <= to_unsigned(xxx * 2, 18);
                        pixeladdr_x_aff5 <= (others => '0');
                     else
                        pixeladdr_x_aff0 <= to_unsigned(((yyy mod 8) * x_size), 18);
                        pixeladdr_x_aff1 <= to_unsigned(((yyy / 8) * sizemult), 18);

                        pixeladdr_x_aff2 <= to_unsigned(((yyy mod 8) * x_size), 18);
                        pixeladdr_x_aff3 <= to_unsigned(((yyy / 8) * 1024), 18);

                        if (Pixel_data0(OAM_HICOLOR) = '0') then
                           pixeladdr_x_aff4 <= to_unsigned((xxx mod 8) / 2, 18);
                           pixeladdr_x_aff5 <= to_unsigned(((xxx / 8) * 32), 18);
                        else
                           pixeladdr_x_aff4 <= to_unsigned(xxx mod 8, 18);
                           pixeladdr_x_aff5 <= to_unsigned(((xxx / 8) * 64), 18);
                        end if;
                     end if;

                     end if;   -- v_affpend = '0'

                  -- synthesis translate_off
                  end if;
                  -- synthesis translate_on
               else

                  if (x mod 2 = 1) then v_second := '1'; else v_second := '0'; end if;

                  if (is_bitmap = '1') then
                     -- bitmap row base is in pixeladdr; hflip mirrors x
                     if (Pixel_data1(OAM_HFLIP) = '1') then
                        pixeladdr_calc := pixeladdr_calc + (sizeX - 1 - x) * 2;
                     else
                        pixeladdr_calc := pixeladdr_calc + x * 2;
                     end if;
                  elsif (Pixel_data1(OAM_HFLIP) = '1') then
                     if (Pixel_data0(OAM_HICOLOR) = '0') then
                        pixeladdr_calc := pixeladdr_calc + (x_flip_offset - ((x mod 8) / 2));
                        pixeladdr_calc := pixeladdr_calc - (((x / 8) - ((sizeX / 8) - 1)) * 32);
                     else
                        pixeladdr_calc := pixeladdr_calc + (x_flip_offset - (x mod 8));
                        pixeladdr_calc := pixeladdr_calc - (((x / 8) - ((sizeX / 8) - 1)) * 64);
                     end if;
                  else
                     if (Pixel_data0(OAM_HICOLOR) = '0') then
                        pixeladdr_calc := pixeladdr_calc + ((x mod 8) / 2);
                        pixeladdr_calc := pixeladdr_calc + ((x / 8) * 32);
                     else
                        pixeladdr_calc := pixeladdr_calc + (x mod 8);
                        pixeladdr_calc := pixeladdr_calc + ((x / 8) * 64);
                     end if;
                  end if;

               end if;

               second_pix <= v_second;

               -- hardware charges one cycle per field pixel walked, two for a
               -- rot/scal sprite. Charged where x advances, so a walk stalled
               -- for queue room is not charged twice. The field pixels the
               -- screen clip removed from the walk entirely are charged at
               -- setup (leading) and here on exit (trailing), so the budget
               -- still sees the sprite's whole field width - the cost to
               -- hardware is the field width, not what landed on screen.
               -- A pending affine sum must be queued before the sprite ends -
               -- leaving NEXTADDR would let the next sprite's walk overwrite
               -- the partial registers it is still holding, dropping its last
               -- pixel. The sum block above clears it, so this is at most a
               -- one-cycle wait per sprite.
               if (time_up = '1' and v_affpend = '0') then
                  PIXELGen <= WAITOAM;
               elsif (x >= fieldX and v_affpend = '0') then
                  -- the sprite ran to its clipped end: settle the field pixels
                  -- past the right edge that the clip elided, so the hardware
                  -- budget still sees the full field width and sees it at the
                  -- point hardware would have charged it
                  if (v_hw + hw_tail > 2047) then
                     v_hw := 2047;
                  else
                     v_hw := v_hw + hw_tail;
                  end if;
                  PIXELGen <= WAITOAM;
               elsif (time_up = '1' or x >= fieldX) then
                  null;                       -- flushing the last affine pixel
                  dbg_stall_why <= 1;
               elsif (skip_var = '1') then
                  -- nothing to fetch or draw; last_addr keeps the last queued
                  -- word so the reuse compare stays truthful
                  realX <= realX + dx;
                  realY <= realY + dy;
                  x     <= x + 1;
                  if (v_hw <= 2046) then v_hw := v_hw + 1; end if;
                  PIXELGen <= NEXTADDR;
               elsif (Pixel_data0(OAM_AFFINE) = '1') then
                  -- Hand this pixel's partial terms (already assigned above)
                  -- to the sum stage and keep walking. Only when the stage is
                  -- free: while it still holds a pixel, advancing would
                  -- overwrite the registers it has not summed yet.
                  if (v_affpend = '0') then
                     aff_target <= x + posX;
                     aff_second <= v_second;
                     v_affpend  := '1';
                     realX <= realX + dx;
                     realY <= realY + dy;
                     x     <= x + 1;
                     if (v_hw <= 2045) then v_hw := v_hw + 2; end if;
                  else
                     dbg_stall_why <= 1;
                  end if;
                  PIXELGen <= NEXTADDR;
               else
                  v_addr  := to_unsigned(pixeladdr_calc mod 262144, 18);
                  v_reuse := (walk_seen = '1') and
                             (v_addr(17 downto 2) = last_addr(17 downto 2));

                  -- room to queue the pixel, and - if it needs a word of its
                  -- own - a free slot to land it in and a channel ready to
                  -- take the request
                  if (v_pcnt < PQ_DEPTH and
                      (v_reuse or (v_wcnt + v_infl < WQ_DEPTH and v_una = '0'))) then
                     ent := ('0', v_addr(1 downto 0), x + posX, v_second,
                             not walk_seen, cur_set);
                     if (not v_reuse) then
                        ent.newword     := '1';
                        req_word        <= v_addr(17 downto 2);
                        VRAM_Drawer_req <= '1';
                        v_una           := '1';
                        v_infl          := v_infl + 1;
                        last_addr       <= v_addr;
                        walk_seen       <= '1';
                     end if;
                     v_pq(v_ptail) := ent;
                     v_ptail := (v_ptail + 1) mod PQ_DEPTH;
                     v_pcnt  := v_pcnt + 1;

                     realX <= realX + dx;
                     realY <= realY + dy;
                     x     <= x + 1;
                     if (v_hw <= 2046) then v_hw := v_hw + 1; end if;
                  else
                     if (v_pcnt >= PQ_DEPTH) then
                        dbg_stall_why <= 2;
                     elsif (v_una = '1') then
                        dbg_stall_why <= 4;
                     else
                        dbg_stall_why <= 3;
                     end if;
                  end if;
                  -- no room: hold x, realX/realY and the state, and retry
                  PIXELGen <= NEXTADDR;
               end if;

         end case;

         -- ------------------------------------------------------------------
         -- DRAIN: one queued pixel per cycle into the pixel pipeline. A pixel
         -- tagged newword waits for its word; a reuse pixel goes immediately,
         -- because drain_word still holds the word it shares.
         -- ------------------------------------------------------------------
         if (v_pcnt > 0) then
            ent := v_pq(v_phead);
            if (ent.newword = '0' or v_wcnt > 0) then
               if (ent.newword = '1') then
                  drain_word <= v_wq(v_whead);
                  v_whead := (v_whead + 1) mod WQ_DEPTH;
                  v_wcnt  := v_wcnt - 1;
               end if;
               issue_pixel  <= '1';
               issue_first  <= ent.first;
               issue_lane   <= ent.lane;
               issue_target <= ent.target;
               issue_second <= ent.second;
               issue_set    <= ent.set;
               v_phead := (v_phead + 1) mod PQ_DEPTH;
               v_pcnt  := v_pcnt - 1;
            end if;
         end if;

         if (applyNextSettings = '1') then
            consumeSettings <= '1';

            -- rot/scal setup: 10 hardware cycles before the first pixel
            if (OAM_data0(OAM_AFFINE) = '1' and v_hw <= 2037) then
               v_hw := v_hw + 10;
            end if;

            walk_seen  <= '0';

            Pixel_data0     <= OAM_data0;
            Pixel_data1     <= OAM_data1;
            Pixel_data2     <= OAM_data2;
            dx              <= to_integer(signed(OAM_data_aff0));
            dy              <= to_integer(signed(OAM_data_aff2));

            -- if/else, not a conditional assignment: Quartus 17's VHDL-2008
            -- subset rejects those in sequential code
            if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11") then
               is_bitmap <= '1';
            else
               is_bitmap <= '0';
            end if;

            if (unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO)) > 16#100#) then
               v_posx := to_integer(unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO))) - 16#200#;
            else
               v_posx := to_integer(unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO)));
            end if;
            posx <= v_posx;

            -- ---------------------------------------------------------------
            -- SCREEN CLIP
            -- ---------------------------------------------------------------
            -- The walk used to start at x=0 and run the sprite's whole field
            -- width, testing each pixel against the 0..255 screen and burning
            -- a cycle on every one that fell outside. On the frame bench's
            -- busiest line that was the single largest thing the drawer did:
            --   walk=422  px=79  edge=286  oob=19  stall=38
            -- 68% of the walk spent stepping over pixels that were never going
            -- to be drawn, against 19% doing the work.
            --
            -- Both ends are closed-form - the first and last on-screen x are
            -- pure arithmetic on posx - so they are computed once here and the
            -- walk simply starts and stops there. A sprite entirely off either
            -- side collapses to first = last and exits on its first cycle.
            --
            -- This is a clip on OUR cycles only. Hardware charges a sprite its
            -- whole field width whether or not it lands on screen, so the
            -- elided pixels are still charged to hwtime below, in one go -
            -- otherwise HW_TIME_LIMIT would start keeping sprites the console
            -- drops, and the golden models do not model truncation, so that
            -- divergence would be silent.
            -- clamp BEFORE the assignment, not after: posx reaches -255, so
            -- -posx does not fit v_xfirst's range on its own
            if (v_posx < 0) then
               if (-v_posx > OAMfetch_fieldX) then
                  v_xfirst := OAMfetch_fieldX;      -- entirely off the left
               else
                  v_xfirst := -v_posx;
               end if;
            else
               v_xfirst := 0;
            end if;

            if (v_posx + OAMfetch_fieldX > 256) then
               if (v_posx >= 256) then
                  v_xlast := v_xfirst;              -- entirely off the right
               else
                  v_xlast := 256 - v_posx;
               end if;
            else
               v_xlast := OAMfetch_fieldX;
            end if;
            if (v_xlast < v_xfirst) then
               v_xlast := v_xfirst;
            end if;

            x      <= v_xfirst;
            sizeX  <= OAMfetch_sizeX;
            sizeY  <= OAMfetch_sizeY;
            fieldX <= v_xlast;

            -- The field pixels the walk will never visit still cost hardware,
            -- so they are charged to the budget - but WHEN matters, not just
            -- how much. Hardware charges the leading run before it draws
            -- anything and the trailing run after, so charging both up front
            -- would trip HW_TIME_LIMIT early and drop sprites the console
            -- finishes. The leading run is charged here; the trailing run is
            -- held and charged when the walk ends.
            v_skipn := v_xfirst;
            if (OAM_data0(OAM_AFFINE) = '1') then
               v_skipn := v_skipn * 2;              -- rot/scal costs 2 each
            end if;
            if (v_hw + v_skipn > 2047) then
               v_hw := 2047;
            else
               v_hw := v_hw + v_skipn;
            end if;

            if (OAM_data0(OAM_AFFINE) = '1') then
               hw_tail <= (OAMfetch_fieldX - v_xlast) * 2;
            else
               hw_tail <= OAMfetch_fieldX - v_xlast;
            end if;

            sizemult      <= OAMfetch_sizemult;
            x_flip_offset <= OAMfetch_x_flip_offset;
            x_size        <= OAMfetch_x_size;

            pixeladdr_base <= OAMfetch_addrbase;

            -- affine
            pixeladdr_pre_a0 := OAMfetch_sizeX * 128;
            pixeladdr_pre_a1 := (OAMfetch_fieldX / 2) * to_integer(signed(OAM_data_aff0));
            pixeladdr_pre_a2 := (OAMfetch_fieldY / 2) * to_integer(signed(OAM_data_aff1));
            pixeladdr_pre_a3 := OAMfetch_ty * to_integer(signed(OAM_data_aff1));
            pixeladdr_pre_a4 := OAMfetch_sizeY * 128;
            pixeladdr_pre_a5 := (OAMfetch_fieldX / 2) * to_integer(signed(OAM_data_aff2));
            pixeladdr_pre_a6 := (OAMfetch_fieldY / 2) * to_integer(signed(OAM_data_aff3));
            pixeladdr_pre_a7 := OAMfetch_ty * to_integer(signed(OAM_data_aff3));

            -- non affine, tile sprites
            pixeladdr_pre_0 := (OAMfetch_y_flip_offset - (OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_1 := ((((OAMfetch_sizeY / 8) - 1) - (OAMfetch_ty / 8)) * OAMfetch_sizemult);
            pixeladdr_pre_2 := (OAMfetch_y_flip_offset - (OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_3 := ((((OAMfetch_sizeY / 8) - 1) - (OAMfetch_ty / 8)) * 1024);
            pixeladdr_pre_4 := ((OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_5 := ((OAMfetch_ty / 8) * OAMfetch_sizemult);
            pixeladdr_pre_6 := ((OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_7 := ((OAMfetch_ty / 8) * 1024);

            -- affine. The non-affine walk recomputes its address from x every
            -- pixel, so the clip costs it nothing; realX/realY are the one
            -- piece of walk state that ACCUMULATES, so starting at v_xfirst
            -- means stepping them there too. v_xfirst is 0..128, so these are
            -- two small multiplies beside the four this block already does.
            realX <= (pixeladdr_pre_a0 - pixeladdr_pre_a1 - pixeladdr_pre_a2 + pixeladdr_pre_a3)
                     + v_xfirst * to_integer(signed(OAM_data_aff0));
            realY <= (pixeladdr_pre_a4 - pixeladdr_pre_a5 - pixeladdr_pre_a6 + pixeladdr_pre_a7)
                     + v_xfirst * to_integer(signed(OAM_data_aff2));

            -- non affine
            if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11") then
               -- bitmap row base (vflip mirrors the row)
               if (OAM_data1(OAM_VFLIP) = '1') then
                  pixeladdr <= OAMfetch_addrbase + (OAMfetch_sizeY - 1 - OAMfetch_ty) * OAMfetch_sizemult;
               else
                  pixeladdr <= OAMfetch_addrbase + OAMfetch_ty * OAMfetch_sizemult;
               end if;
            elsif (OAM_data1(OAM_VFLIP) = '1') then
               if (one_dim_mapping = '1') then
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_0 + pixeladdr_pre_1;
               else
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_2 + pixeladdr_pre_3;
               end if;
            else
               if (one_dim_mapping = '1') then
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_4 + pixeladdr_pre_5;
               else
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_6 + pixeladdr_pre_7;
               end if;
            end if;
         end if;

         hwtime <= v_hw;

         pq         <= v_pq;
         pq_head    <= v_phead;
         pq_tail    <= v_ptail;
         pq_cnt     <= v_pcnt;
         wq         <= v_wq;
         wq_head    <= v_whead;
         wq_tail    <= v_wtail;
         wq_cnt     <= v_wcnt;
         inflight   <= v_infl;
         unaccepted <= v_una;
         aff_pend   <= v_affpend;

      end if;
   end process;

   -- Pixel Pipeline
   process (clk)
      variable colorbyte             : std_logic_vector(7 downto 0);
      variable colorword             : std_logic_vector(15 downto 0);
      variable colordata             : std_logic_vector(3 downto 0);
      variable VRAM_Drawer_dataMuxed : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then

         if (drawline = '1') then
            pixelarray <= (others => ('1', "11", '0', '0'));
         end if;

         -- first cycle - take everything the drain published with the pixel.
         -- The WORD travels here too: it can no longer be read out of a single
         -- "last fetched" register, because the drain may publish the next
         -- pixel's word before this one has been consumed.
         enable_eval       <= issue_pixel;
         sprfirst_eval     <= issue_first;
         readaddr_mux_eval <= issue_lane;
         target_eval       <= issue_target;
         second_pix_eval   <= issue_second;
         word_eval         <= drain_word;

         -- ...including which sprite it came from. Reading these off the live
         -- Pixel_data* registers was what forced the drain to finish before
         -- the next sprite could be latched.
         prio_eval       <= issue_set.prio;
         mode_eval       <= issue_set.mode;
         hicolor_eval    <= issue_set.hicolor;
         affine_eval     <= issue_set.affine;
         hflip_eval      <= issue_set.hflip;
         palette_eval    <= issue_set.palette;
         mosaic_eval     <= issue_set.mosaic;
         bitmap_eval     <= issue_set.bitmap;

         -- second cycle - eval vram
         target_wait   <= target_eval;
         enable_wait   <= enable_eval;
         sprfirst_wait <= sprfirst_eval;
         mosaic_wait   <= mosaic_eval;
         bitmap_wait   <= bitmap_eval;
         bmpalpha_wait <= palette_eval;
         extpal_wait   <= hicolor_eval and obj_extpal;

         Pixel_wait.prio        <= prio_eval;
         if (mode_eval = "01") then Pixel_wait.alpha  <= '1'; else Pixel_wait.alpha  <= '0'; end if;
         if (mode_eval = "10") then Pixel_wait.objwnd <= '1'; else Pixel_wait.objwnd <= '0'; end if;

         VRAM_Drawer_dataMuxed := word_eval;

         case (readaddr_mux_eval(1 downto 0)) is
            when "00" => colorbyte := VRAM_Drawer_dataMuxed(7  downto 0);
            when "01" => colorbyte := VRAM_Drawer_dataMuxed(15 downto 8);
            when "10" => colorbyte := VRAM_Drawer_dataMuxed(23 downto 16);
            when "11" => colorbyte := VRAM_Drawer_dataMuxed(31 downto 24);
            when others => null;
         end case;

         if (readaddr_mux_eval(1) = '1') then
            colorword := VRAM_Drawer_dataMuxed(31 downto 16);
         else
            colorword := VRAM_Drawer_dataMuxed(15 downto 0);
         end if;

         if (enable_eval = '1') then
            if (bitmap_eval = '1') then
               bmpcolor_wait <= colorword;
               Pixel_wait.transparent <= not colorword(15);
            elsif (hicolor_eval = '0') then
               if (affine_eval = '1') then
                  if (second_pix_eval = '1') then
                     colordata := colorbyte(7 downto 4);
                  else
                     colordata := colorbyte(3 downto 0);
                  end if;
               else
                  if ((hflip_eval = '1' and second_pix_eval = '0') or (hflip_eval = '0' and second_pix_eval = '1')) then
                     colordata := colorbyte(7 downto 4);
                  else
                     colordata := colorbyte(3 downto 0);
                  end if;
               end if;

               if (colordata = x"0") then Pixel_wait.transparent <= '1'; else Pixel_wait.transparent <= '0'; end if;

               PALETTE_byteaddr <= palette_eval & colordata & '0';

            else

               if (colorbyte = x"00") then Pixel_wait.transparent <= '1'; else Pixel_wait.transparent <= '0'; end if;

               PALETTE_byteaddr <= colorbyte & '0';
               EXTPAL_byteaddr  <= palette_eval & colorbyte & '0';

            end if;
         end if;

         -- third cycle - wait palette + mosaic
         enable_merge    <= enable_wait;
         target_merge    <= target_wait;
         Pixel_readback  <= pixelarray(target_wait);
         PALETTE_addrlow <= PALETTE_byteaddr(1);
         EXTPAL_addrlow  <= EXTPAL_byteaddr(1);
         bitmap_merge    <= bitmap_wait;
         bmpalpha_merge  <= bmpalpha_wait;
         bmpcolor_merge  <= bmpcolor_wait;
         extpal_merge    <= extpal_wait;

         mosaik_merge <= '0';
         if (drawline = '1') then
            mos_prevx <= 256;
         end if;
         if (enable_wait = '1') then
            -- repeat needs: mosaic sprite, opaque pixel, not the sprite's
            -- first emitted pixel, not on the screen-aligned grid restart,
            -- and the previous screen pixel opaque from this sprite
            -- (melonDS objIndex continuity - a transparency hole stays a
            -- hole, restarts the block, and still claims settings like any
            -- transparent pixel)
            if (mosaic_wait = '1' and sprfirst_wait = '0' and
                Pixel_wait.transparent = '0' and
                mos_prevx = target_wait - 1 and
                not MOSTAB0(to_integer(Mosaic_H_Size), target_wait)) then
               mosaik_merge <= '1';      -- repeat the last fresh pixel
               mos_prevx    <= target_wait;
            else
               Pixel_merge <= Pixel_wait;
               if (Pixel_wait.transparent = '0') then
                  mos_prevx <= target_wait;
               else
                  mos_prevx <= 256;
               end if;
            end if;
         end if;

         -- fourth cycle
         pixel_we_color    <= '0';
         pixel_we_settings <= '0';
         pixel_objwnd      <= '0';
         pixel_x           <= target_merge;

         if (enable_merge = '1' and mosaik_merge = '0') then
            if (bitmap_merge = '1') then
               pixeldata_color <= '0' & bmpcolor_merge(14 downto 0);
            elsif (extpal_merge = '1') then
               if (EXTPAL_addrlow = '1') then
                  pixeldata_color <= '0' & EXTPAL_Drawer_data(30 downto 16);
               else
                  pixeldata_color <= '0' & EXTPAL_Drawer_data(14 downto 0);
               end if;
            elsif (PALETTE_addrlow = '1') then
               pixeldata_color <= '0' & PALETTE_Drawer_data(30 downto 16);
            else
               pixeldata_color <= '0' & PALETTE_Drawer_data(14 downto 0);
            end if;
            if (bitmap_merge = '1') then
               pixeldata_settings <= bmpalpha_merge & '1' & Pixel_merge.alpha & Pixel_merge.prio;
            else
               pixeldata_settings <= "0000" & '0' & Pixel_merge.alpha & Pixel_merge.prio;
            end if;
         end if;

         if (enable_merge = '1' and output_ok = '1') then

            if (Pixel_merge.transparent = '0' and Pixel_merge.objwnd = '1') then
               pixel_objwnd <= '1';
            end if;

            if (Pixel_merge.objwnd = '0') then
               if (Pixel_readback.transparent = '1' or unsigned(Pixel_merge.prio) < unsigned(Pixel_readback.prio)) then
                  pixel_we_settings             <= '1';
                  pixelarray(target_merge).prio <= Pixel_merge.prio;
                  if (Pixel_merge.transparent = '0') then
                     pixel_we_color                       <= '1';
                     pixelarray(target_merge).transparent <= '0';
                  end if;
               end if;
            end if;

         end if;

      end if;
   end process;

   -- synthesis translate_off
   -- ==========================================================================
   -- PER-LINE PHASE BREAKDOWN (simulation only)
   -- ==========================================================================
   -- The frame profile reports one number, "obj=2000 of a 2130 budget", which
   -- says the drawer is over but not WHERE. This splits the drawer's own busy
   -- time into the four things it can be doing, so the next optimisation is
   -- aimed by measurement rather than by inspection of the state machine.
   --
   --   fetch     - the OAM state machine is reading OAM (overlaps walk)
   --   walk      - the pixel walk is producing addresses (the useful work)
   --   drainwait - walk finished, waiting for the queue to empty before the
   --               next sprite's settings may be applied (settings_go's
   --               pq_cnt = 0 term). This is the per-sprite bubble.
   --   oamwait   - walk idle with an empty queue, waiting for OAM to deliver
   --               the next sprite
   --
   -- fetch overlaps walk by design, so the four do not sum to total.
   --
   -- The walk is then split again, because "walk" being the biggest number
   -- does not say whether the walk is DOING anything. Every walk cycle is one
   -- of three things, and only the first is work:
   --
   --   px      - a pixel was queued (advanced x AND pushed onto the queue)
   --   edge    - advanced but queued nothing because x+posX left the 0..255
   --             screen. This is what motivated the screen clip and it should
   --             now read ZERO on every line: the clip means the walk never
   --             visits an off-screen x at all. Left in place as the clip's
   --             tripwire - if it comes back non-zero, the clip is wrong.
   --   oob     - advanced but queued nothing because a rot/scal pixel mapped
   --             outside its source sprite. Not closed-form under rotation.
   --
   -- Both are charged a full cycle per pixel because a sprite's cost is its
   -- FIELD width, not what landed on screen.
   --   stall   - did not advance at all: no queue room, or the affine sum
   --             stage still holding the previous pixel.
   --
   -- Derived from existing signals rather than new ones so the walk itself
   -- stays untouched: advances are x changing, and every queued pixel is
   -- drained exactly once, so issue_pixel counts them.
   p_objprof : process (clk)
      variable c_fetch : integer := 0;
      variable c_walk  : integer := 0;
      variable c_drain : integer := 0;
      variable c_oam   : integer := 0;
      variable n_spr   : integer := 0;
      variable n_aff   : integer := 0;
      variable tot     : integer := 0;
      variable y_line  : integer := 0;
      variable started : boolean := false;
      variable prev_fetch : t_OAMFetch := IDLE;
      variable c_adv   : integer := 0;   -- walk cycles that advanced x
      variable c_iss   : integer := 0;   -- pixels actually queued
      variable c_edge  : integer := 0;   -- of the advances, off-screen ones
      variable c_lead  : integer := 0;   -- of those, off the LEFT edge
      variable c_saff  : integer := 0;   -- stalls: affine sum stage busy
      variable c_spq   : integer := 0;   -- stalls: pixel queue full
      variable c_swq   : integer := 0;   -- stalls: word queue full
      variable c_sacc  : integer := 0;   -- stalls: request not accepted
      -- the drain's own stall: a pixel is queued, it needs a fetched word,
      -- and no word has landed. This is what backs the queue up into pqfull.
      variable c_wordwait : integer := 0;
      variable prev_x  : integer := 0;
   begin
      if rising_edge(clk) then

         if (drawline = '1') then
            if (started and y_line < 8) then
               report "OBJPROF y=" & integer'image(y_line) &
                      " total=" & integer'image(tot) &
                      " fetch=" & integer'image(c_fetch) &
                      " walk=" & integer'image(c_walk) &
                      " drainwait=" & integer'image(c_drain) &
                      " oamwait=" & integer'image(c_oam) &
                      " sprites=" & integer'image(n_spr) &
                      " affine=" & integer'image(n_aff) &
                      " | px=" & integer'image(c_iss) &
                      " edge=" & integer'image(c_edge) &
                      " (lead=" & integer'image(c_lead) &
                      " trail=" & integer'image(c_edge - c_lead) & ")" &
                      " oob=" & integer'image(c_adv - c_iss - c_edge) &
                      " stall=" & integer'image(c_walk - c_adv) &
                      " (affsum=" & integer'image(c_saff) &
                      " pqfull=" & integer'image(c_spq) &
                      " wqfull=" & integer'image(c_swq) &
                      " unacc=" & integer'image(c_sacc) & ")" &
                      " wordwait=" & integer'image(c_wordwait);
            end if;
            c_fetch := 0; c_walk := 0; c_drain := 0; c_oam := 0;
            n_spr   := 0; n_aff  := 0; tot     := 0;
            c_adv   := 0; c_iss  := 0; c_edge := 0; c_lead := 0;
            c_saff  := 0; c_spq  := 0; c_swq  := 0; c_sacc := 0;
            c_wordwait := 0;
            y_line  := ypos;
            started := true;
         end if;

         if (OAMFetch /= IDLE or PIXELGen /= WAITOAM or pq_cnt /= 0) then
            tot := tot + 1;
         end if;

         if (PIXELGen = NEXTADDR) then
            c_walk := c_walk + 1;
            -- x+1, not x/=prev_x: the per-sprite reset to 0 also changes x,
            -- and it happens in WAITOAM, so it would read as an advance
            if (x /= prev_x + 1) then
               -- a stall: dbg_stall_why was set by the walk in this same cycle
               case (dbg_stall_why) is
                  when 1      => c_saff := c_saff + 1;
                  when 2      => c_spq  := c_spq  + 1;
                  when 3      => c_swq  := c_swq  + 1;
                  when 4      => c_sacc := c_sacc + 1;
                  when others => null;
               end case;
            end if;
            if (x = prev_x + 1) then
               c_adv := c_adv + 1;
               -- same test the walk itself makes, one cycle later, so it
               -- classifies the advance that just happened
               if ((prev_x + posx) < 0 or (prev_x + posx) > 255) then
                  c_edge := c_edge + 1;
                  if ((prev_x + posx) < 0) then c_lead := c_lead + 1; end if;
               end if;
            end if;
         elsif (PIXELGen = WAITOAM) then
            if (pq_cnt /= 0) then
               c_drain := c_drain + 1;
            elsif (OAMFetch /= IDLE and OAMFetch /= DONE) then
               c_oam := c_oam + 1;
            end if;
         end if;

         -- WAITAFF is one cycle per rot/scal sprite, so it counts them
         -- directly; a drawn sprite is one that leaves WAITFIRST for either of
         -- the two accept states rather than staying to scan the next entry.
         if (OAMFetch = WAITAFF) then n_aff := n_aff + 1; end if;
         if (prev_fetch = WAITFIRST and (OAMFetch = WAITAFF or OAMFetch = DONE)) then
            n_spr := n_spr + 1;
         end if;
         prev_fetch := OAMFetch;

         if (issue_pixel = '1') then c_iss := c_iss + 1; end if;
         if (pq_cnt /= 0 and pq(pq_head).newword = '1' and wq_cnt = 0) then
            c_wordwait := c_wordwait + 1;
         end if;
         prev_x := x;

         if (OAMFetch /= IDLE and OAMFetch /= DONE) then
            c_fetch := c_fetch + 1;
         end if;

      end if;
   end process;
   -- synthesis translate_on

end architecture;
