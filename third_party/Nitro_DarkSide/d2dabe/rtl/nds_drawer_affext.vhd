-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS rot/scale BG drawer for BG2/BG3 - both plain AFFINE and EXTENDED
-- (BGxCNT.7) modes in one entity. Every mode here is rot/scale (ref/dx/dy)
-- with the wrapping bit; IS_AFFINE and VARIANT select the pixel source:
--
--   is_affine = 1: plain affine. 8bpp tiles with 8-BIT map entries, sizes
--      128..1024, standard palette only - extended palettes apply to text
--      and extended-mode BGs, not plain affine (GBATEK). No tile flips.
--
--   is_affine = 0, variant
--   0: 8bpp tiles with 16-bit map entries (tile# 9:0, hflip 10, vflip 11,
--      palno 15:12), sizes 128..1024 like plain affine; ext palettes
--      supported (slot = BG index from the orchestrator)
--   1: 256-color bitmap, std BG palette, sizes 128x128/256x256/512x256/
--      512x512, mapbase = bitmap base (16 KB units upstream)
--   2: direct-color bitmap, same sizes; bit15 of the pixel = alpha
--      (0 -> transparent), no palette lookup
--
-- Register semantics per GBATEK / melonDS GPU2D.
--
-- ============================================================================
-- WHY THE TWO DRAWERS ARE ONE
-- ============================================================================
--
-- These were separate entities (nds_drawer_affine and nds_drawer_extended),
-- and nds_gpu2d instantiated BOTH for each of BG2 and BG3 - four drawers to
-- render at most two BGs, because bgtype picks one per BG per mode and the
-- other sits idle all frame. That cost ~1.3-2.1k ALMs of pure duplication in
-- a design that is out of LABs, which is what forces the ARM9 island to place
-- loosely and miss its 2:1 timing.
--
-- Merging is cheap because plain affine is a strict SUBSET of extended
-- variant 0, not a parallel case. Once the 8-bit map entry is widened to the
-- 16-bit layout - tile number in 9:0, flips and palette number ZERO - every
-- other stage is already bit-identical:
--
--   * the texel address (tilebase + tile*64 + yf*8 + xf) needs no special
--     case: clear flip bits make xf/yf the unflipped xlow/ylow
--   * the wrap, the map-index arithmetic, the out-of-bounds rule, index-0
--     transparency, the palette byte address and the mosaic rules are the
--     same expressions with the same operands
--   * cfg_xlim/cfg_ylim already take the variant-0 values (128 << size) on
--     both axes, which is exactly affine's scroll_mod
--
-- So the whole of affine costs three things here: the map index is NOT
-- doubled (1-byte entries, not 2), the map word is cut into byte lanes rather
-- than halfwords, and ext palettes are forced off. Everything else is shared
-- fabric. Bitmap variants 1 and 2 remain reachable only with is_affine = 0.
--
-- Equivalence is held by sim/run_drawer_affext_equiv.sh, which drives this
-- entity in BOTH modes against verbatim v1 copies of the two originals
-- (sim/nds_drawer_affine_ref.vhd, sim/nds_drawer_extended_ref.vhd) over 120
-- configurations. The affine instance there is fed the real variant /
-- extpalette stimulus with is_affine tied high, so the forcing is tested and
-- not merely assumed.
--
-- ============================================================================
-- v2: DECOUPLED RUN-AHEAD PIPELINE
-- ============================================================================
--
-- Both modes were pipelined the same way and for the same reason, and the
-- shared description is here. v1 walked one pixel at a
-- time through CALCADDR -> WAITREAD_TILE -> EVALTILE -> WAITREAD_COLOR ->
-- HANDOFF with a separate palette FSM the walk had to wait on, so every
-- pixel paid the state walk, the VRAM round trips and the palette lookup in
-- series. Measured ~1,265 cycles/line per extended BG against a 6,390-cycle
-- budget, and after affine went pipelined this drawer was what still missed
-- the budget in mixed scenes.
--
-- A PIXEL QUEUE holds up to PQ_DEPTH pixels:
--
--   E_MAPREQ    map word owed          (variant 0 only)
--   E_PIXNEED   tile entry known, pixel word not asked for yet (variant 0)
--   E_PIXREQ    pixel word owed
--   E_READY     colour in hand - the pixel stage may drain it
--
-- The variants differ in where an entry ENTERS. Variant 0 is the two-level
-- walk affine has (map word, then the tile's texel). Variants 1 and 2 are
-- bitmaps: the address comes straight from xxx/yyy with no dependent fetch,
-- so the walk issues on the pixel stream itself and an entry never visits
-- E_MAPREQ/E_PIXNEED at all. variant is a runtime input rather than a
-- generic, so both paths exist in the fabric either way.
--
-- A map word covers 2 tiles in extended mode (16-bit entries) or 4 in affine
-- mode (8-bit), and a pixel word 4 texels at 8bpp or 2 at 16bpp.
--
-- pend_*/cache_* are process VARIABLES, not signals, and that is load-bearing:
-- a response updates both, and the SAME cycle's pixel issue and walk must see
-- it. As signals they update a cycle late, so an entry could chain onto a slot
-- whose response had already been consumed - that rider is then never filled
-- and the line WEDGES. It also costs reuse: a pixel wanting the word that just
-- landed would re-fetch it.
--
-- Kept deliberately verbatim from v1 because it is GBATEK-derived semantics
-- rather than the part that was slow: the xlim/ylim wrap and map-entry
-- arithmetic, the xlim_sel/ylim_sel trick that keeps `mod`/`*` as
-- literal-constant operations, the tile flips, the direct-colour alpha rule
-- and the mosaic / transparency rules.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_affext is
   generic
   (
      DXYBITS      : integer := 16;
      ACCURACYBITS : integer := 28
   );
   port
   (
      clk                  : in  std_logic;

      line_trigger         : in  std_logic;
      drawline             : in  std_logic;
      busy                 : out std_logic := '0';

      -- plain affine (8-bit map entries, no flips, no ext palette). Latched at
      -- drawline like the rest of the configuration; it overrides variant and
      -- extpalette, so the orchestrator may leave those at their BG values.
      is_affine            : in  std_logic := '0';
      variant              : in  unsigned(1 downto 0);
      mapbase              : in  unsigned(18 downto 0);   -- map / bitmap byte base
      tilebase             : in  unsigned(18 downto 0);   -- tile byte base (variant 0)
      extpalette           : in  std_logic;
      extpal_slot          : in  unsigned(1 downto 0);
      screensize           : in  unsigned(1 downto 0);
      wrapping             : in  std_logic;
      mosaic               : in  std_logic;
      Mosaic_H_Size        : in  unsigned(3 downto 0);
      refX                 : in  signed;
      refY                 : in  signed;
      refX_mosaic          : in  signed(27 downto 0);
      refY_mosaic          : in  signed(27 downto 0);
      dx                   : in  signed(DXYBITS - 1 downto 0);
      dy                   : in  signed(DXYBITS - 1 downto 0);

      pixel_we             : out std_logic := '0';
      pixeldata            : buffer std_logic_vector(15 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 255;

      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);
      PALETTE_Drawer_valid : in  std_logic;

      EXTPAL_Drawer_addr   : out integer range 0 to 8191;
      EXTPAL_Drawer_data   : in  std_logic_vector(31 downto 0);
      EXTPAL_Drawer_valid  : in  std_logic;

      -- several requests in flight; req is a one-cycle pulse and addr is held
      -- until accept, because the arbiter latches the request but samples the
      -- address at issue time. done pulses in issue order, data valid that cycle.
      VRAM_Drawer_req      : out std_logic := '0';
      VRAM_Drawer_addr     : out integer range 0 to 131071;
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_done     : in  std_logic;
      VRAM_Drawer_accept   : in  std_logic := '1'
   );
end entity;

architecture arch of nds_drawer_affext is

   constant PQ_DEPTH  : integer := 4;   -- pixels tracked in flight
   constant TAG_DEPTH : integer := 4;   -- VRAM requests trackable in flight

   -- ================= line configuration, latched at drawline =================
   signal cfg_affine   : std_logic := '0';
   signal cfg_variant  : unsigned(1 downto 0) := "00";
   signal cfg_mapbase  : unsigned(18 downto 0) := (others => '0');
   signal cfg_tilebase : unsigned(18 downto 0) := (others => '0');
   signal cfg_extpal   : std_logic := '0';
   signal cfg_slot     : unsigned(1 downto 0) := "00";
   signal cfg_size     : unsigned(1 downto 0) := "00";
   signal cfg_wrap     : std_logic := '0';
   signal cfg_mosaic   : std_logic := '0';
   signal cfg_mossize  : unsigned(3 downto 0) := (others => '0');
   signal cfg_xlim     : integer range 128 to 1024 := 128;
   signal cfg_ylim     : integer range 128 to 1024 := 128;
   -- cfg_xlim/cfg_ylim only ever hold 128/256/512/1024, but as plain runtime
   -- integers Quartus can't see that, so `mod xlim` / `* xlim` below
   -- synthesize as full dividers/multipliers. The _sel copies carry the same
   -- value as a 2-bit index so those ops become literal-constant case/when
   -- expressions (mask/shift).
   signal cfg_xlimsel  : unsigned(1 downto 0) := "00";
   signal cfg_ylimsel  : unsigned(1 downto 0) := "00";

   -- ================= pixel queue =================
   type t_estate is (E_FREE, E_MAPREQ, E_PIXNEED, E_PIXREQ, E_READY);
   type t_pq_entry is record
      state  : t_estate;
      x      : integer range 0 to 255;
      -- byte lane of the map entry within the map word. Extended entries are
      -- 16-bit so only bit 1 matters there; affine entries are 8-bit and use
      -- both bits. One field serves both - see map_ent().
      mlane  : unsigned(1 downto 0);
      mchain : std_logic;                     -- rides another entry's map request
      mowner : integer range 0 to PQ_DEPTH-1;
      xlow   : unsigned(2 downto 0);          -- xxx(2:0), for the tile texel
      ylow   : unsigned(2 downto 0);          -- yyy(2:0)
      tent   : std_logic_vector(15 downto 0); -- map entry, always 16-bit form
      plane  : unsigned(1 downto 0);          -- byte lane in the pixel word
      pchain : std_logic;                     -- rides another entry's pixel request
      powner : integer range 0 to PQ_DEPTH-1;
      color  : std_logic_vector(15 downto 0);
   end record;
   constant PQ_INIT : t_pq_entry :=
      (E_FREE, 0, "00", '0', 0, "000", "000", (others => '0'), "00", '0', 0, (others => '0'));
   type t_pq is array (0 to PQ_DEPTH-1) of t_pq_entry;
   signal pq       : t_pq := (others => PQ_INIT);
   signal pq_head  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pq_tail  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pq_count : integer range 0 to PQ_DEPTH := 0;

   -- ================= response tags =================
   type t_tagkind is (T_MAP, T_PIX);
   type t_tag is record
      kind : t_tagkind;
      slot : integer range 0 to PQ_DEPTH-1;
      addr : unsigned(16 downto 0);   -- travels with the response
   end record;
   type t_tagq is array (0 to TAG_DEPTH-1) of t_tag;
   signal tagq      : t_tagq := (others => (T_MAP, 0, (others => '0')));
   signal tag_head  : integer range 0 to TAG_DEPTH-1 := 0;
   signal tag_tail  : integer range 0 to TAG_DEPTH-1 := 0;
   signal tag_count : integer range 0 to TAG_DEPTH := 0;

   signal unaccepted : std_logic := '0';

   -- ================= per-stream word tracking =================
   signal pend_maddr  : unsigned(16 downto 0) := (others => '0');
   signal pend_mvalid : std_logic := '0';
   signal pend_mslot  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pend_paddr  : unsigned(16 downto 0) := (others => '0');
   signal pend_pvalid : std_logic := '0';
   signal pend_pslot  : integer range 0 to PQ_DEPTH-1 := 0;

   signal cache_maddr  : unsigned(16 downto 0) := (others => '0');
   signal cache_mdata  : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_mvalid : std_logic := '0';
   signal cache_paddr  : unsigned(16 downto 0) := (others => '0');
   signal cache_pdata  : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_pvalid : std_logic := '0';

   -- ================= walk =================
   signal realX    : signed(ACCURACYBITS - 1 downto 0) := (others => '0');
   signal realY    : signed(ACCURACYBITS - 1 downto 0) := (others => '0');
   signal w_active : std_logic := '0';
   signal w_x      : integer range 0 to 256 := 0;

   signal xxx_pre    : signed(19 downto 0);
   signal yyy_pre    : signed(19 downto 0);
   signal xxx        : signed(19 downto 0);
   signal yyy        : signed(19 downto 0);
   -- both are sums of signed(19 downto 0) terms, so the index is bounded by
   -- that width and the byte offset by twice it. Bounded (and initialised)
   -- rather than plain INTEGER because map_index feeds a x2: left to default,
   -- it would start at INTEGER'left and overflow the multiply at time 0.
   signal map_index  : integer range -524288 to 524287 := 0;
   signal map_entry  : integer range -1048576 to 1048574 := 0;
   signal yyy_x_xlim : integer := 0;

   -- ================= pixel stage =================
   signal p_active    : std_logic := '0';
   signal mosaik_cnt  : integer range 0 to 15 := 0;
   signal last_transp : std_logic := '1';

   -- stage 1 -> stage 2 (palette read in flight)
   signal s_valid  : std_logic := '0';
   signal s_x      : integer range 0 to 255 := 0;
   signal s_hi     : std_logic := '0';
   signal s_ext    : std_logic := '0';
   signal s_direct : std_logic := '0';   -- variant 2: no lookup, colour is the pixel
   signal s_color  : std_logic_vector(15 downto 0) := (others => '0');
   signal s_repeat : std_logic := '0';
   signal s_rep_we : std_logic := '0';
   signal s_transp : std_logic := '0';

   -- combinational view of the head entry
   signal h_ready  : std_logic;
   signal h_color  : std_logic_vector(15 downto 0);
   signal h_palno  : std_logic_vector(3 downto 0);
   signal h_transp : std_logic;
   signal h_pbyte  : unsigned(8 downto 0);
   signal h_ebyte  : unsigned(14 downto 0);

begin

   -- ==========================================================================
   -- walk address arithmetic - verbatim v1, now evaluated at allocate time
   -- ==========================================================================
   xxx_pre <= realX(realX'left downto realX'left - 19);
   yyy_pre <= realY(realY'left downto realY'left - 19);

   xxx     <= xxx_pre           when (cfg_wrap = '0') else
              xxx_pre mod 128   when (cfg_xlimsel = "00") else
              xxx_pre mod 256   when (cfg_xlimsel = "01") else
              xxx_pre mod 512   when (cfg_xlimsel = "10") else
              xxx_pre mod 1024;
   yyy     <= yyy_pre           when (cfg_wrap = '0') else
              yyy_pre mod 128   when (cfg_ylimsel = "00") else
              yyy_pre mod 256   when (cfg_ylimsel = "01") else
              yyy_pre mod 512   when (cfg_ylimsel = "10") else
              yyy_pre mod 1024;

   -- tile index within the map (the map is (xlim/8) entries wide). The BYTE
   -- offset of that entry is the only place the two tile modes differ in
   -- address arithmetic: extended variant-0 entries are 16-bit, plain affine
   -- entries are 8-bit.
   map_index <=
      to_integer((xxx / 8) + shift_left(shift_right(yyy, 3), 4 + to_integer(cfg_size)));
   map_entry <= map_index when (cfg_affine = '1') else map_index * 2;

   -- to_integer(yyy) * xlim, as a mux of literal-constant multiplies
   yyy_x_xlim <=
      to_integer(yyy) * 128    when (cfg_xlimsel = "00") else
      to_integer(yyy) * 256    when (cfg_xlimsel = "01") else
      to_integer(yyy) * 512    when (cfg_xlimsel = "10") else
      to_integer(yyy) * 1024;

   -- ==========================================================================
   -- head-entry colour select (combinational, feeds both palette addresses)
   -- ==========================================================================
   h_ready  <= '1' when (pq(pq_head).state = E_READY) else '0';
   h_color  <= pq(pq_head).color;
   h_palno  <= pq(pq_head).tent(15 downto 12);

   -- variant 2 is transparent on a clear alpha bit, the others on index 0
   h_transp <= '1' when (cfg_variant  = "10" and h_color(15) = '0') else
               '1' when (cfg_variant /= "10" and h_color(7 downto 0) = x"00") else
               '0';

   h_pbyte <= unsigned(h_color(7 downto 0) & '0');
   h_ebyte <= unsigned(std_logic_vector(cfg_slot) & h_palno & h_color(7 downto 0) & '0');

   PALETTE_Drawer_addr <= to_integer(h_pbyte(8 downto 2));
   EXTPAL_Drawer_addr  <= to_integer(h_ebyte(14 downto 2));

   -- ==========================================================================
   -- one clocked process owns the whole drawer: configuration, the fetch side
   -- and the pixel side. They share the pixel queue, so keeping them in one
   -- process is what makes "allocate, complete and pop in the same cycle" safe.
   -- ==========================================================================
   process (clk)
      variable v_pq    : t_pq;
      variable v_cnt   : integer range 0 to PQ_DEPTH;
      variable v_head  : integer range 0 to PQ_DEPTH-1;
      variable v_tail  : integer range 0 to PQ_DEPTH-1;
      variable v_tagc  : integer range 0 to TAG_DEPTH;
      variable v_tagh  : integer range 0 to TAG_DEPTH-1;
      variable v_tagt  : integer range 0 to TAG_DEPTH-1;
      variable issued  : boolean;
      variable advance : boolean;
      variable tg      : t_tag;
      variable sel     : integer range 0 to PQ_DEPTH-1;
      variable k2      : integer range 0 to PQ_DEPTH-1;
      variable found   : boolean;
      variable col     : std_logic_vector(15 downto 0);
      variable ment    : std_logic_vector(15 downto 0);
      variable mbyte   : integer range 0 to 524287;
      variable mword   : unsigned(16 downto 0);
      variable pbyte   : integer range 0 to 524287;
      variable pword   : unsigned(16 downto 0);
      variable xf      : unsigned(2 downto 0);
      variable yf      : unsigned(2 downto 0);
      variable oob     : boolean;
      -- see the run-ahead notes in the header: these must be variables so a
      -- response is visible to the same cycle's issue and walk stages
      variable vc_maddr : unsigned(16 downto 0);
      variable vc_mdata : std_logic_vector(31 downto 0);
      variable vc_mval  : std_logic;
      variable vc_paddr : unsigned(16 downto 0);
      variable vc_pdata : std_logic_vector(31 downto 0);
      variable vc_pval  : std_logic;
      variable vp_maddr : unsigned(16 downto 0);
      variable vp_mval  : std_logic;
      variable vp_mslot : integer range 0 to PQ_DEPTH-1;
      variable vp_paddr : unsigned(16 downto 0);
      variable vp_pval  : std_logic;
      variable vp_pslot : integer range 0 to PQ_DEPTH-1;

      -- pixel-word lane extraction, shared by the cache-hit and response paths
      function pix_col (d : std_logic_vector(31 downto 0);
                        lane : unsigned(1 downto 0);
                        v : unsigned(1 downto 0)) return std_logic_vector is
      begin
         if (v /= "10") then
            case (to_integer(lane)) is
               when 0      => return x"00" & d( 7 downto  0);
               when 1      => return x"00" & d(15 downto  8);
               when 2      => return x"00" & d(23 downto 16);
               when others => return x"00" & d(31 downto 24);
            end case;
         elsif (lane(1) = '0') then
            return d(15 downto 0);
         else
            return d(31 downto 16);
         end if;
      end function;

      -- map-entry extraction, shared by the cache-hit and response paths.
      -- Extended variant 0 has 16-bit entries. Plain affine has 8-bit ones,
      -- which widen into the SAME layout for free: tile number 0..255 in 9:0,
      -- both flip bits clear and palette number 0 - which is exactly affine's
      -- semantics (no flips, standard palette). Everything downstream of here
      -- is then one shared path.
      function map_ent (d    : std_logic_vector(31 downto 0);
                        lane : unsigned(1 downto 0);
                        aff  : std_logic) return std_logic_vector is
      begin
         if (aff = '1') then
            case (to_integer(lane)) is
               when 0      => return x"00" & d( 7 downto  0);
               when 1      => return x"00" & d(15 downto  8);
               when 2      => return x"00" & d(23 downto 16);
               when others => return x"00" & d(31 downto 24);
            end case;
         elsif (lane(1) = '0') then
            return d(15 downto 0);
         else
            return d(31 downto 16);
         end if;
      end function;
   begin
      if rising_edge(clk) then

         VRAM_Drawer_req <= '0';
         pixel_we        <= '0';

         if (VRAM_Drawer_accept = '1') then
            unaccepted <= '0';
         end if;

         if (drawline = '1') then
            -- ---------------------------------------------------------------
            -- start of line: latch configuration, reset both sides. realX/realY
            -- are NOT reloaded here - they carry the reference point that
            -- line_trigger set, which is how dmx/dmy accumulate down the frame.
            -- ---------------------------------------------------------------
            -- affine is variant 0 with the standard palette, always: the
            -- bitmap variants and ext palettes are extended-mode only, so
            -- forcing them here is what lets every stage below stay shared.
            -- spelled out rather than as a conditional signal assignment:
            -- that form is VHDL-2008-only in a sequential context and Quartus
            -- 17.0.2 rejects it, though nvc takes it.
            cfg_affine   <= is_affine;
            if (is_affine = '1') then
               cfg_variant <= "00";
               cfg_extpal  <= '0';
            else
               cfg_variant <= variant;
               cfg_extpal  <= extpalette;
            end if;
            cfg_mapbase  <= mapbase;
            cfg_tilebase <= tilebase;
            cfg_slot     <= extpal_slot;
            cfg_size     <= screensize;
            cfg_wrap     <= wrapping;
            cfg_mosaic   <= mosaic;
            cfg_mossize  <= Mosaic_H_Size;
            if (is_affine = '1' or variant = "00") then
               cfg_xlim    <= 128 * (2 ** to_integer(screensize));
               cfg_ylim    <= 128 * (2 ** to_integer(screensize));
               cfg_xlimsel <= screensize;
               cfg_ylimsel <= screensize;
            else
               case (to_integer(screensize)) is
                  when 0      => cfg_xlim <= 128; cfg_ylim <= 128; cfg_xlimsel <= "00"; cfg_ylimsel <= "00";
                  when 1      => cfg_xlim <= 256; cfg_ylim <= 256; cfg_xlimsel <= "01"; cfg_ylimsel <= "01";
                  when 2      => cfg_xlim <= 512; cfg_ylim <= 256; cfg_xlimsel <= "10"; cfg_ylimsel <= "01";
                  when others => cfg_xlim <= 512; cfg_ylim <= 512; cfg_xlimsel <= "10"; cfg_ylimsel <= "10";
               end case;
            end if;

            pq           <= (others => PQ_INIT);
            pq_head      <= 0;
            pq_tail      <= 0;
            pq_count     <= 0;
            tag_head     <= 0;
            tag_tail     <= 0;
            tag_count    <= 0;
            unaccepted   <= '0';
            pend_mvalid  <= '0';
            pend_pvalid  <= '0';
            cache_mvalid <= '0';
            cache_pvalid <= '0';

            busy          <= '1';
            w_active      <= '1';
            w_x           <= 0;
            p_active      <= '1';
            mosaik_cnt    <= 15;          -- v1: the first pixel must fetch
            last_transp   <= '1';
            pixeldata(15) <= '1';
            s_valid       <= '0';

         elsif (line_trigger = '1' and w_active = '0' and p_active = '0') then
            -- v1 accepted the reference point only while idle
            realX <= (others => '0');
            realY <= (others => '0');
            if (mosaic = '1' and unsigned(Mosaic_H_Size) > 0) then
               realX(realX'left downto realX'left - refX_mosaic'length + 1) <= refX_mosaic;
               realY(realY'left downto realY'left - refY_mosaic'length + 1) <= refY_mosaic;
            else
               realX(realX'left downto realX'left - refX'length + 1) <= refX;
               realY(realY'left downto realY'left - refY'length + 1) <= refY;
            end if;

         else

            v_pq    := pq;
            v_cnt   := pq_count;
            v_head  := pq_head;
            v_tail  := pq_tail;
            v_tagc  := tag_count;
            v_tagh  := tag_head;
            v_tagt  := tag_tail;
            issued  := false;
            advance := false;

            vc_maddr := cache_maddr;  vc_mdata := cache_mdata;  vc_mval := cache_mvalid;
            vc_paddr := cache_paddr;  vc_pdata := cache_pdata;  vc_pval := cache_pvalid;
            vp_maddr := pend_maddr;   vp_mval  := pend_mvalid;  vp_mslot := pend_mslot;
            vp_paddr := pend_paddr;   vp_pval  := pend_pvalid;  vp_pslot := pend_pslot;

            -- ===============================================================
            -- FETCH: responses, in issue order. The tagged entry takes the
            -- word, and so does every entry riding on it.
            -- ===============================================================
            if (VRAM_Drawer_done = '1' and v_tagc > 0) then
               tg := tagq(v_tagh);

               if (tg.kind = T_MAP) then
                  vc_maddr := tg.addr;
                  vc_mdata := VRAM_Drawer_data;
                  vc_mval  := '1';
                  if (vp_mval = '1' and vp_maddr = tg.addr) then
                     vp_mval := '0';
                  end if;

                  for kk in 0 to PQ_DEPTH-1 loop
                     if (v_pq(kk).state = E_MAPREQ and
                         (kk = tg.slot or
                          (v_pq(kk).mchain = '1' and v_pq(kk).mowner = tg.slot))) then
                        v_pq(kk).tent  := map_ent(VRAM_Drawer_data, v_pq(kk).mlane, cfg_affine);
                        v_pq(kk).state := E_PIXNEED;
                     end if;
                  end loop;

               else
                  vc_paddr := tg.addr;
                  vc_pdata := VRAM_Drawer_data;
                  vc_pval  := '1';
                  if (vp_pval = '1' and vp_paddr = tg.addr) then
                     vp_pval := '0';
                  end if;

                  for kk in 0 to PQ_DEPTH-1 loop
                     if (v_pq(kk).state = E_PIXREQ and
                         (kk = tg.slot or
                          (v_pq(kk).pchain = '1' and v_pq(kk).powner = tg.slot))) then
                        v_pq(kk).color := pix_col(VRAM_Drawer_data, v_pq(kk).plane, cfg_variant);
                        v_pq(kk).state := E_READY;
                     end if;
                  end loop;
               end if;

               v_tagh := (v_tagh + 1) mod TAG_DEPTH;
               v_tagc := v_tagc - 1;
            end if;

            -- ===============================================================
            -- FETCH: variant-0 texel for the oldest entry that has its map
            -- entry. The flips come from that entry, so this address cannot
            -- be formed until the map word is back.
            -- ===============================================================
            found := false;
            sel   := 0;
            for k in 0 to PQ_DEPTH-1 loop
               if (not found) then
                  k2 := (v_head + k) mod PQ_DEPTH;
                  if (v_pq(k2).state = E_PIXNEED) then
                     sel   := k2;
                     found := true;
                  end if;
               end if;
            end loop;

            if (found) then
               ment := v_pq(sel).tent;
               if (ment(10) = '0') then xf := v_pq(sel).xlow; else xf := 7 - v_pq(sel).xlow; end if;
               if (ment(11) = '0') then yf := v_pq(sel).ylow; else yf := 7 - v_pq(sel).ylow; end if;
               pbyte := (to_integer(cfg_tilebase)
                         + to_integer(unsigned(ment(9 downto 0))) * 64
                         + to_integer(yf) * 8 + to_integer(xf)) mod 524288;
               pword := to_unsigned(pbyte, 19)(18 downto 2);
               v_pq(sel).plane := to_unsigned(pbyte, 19)(1 downto 0);

               if (vc_pval = '1' and vc_paddr = pword) then
                  v_pq(sel).color  := pix_col(vc_pdata, to_unsigned(pbyte, 19)(1 downto 0), cfg_variant);
                  v_pq(sel).state  := E_READY;
                  v_pq(sel).pchain := '0';
               elsif (vp_pval = '1' and vp_paddr = pword) then
                  v_pq(sel).pchain := '1';
                  v_pq(sel).powner := vp_pslot;
                  v_pq(sel).state  := E_PIXREQ;
               elsif (v_tagc < TAG_DEPTH and (unaccepted = '0' or VRAM_Drawer_accept = '1')) then
                  VRAM_Drawer_addr <= to_integer(pword);
                  VRAM_Drawer_req  <= '1';
                  unaccepted       <= '1';
                  tagq(v_tagt)     <= (T_PIX, sel, pword);
                  v_tagt := (v_tagt + 1) mod TAG_DEPTH;
                  v_tagc := v_tagc + 1;
                  vp_paddr := pword;
                  vp_pval  := '1';
                  vp_pslot := sel;
                  v_pq(sel).pchain := '0';
                  v_pq(sel).state  := E_PIXREQ;
                  issued := true;
               end if;
            end if;

            -- ===============================================================
            -- WALK: allocate the next pixel. Variant 0 enters on the map
            -- stream; the bitmap variants have no dependent fetch and enter
            -- straight onto the pixel stream. Out-of-bounds pixels on a
            -- non-wrapping BG are stepped over without an entry - v1 emitted
            -- nothing for them and left the mosaic counter alone.
            -- ===============================================================
            if (w_active = '1' and v_cnt < PQ_DEPTH) then
               oob := (cfg_wrap = '0') and
                      (xxx_pre < 0 or yyy_pre < 0 or
                       xxx_pre >= cfg_xlim or yyy_pre >= cfg_ylim);

               if (oob) then
                  realX <= realX + dx;
                  realY <= realY + dy;
                  if (w_x = 255) then
                     w_active <= '0';
                     w_x      <= 256;
                  else
                     w_x <= w_x + 1;
                  end if;
               else
                  v_pq(v_tail)      := PQ_INIT;
                  v_pq(v_tail).x    := w_x;
                  v_pq(v_tail).xlow := unsigned(std_logic_vector(xxx(2 downto 0)));
                  v_pq(v_tail).ylow := unsigned(std_logic_vector(yyy(2 downto 0)));

                  found := false;

                  if (cfg_variant = "00") then
                     mbyte := (to_integer(cfg_mapbase) + map_entry) mod 524288;
                     mword := to_unsigned(mbyte, 19)(18 downto 2);
                     v_pq(v_tail).mlane := to_unsigned(mbyte, 19)(1 downto 0);

                     if (vc_mval = '1' and vc_maddr = mword) then
                        v_pq(v_tail).tent   := map_ent(vc_mdata, to_unsigned(mbyte, 19)(1 downto 0), cfg_affine);
                        v_pq(v_tail).mchain := '0';
                        v_pq(v_tail).state  := E_PIXNEED;
                        found := true;
                     elsif (vp_mval = '1' and vp_maddr = mword) then
                        v_pq(v_tail).mchain := '1';
                        v_pq(v_tail).mowner := vp_mslot;
                        v_pq(v_tail).state  := E_MAPREQ;
                        found := true;
                     elsif (not issued and v_tagc < TAG_DEPTH and
                            (unaccepted = '0' or VRAM_Drawer_accept = '1')) then
                        VRAM_Drawer_addr <= to_integer(mword);
                        VRAM_Drawer_req  <= '1';
                        unaccepted       <= '1';
                        tagq(v_tagt)     <= (T_MAP, v_tail, mword);
                        v_tagt := (v_tagt + 1) mod TAG_DEPTH;
                        v_tagc := v_tagc + 1;
                        vp_maddr := mword;
                        vp_mval  := '1';
                        vp_mslot := v_tail;
                        v_pq(v_tail).mchain := '0';
                        v_pq(v_tail).state  := E_MAPREQ;
                        issued := true;
                        found  := true;
                     end if;

                  else
                     if (cfg_variant = "01") then
                        pbyte := (to_integer(cfg_mapbase) + yyy_x_xlim
                                  + to_integer(xxx)) mod 524288;
                     else
                        pbyte := (to_integer(cfg_mapbase)
                                  + (yyy_x_xlim + to_integer(xxx)) * 2) mod 524288;
                     end if;
                     pword := to_unsigned(pbyte, 19)(18 downto 2);
                     v_pq(v_tail).plane := to_unsigned(pbyte, 19)(1 downto 0);

                     if (vc_pval = '1' and vc_paddr = pword) then
                        v_pq(v_tail).color  := pix_col(vc_pdata, to_unsigned(pbyte, 19)(1 downto 0), cfg_variant);
                        v_pq(v_tail).pchain := '0';
                        v_pq(v_tail).state  := E_READY;
                        found := true;
                     elsif (vp_pval = '1' and vp_paddr = pword) then
                        v_pq(v_tail).pchain := '1';
                        v_pq(v_tail).powner := vp_pslot;
                        v_pq(v_tail).state  := E_PIXREQ;
                        found := true;
                     elsif (not issued and v_tagc < TAG_DEPTH and
                            (unaccepted = '0' or VRAM_Drawer_accept = '1')) then
                        VRAM_Drawer_addr <= to_integer(pword);
                        VRAM_Drawer_req  <= '1';
                        unaccepted       <= '1';
                        tagq(v_tagt)     <= (T_PIX, v_tail, pword);
                        v_tagt := (v_tagt + 1) mod TAG_DEPTH;
                        v_tagc := v_tagc + 1;
                        vp_paddr := pword;
                        vp_pval  := '1';
                        vp_pslot := v_tail;
                        v_pq(v_tail).pchain := '0';
                        v_pq(v_tail).state  := E_PIXREQ;
                        issued := true;
                        found  := true;
                     end if;
                  end if;

                  if (found) then
                     v_tail := (v_tail + 1) mod PQ_DEPTH;
                     v_cnt  := v_cnt + 1;
                     realX  <= realX + dx;
                     realY  <= realY + dy;
                     if (w_x = 255) then
                        w_active <= '0';
                        w_x      <= 256;
                     else
                        w_x <= w_x + 1;
                     end if;
                  end if;
               end if;
            end if;

            -- ===============================================================
            -- PIXEL stage 1: one pixel per cycle out of the head entry
            -- ===============================================================
            s_valid <= '0';
            if (p_active = '1' and v_cnt > 0 and h_ready = '1') then
               if (cfg_mosaic = '1' and mosaik_cnt < to_integer(cfg_mossize)) then
                  -- mosaic repeat: re-emit the last colour, no palette read.
                  -- v1 wrote `pixel_we <= not pixeldata(15)`, i.e. repeat
                  -- unless the source pixel was transparent.
                  mosaik_cnt <= mosaik_cnt + 1;
                  s_valid    <= '1';
                  s_repeat   <= '1';
                  s_rep_we   <= not last_transp;
                  s_x        <= v_pq(v_head).x;
               else
                  mosaik_cnt <= 0;
                  s_valid    <= '1';
                  s_repeat   <= '0';
                  s_x        <= v_pq(v_head).x;
                  s_color    <= h_color;
                  if (h_transp = '1') then
                     s_transp    <= '1';
                     last_transp <= '1';
                  else
                     s_transp    <= '0';
                     last_transp <= '0';
                     if (cfg_variant = "10") then
                        s_direct <= '1';
                        s_ext    <= '0';
                     elsif (cfg_variant = "00" and cfg_extpal = '1') then
                        s_direct <= '0';
                        s_ext    <= '1';
                        s_hi     <= h_ebyte(1);
                     else
                        s_direct <= '0';
                        s_ext    <= '0';
                        s_hi     <= h_pbyte(1);
                     end if;
                  end if;
               end if;
               advance := true;
            end if;

            if (advance) then
               v_pq(v_head).state := E_FREE;
               v_head := (v_head + 1) mod PQ_DEPTH;
               v_cnt  := v_cnt - 1;
               if (w_active = '0' and v_cnt = 0) then
                  p_active <= '0';
               end if;
            end if;

            -- ===============================================================
            -- PIXEL stage 2: the palette word has arrived
            -- ===============================================================
            if (s_valid = '1') then
               pixel_x <= s_x;
               if (s_repeat = '1') then
                  -- pixeldata still holds the last colour, so just re-write it
                  pixel_we <= s_rep_we;
               elsif (s_transp = '1') then
                  pixeldata(15) <= '1';
               elsif (s_direct = '1') then
                  pixel_we  <= '1';
                  pixeldata <= '0' & s_color(14 downto 0);
               elsif (s_ext = '1') then
                  pixel_we <= '1';
                  if (s_hi = '1') then
                     pixeldata <= '0' & EXTPAL_Drawer_data(30 downto 16);
                  else
                     pixeldata <= '0' & EXTPAL_Drawer_data(14 downto 0);
                  end if;
               else
                  pixel_we <= '1';
                  if (s_hi = '1') then
                     pixeldata <= '0' & PALETTE_Drawer_data(30 downto 16);
                  else
                     pixeldata <= '0' & PALETTE_Drawer_data(14 downto 0);
                  end if;
               end if;
            end if;

            -- busy drops only once the last pixel has left stage 2
            if (w_active = '0' and v_cnt = 0 and s_valid = '0') then
               busy     <= '0';
               p_active <= '0';
            end if;

            pq        <= v_pq;
            pq_head   <= v_head;
            pq_tail   <= v_tail;
            pq_count  <= v_cnt;
            tag_head  <= v_tagh;
            tag_tail  <= v_tagt;
            tag_count <= v_tagc;

            cache_maddr <= vc_maddr;  cache_mdata <= vc_mdata;  cache_mvalid <= vc_mval;
            cache_paddr <= vc_paddr;  cache_pdata <= vc_pdata;  cache_pvalid <= vc_pval;
            pend_maddr  <= vp_maddr;  pend_mvalid <= vp_mval;   pend_mslot   <= vp_mslot;
            pend_paddr  <= vp_paddr;  pend_pvalid <= vp_pval;   pend_pslot   <= vp_pslot;

         end if;
      end if;
   end process;

end architecture;
