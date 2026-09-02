-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS text-mode BG drawer (fork of gba_drawer_mode0). One instance renders
-- one BG line into the per-BG line buffer. Deltas vs the GBA donor:
--
--   * 256-pixel line (0..255), ypos 0..191
--   * 512 KB BG address space: mapbase/tilebase arrive as full byte
--     addresses (the orchestrator sums DISPCNT char/screen base offsets
--     with BGxCNT blocks), VRAM_Drawer_addr is a 17-bit word address
--   * extended palettes: in 256-color mode with extpalette='1' the color
--     is looked up in the 32 KB ext-pal space (slot from the orchestrator:
--     BG0/1 -> slot 0/1 or 2/3 per BGxCNT.13, BG2/3 -> slot 2/3) as
--     slot*8K + palno*512 + color*2, palno = tileinfo(15:12). Without
--     extpalette, 256-color tiles use the std palette and ignore palno
--     (GBA behavior). 16-color tiles always use the std palette.
--
-- Map layout, flips, mosaic, and the transparent-on-index-0 rule are
-- unchanged from the GBA. Register semantics per GBATEK / melonDS GPU2D.
--
-- ============================================================================
-- v2: DECOUPLED PREFETCH PIPELINE
-- ============================================================================
--
-- v1 walked ONE PIXEL at a time through CALCADDR -> WAITREAD_TILE ->
-- CALCCOLORADDR -> WAITREAD_COLOR, and a second FSM did the palette lookup.
-- The pixel loop could not advance until that palette FSM went idle, so every
-- pixel paid a state walk AND memory latency in series with nothing
-- overlapped. Measured: 21.7 cycles per pixel against a budget of about 8, and
-- 95% of the entire renderer's cost.
--
-- None of that waiting is necessary, because a scanline's address stream is
-- entirely predictable: map entries are sequential, and a tile's char-row
-- address follows from its map entry. So v2 runs the fetch AHEAD of the pixels.
--
-- A TILE QUEUE holds up to TQ_DEPTH tiles, each entry advancing through:
--
--   E_MAPREQ    map word requested (or taken from the one-word map cache)
--   E_CHARNEED  tile info known, char row words not yet asked for
--   E_CHARREQ   char words asked for, waiting for them to come back
--   E_READY     row complete - the pixel stage may drain it
--
-- Requests for DIFFERENT entries are in flight at the same time: while entry N
-- waits for its char row, entry N+1 is already fetching its map word, and an
-- 8bpp tile's two row words are both outstanding at once. The line server
-- answers a channel in the order it was asked, so a small tag FIFO routes each
-- answer to the entry and word half that asked for it - no tags on the wire.
--
-- The pixel stage is then a two-stage pipeline with no back-pressure: select
-- the colour index out of the head entry's row and present the palette address
-- (one cycle), then take the palette word and write the pixel (the next). One
-- pixel per cycle; it stalls only if the fetch side failed to stay ahead.
--
-- This depends on the palette read being UNCONDITIONAL - see nds_gpu2d's
-- gpal_bg copies and ext-pal slot RAMs, which give every BG its own read port.
-- The 4-phase round robin that used to answer one BG in four was itself worth
-- several cycles per pixel.
--
-- Kept deliberately verbatim from v1, because it is GBATEK-derived semantics
-- rather than the part that was slow: the map address arithmetic (screen-size
-- wrapping and the 1024/2048 tile-index blocks), and the flip / mosaic /
-- transparency rules.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_text is
   port
   (
      clk                  : in  std_logic;

      drawline             : in  std_logic;
      busy                 : out std_logic := '0';

      ypos                 : in  integer range 0 to 191;
      ypos_mosaic          : in  integer range 0 to 191;
      mapbase              : in  unsigned(18 downto 0);   -- byte address, 2 KB aligned
      tilebase             : in  unsigned(18 downto 0);   -- byte address, 16 KB aligned
      hicolor              : in  std_logic;
      extpalette           : in  std_logic;
      extpal_slot          : in  unsigned(1 downto 0);
      mosaic               : in  std_logic;
      Mosaic_H_Size        : in  unsigned(3 downto 0);
      screensize           : in  unsigned(1 downto 0);
      scrollX              : in  unsigned(8 downto 0);
      scrollY              : in  unsigned(8 downto 0);

      pixel_we             : out std_logic := '0';
      pixeldata            : buffer std_logic_vector(15 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 255;

      -- Palette reads are UNCONDITIONAL: present an address, take the word the
      -- next cycle. The *_valid inputs are kept so the port list still matches
      -- the affine/extended drawers, and are not waited on.
      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);
      PALETTE_Drawer_valid : in  std_logic;

      EXTPAL_Drawer_addr   : out integer range 0 to 8191;  -- word into 32 KB ext-pal space
      EXTPAL_Drawer_data   : in  std_logic_vector(31 downto 0);
      EXTPAL_Drawer_valid  : in  std_logic;

      -- VRAM char/map fetch. SEVERAL requests may be in flight: present req
      -- with addr, the arbiter pulses accept when it takes it, and done pulses
      -- once per answer IN ISSUE ORDER (nds_gpu2d's arbiter and nds_vram's
      -- server both retire in order, which is what makes the tag FIFO enough).
      VRAM_Drawer_req      : out std_logic := '0';
      VRAM_Drawer_addr     : out integer range 0 to 131071; -- word into 512 KB BG space
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_done     : in  std_logic;
      VRAM_Drawer_accept   : in  std_logic := '1'
   );
end entity;

architecture arch of nds_drawer_text is

   constant TQ_DEPTH  : integer := 4;   -- tiles tracked in flight
   -- TAG_DEPTH was 8, which no instance could ever use: the gpu2d arbiter
   -- tracks 8 ops across ALL FOUR BGs, and a tile queue 4 deep cannot owe more
   -- than 8 words anyway. 8 tag slots x 8 text instances was pure fabric.
   -- Frame bench is bit-identical at 4 (cycles/line unchanged, 0 drops).
   constant TAG_DEPTH : integer := 4;   -- VRAM requests trackable in flight

   -- ================= line configuration, latched at drawline =================
   signal cfg_hicolor    : std_logic := '0';
   signal cfg_extpal     : std_logic := '0';
   signal cfg_slot       : unsigned(1 downto 0) := "00";
   signal cfg_mosaic     : std_logic := '0';
   signal cfg_mossize    : unsigned(3 downto 0) := (others => '0');
   signal cfg_size       : unsigned(1 downto 0) := "00";
   signal cfg_mapbase    : unsigned(18 downto 0) := (others => '0');
   signal cfg_tilebase   : unsigned(18 downto 0) := (others => '0');
   signal cfg_scrollx    : unsigned(8 downto 0) := (others => '0');
   signal cfg_x512       : std_logic := '0';
   signal cfg_offset_y   : integer range 0 to 1023 := 0;
   signal cfg_ymod       : integer range 0 to 511 := 0;
   signal cfg_row        : integer range 0 to 7 := 0;    -- row within the tile
   signal cfg_ntiles     : integer range 1 to 33 := 33;

   -- ================= tile queue =================
   type t_estate is (E_FREE, E_MAPREQ, E_CHARNEED, E_CHARREQ, E_READY);
   type t_tq_entry is record
      state  : t_estate;
      palno  : std_logic_vector(3 downto 0);
      hflip  : std_logic;
      vflip  : std_logic;
      tileno : unsigned(9 downto 0);
      need   : integer range 0 to 2;   -- char words this tile needs (1 or 2)
      issued : integer range 0 to 2;   -- char words asked for so far
      left   : integer range 0 to 2;   -- char words still owed
      row    : std_logic_vector(63 downto 0);
   end record;
   constant TQ_INIT : t_tq_entry :=
      (E_FREE, (others => '0'), '0', '0', (others => '0'), 0, 0, 0, (others => '0'));
   type t_tq is array (0 to TQ_DEPTH-1) of t_tq_entry;
   signal tq       : t_tq := (others => TQ_INIT);
   signal tq_head  : integer range 0 to TQ_DEPTH-1 := 0;
   signal tq_tail  : integer range 0 to TQ_DEPTH-1 := 0;
   signal tq_count : integer range 0 to TQ_DEPTH := 0;

   -- ================= response tags =================
   -- one per outstanding VRAM request, popped in order on done
   type t_tagkind is (T_MAP, T_CHAR);
   type t_tag is record
      kind  : t_tagkind;
      slot  : integer range 0 to TQ_DEPTH-1;
      half  : integer range 0 to 1;    -- which 32-bit half of row (char only)
      odd   : std_logic;               -- map entry is the high half of the word
      -- The map word's own address travels WITH the response. Setting the cache
      -- tag at issue time instead was a real bug: a later tile could retarget
      -- mapc_addr while an earlier map request was still in flight, and that
      -- earlier response then filled the cache under the newer address - so a
      -- following tile read one word's data believing it was another's, and got
      -- a whole wrong tile. Sporadic, and dependent on request interleaving.
      maddr : unsigned(16 downto 0);
   end record;
   type t_tagq is array (0 to TAG_DEPTH-1) of t_tag;
   signal tagq      : t_tagq := (others => (T_MAP, 0, 0, '0', (others => '0')));
   signal tag_head  : integer range 0 to TAG_DEPTH-1 := 0;
   signal tag_tail  : integer range 0 to TAG_DEPTH-1 := 0;
   signal tag_count : integer range 0 to TAG_DEPTH := 0;

   -- ================= fetch walk =================
   signal f_tile     : integer range 0 to 33 := 0;   -- next tile to allocate
   signal unaccepted : std_logic := '0';             -- request presented, not taken

   -- one-word map cache: a 32-bit map word holds TWO tile entries, so every
   -- second tile costs no fetch at all
   signal mapc_addr  : unsigned(16 downto 0) := (others => '0');
   signal mapc_data  : std_logic_vector(31 downto 0) := (others => '0');
   signal mapc_valid : std_logic := '0';

   -- ================= pixel stage =================
   signal p_active    : std_logic := '0';
   signal p_x         : integer range 0 to 256 := 0;
   signal p_sub       : integer range 0 to 7 := 0;
   signal mosaik_cnt  : integer range 0 to 15 := 0;
   -- "the last colour actually fetched was transparent". v1 read pixeldata(15)
   -- for this, which a pipelined pixel path cannot do: pixeldata is written a
   -- cycle later, so the next pixel's mosaic decision would read a stale bit.
   signal last_transp : std_logic := '1';

   -- stage 1 -> stage 2 (palette read in flight)
   signal w_valid  : std_logic := '0';
   signal w_x      : integer range 0 to 255 := 0;
   signal w_ext    : std_logic := '0';
   signal w_hi     : std_logic := '0';   -- which halfword of the palette word
   signal w_repeat : std_logic := '0';   -- mosaic repeat: no palette read
   signal w_rep_we : std_logic := '0';
   signal w_transp : std_logic := '0';

   -- combinational view of the head entry at the current sub-pixel
   signal h_ready  : std_logic;
   signal h_idx    : std_logic_vector(7 downto 0);
   signal h_transp : std_logic;
   signal h_palno  : std_logic_vector(3 downto 0);
   signal h_pbyte  : unsigned(8 downto 0);    -- std-palette byte address
   signal h_ebyte  : unsigned(14 downto 0);   -- ext-palette byte address

begin

   -- ==========================================================================
   -- head-entry colour select (combinational, feeds the palette address)
   -- ==========================================================================
   -- e is the index within the tile row, mirrored when the tile is h-flipped:
   -- in 4bpp it selects a NIBBLE of the 32-bit row, in 8bpp a BYTE of the
   -- 64-bit row. v1 reached the same value the long way round, via a byte
   -- address plus a separate high/low nibble select - these agree by
   -- construction (hflip=0 gives e = x_scrolled(2:0), hflip=1 gives 7 - that).
   process (all)
      variable e   : integer range 0 to 7;
      variable nib : std_logic_vector(3 downto 0);
      variable byt : std_logic_vector(7 downto 0);
   begin
      h_ready  <= '0';
      h_idx    <= (others => '0');
      h_transp <= '1';
      h_palno  <= (others => '0');

      if (tq(tq_head).state = E_READY) then
         h_ready <= '1';
         h_palno <= tq(tq_head).palno;
         if (tq(tq_head).hflip = '1') then
            e := 7 - p_sub;
         else
            e := p_sub;
         end if;
         if (cfg_hicolor = '0') then
            nib   := tq(tq_head).row(4 * e + 3 downto 4 * e);
            h_idx <= "0000" & nib;
            if (nib = x"0") then h_transp <= '1'; else h_transp <= '0'; end if;
         else
            byt   := tq(tq_head).row(8 * e + 7 downto 8 * e);
            h_idx <= byt;
            if (byt = x"00") then h_transp <= '1'; else h_transp <= '0'; end if;
         end if;
      end if;
   end process;

   -- palette addressing, byte addresses exactly as v1 formed them:
   --   4bpp        : palno & nibble & '0'
   --   8bpp std    : colour & '0'          (palno ignored - GBA behaviour)
   --   8bpp extpal : slot & palno & colour & '0'
   h_pbyte <= unsigned(h_palno & h_idx(3 downto 0) & '0') when cfg_hicolor = '0' else
              unsigned(h_idx & '0');
   h_ebyte <= unsigned(std_logic_vector(cfg_slot) & h_palno & h_idx & '0');

   PALETTE_Drawer_addr <= to_integer(h_pbyte(8 downto 2));
   EXTPAL_Drawer_addr  <= to_integer(h_ebyte(14 downto 2));

   -- ==========================================================================
   -- one clocked process owns the whole drawer: configuration, the fetch side
   -- and the pixel side. They share the tile queue, so keeping them in one
   -- process is what makes "allocate, complete and pop in the same cycle" safe.
   -- ==========================================================================
   process (clk)
      variable v_tq    : t_tq;
      variable v_cnt   : integer range 0 to TQ_DEPTH;
      variable v_tail  : integer range 0 to TQ_DEPTH-1;
      variable v_head  : integer range 0 to TQ_DEPTH-1;
      variable v_tagc  : integer range 0 to TAG_DEPTH;
      variable v_tagh  : integer range 0 to TAG_DEPTH-1;
      variable v_tagt  : integer range 0 to TAG_DEPTH-1;
      variable v_ftile : integer range 0 to 33;
      variable issued  : boolean;
      variable tg      : t_tag;
      variable info    : std_logic_vector(15 downto 0);
      variable sel     : integer range 0 to TQ_DEPTH-1;
      variable found   : boolean;
      variable ys      : integer range 0 to 1023;
      variable advance : boolean;
      -- map / char address arithmetic
      variable xsb     : integer range 0 to 1023;
      variable tidx    : integer range 0 to 3072;
      variable taddr   : integer range 0 to 4095;
      variable mbyte   : integer range 0 to 524287;
      variable mword   : unsigned(16 downto 0);
      variable crow    : integer range 0 to 7;
      variable cbyte   : integer range 0 to 524287;
   begin
      if rising_edge(clk) then

         VRAM_Drawer_req <= '0';
         pixel_we        <= '0';

         if (VRAM_Drawer_accept = '1') then
            unaccepted <= '0';
         end if;

         -- ------------------------------------------------------------------
         -- start of line: latch configuration, reset both sides
         -- ------------------------------------------------------------------
         if (drawline = '1') then
            cfg_hicolor  <= hicolor;
            cfg_extpal   <= extpalette;
            cfg_slot     <= extpal_slot;
            cfg_mosaic   <= mosaic;
            cfg_mossize  <= Mosaic_H_Size;
            cfg_size     <= screensize;
            cfg_mapbase  <= mapbase;
            cfg_tilebase <= tilebase;
            cfg_scrollx  <= scrollX;

            cfg_x512 <= '0';
            if (screensize = "01" or screensize = "11") then
               cfg_x512 <= '1';
            end if;

            if (mosaic = '1') then
               ys := ypos_mosaic + to_integer(scrollY);
            else
               ys := ypos + to_integer(scrollY);
            end if;
            cfg_offset_y <= ((ys mod 256) / 8) * 32;
            if (screensize = "10" or screensize = "11") then
               cfg_ymod <= ys mod 512;
            else
               cfg_ymod <= ys mod 256;
            end if;
            cfg_row <= ys mod 8;

            if (scrollX(2 downto 0) = "000") then
               cfg_ntiles <= 32;
            else
               cfg_ntiles <= 33;
            end if;

            tq          <= (others => TQ_INIT);
            tq_head     <= 0;
            tq_tail     <= 0;
            tq_count    <= 0;
            tag_head    <= 0;
            tag_tail    <= 0;
            tag_count   <= 0;
            f_tile      <= 0;
            mapc_valid  <= '0';
            unaccepted  <= '0';

            busy        <= '1';
            p_active    <= '1';
            p_x         <= 0;
            p_sub       <= to_integer(scrollX(2 downto 0));
            mosaik_cnt  <= 15;          -- v1: the first pixel must fetch
            last_transp <= '1';
            pixeldata(15) <= '1';
            w_valid     <= '0';

         else

            v_tq    := tq;
            v_cnt   := tq_count;
            v_tail  := tq_tail;
            v_head  := tq_head;
            v_tagc  := tag_count;
            v_tagh  := tag_head;
            v_tagt  := tag_tail;
            v_ftile := f_tile;
            issued  := false;
            advance := false;

            -- ===============================================================
            -- FETCH: responses, in issue order
            -- ===============================================================
            if (VRAM_Drawer_done = '1' and v_tagc > 0) then
               tg := tagq(v_tagh);
               if (tg.kind = T_MAP) then
                  -- cache the word; its other half is the next tile, free
                  mapc_addr  <= tg.maddr;
                  mapc_data  <= VRAM_Drawer_data;
                  mapc_valid <= '1';
                  if (tg.odd = '1') then
                     info := VRAM_Drawer_data(31 downto 16);
                  else
                     info := VRAM_Drawer_data(15 downto 0);
                  end if;
                  v_tq(tg.slot).palno  := info(15 downto 12);
                  v_tq(tg.slot).hflip  := info(10);
                  v_tq(tg.slot).vflip  := info(11);
                  v_tq(tg.slot).tileno := unsigned(info(9 downto 0));
                  if (cfg_hicolor = '0') then
                     v_tq(tg.slot).need := 1;
                     v_tq(tg.slot).left := 1;
                  else
                     v_tq(tg.slot).need := 2;
                     v_tq(tg.slot).left := 2;
                  end if;
                  v_tq(tg.slot).issued := 0;
                  v_tq(tg.slot).state  := E_CHARNEED;
               else
                  if (tg.half = 1) then
                     v_tq(tg.slot).row(63 downto 32) := VRAM_Drawer_data;
                  else
                     v_tq(tg.slot).row(31 downto 0)  := VRAM_Drawer_data;
                  end if;
                  v_tq(tg.slot).left := v_tq(tg.slot).left - 1;
                  if (v_tq(tg.slot).left = 0) then
                     v_tq(tg.slot).state := E_READY;
                  end if;
               end if;
               v_tagh := (v_tagh + 1) mod TAG_DEPTH;
               v_tagc := v_tagc - 1;
            end if;

            -- ===============================================================
            -- FETCH: issue a char word. Oldest entry first, and an entry may
            -- have both of its 8bpp words outstanding at once (issued tracks
            -- how many were asked for, left how many are still owed).
            -- ===============================================================
            if (v_tagc < TAG_DEPTH and (unaccepted = '0' or VRAM_Drawer_accept = '1')) then
               found := false;
               sel   := 0;
               for k in 0 to TQ_DEPTH-1 loop
                  if (not found) then
                     sel := (v_head + k) mod TQ_DEPTH;
                     if ((v_tq(sel).state = E_CHARNEED or v_tq(sel).state = E_CHARREQ)
                         and v_tq(sel).issued < v_tq(sel).need) then
                        found := true;
                     end if;
                  end if;
               end loop;
               if (found) then
                  if (v_tq(sel).vflip = '1') then
                     crow := 7 - cfg_row;
                  else
                     crow := cfg_row;
                  end if;
                  if (cfg_hicolor = '0') then
                     cbyte := (to_integer(cfg_tilebase) +
                               to_integer(v_tq(sel).tileno) * 32 + crow * 4) mod 524288;
                  else
                     cbyte := (to_integer(cfg_tilebase) +
                               to_integer(v_tq(sel).tileno) * 64 + crow * 8 +
                               v_tq(sel).issued * 4) mod 524288;
                  end if;
                  VRAM_Drawer_addr <= to_integer(to_unsigned(cbyte, 19)(18 downto 2));
                  VRAM_Drawer_req  <= '1';
                  unaccepted       <= '1';
                  tagq(v_tagt)     <= (T_CHAR, sel, v_tq(sel).issued, '0',
                                       (others => '0'));
                  v_tagt := (v_tagt + 1) mod TAG_DEPTH;
                  v_tagc := v_tagc + 1;
                  v_tq(sel).issued := v_tq(sel).issued + 1;
                  v_tq(sel).state  := E_CHARREQ;
                  issued := true;
               end if;
            end if;

            -- ===============================================================
            -- FETCH: allocate the next tile (map word from cache, or request)
            -- ===============================================================
            if (v_cnt < TQ_DEPTH and v_ftile < cfg_ntiles) then
               -- the tile's x_scrolled base: v1's CALCADDR on the tile-aligned
               -- x, which is the same value for all eight of its pixels
               xsb := to_integer(cfg_scrollx) - to_integer(cfg_scrollx(2 downto 0))
                      + v_ftile * 8;
               if (cfg_x512 = '1') then
                  xsb := xsb mod 512;
               else
                  xsb := xsb mod 256;
               end if;
               tidx := 0;
               if (xsb >= 256 or (cfg_ymod >= 256 and cfg_size = "10")) then
                  tidx := tidx + 1024;
               end if;
               if (cfg_ymod >= 256 and cfg_size = "11") then
                  tidx := tidx + 2048;
               end if;
               taddr := tidx + cfg_offset_y + ((xsb mod 256) / 8);
               mbyte := (to_integer(cfg_mapbase) + taddr * 2) mod 524288;
               mword := to_unsigned(mbyte, 19)(18 downto 2);

               v_tq(v_tail).row    := (others => '0');
               v_tq(v_tail).issued := 0;

               if (mapc_valid = '1' and mapc_addr = mword) then
                  -- the second tile of a map word: its info is already here
                  if (mbyte mod 4 = 2) then
                     info := mapc_data(31 downto 16);
                  else
                     info := mapc_data(15 downto 0);
                  end if;
                  v_tq(v_tail).palno  := info(15 downto 12);
                  v_tq(v_tail).hflip  := info(10);
                  v_tq(v_tail).vflip  := info(11);
                  v_tq(v_tail).tileno := unsigned(info(9 downto 0));
                  if (cfg_hicolor = '0') then
                     v_tq(v_tail).need := 1;
                     v_tq(v_tail).left := 1;
                  else
                     v_tq(v_tail).need := 2;
                     v_tq(v_tail).left := 2;
                  end if;
                  v_tq(v_tail).state := E_CHARNEED;
                  v_tail  := (v_tail + 1) mod TQ_DEPTH;
                  v_cnt   := v_cnt + 1;
                  v_ftile := v_ftile + 1;
               elsif (not issued and v_tagc < TAG_DEPTH and
                      (unaccepted = '0' or VRAM_Drawer_accept = '1')) then
                  VRAM_Drawer_addr <= to_integer(mword);
                  VRAM_Drawer_req  <= '1';
                  unaccepted       <= '1';
                  tg := (T_MAP, v_tail, 0, '0', mword);
                  if (mbyte mod 4 = 2) then
                     tg.odd := '1';
                  end if;
                  tagq(v_tagt) <= tg;
                  v_tagt := (v_tagt + 1) mod TAG_DEPTH;
                  v_tagc := v_tagc + 1;
                  v_tq(v_tail).need   := 0;
                  v_tq(v_tail).left   := 0;
                  v_tq(v_tail).state  := E_MAPREQ;
                  v_tail  := (v_tail + 1) mod TQ_DEPTH;
                  v_cnt   := v_cnt + 1;
                  v_ftile := v_ftile + 1;
                  issued  := true;
               end if;
            end if;

            -- ===============================================================
            -- PIXEL stage 1: one pixel per cycle out of the head entry
            -- ===============================================================
            w_valid <= '0';
            if (p_active = '1') then
               if (cfg_mosaic = '1' and mosaik_cnt < to_integer(cfg_mossize)) then
                  -- mosaic repeat: re-emit the last colour, no palette read.
                  -- v1 wrote `pixel_we <= not pixeldata(15)`, i.e. repeat
                  -- unless the source pixel was transparent.
                  mosaik_cnt <= mosaik_cnt + 1;
                  w_valid    <= '1';
                  w_repeat   <= '1';
                  w_transp   <= '0';
                  w_rep_we   <= not last_transp;
                  w_x        <= p_x;
                  advance    := true;
               elsif (h_ready = '1') then
                  mosaik_cnt <= 0;
                  w_valid    <= '1';
                  w_repeat   <= '0';
                  w_x        <= p_x;
                  w_ext      <= cfg_hicolor and cfg_extpal;
                  if (h_transp = '1') then
                     w_transp    <= '1';
                     last_transp <= '1';
                  else
                     w_transp    <= '0';
                     last_transp <= '0';
                     if ((cfg_hicolor and cfg_extpal) = '1') then
                        w_hi <= h_ebyte(1);
                     else
                        w_hi <= h_pbyte(1);
                     end if;
                  end if;
                  advance := true;
               end if;
            end if;

            if (advance) then
               if (p_x = 255) then
                  p_active <= '0';
                  p_x      <= 256;
               else
                  p_x <= p_x + 1;
               end if;
               if (p_sub = 7) then
                  -- last pixel of the head tile: retire it
                  p_sub  <= 0;
                  v_tq(v_head).state := E_FREE;
                  v_head := (v_head + 1) mod TQ_DEPTH;
                  v_cnt  := v_cnt - 1;
               else
                  p_sub <= p_sub + 1;
               end if;
            end if;

            -- ===============================================================
            -- PIXEL stage 2: the palette word has arrived
            -- ===============================================================
            if (w_valid = '1') then
               pixel_x <= w_x;
               if (w_repeat = '1') then
                  -- pixeldata still holds the last colour, so just re-write it
                  pixel_we <= w_rep_we;
               elsif (w_transp = '1') then
                  pixeldata(15) <= '1';
               else
                  pixel_we <= '1';
                  if (w_ext = '1') then
                     if (w_hi = '1') then
                        pixeldata <= '0' & EXTPAL_Drawer_data(30 downto 16);
                     else
                        pixeldata <= '0' & EXTPAL_Drawer_data(14 downto 0);
                     end if;
                  else
                     if (w_hi = '1') then
                        pixeldata <= '0' & PALETTE_Drawer_data(30 downto 16);
                     else
                        pixeldata <= '0' & PALETTE_Drawer_data(14 downto 0);
                     end if;
                  end if;
               end if;
            end if;

            -- busy drops only once the last pixel has left stage 2
            if (p_active = '0' and w_valid = '0') then
               busy <= '0';
            end if;

            tq        <= v_tq;
            tq_head   <= v_head;
            tq_tail   <= v_tail;
            tq_count  <= v_cnt;
            tag_head  <= v_tagh;
            tag_tail  <= v_tagt;
            tag_count <= v_tagc;
            f_tile    <= v_ftile;

         end if;
      end if;
   end process;

end architecture;
