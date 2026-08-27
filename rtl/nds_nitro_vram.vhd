-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Product-local derivative of authenticated Nitro_DarkSide
-- d2dabe/rtl/nds_vram.vhd at commit
-- d2dabe03344c0a685cd0f00e42b1a89606710dee.
-- Donor SHA-256: a9d3fe072906adb6d0c7ee7874e4d6ca5a6c9d2f7d2cb19d6c32c73b253b3aa8.
-- Intentional delta: retain the eight per-renderer-channel A..D line caches
-- and add two ownerless victim lines keyed by physical bank plus line.
-- Late backing responses cannot refill after a CPU or posted-write invalidation.
-- This is an experimental board-measurement optimization. It removed the
-- bounded line-130 overrun, but sustained frame simulation still dropped lines.
-- NDS VRAM subsystem — bank stores + CPU datapath + renderer line server (v1).
--
-- Decode is nds_vram_map (unit-tested against the SDK truth table). This module
-- adds the storage and the hardware semantics:
--   * overlapping banks: writes fan out to ALL hit banks, reads OR all hit banks
--   * unmapped reads return 0
--   * banks E..I (144 KB total) are on-chip BRAM (port A = CPU, port B = renderer)
--   * banks A..D (512 KB) live behind the srv_* channel — in the real core that
--     is an SDRAM guest client (docs/MEMORY_MAP.md "Renderer feed"); testbenches
--     attach a behavioral model
--
-- CPU port protocol (both ports): pulse ena with rnw/addr/be/din held stable
-- until done; done pulses for exactly one cycle; reads: dout valid with done.
-- One op in flight per port; ops from the two ports are serialized internally
-- (fairness: alternating grant), matching the single VRAM arbiter on hardware.
--
-- Renderer line server v1 (engine A): four read-only request channels in the
-- renderer's flat spaces —
--   rdr_bg     512 KB main-BG space   (banks A..D MST=1, E MST=1, F/G MST=1)
--   rdr_obj    256 KB main-OBJ space  (banks A/B MST=2, E MST=2, F/G MST=2)
--   rdr_bgep    32 KB BG ext palette, 4 slots (E MST=4 all, F/G MST=4 by OFS.0)
--   rdr_objep    8 KB OBJ ext palette (F/G MST=5)
-- and the engine-B set (M6):
--   rdr_bgb    128 KB sub-BG space    (C MST=4, H MST=1, I MST=1 @ 0x8000)
--   rdr_objb   128 KB sub-OBJ space   (D MST=4, I MST=2)
--   rdr_bgepb   32 KB BG ext palette  (H MST=2, all 4 slots)
--   rdr_objepb   8 KB OBJ ext palette (I MST=3)
-- Protocol per channel: present req with stable addr; the server pulses accept
-- on the cycle it takes the request, and done (1 cycle, dout valid with done)
-- when the word is ready. A channel may hold req until accept, or pulse it for
-- one cycle - either way exactly one request is taken per accept.
--
-- The renderer server is PIPELINED (v2, see the block comment at the pipeline
-- itself): one request accepted per cycle, several in flight, retired IN ISSUE
-- ORDER, so a channel may have several outstanding requests and needs no tags
-- to match answers to asks. E..I hits are BRAM port-B reads (2-cycle
-- latency); A..D hits go through the read-only rsrv_* channel, which is itself
-- pipelined (one op issued per cycle, up to AD_DEPTH outstanding, answered in
-- order, held until rsrv_ready takes them). Multi-hit reads OR, unmapped reads
-- return 0 — same semantics as the CPU side, and the same semantics v1 had.
--
-- v1 was one op at a time through a six-state FSM: five cycles for a BRAM hit,
-- nothing overlapped. On tb_gpu2d_timed it occupied 58-61% of every rendered
-- line. Throughput, not latency, was the problem, so v2 pipelines rather than
-- shortens: latency is now hidden by the clients' prefetch FIFOs instead.
-- Engine B roles (H/I, C/D sub) come with M6.
--
-- Timing is NOT cycle-accurate (M1): a BRAM op answers in 2 cycles, A..D ops
-- in whatever the backing channel takes. Accuracy pass comes with the membus
-- integration.
--
-- Reset clear pass (CLR_BRAM / CLR_SRV / CLR_SRVWAIT). On a MiSTer the FPGA is
-- NOT reconfigured between ROM loads - only the loader re-runs - so every bank
-- keeps the previous game's contents and the new game shows its leftovers until
-- it happens to overwrite them. Real hardware gets VRAM cleared by the firmware
-- boot direct boot skips, exactly like the main RAM zeroing in nds_loader
-- (CLR_WR). The loader has no path to VRAM, so the clear lives here: on reset
-- the FSM walks E..I (all five BRAMs in parallel, one word per cycle) and then
-- A..D through the srv_* write channel it already owns, and holds clr_busy high
-- until it is finished. nds_top gates the CPU release on clr_busy, so the pass
-- is guaranteed to complete before any CPU or renderer request can arrive -
-- it is NOT gated on is_simu, because gating the equivalent main-RAM clear out
-- of simulation is precisely what hid the SWP cartridge-lock bug (see
-- nds_loader.vhd). tb_vram_torture pre-dirties every bank and re-asserts reset
-- to prove the pass actually zeroes them.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

use work.pnds_vram_map.all;

entity nds_vram is
   generic
   (
      is_simu : std_logic := '0';
      -- Posted A..D writes: correct and measured, but 4,197..4,204 LABs across
      -- four fitter seeds against the 4,191 this device has, on an image that
      -- already fitted by 2. Held behind a generic so the RTL lives in the tree
      -- and can be A/B'd for area the way every other tradeoff in NDS.qsf is,
      -- rather than being carried on a branch or deleted.
      --
      -- false makes cpu9_welig/cpu9_wok constant '0', so nds_dma9 never presents
      -- a posted write, nothing ever enters the queue, and synthesis removes the
      -- whole thing: 7 cycles per 16-bit unit into VRAM D instead of 2, and
      -- [04-02] fails as it did before.
      --
      -- It is an A/B MEASUREMENT knob, not a shipping fallback, and the
      -- measurement it produced is the surprising part: false still needs 4,214
      -- LABs where true needs 4,197..4,204. Deleting the entire queue does not
      -- get this image back under 4,191, because the queue was never the
      -- expensive half - the combinational single-cycle fast-lane request in
      -- nds_dma9 is, and that one is unconditional because it is what makes an
      -- access one cycle. If you are hunting the ~10-25 LABs, hunt there or
      -- outside this module; do not spend another fit on WQ_DEPTH.
      POSTED_WRITES : boolean := true
   );
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      -- VRAMCNT_A..I raw bytes (from the GX register bank)
      vramcnt   : in  std_logic_vector(71 downto 0);

      -- ARM9 CPU port (word ops; membus produces BE for byte/halfword)
      cpu9_ena  : in  std_logic;
      cpu9_rnw  : in  std_logic;
      cpu9_addr : in  unsigned(23 downto 2);
      cpu9_be   : in  std_logic_vector(3 downto 0);
      cpu9_din  : in  std_logic_vector(31 downto 0);
      cpu9_dout : out std_logic_vector(31 downto 0) := (others => '0');
      cpu9_done : out std_logic := '0';
      -- Posted writes, opt-in. With cpu9_wpost held, a write that lands in
      -- exactly one of banks A..D and nowhere else is taken into a short queue
      -- and acknowledged by cpu9_wok in the SAME cycle cpu9_ena is presented -
      -- no cpu9_done follows for it. The queue drains over srv_* in the
      -- background and combines adjacent halfwords into whole words, which is
      -- what makes it keep up: a 16-bit-per-2-cycles writer produces one word
      -- every 4 cycles and srv_* sustains one every 3.
      --
      -- Only nds_dma9 asks for this. The requester must check cpu9_wok in the
      -- cycle it presents the access and hold the access until it is high; a
      -- write that is not eligible (multi-bank, or E..I) leaves cpu9_wok low and
      -- goes down the ordinary cpu9_done path unchanged.
      cpu9_wpost : in  std_logic := '0';
      cpu9_welig : out std_logic;
      cpu9_wok   : out std_logic;

      -- ARM7 CPU port (only banks C/D in MST=2 can ever hit)
      cpu7_ena  : in  std_logic;
      cpu7_rnw  : in  std_logic;
      cpu7_addr : in  unsigned(23 downto 2);
      cpu7_be   : in  std_logic_vector(3 downto 0);
      cpu7_din  : in  std_logic_vector(31 downto 0);
      cpu7_dout : out std_logic_vector(31 downto 0) := (others => '0');
      cpu7_done : out std_logic := '0';

      -- banks A..D backing-store channel (SDRAM guest client / sim model)
      -- req held high with stable payload until done pulses
      srv_req   : out std_logic := '0';
      srv_rnw   : out std_logic := '1';
      srv_bank  : out std_logic_vector(1 downto 0) := "00";
      srv_addr  : out unsigned(16 downto 2) := (others => '0');
      srv_be    : out std_logic_vector(3 downto 0) := (others => '0');
      srv_din   : out std_logic_vector(31 downto 0) := (others => '0');
      srv_dout  : in  std_logic_vector(31 downto 0);
      srv_done  : in  std_logic;

      -- renderer line-server channels (read-only; see header). accept pulses
      -- the cycle the server takes the request - a client may present the
      -- next one immediately and have several outstanding, answered in order.
      rdr_bg_req     : in  std_logic := '0';
      rdr_bg_addr    : in  unsigned(18 downto 2) := (others => '0');
      rdr_bg_dout    : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bg_done    : out std_logic := '0';
      rdr_bg_accept  : out std_logic := '0';

      rdr_obj_req    : in  std_logic := '0';
      rdr_obj_addr   : in  unsigned(17 downto 2) := (others => '0');
      rdr_obj_dout   : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_obj_done   : out std_logic := '0';
      rdr_obj_accept : out std_logic := '0';

      rdr_bgep_req   : in  std_logic := '0';
      rdr_bgep_addr  : in  unsigned(14 downto 2) := (others => '0');
      rdr_bgep_dout  : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgep_done  : out std_logic := '0';
      rdr_bgep_accept : out std_logic := '0';

      rdr_objep_req  : in  std_logic := '0';
      rdr_objep_addr : in  unsigned(12 downto 2) := (others => '0');
      rdr_objep_dout : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objep_done : out std_logic := '0';
      rdr_objep_accept : out std_logic := '0';

      rdr_bgb_req    : in  std_logic := '0';
      rdr_bgb_addr   : in  unsigned(16 downto 2) := (others => '0');
      rdr_bgb_dout   : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgb_done   : out std_logic := '0';
      rdr_bgb_accept : out std_logic := '0';

      rdr_objb_req   : in  std_logic := '0';
      rdr_objb_addr  : in  unsigned(16 downto 2) := (others => '0');
      rdr_objb_dout  : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objb_done  : out std_logic := '0';
      rdr_objb_accept : out std_logic := '0';

      rdr_bgepb_req  : in  std_logic := '0';
      rdr_bgepb_addr : in  unsigned(14 downto 2) := (others => '0');
      rdr_bgepb_dout : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgepb_done : out std_logic := '0';
      rdr_bgepb_accept : out std_logic := '0';

      rdr_objepb_req : in  std_logic := '0';
      rdr_objepb_addr: in  unsigned(12 downto 2) := (others => '0');
      rdr_objepb_dout: out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objepb_done: out std_logic := '0';
      rdr_objepb_accept : out std_logic := '0';

      -- high from reset until the reset clear pass has zeroed every bank;
      -- nds_top holds the CPUs until it drops (see the header)
      clr_busy  : out std_logic := '1';

      -- Renderer A..D backing channel (read-only), PIPELINED: up to AD_DEPTH
      -- ops may be outstanding and rsrv_done pulses once per completed op IN
      -- ISSUE ORDER. v1 held req until done and allowed exactly one op, which
      -- on hardware means the renderer pays full SDRAM latency per word with
      -- nothing overlapped - the dominant cost of the whole render path there,
      -- since for a typical title all BG char/map data lives in banks A..D.
      --
      -- rsrv_req/rsrv_ready is a VALID/READY handshake: the request is
      -- presented and HELD until a rising edge at which rsrv_ready is high,
      -- and that edge is the transfer. It is the same edge the channel samples
      -- rsrv_req on, so the two ends can never disagree about which requests
      -- were taken.
      --
      -- It must be a held level, not a pulse. rsrv_ready cannot reflect a
      -- request that has not been presented yet, so a pulse is always issued on
      -- a STALE ready, and whether that is safe depends on how quickly ready
      -- falls after the channel accepts. It was not safe against the bench's
      -- model of the hardware channel, whose busy rises only once it has SAMPLED
      -- the request: ready then reads high for two consecutive cycles, the core
      -- issues a second op into a one-deep channel, that op is dropped, and the
      -- queue entry owes a word forever. A held request has no such dependence,
      -- and needs no knowledge of the channel's depth or latency.
      --
      -- (On hardware the same pulse scheme happened NOT to drop - NDS.sv's ready
      -- is combinational and falls a third of a clk1x period before the core
      -- samples again. It was correct by coincidence. The hardware white screen
      -- was the drawline livelock in nds_gpu2d, not this.)
      --
      -- rsrv_ready defaults high so a backing model that is always ready needs
      -- no wiring change: with ready tied high the wire frees every cycle, so
      -- this degenerates to exactly the old one-op-per-cycle pulse stream.
      --
      -- The channel is 64 BITS WIDE and addressed by 8-byte LINE, not by word.
      -- sdram.sv's ch1 already reads four halfwords per access (BURST_LENGTH=4,
      -- sequential, so the aligned 8-byte block containing the request) and
      -- NDS.sv was using 32 bits of it and throwing the rest away. Asking for the
      -- aligned line makes the burst wrap irrelevant - a sequential SDRAM burst
      -- wraps inside its aligned block, so an unaligned request would return the
      -- same eight bytes rotated - and doubles what one access yields.
      --
      -- Paired with the per-channel line cache below, this removed 76% of A..D
      -- reads on the mode-0 bench (measured, LINEPROBE in tb_top_frame). A single
      -- SHARED line would have been worthless: measured 1%, because the eight
      -- renderer channels interleave and each evicts the others. Each channel
      -- walking its own address run is exactly what a per-channel line fits.
      rsrv_req   : out std_logic := '0';
      rsrv_bank  : out std_logic_vector(1 downto 0) := "00";
      rsrv_addr  : out unsigned(16 downto 3) := (others => '0');
      rsrv_dout  : in  std_logic_vector(63 downto 0) := (others => '0');
      rsrv_done  : in  std_logic := '0';
      rsrv_ready : in  std_logic := '1';

      -- Renderer-side server busy: work is in flight in the completion queue.
      -- Exposed as a PORT because the queue is declared in this architecture
      -- and cannot be reached by a bench external name, and because measuring
      -- occupancy from srv_*_req does NOT work:
      -- nds_gpu2d drives req as a one-cycle pulse, so counting req-asserted
      -- cycles counts REQUESTS, not waiting time (measured 0.94 cycles per op
      -- where an op takes ~4).
      dbg_rbusy    : out std_logic
   );
end entity;

architecture arch of nds_vram is

   -- per-port decoders (combinational, on the live address)
   signal dec9_hit  : std_logic_vector(8 downto 0);
   signal dec9_offs : t_vram_offs;
   signal dec7_hit  : std_logic_vector(8 downto 0);
   signal dec7_offs : t_vram_offs;

   -- latched requests
   type t_req is record
      valid : std_logic;
      rnw   : std_logic;
      be    : std_logic_vector(3 downto 0);
      din   : std_logic_vector(31 downto 0);
      hit   : std_logic_vector(8 downto 0);
      offs  : t_vram_offs;
   end record;
   constant REQ_INIT : t_req := ('0', '1', (others => '0'), (others => '0'), (others => '0'), (others => (others => '0')));
   signal req9, req7 : t_req := REQ_INIT;

   -- main FSM
   type tstate is
   (
      IDLE,
      BRAMWAIT,   -- E..I registered read settles
      BRAMREAD,   -- capture + OR the BRAM dataouts
      SRVSCAN,    -- multi-bank continuation only: re-arm srv_req for bank n+1
      SRVWAIT,    -- wait for server done
      WQ_WAIT,    -- posted-write drain: wait for the server
      CLR_BRAM,   -- reset clear: sweep E..I (all five in parallel)
      CLR_SRV,    -- reset clear: issue one A..D word write
      CLR_SRVWAIT -- reset clear: wait for the server
   );
   signal state    : tstate := CLR_BRAM;
   signal cur      : t_req := REQ_INIT;
   signal cur_is9  : std_logic := '0';
   signal acc      : std_logic_vector(31 downto 0) := (others => '0');
   signal srv_idx  : integer range 0 to 4 := 0;
   signal prefer9  : std_logic := '1';
   -- VHDL-93 does not permit reading an OUT port. Keep the live backing-store
   -- identity internally because the renderer coherency process must compare
   -- cache tags against the write being presented.
   signal srv_bank_int : std_logic_vector(1 downto 0) := (others => '0');
   signal srv_addr_int : unsigned(16 downto 2) := (others => '0');

   -- Lowest A..D bank at or above `from_idx` that this request hits, or 4 for
   -- none. This used to be a state of its own (SRVSCAN) evaluated once before
   -- the first srv op and once more after the last one just to discover there
   -- was no next bank, plus a FINISH state to hand the result back. It is a
   -- pure function of the hit mask, so it folds into the cycles that already
   -- know the answer: the dispatch edge and the srv_done edge. Nearly every
   -- access hits exactly one bank, and that path drops 8 cycles to 5.
   --
   -- SRVSCAN survives for the multi-bank case only. There it is not overhead:
   -- srv_req has to drop for a cycle between ops for the server to see a new
   -- request, so the continuation needs an idle cycle regardless.
   function ad_next (hit : std_logic_vector(8 downto 0); from_idx : integer) return integer is
      variable n : integer range 0 to 4 := 4;
   begin
      for i in BANK_D downto BANK_A loop
         if (i >= from_idx and hit(i) = '1') then
            n := i;
         end if;
      end loop;
      return n;
   end function;

   -- ==================== posted write queue (A..D) ====================
   -- A..D leave the chip over srv_*, which takes several cycles per word. That
   -- latency is unavoidable, but it does not have to be in the writer's way: a
   -- write has no result to wait for. So eligible writes are queued and
   -- acknowledged on the spot, and the queue drains behind them.
   --
   -- What this buys, and the whole reason it exists: it lets a DMA sustain one
   -- 16-bit unit every two bus cycles, which is what real hardware does and what
   -- the NITRO Tester's [04-02] measures. See docs/NTR_EVA_TESTER.md.
   --
   -- What it costs is a read-after-write window that silicon does not have, and
   -- three readers can fall into it: the cpu9/cpu7 port, the renderer's rsrv
   -- channel, and the A..D line cache. Each is closed below, and the closures
   -- are levels rather than edges for the same reason the pre-existing srv_req
   -- invalidation is - a level cannot be missed.
   -- Depth is an AREA decision, not a comfort one: this core fits in 4,189 of
   -- the device's 4,191 LABs, so every entry is 54 registers that have to come
   -- from somewhere. Depth 4 was headroom rather than a requirement - with
   -- combining, the push and drain rates are both one word per 4 cycles, so the
   -- queue absorbs jitter, not a rate mismatch.
   --
   -- 3 is MEASURED, not chosen for comfort. 2 is the smallest that can work at
   -- all - one entry draining while the next fills - and it does not hold: even
   -- with cpu9_wok widened to count the pop landing on the same edge, dmaprio
   -- comes back with deltas of [2, 4] rather than [2]. A handful of units in 2048
   -- taking 4 cycles is enough to fail [04-02], which wants exactly 2 everywhere.
   --
   -- Beware the census average when checking this: 4,101 cycles over 2,048 units
   -- prints as "2/unit" and hides the 4s completely. sim/tests/dmaprio/check.py
   -- walks the per-step deltas, and that is the number that decides.
   --
   -- 3 is also not free the way 2 and 4 are - `mod 3` synthesises to comparators
   -- where a power of two is a dropped carry, which is why 4 -> 3 bought only 25
   -- ALMs of the ~130 its registers should have been worth.
   constant WQ_DEPTH : integer := 3;

   type t_wq_entry is record
      valid : std_logic;
      bank  : integer range BANK_A to BANK_D;
      addr  : unsigned(16 downto 2);
      be    : std_logic_vector(3 downto 0);
      din   : std_logic_vector(31 downto 0);
   end record;
   constant WQ_INIT : t_wq_entry := ('0', BANK_A, (others => '0'), (others => '0'), (others => '0'));
   type t_wq is array (0 to WQ_DEPTH-1) of t_wq_entry;

   signal wq       : t_wq := (others => WQ_INIT);
   signal wq_head  : integer range 0 to WQ_DEPTH-1 := 0;
   signal wq_tail  : integer range 0 to WQ_DEPTH-1 := 0;
   signal wq_count : integer range 0 to WQ_DEPTH := 0;

   -- combinational eligibility, so the requester can decide in the cycle it
   -- presents the access
   signal wq_elig     : std_logic;
   signal wq_push_now : std_logic;
   signal wq_bank_now : integer range 0 to 4;

   -- the 64-bit renderer line the write being accepted on this edge lands in
   signal wq_push_line : unsigned(16 downto 3);

   -- Does a write that has not reached the store yet cover this 64-bit line?
   -- Includes the one being accepted on this very edge, so a reader gated on
   -- registered state cannot slip through the cycle in between.
   --
   -- This was per-BANK first, and that was far too coarse: a burst uploading into
   -- the bank being displayed held the renderer off for the whole burst, and
   -- tb_top_frame duly dropped a line. Real hardware interleaves DMA and render
   -- accesses at word granularity, so blocking a whole bank is not the authentic
   -- behaviour either. Per-line costs 5 comparators and makes the renderer wait
   -- only when it genuinely wants the words being written.
   function wq_touches(q : t_wq; pushv : std_logic; pbank : integer;
                       pline : unsigned(16 downto 3);
                       bank : integer; line : unsigned(16 downto 3)) return boolean is
   begin
      if (pushv = '1' and pbank = bank and pline = line) then
         return true;
      end if;
      for k in 0 to WQ_DEPTH-1 loop
         if (q(k).valid = '1' and q(k).bank = bank and q(k).addr(16 downto 3) = line) then
            return true;
         end if;
      end loop;
      return false;
   end function;

   -- Conservative bank-level conflict predicate used only by the victim cache's
   -- in-flight fill-safety bit. The functional issue gate above remains the
   -- exact-line predicate, so renderer timing is not changed by an unrelated
   -- write in the same bank; only whether the eventual response may refill a
   -- cache is affected.
   function wq_bank_active(q : t_wq; pushv : std_logic; pbank : integer;
                           bank : integer) return boolean is
   begin
      if (pushv = '1' and pbank = bank) then
         return true;
      end if;
      for k in 0 to WQ_DEPTH-1 loop
         if (q(k).valid = '1' and q(k).bank = bank) then
            return true;
         end if;
      end loop;
      return false;
   end function;

   -- reset clear pass: one counter for both phases (E..I sweep 0..16383,
   -- each A..D bank 0..32767)
   signal clr_addr : unsigned(14 downto 0) := (others => '0');
   signal clr_bank : integer range 0 to 3 := 0;
   signal clr_bram_en : std_logic;                    -- combinational: state = CLR_BRAM
   constant CLR_BRAM_LAST : natural := 16383;      -- bank E, the largest BRAM
   constant CLR_SRV_LAST  : natural := 32767;      -- 128 KB per A..D bank

   -- E..I BRAM plumbing (CPU side = port A; renderer = port B)
   type t_bram_dout is array (BANK_E to BANK_I) of std_logic_vector(31 downto 0);
   signal bram_dout : t_bram_dout;
   signal bram_ce   : std_logic_vector(BANK_E to BANK_I);
   signal bram_we   : std_logic_vector(BANK_E to BANK_I);

   signal dispatch    : std_logic;
   signal chosen      : t_req;
   signal chosen_is9  : std_logic;

   type t_addrwidth is array (BANK_E to BANK_I) of natural;
   constant BRAM_AW : t_addrwidth := (BANK_E => 14, BANK_F => 12, BANK_G => 12, BANK_H => 13, BANK_I => 12);

   -- port-A payload: normally the dispatched CPU op, during the clear pass the
   -- sweep counter with an all-bytes zero write
   type t_bram_addr is array (BANK_E to BANK_I) of unsigned(13 downto 0);
   signal bram_addr_a : t_bram_addr;
   signal bram_din_a  : std_logic_vector(31 downto 0);
   signal bram_be_a   : std_logic_vector(3 downto 0);

   -- ==================== renderer line server ====================

   -- BG/OBJ channels reuse the CPU decoder at the canonical region addresses
   signal rdec_bg_addr   : unsigned(23 downto 0);
   signal rdec_obj_addr  : unsigned(23 downto 0);
   signal rdec_bgb_addr  : unsigned(23 downto 0);
   signal rdec_objb_addr : unsigned(23 downto 0);
   signal rdec_bg_hit    : std_logic_vector(8 downto 0);
   signal rdec_bg_offs   : t_vram_offs;
   signal rdec_obj_hit   : std_logic_vector(8 downto 0);
   signal rdec_obj_offs  : t_vram_offs;
   signal rdec_bgb_hit   : std_logic_vector(8 downto 0);
   signal rdec_bgb_offs  : t_vram_offs;
   signal rdec_objb_hit  : std_logic_vector(8 downto 0);
   signal rdec_objb_offs : t_vram_offs;

   -- ext-palette decode (no CPU mapping; renderer-only roles of E/F/G/H/I)
   signal bgep_hit    : std_logic_vector(8 downto 0);
   signal bgep_offs   : t_vram_offs;
   signal objep_hit   : std_logic_vector(8 downto 0);
   signal objep_offs  : t_vram_offs;
   signal bgepb_hit   : std_logic_vector(8 downto 0);
   signal bgepb_offs  : t_vram_offs;
   signal objepb_hit  : std_logic_vector(8 downto 0);
   signal objepb_offs : t_vram_offs;

   -- ---------------- pipelined renderer server (v2) ----------------
   -- v1 was a six-state FSM serving ONE request at a time: RIDLE -> RBRAMWAIT
   -- -> RBRAMREAD -> RSRVSCAN -> RFINISH, five cycles per op even for a plain
   -- BRAM hit, with nothing overlapped. Measured on tb_gpu2d_timed it was busy
   -- 2,847-2,983 cycles of a 4,794-5,162-cycle rendered line - 58-61% of the
   -- line, against a 2,130-cycle budget for the whole line. That is the wall.
   --
   -- v2 is a pipeline. One request is accepted per cycle and retires IN ORDER
   -- through a completion queue:
   --
   --   S0 (issue)   rotating-priority pick over channels with a pending req;
   --                allocate a queue entry; drive BRAM port B combinationally
   --   S1 (bram)    port-B q is valid one cycle later -> OR into that entry
   --   A..D         entries needing banks A..D issue rsrv ops in queue order;
   --                rsrv returns in order, so each op ORs into its own entry
   --   retire       the HEAD entry, once it has every word it needs, drives
   --                that channel's dout and pulses its done
   --
   -- In-order retirement is what keeps this safe: a channel is allowed several
   -- outstanding requests (the prefetching drawers depend on that) and they
   -- come back in issue order, so no client needs tags. Head-of-line blocking
   -- costs latency, never throughput, because the backing channel is itself
   -- pipelined and the clients' FIFOs absorb latency.
   --
   -- Semantics preserved from v1 exactly: multi-hit reads OR every hit bank,
   -- unmapped reads return 0, done pulses one cycle with dout valid.
   constant RQ_DEPTH : integer := 8;   -- completion queue entries
   constant AD_DEPTH : integer := 4;   -- rsrv ops allowed in flight

   type t_rq_entry is record
      valid    : std_logic;
      chan     : integer range 0 to 7;
      need_br  : std_logic;                           -- waiting on the BRAM stage
      ad_todo  : std_logic_vector(BANK_A to BANK_D);  -- A..D words not yet issued
      ad_owed  : integer range 0 to 4;                -- A..D words not yet returned
      acc      : std_logic_vector(31 downto 0);
   end record;
   constant RQ_INIT : t_rq_entry :=
      ('0', 0, '0', (others => '0'), 0, (others => '0'));
   type t_rq is array (0 to RQ_DEPTH-1) of t_rq_entry;
   signal rq       : t_rq := (others => RQ_INIT);
   signal rq_head  : integer range 0 to RQ_DEPTH-1 := 0;
   signal rq_tail  : integer range 0 to RQ_DEPTH-1 := 0;
   signal rq_count : integer range 0 to RQ_DEPTH := 0;

   -- the BRAM stage holds at most one entry (one set of port-B reads)
   signal br_valid : std_logic := '0';
   signal br_slot  : integer range 0 to RQ_DEPTH-1 := 0;
   signal br_hit   : std_logic_vector(BANK_E to BANK_I) := (others => '0');

   -- A..D issue walker: which queue slot and which bank it is working on
   signal ad_scan  : integer range 0 to RQ_DEPTH-1 := 0;
   signal ad_hit   : std_logic_vector(BANK_A to BANK_D) := (others => '0');
   signal ad_armed : std_logic := '0';   -- ad_hit/ad_scan describe a live entry
   -- in-flight rsrv ops, in issue order (rsrv returns in order). The response is
   -- an 8-byte line, so the entry also carries which word of it was wanted and
   -- the line's identity, for the cache fill.
   type t_adq_entry is record
      slot : integer range 0 to RQ_DEPTH-1;
      bank : integer range BANK_A to BANK_D;
      hi   : std_logic;                    -- wanted the high word of the line
      chan : integer range 0 to 7;         -- which renderer channel owns the line
      line : unsigned(16 downto 3);
      -- Remains high only if no invalidating CPU/posted
      -- write raced this miss between issue and response. Completion is always
      -- delivered; low suppresses only primary/victim insertion.
      cacheable : std_logic;
   end record;
   type t_adq is array (0 to AD_DEPTH-1) of t_adq_entry;
   signal adq       : t_adq :=
      (others => (0, BANK_A, '0', 0, (others => '0'), '0'));
   signal adq_head  : integer range 0 to AD_DEPTH-1 := 0;
   signal adq_tail  : integer range 0 to AD_DEPTH-1 := 0;
   signal adq_count : integer range 0 to AD_DEPTH := 0;

   signal rreq_vec     : std_logic_vector(7 downto 0);
   signal rpend        : std_logic_vector(7 downto 0) := (others => '0');
   signal rpick        : integer range 0 to 7 := 0;
   signal rpick_valid  : std_logic;
   signal rdispatch    : std_logic;
   signal rchosen_hit  : std_logic_vector(8 downto 0);
   signal rchosen_offs : t_vram_offs;
   signal rr_pri       : integer range 0 to 7 := 0;

   -- per-request A..D word addresses have to survive until the walker issues
   -- them, so the offsets are held per queue slot
   type t_adaddr is array (0 to RQ_DEPTH-1, BANK_A to BANK_D) of unsigned(16 downto 2);
   signal ad_addr : t_adaddr := (others => (others => (others => '0')));

   -- ---- per-channel A..D line cache (see the rsrv_* port comment) ----
   -- One 8-byte line per renderer channel, indexed by channel, so there is no
   -- associative search and no channel can evict another's line: each of the
   -- eight walks its own address run, and the second word of every line it asks
   -- for costs no memory access at all. Measured on the mode-0 bench: 76% of A..D
   -- reads removed. A single shared line measured 1% - the interleave destroys it.
   type t_adline is record
      valid : std_logic;
      bank  : integer range BANK_A to BANK_D;
      line  : unsigned(16 downto 3);
      data  : std_logic_vector(63 downto 0);
   end record;
   constant ADLINE_INIT : t_adline := ('0', BANK_A, (others => '0'), (others => '0'));
   type t_adlines is array (0 to 7) of t_adline;
   signal adline : t_adlines := (others => ADLINE_INIT);

   -- rsrv response staged one cycle before it is used. The completion path
   -- (64:32 mux, OR into acc, retire compare, channel dout register) used to run
   -- in the SAME cycle the response arrived, and rsrv_done is driven from the
   -- clk_mem side: on hardware that made vrsrv_done_r -> rdr_*_dout a cross-domain
   -- path whose setup budget is ONE clkMem period (9.94 ns at 100.5 MHz), not a
   -- clk_sys period, and it needed 13.42 ns - which is how the line cache came in
   -- at -4.50 ns slack. Staging moves all of that arithmetic inside clk_sys with a
   -- full period. It costs one cycle on a path that already takes five and nothing
   -- at all on throughput: one response in per cycle, one consumed per cycle.
   signal rsp_valid : std_logic := '0';
   signal rsp_data  : std_logic_vector(63 downto 0) := (others => '0');

   -- A..D line-cache HIT staged one cycle, for exactly the same reason rsp_* is,
   -- and it is the second half of the same mistake. The hit branch of the issue
   -- stage used to OR its word into v_rq(...).acc and decrement ad_owed in the
   -- cycle it was decided - and that decision is gated on `rsrv_ready`, which on
   -- hardware is driven from clk_mem (NDS.sv's `~vr_pend & (vr_out < 2)`). So
   -- rsrv_ready reached the retire compare and the rdr_*_dout mux
   -- COMBINATIONALLY, across the domain, on a path whose setup budget is ONE
   -- clkMem period rather than a clk_sys one.
   --
   -- That is affordable at 3x (9.945 ns; measured +0.721) and it is not at 4x
   -- (7.459 ns): vr_pend/vr_out -> nds_vram|rdr_*_dout was 48 of the 50 worst
   -- paths in the design at -1.166 ns. Staging moves the whole
   -- accumulate-and-retire chain inside clk_sys with a full period, and the only
   -- cost is that a request finished BY a cache hit retires one cycle later.
   --
   -- Note what is deliberately NOT done: `rsrv_ready` is not registered. That is
   -- the stale-ready wedge the port comment warns about - the issue stage must
   -- still see the live level, because a request is transferred exactly once and
   -- both ends have to agree at the same edge about which edge that was.
   signal adhit_valid : std_logic := '0';
   signal adhit_slot  : integer range 0 to RQ_DEPTH-1 := 0;
   signal adhit_word  : std_logic_vector(31 downto 0) := (others => '0');

   -- Two-entry ownerless victim extension. Entry 0 is MRU and entry 1 is LRU.
   -- Tags are ownerless: any renderer channel may hit a line evicted by any
   -- other channel. The eight `adline` entries remain functional primaries.
   -- A victim hit installs the hit line in the requesting channel's primary and
   -- promotes its displaced primary to victim MRU. A backing fill likewise
   -- installs in primary and inserts the displaced valid primary in the pair.
   type t_adglobal2 is array (0 to 1) of t_adline;
   signal adglobal2 : t_adglobal2 := (others => ADLINE_INIT);

   -- false: no cache, every word costs a memory access (the 64-bit channel still
   -- carries the line, only its low word is used). It was false for one build:
   -- the cache landed at -4.50 ns clk_sys slack where the same tree closed at
   -- +0.91 ns without it. The cache was not really the cause - the completion path
   -- was already crossing clk_mem -> clk_sys and computing in one cycle, with only
   -- one clkMem period of budget, and the cache's mux was simply the straw. See
   -- rsp_valid/rsp_data above.
   constant AD_CACHE_EN : boolean := true;

   signal bram_dout_b : t_bram_dout;
   signal rbram_ce    : std_logic_vector(BANK_E to BANK_I);

   signal rdone_int   : std_logic_vector(7 downto 0) := (others => '0');
   signal rreq_now    : std_logic_vector(7 downto 0);

begin

   srv_bank <= srv_bank_int;
   srv_addr <= srv_addr_int;

   idec9 : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => cpu9_addr & "00", is_arm7 => '0', hit => dec9_hit, offs => dec9_offs );

   idec7 : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => cpu7_addr & "00", is_arm7 => '1', hit => dec7_hit, offs => dec7_offs );

   -- renderer BG/OBJ decode: flat renderer spaces are exactly the ARM9 view of
   -- the main-BG (0x000000) and main-OBJ (0x400000) regions
   rdec_bg_addr   <= "00000" & rdr_bg_addr & "00";
   rdec_obj_addr  <= "010000" & rdr_obj_addr & "00";
   rdec_bgb_addr  <= "0010000" & rdr_bgb_addr & "00";   -- 0x06200000 region
   rdec_objb_addr <= "0110000" & rdr_objb_addr & "00";  -- 0x06600000 region

   irdec_bg : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_bg_addr, is_arm7 => '0', hit => rdec_bg_hit, offs => rdec_bg_offs );

   irdec_obj : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_obj_addr, is_arm7 => '0', hit => rdec_obj_hit, offs => rdec_obj_offs );

   irdec_bgb : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_bgb_addr, is_arm7 => '0', hit => rdec_bgb_hit, offs => rdec_bgb_offs );

   irdec_objb : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_objb_addr, is_arm7 => '0', hit => rdec_objb_hit, offs => rdec_objb_offs );

   -- ext-palette decode (GBATEK "DS Video Memory Control", renderer-only):
   --   BG ext pal, 32 KB / 4 slots: E MST=4 covers all slots; F/G MST=4 cover
   --   slots 0-1 (OFS.0=0) or 2-3 (OFS.0=1)
   --   OBJ ext pal, 8 KB: F/G MST=5 (lower half of the bank)
   pextpal : process (all)
      variable mstE, mstF, mstG, mstH, mstI : unsigned(2 downto 0);
      variable ofsF, ofsG       : unsigned(1 downto 0);
   begin
      mstE := unsigned(vramcnt(BANK_E*8 + 2 downto BANK_E*8));
      mstF := unsigned(vramcnt(BANK_F*8 + 2 downto BANK_F*8));
      mstG := unsigned(vramcnt(BANK_G*8 + 2 downto BANK_G*8));
      mstH := unsigned(vramcnt(BANK_H*8 + 2 downto BANK_H*8));
      mstI := unsigned(vramcnt(BANK_I*8 + 2 downto BANK_I*8));
      ofsF := unsigned(vramcnt(BANK_F*8 + 4 downto BANK_F*8 + 3));
      ofsG := unsigned(vramcnt(BANK_G*8 + 4 downto BANK_G*8 + 3));

      bgep_hit    <= (others => '0');
      bgep_offs   <= (others => (others => '0'));
      objep_hit   <= (others => '0');
      objep_offs  <= (others => (others => '0'));
      bgepb_hit   <= (others => '0');
      bgepb_offs  <= (others => (others => '0'));
      objepb_hit  <= (others => '0');
      objepb_offs <= (others => (others => '0'));

      -- engine B: bank H MST=2 = BG ext pal (all 4 slots), bank I MST=3 =
      -- OBJ ext pal (first 8 KB of the 16 KB bank)
      if (vramcnt(BANK_H*8 + 7) = '1' and mstH = 2) then
         bgepb_hit(BANK_H)  <= '1';
         bgepb_offs(BANK_H) <= "00" & rdr_bgepb_addr & "00";
      end if;
      if (vramcnt(BANK_I*8 + 7) = '1' and mstI = 3) then
         objepb_hit(BANK_I)  <= '1';
         objepb_offs(BANK_I) <= "0000" & rdr_objepb_addr & "00";
      end if;

      if (vramcnt(BANK_E*8 + 7) = '1' and mstE = 4) then
         bgep_hit(BANK_E)  <= '1';
         bgep_offs(BANK_E) <= "00" & rdr_bgep_addr & "00";
      end if;
      if (vramcnt(BANK_F*8 + 7) = '1' and mstF = 4 and rdr_bgep_addr(14) = ofsF(0)) then
         bgep_hit(BANK_F)  <= '1';
         bgep_offs(BANK_F) <= "000" & rdr_bgep_addr(13 downto 2) & "00";
      end if;
      if (vramcnt(BANK_G*8 + 7) = '1' and mstG = 4 and rdr_bgep_addr(14) = ofsG(0)) then
         bgep_hit(BANK_G)  <= '1';
         bgep_offs(BANK_G) <= "000" & rdr_bgep_addr(13 downto 2) & "00";
      end if;

      if (vramcnt(BANK_F*8 + 7) = '1' and mstF = 5) then
         objep_hit(BANK_F)  <= '1';
         objep_offs(BANK_F) <= "0000" & rdr_objep_addr & "00";
      end if;
      if (vramcnt(BANK_G*8 + 7) = '1' and mstG = 5) then
         objep_hit(BANK_G)  <= '1';
         objep_offs(BANK_G) <= "0000" & rdr_objep_addr & "00";
      end if;
   end process;

   -- renderer channel arbitration: rotating priority, ONE REQUEST PER CYCLE
   -- accepted, several in flight.
   --
   -- rpend is a one-deep per-channel request latch, cleared when the server
   -- accepts (rdr_*_accept). It serves two client styles at once:
   --   * pulse-per-request (the drawers, the ext-pal fill): the pulse is
   --     latched, so a request is never dropped because the queue was full,
   --     and the client may pulse again immediately - giving it as many
   --     outstanding requests as the prefetch pipelines need
   --   * hold-until-accept (nds_gpu2d_fast across the clkMem crossing): the
   --     level is latched once and re-latching is blocked while rpend is
   --     still set, so a held req is never counted twice
   -- v1 blocked re-latching for as long as an op for that channel was IN
   -- FLIGHT, which is what limited a channel to one outstanding request. That
   -- restriction is gone; the narrower rpend guard replaces it, and in-order
   -- retirement is what keeps a channel's responses matched to its requests.
   rreq_now <= rdr_objepb_req & rdr_bgepb_req & rdr_objb_req & rdr_bgb_req &
               rdr_objep_req & rdr_bgep_req & rdr_obj_req & rdr_bg_req;

   grreq : for i in 0 to 7 generate
      rreq_vec(i) <= '1' when (rreq_now(i) = '1' or rpend(i) = '1') else '0';
   end generate;

   prpend : process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            rpend <= (others => '0');
         else
            for i in 0 to 7 loop
               -- latch a fresh request; do not re-latch a still-held level
               -- that is already pending
               if (rreq_now(i) = '1' and rpend(i) = '0') then
                  rpend(i) <= '1';
               end if;
            end loop;
            if (rdispatch = '1') then
               rpend(rpick) <= '0';
            end if;
         end if;
      end if;
   end process;

   -- accept pulses: the client's request was taken this cycle
   rdr_bg_accept     <= rdispatch when rpick = 0 else '0';
   rdr_obj_accept    <= rdispatch when rpick = 1 else '0';
   rdr_bgep_accept   <= rdispatch when rpick = 2 else '0';
   rdr_objep_accept  <= rdispatch when rpick = 3 else '0';
   rdr_bgb_accept    <= rdispatch when rpick = 4 else '0';
   rdr_objb_accept   <= rdispatch when rpick = 5 else '0';
   rdr_bgepb_accept  <= rdispatch when rpick = 6 else '0';
   rdr_objepb_accept <= rdispatch when rpick = 7 else '0';

   rdr_bg_done     <= rdone_int(0);
   rdr_obj_done    <= rdone_int(1);
   rdr_bgep_done   <= rdone_int(2);
   rdr_objep_done  <= rdone_int(3);
   rdr_bgb_done    <= rdone_int(4);
   rdr_objb_done   <= rdone_int(5);
   rdr_bgepb_done  <= rdone_int(6);
   rdr_objepb_done <= rdone_int(7);

   prpick : process (all)
      variable idx : integer range 0 to 7;
      variable got : std_logic;
   begin
      idx := 0;
      got := '0';
      for k in 0 to 7 loop
         if (got = '0' and rreq_vec((rr_pri + k) mod 8) = '1') then
            idx := (rr_pri + k) mod 8;
            got := '1';
         end if;
      end loop;
      rpick       <= idx;
      rpick_valid <= got;
   end process;

   -- accept a request whenever the completion queue has room. The BRAM stage
   -- is free by construction (it holds at most the request issued last cycle
   -- and drains every cycle), so queue space is the only back-pressure.
   rdispatch <= '1' when (rq_count < RQ_DEPTH and rpick_valid = '1') else '0';

   -- true renderer-memory occupancy, for the bench (see the port comment):
   -- anything still in the queue counts as work in flight
   dbg_rbusy <= '0' when rq_count = 0 else '1';

   rchosen_hit  <= rdec_bg_hit    when rpick = 0 else
                   rdec_obj_hit   when rpick = 1 else
                   bgep_hit       when rpick = 2 else
                   objep_hit      when rpick = 3 else
                   rdec_bgb_hit   when rpick = 4 else
                   rdec_objb_hit  when rpick = 5 else
                   bgepb_hit      when rpick = 6 else
                   objepb_hit;
   rchosen_offs <= rdec_bg_offs   when rpick = 0 else
                   rdec_obj_offs  when rpick = 1 else
                   bgep_offs      when rpick = 2 else
                   objep_offs     when rpick = 3 else
                   rdec_bgb_offs  when rpick = 4 else
                   rdec_objb_offs when rpick = 5 else
                   bgepb_offs     when rpick = 6 else
                   objepb_offs;

   grdrctl : for i in BANK_E to BANK_I generate
      rbram_ce(i) <= rdispatch and rchosen_hit(i);
   end generate;

   -- ---- posted-write eligibility, all combinational from the live cpu9 inputs
   -- Exactly one A..D bank and no E..I bank: a multi-bank write would need two
   -- queue entries, and an E..I hit retires on the dispatch edge instead. Both
   -- fall back to the cpu9_done path, which is unchanged.
   wq_elig <= '1' when (ad_next(dec9_hit, 0) /= 4 and
                        ad_next(dec9_hit, ad_next(dec9_hit, 0) + 1) = 4 and
                        (dec9_hit(BANK_E) or dec9_hit(BANK_F) or dec9_hit(BANK_G) or
                         dec9_hit(BANK_H) or dec9_hit(BANK_I)) = '0') else '0';

   -- welig: postable at all. wok: and there is room for it right now. The
   -- requester needs both, because they mean different things to it - no room is
   -- backpressure to wait out, not postable is a reason to take the slow path.
   cpu9_welig  <= '1' when (POSTED_WRITES and cpu9_wpost = '1' and cpu9_rnw = '0' and
                            wq_elig = '1' and clr_busy = '0') else '0';
   cpu9_wok    <= '1' when (cpu9_welig = '1' and wq_count < WQ_DEPTH) else '0';
   wq_push_now  <= cpu9_ena and cpu9_wok;
   wq_bank_now  <= ad_next(dec9_hit, 0);
   wq_push_line <= dec9_offs(wq_bank_now)(16 downto 3);

   -- arbitration: dispatch a latched request when the FSM is free. Holding
   -- dispatch off while anything is queued is what keeps the cpu9/cpu7 port
   -- ordered against the posted writes: a read cannot overtake a write that has
   -- not reached the store, and neither can a later non-posted write. The queue
   -- is only ever non-empty during a DMA burst, when both CPUs are paused.
   dispatch   <= '1' when (state = IDLE and wq_count = 0 and
                           (req9.valid = '1' or req7.valid = '1')) else '0';
   chosen_is9 <= '1' when (req9.valid = '1' and (req7.valid = '0' or prefer9 = '1')) else '0';
   chosen     <= req9 when chosen_is9 = '1' else req7;

   -- E..I BRAM inputs are driven combinationally in the dispatch cycle so the
   -- RAM samples them on the same edge the FSM leaves IDLE (ARM9 only — the
   -- ARM7 can never hit E..I)
   -- during the clear pass all five BRAMs take the same word index, so E..I go
   -- in parallel; the banks narrower than E are simply swept more than once
   clr_bram_en <= '1' when state = CLR_BRAM else '0';

   gbramctl : for i in BANK_E to BANK_I generate
      bram_ce(i)    <= clr_bram_en or (dispatch and chosen_is9 and chosen.hit(i));
      bram_we(i)    <= clr_bram_en or (dispatch and chosen_is9 and chosen.hit(i) and (not chosen.rnw));
      bram_addr_a(i) <= resize(clr_addr(BRAM_AW(i) - 1 downto 0), 14) when clr_bram_en = '1' else
                        resize(chosen.offs(i)(BRAM_AW(i) + 1 downto 2), 14);
   end generate;

   bram_din_a <= (others => '0') when clr_bram_en = '1' else chosen.din;
   bram_be_a  <= "1111"          when clr_bram_en = '1' else chosen.be;

   gbram : for i in BANK_E to BANK_I generate
      ibank : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         BYTES       => 4,
         ADDR_WIDTH  => BRAM_AW(i)
      )
      port map
      (
         clk        => clk,

         ce_a       => bram_ce(i),
         addr_a     => to_integer(bram_addr_a(i)(BRAM_AW(i) - 1 downto 0)),
         datain_a0  => bram_din_a( 7 downto  0),
         datain_a1  => bram_din_a(15 downto  8),
         datain_a2  => bram_din_a(23 downto 16),
         datain_a3  => bram_din_a(31 downto 24),
         dataout_a  => bram_dout(i),
         we_a       => bram_we(i),
         be_a       => bram_be_a,

         -- renderer port (read-only)
         ce_b       => rbram_ce(i),
         addr_b     => to_integer(rchosen_offs(i)(BRAM_AW(i) + 1 downto 2)),
         datain_b0  => x"00",
         datain_b1  => x"00",
         datain_b2  => x"00",
         datain_b3  => x"00",
         dataout_b  => bram_dout_b(i),
         we_b       => '0',
         be_b       => "0000"
      );
   end generate;

   -- A..D issue selection: the OLDEST queue entry that still owes a word,
   -- scanned from the head so rsrv ops are issued in queue order (rsrv answers
   -- in order, so op order and entry order stay matched with no tags).
   pad_pick : process (all)
      variable idx   : integer range 0 to RQ_DEPTH-1;
      variable found : boolean;
   begin
      idx   := 0;
      found := false;
      for k in 0 to RQ_DEPTH-1 loop
         if (not found) then
            idx := (rq_head + k) mod RQ_DEPTH;
            if (rq(idx).valid = '1' and rq(idx).ad_todo /= "0000") then
               found := true;
            end if;
         end if;
      end loop;
      if (found) then
         ad_scan  <= idx;
         ad_hit   <= rq(idx).ad_todo;
         ad_armed <= '1';
      else
         ad_scan  <= 0;
         ad_hit   <= (others => '0');
         ad_armed <= '0';
      end if;
   end process;

   -- renderer pipeline: issue / BRAM collect / A..D collect / in-order retire.
   -- All four happen every cycle; they touch different fields of the queue.
   prdr : process (clk)
      variable v_rq    : t_rq;
      variable v_cnt   : integer range 0 to RQ_DEPTH;
      variable v_head  : integer range 0 to RQ_DEPTH-1;
      variable v_tail  : integer range 0 to RQ_DEPTH-1;
      variable v_acc   : std_logic_vector(31 downto 0);
      variable v_adcnt : integer range 0 to AD_DEPTH;
      variable v_adh   : integer range 0 to AD_DEPTH-1;
      variable v_adt   : integer range 0 to AD_DEPTH-1;
      variable v_adq   : t_adq;
      variable v_qidx  : integer range 0 to AD_DEPTH-1;
      variable v_bank  : integer range BANK_A to BANK_D;
      variable v_nad   : integer range 0 to 4;
      variable v_slot  : integer range 0 to RQ_DEPTH-1;
      -- A..D line cache working copy, plus the pieces of one line lookup
      variable v_adl   : t_adlines;
      variable v_word  : std_logic_vector(31 downto 0);
      variable v_chan  : integer range 0 to 7;
      variable v_line  : unsigned(16 downto 3);
      variable v_hi    : std_logic;
      variable v_g2    : t_adglobal2;
      variable v_g2_hit: integer range -1 to 1;
      variable v_direct_hit : boolean;
      variable v_line_data  : std_logic_vector(63 downto 0);
      variable v_old_line   : t_adline;
      variable v_cacheable  : std_logic;

      function same_tag(a : t_adline; b : t_adline) return boolean is
      begin
         return a.valid = '1' and b.valid = '1' and
                a.bank = b.bank and a.line = b.line;
      end function;

      procedure victim_remove(variable cache : inout t_adglobal2;
                              constant idx : in integer) is
      begin
         if idx = 0 then
            cache(0) := cache(1);
            cache(1) := ADLINE_INIT;
         elsif idx = 1 then
            cache(1) := ADLINE_INIT;
         end if;
      end procedure;

      -- Insert or promote at MRU while maintaining unique valid tags inside
      -- the victim pair.
      procedure victim_insert(variable cache : inout t_adglobal2;
                              constant incoming : in t_adline) is
         variable old_mru : t_adline;
      begin
         if incoming.valid = '0' then
            return;
         elsif same_tag(cache(0), incoming) then
            cache(0) := incoming;
         elsif same_tag(cache(1), incoming) then
            old_mru := cache(0);
            cache(0) := incoming;
            cache(1) := old_mru;
         else
            cache(1) := cache(0);
            cache(0) := incoming;
         end if;
      end procedure;
   begin
      if rising_edge(clk) then

         rdone_int <= (others => '0');
         -- stage the response: unconditional, so one arrival per cycle is carried
         -- and one is consumed per cycle below - nothing can queue up behind it
         rsp_valid <= rsrv_done;
         rsp_data  <= rsrv_dout;
         -- NOTE: rsrv_req is deliberately NOT defaulted low here - it is a held
         -- level and only the issue stage below may clear it (see the port).

         if (reset = '1') then

            rq        <= (others => RQ_INIT);
            rq_head   <= 0;
            rq_tail   <= 0;
            rq_count  <= 0;
            br_valid  <= '0';
            adq_head  <= 0;
            adq_tail  <= 0;
            adq_count <= 0;
            adq       <= (others => (0, BANK_A, '0', 0, (others => '0'), '0'));
            rr_pri    <= 0;
            rsrv_req  <= '0';
            adline    <= (others => ADLINE_INIT);
            adglobal2 <= (others => ADLINE_INIT);
            rsp_valid <= '0';
            adhit_valid <= '0';

         else

            v_rq    := rq;
            v_cnt   := rq_count;
            v_head  := rq_head;
            v_tail  := rq_tail;
            v_adcnt := adq_count;
            v_adh   := adq_head;
            v_adt   := adq_tail;
            v_adq   := adq;
            v_adl   := adline;
            v_g2    := adglobal2;

            -- ---- A..D line cache invalidation. The CPU reaches A..D through the
            -- srv channel, which HOLDS req for the whole write, so invalidating on
            -- the level covers the whole window in which a fill could otherwise
            -- capture pre-write data. Everything that writes A..D goes through
            -- here, including the reset clear pass, so invalidate the exact
            -- 64-bit line on the live backing-store write. Graphics DMA can and
            -- does overlap drawing; flushing unrelated lines in the same bank
            -- turned each accepted halfword into avoidable renderer misses.
            if (srv_req = '1' and srv_rnw = '0') then
               for i in 0 to 7 loop
                  if v_adl(i).bank = to_integer(unsigned(srv_bank_int)) and
                     v_adl(i).line = srv_addr_int(16 downto 3) then
                     v_adl(i).valid := '0';
                  end if;
               end loop;
               for i in 0 to 1 loop
                  if v_g2(i).bank = to_integer(unsigned(srv_bank_int)) and
                     v_g2(i).line = srv_addr_int(16 downto 3) then
                     v_g2(i).valid := '0';
                  end if;
               end loop;
               -- A response already in flight must not recreate the written
               -- line. Mark matching live misses before completions are
               -- consumed below, so same-edge invalidation wins over fill.
               for k in 0 to AD_DEPTH-1 loop
                  if k < v_adcnt then
                     v_qidx := (v_adh + k) mod AD_DEPTH;
                     if v_adq(v_qidx).bank = to_integer(unsigned(srv_bank_int)) and
                        v_adq(v_qidx).line = srv_addr_int(16 downto 3) then
                        v_adq(v_qidx).cacheable := '0';
                     end if;
                  end if;
               end loop;
            end if;

            -- ---- and the same closure for posted writes, which are acknowledged
            -- long before srv_req rises for them. A pulse is enough here, unlike
            -- the level above, precisely BECAUSE the issue gate below is
            -- per-line: this drops any cached copy of the line being written on
            -- the edge it is accepted, and the gate then keeps that line from
            -- being refetched until the write has drained. Both read
            -- wq_push_now combinationally, so there is no cycle in between for a
            -- fill to slip into.
            -- Invalidate only the 64-bit line being written.  The former
            -- bank-wide policy assumed graphics uploads never overlapped drawing;
            -- a displayed-bank DMA burst therefore discarded every channel's
            -- otherwise unrelated line on every accepted halfword and could push
            -- the renderer over its scanline deadline.  The issue gate is already
            -- exact-line, so use the same coherency scope for cached and in-flight
            -- lines.
            if (wq_push_now = '1') then
               for i in 0 to 7 loop
                  if (v_adl(i).bank = wq_bank_now and
                      v_adl(i).line = wq_push_line) then
                     v_adl(i).valid := '0';
                  end if;
               end loop;
               for i in 0 to 1 loop
                  if (v_g2(i).bank = wq_bank_now and
                      v_g2(i).line = wq_push_line) then
                     v_g2(i).valid := '0';
                  end if;
               end loop;
               for k in 0 to AD_DEPTH-1 loop
                  if k < v_adcnt then
                     v_qidx := (v_adh + k) mod AD_DEPTH;
                     if v_adq(v_qidx).bank = wq_bank_now and
                        v_adq(v_qidx).line = wq_push_line then
                        v_adq(v_qidx).cacheable := '0';
                     end if;
                  end if;
               end loop;
            end if;

            -- ---- S1: the BRAM stage. port-B q is valid the cycle after the
            -- address was presented, so this collects the request issued last
            -- cycle. It runs before the new issue below, which re-drives the
            -- port for the NEXT request - the two do not conflict because the
            -- address register and q are one cycle apart.
            if (br_valid = '1') then
               v_acc := v_rq(br_slot).acc;
               for i in BANK_E to BANK_I loop
                  if (br_hit(i) = '1') then
                     v_acc := v_acc or bram_dout_b(i);
                  end if;
               end loop;
               v_rq(br_slot).acc     := v_acc;
               v_rq(br_slot).need_br := '0';
            end if;
            br_valid <= '0';

            -- ---- A..D completions: rsrv answers in issue order, so the
            -- oldest in-flight op owns this word. The response is an 8-byte line;
            -- take the half that was wanted and keep the whole line for the
            -- channel, which is where the other half gets used for free.
            if (rsp_valid = '1' and v_adcnt > 0) then
               v_slot := v_adq(v_adh).slot;
               if (v_adq(v_adh).hi = '1') then
                  v_word := rsp_data(63 downto 32);
               else
                  v_word := rsp_data(31 downto 0);
               end if;
               v_rq(v_slot).acc     := v_rq(v_slot).acc or v_word;
               v_rq(v_slot).ad_owed := v_rq(v_slot).ad_owed - 1;
               if (AD_CACHE_EN and v_adq(v_adh).cacheable = '1') then
                  v_old_line := v_adl(v_adq(v_adh).chan);
                  v_line_data := rsp_data;
                  -- A same-line response can exist when two misses were
                  -- outstanding before the first fill landed. Remove any
                  -- victim copy of the arriving line before it becomes the
                  -- channel primary.
                  v_g2_hit := -1;
                  for e in 0 to 1 loop
                     if v_g2(e).valid = '1' and
                        v_g2(e).bank = v_adq(v_adh).bank and
                        v_g2(e).line = v_adq(v_adh).line then
                        v_g2_hit := e;
                        exit;
                     end if;
                  end loop;
                  if v_g2_hit >= 0 then
                     victim_remove(v_g2, v_g2_hit);
                  end if;
                  if v_old_line.valid = '1' and
                     v_old_line.bank = v_adq(v_adh).bank and
                     v_old_line.line = v_adq(v_adh).line then
                     -- Repeated same-line fill updates primary in place. It
                     -- must not evict that same tag into the victim pair.
                     null;
                  else
                     victim_insert(v_g2, v_old_line);
                  end if;
                  v_adl(v_adq(v_adh).chan) :=
                     ('1', v_adq(v_adh).bank, v_adq(v_adh).line, v_line_data);
               end if;
               v_adh   := (v_adh + 1) mod AD_DEPTH;
               v_adcnt := v_adcnt - 1;
            end if;

            -- ---- A..D line-cache hit decided LAST cycle (see adhit_*). Applied
            -- here, after the memory completion above and before the retire
            -- below, so a hit still retires its request with no extra latency
            -- beyond the one staging cycle. Composing with the block above is
            -- safe even when both target the same slot: these are sequential
            -- variable assignments, so the second reads what the first wrote.
            -- Nothing can queue up behind it - the issue stage produces at most
            -- one hit per cycle and this consumes one per cycle.
            if (adhit_valid = '1') then
               v_rq(adhit_slot).acc     := v_rq(adhit_slot).acc or adhit_word;
               v_rq(adhit_slot).ad_owed := v_rq(adhit_slot).ad_owed - 1;
            end if;
            adhit_valid <= '0';

            -- ---- A..D issue: present the next op when the request wire is
            -- free - either nothing is on it, or what was on it is taken by
            -- THIS edge (rsrv_ready high). Bookkeeping happens at presentation
            -- because a presented request is transferred exactly once: it is
            -- held until the channel takes it. Never gate presentation on
            -- rsrv_ready alone - that is the stale-ready wedge (see the port).
            if (rsrv_req = '0' or rsrv_ready = '1') then
               if (ad_armed = '1' and v_adcnt < AD_DEPTH) then
                  v_bank := BANK_A;
                  for i in BANK_D downto BANK_A loop
                     if (ad_hit(i) = '1') then
                        v_bank := i;
                     end if;
                  end loop;
                  v_chan := v_rq(ad_scan).chan;
                  v_line := ad_addr(ad_scan, v_bank)(16 downto 3);
                  v_hi   := ad_addr(ad_scan, v_bank)(2);

                  if (wq_touches(wq, wq_push_now, wq_bank_now, wq_push_line,
                                 v_bank, v_line)) then
                     -- a posted write covering this exact line has not reached the
                     -- store yet. rsrv_* is a separate port into the same memory,
                     -- so reading now would legitimately return pre-write data.
                     -- Present nothing and pick this request up again once the
                     -- queue drains - releasing the wire is the same thing the
                     -- not-armed branch below does, and cannot wedge.
                     rsrv_req <= '0';
                  else

                  v_direct_hit := AD_CACHE_EN and v_adl(v_chan).valid = '1' and
                                  v_adl(v_chan).bank = v_bank and
                                  v_adl(v_chan).line = v_line;

                  -- the channel's own cached line already holds this word: take it
                  -- now and issue nothing. This is the whole point of the 64-bit
                  -- line - the memory access for the neighbouring word already
                  -- happened.
                  v_g2_hit := -1;
                  if (not v_direct_hit) then
                     if v_g2(0).valid = '1' and v_g2(0).bank = v_bank and
                        v_g2(0).line = v_line then
                        v_g2_hit := 0;
                     elsif v_g2(1).valid = '1' and v_g2(1).bank = v_bank and
                           v_g2(1).line = v_line then
                        v_g2_hit := 1;
                     end if;
                  end if;
                  if (AD_CACHE_EN and (v_direct_hit or v_g2_hit >= 0)) then
                     if v_direct_hit then
                        if (v_hi = '1') then
                           v_word := v_adl(v_chan).data(63 downto 32);
                        else
                           v_word := v_adl(v_chan).data(31 downto 0);
                        end if;
                     else
                        -- Primary miss + victim hit: remove/promote the hit line
                        -- into this channel's primary, and send the displaced
                        -- valid primary into the ownerless victim MRU position.
                        v_line_data := v_g2(v_g2_hit).data;
                        v_word := v_line_data(31 downto 0);
                        if (v_hi = '1') then v_word := v_line_data(63 downto 32); end if;
                        v_old_line := v_adl(v_chan);
                        victim_remove(v_g2, v_g2_hit);
                        victim_insert(v_g2, v_old_line);
                        v_adl(v_chan) := ('1', v_bank, v_line, v_line_data);
                     end if;
                     -- staged, NOT applied here: this branch is gated on
                     -- rsrv_ready and .acc/.ad_owed feed the retire compare and
                     -- the rdr_*_dout mux (see adhit_*). ad_todo is still
                     -- cleared now, because the scanner must not re-pick this
                     -- bank next cycle; ad_todo reaches pad_pick, not the
                     -- dout registers.
                     adhit_valid <= '1';
                     adhit_slot  <= ad_scan;
                     adhit_word  <= v_word;
                     v_rq(ad_scan).ad_todo(v_bank) := '0';
                     -- the wire was free when we got here, so it must be released:
                     -- leaving it asserted would re-present the request that was
                     -- just taken and fetch the same line twice
                     rsrv_req <= '0';
                  else
                     rsrv_req  <= '1';
                     rsrv_bank <= std_logic_vector(to_unsigned(v_bank, 2));
                     rsrv_addr <= v_line;
                     v_rq(ad_scan).ad_todo(v_bank) := '0';
                     -- Refuse to refill from a miss issued while a backing-store
                     -- write owns this exact line or while a posted write owns this exact
                     -- 64-bit line.  Unrelated writes in the same bank do not
                     -- invalidate or suppress the renderer cache.
                     v_cacheable := '1';
                     if ((srv_req = '1' and srv_rnw = '0' and
                          to_integer(unsigned(srv_bank_int)) = v_bank and
                          srv_addr_int(16 downto 3) = v_line) or
                         wq_touches(wq, wq_push_now, wq_bank_now, wq_push_line,
                                    v_bank, v_line)) then
                        v_cacheable := '0';
                     end if;
                     v_adq(v_adt) :=
                        (ad_scan, v_bank, v_hi, v_chan, v_line, v_cacheable);
                     v_adt   := (v_adt + 1) mod AD_DEPTH;
                     v_adcnt := v_adcnt + 1;
                  end if;

                  end if;   -- wq_touches
               else
                  rsrv_req <= '0';
               end if;
            end if;

            -- ---- S0: issue. One request per cycle into the queue tail.
            if (rdispatch = '1') then
               v_nad := 0;
               for i in BANK_A to BANK_D loop
                  if (rchosen_hit(i) = '1') then
                     v_nad := v_nad + 1;
                  end if;
               end loop;

               v_rq(v_tail).valid   := '1';
               v_rq(v_tail).chan    := rpick;
               v_rq(v_tail).acc     := (others => '0');
               v_rq(v_tail).ad_owed := v_nad;
               for i in BANK_A to BANK_D loop
                  v_rq(v_tail).ad_todo(i) := rchosen_hit(i);
                  ad_addr(v_tail, i) <= rchosen_offs(i)(16 downto 2);
               end loop;
               v_rq(v_tail).need_br := rchosen_hit(BANK_E) or rchosen_hit(BANK_F) or
                                       rchosen_hit(BANK_G) or rchosen_hit(BANK_H) or
                                       rchosen_hit(BANK_I);

               -- hand the BRAM stage this request (port B was driven
               -- combinationally by rbram_ce/addr_b this same cycle)
               if (v_rq(v_tail).need_br = '1') then
                  br_valid <= '1';
                  br_slot  <= v_tail;
                  for i in BANK_E to BANK_I loop
                     br_hit(i) <= rchosen_hit(i);
                  end loop;
               end if;

               rr_pri  <= (rpick + 1) mod 8;
               v_tail  := (v_tail + 1) mod RQ_DEPTH;
               v_cnt   := v_cnt + 1;
            end if;

            -- ---- retire: only the head, and only when it owes nothing. In
            -- order, so a channel's responses arrive in the order it asked.
            if (v_cnt > 0 and v_rq(v_head).valid = '1' and
                v_rq(v_head).need_br = '0' and v_rq(v_head).ad_owed = 0) then
               case v_rq(v_head).chan is
                  when 0 => rdr_bg_dout     <= v_rq(v_head).acc;
                  when 1 => rdr_obj_dout    <= v_rq(v_head).acc;
                  when 2 => rdr_bgep_dout   <= v_rq(v_head).acc;
                  when 3 => rdr_objep_dout  <= v_rq(v_head).acc;
                  when 4 => rdr_bgb_dout    <= v_rq(v_head).acc;
                  when 5 => rdr_objb_dout   <= v_rq(v_head).acc;
                  when 6 => rdr_bgepb_dout  <= v_rq(v_head).acc;
                  when 7 => rdr_objepb_dout <= v_rq(v_head).acc;
               end case;
               rdone_int(v_rq(v_head).chan) <= '1';
               v_rq(v_head).valid := '0';
               v_head := (v_head + 1) mod RQ_DEPTH;
               v_cnt  := v_cnt - 1;
            end if;

            rq        <= v_rq;
            rq_head   <= v_head;
            rq_tail   <= v_tail;
            rq_count  <= v_cnt;
            adq_head  <= v_adh;
            adq_tail  <= v_adt;
            adq_count <= v_adcnt;
            adq       <= v_adq;
            adline    <= v_adl;
            assert not same_tag(v_g2(0), v_g2(1))
               report "victim pair contains duplicate valid tags"
               severity failure;
            adglobal2 <= v_g2;

         end if;
      end if;
   end process;

   process (clk)
      variable v_acc  : std_logic_vector(31 downto 0);
      variable v_next : integer range 0 to 4;

      -- posted-write queue, worked on as variables because a push and a pop can
      -- land on the same edge
      variable v_wq    : t_wq;
      variable v_wh    : integer range 0 to WQ_DEPTH-1;
      variable v_wt    : integer range 0 to WQ_DEPTH-1;
      variable v_wcnt  : integer range 0 to WQ_DEPTH;
      variable v_wprev : integer range 0 to WQ_DEPTH-1;
      variable v_wbusy : boolean;

      -- Hand bank `nxt` of request `r` to the srv_* channel and wait on it.
      procedure issue_srv (r : t_req; nxt : integer) is
      begin
         srv_req  <= '1';
         srv_rnw  <= r.rnw;
         srv_bank_int <= std_logic_vector(to_unsigned(nxt, 2));
         srv_addr_int <= r.offs(nxt)(16 downto 2);
         srv_be   <= r.be;
         srv_din  <= r.din;
         srv_idx  <= nxt + 1;
         state    <= SRVWAIT;
      end procedure;

      -- Drive the requester's result and pulse its done. `is9` is passed in
      -- rather than read from cur_is9 because the dispatch cycle can retire an
      -- access outright (an E..I write, or an unmapped one) and cur_is9 is only
      -- being assigned on that same edge.
      procedure retire (is9 : std_logic; d : std_logic_vector(31 downto 0)) is
      begin
         if (is9 = '1') then
            cpu9_dout <= d;
            cpu9_done <= '1';
         else
            cpu7_dout <= d;
            cpu7_done <= '1';
         end if;
         state <= IDLE;
      end procedure;
   begin
      if rising_edge(clk) then

         cpu9_done <= '0';
         cpu7_done <= '0';

         v_wq    := wq;
         v_wh    := wq_head;
         v_wt    := wq_tail;
         v_wcnt  := wq_count;
         v_wbusy := (state = WQ_WAIT);   -- the head is on the wire right now

         -- request latching (ena is a single-cycle pulse). A posted write never
         -- reaches req9: cpu9_wok already acknowledged it, and pushing it here
         -- as well would perform it twice.
         if (cpu9_ena = '1' and cpu9_wok = '0') then
            req9 <= ('1', cpu9_rnw, cpu9_be, cpu9_din, dec9_hit, dec9_offs);
            -- sim guard: no second op while one is in flight
            -- synthesis translate_off
            assert req9.valid = '0' report "cpu9 request overrun" severity failure;
            -- synthesis translate_on
         end if;
         if (cpu7_ena = '1') then
            req7 <= ('1', cpu7_rnw, cpu7_be, cpu7_din, dec7_hit, dec7_offs);
            -- synthesis translate_off
            assert req7.valid = '0' report "cpu7 request overrun" severity failure;
            -- synthesis translate_on
         end if;

         if (reset = '1') then

            -- reset re-arms the clear pass; it runs once reset releases, and
            -- clr_busy keeps the CPUs held until it is done
            state      <= CLR_BRAM;
            clr_addr   <= (others => '0');
            clr_bank   <= 0;
            clr_busy   <= '1';
            req9.valid <= '0';
            req7.valid <= '0';
            srv_req    <= '0';
            prefer9    <= '1';
            v_wq       := (others => WQ_INIT);
            v_wh       := 0;
            v_wt       := 0;
            v_wcnt     := 0;

         else

            case state is

               when IDLE =>
                  -- draining outranks dispatch, and `dispatch` is gated on the
                  -- queue being empty so the two can never both fire
                  if (v_wcnt > 0) then
                     srv_req  <= '1';
                     srv_rnw  <= '0';
                     srv_bank_int <= std_logic_vector(to_unsigned(v_wq(v_wh).bank, 2));
                     srv_addr_int <= v_wq(v_wh).addr;
                     srv_be   <= v_wq(v_wh).be;
                     srv_din  <= v_wq(v_wh).din;
                     state    <= WQ_WAIT;
                     v_wbusy  := true;   -- blocks a merge into it on this edge
                  elsif (dispatch = '1') then
                     cur     <= chosen;
                     cur_is9 <= chosen_is9;
                     acc     <= (others => '0');
                     srv_idx <= 0;
                     if (chosen_is9 = '1') then
                        req9.valid <= '0';
                        prefer9    <= '0';   -- fairness toggle
                     else
                        req7.valid <= '0';
                        prefer9    <= '1';
                     end if;
                     -- E..I writes complete on this same edge (bram_we);
                     -- reads need the registered dataout to settle
                     if (chosen_is9 = '1' and chosen.rnw = '1' and
                         (chosen.hit(BANK_E) or chosen.hit(BANK_F) or chosen.hit(BANK_G) or
                          chosen.hit(BANK_H) or chosen.hit(BANK_I)) = '1') then
                        state <= BRAMWAIT;
                     else
                        v_next := ad_next(chosen.hit, 0);
                        if (v_next = 4) then
                           -- nothing off-chip to do: an E..I write already
                           -- landed on this edge via bram_we, and an access
                           -- that maps nowhere reads as 0
                           retire(chosen_is9, (others => '0'));
                        else
                           issue_srv(chosen, v_next);
                        end if;
                     end if;
                  end if;

               when BRAMWAIT =>
                  state <= BRAMREAD;

               when BRAMREAD =>
                  v_acc := acc;
                  for i in BANK_E to BANK_I loop
                     if (cur.hit(i) = '1') then
                        v_acc := v_acc or bram_dout(i);
                     end if;
                  end loop;
                  acc    <= v_acc;
                  v_next := ad_next(cur.hit, 0);
                  if (v_next = 4) then
                     retire(cur_is9, v_acc);
                  else
                     issue_srv(cur, v_next);
                  end if;

               when SRVSCAN =>
                  v_next := ad_next(cur.hit, srv_idx);
                  if (v_next = 4) then
                     -- unreachable: SRVWAIT only comes here when it has already
                     -- found a next bank. Retiring keeps the FSM total anyway.
                     retire(cur_is9, acc);
                  else
                     issue_srv(cur, v_next);
                  end if;

               when SRVWAIT =>
                  if (srv_done = '1') then
                     v_acc := acc;
                     if (cur.rnw = '1') then
                        v_acc := v_acc or srv_dout;
                        acc   <= v_acc;
                     end if;
                     srv_req <= '0';
                     if (ad_next(cur.hit, srv_idx) = 4) then
                        retire(cur_is9, v_acc);
                     else
                        state <= SRVSCAN;
                     end if;
                  end if;

               when WQ_WAIT =>
                  -- a posted write has no result and nobody is waiting on it, so
                  -- retiring it is just a pop
                  if (srv_done = '1') then
                     srv_req          <= '0';
                     v_wq(v_wh).valid := '0';
                     if (v_wh = WQ_DEPTH - 1) then
                        v_wh := 0;
                     else
                        v_wh := v_wh + 1;
                     end if;
                     v_wcnt           := v_wcnt - 1;
                     v_wbusy          := false;
                     state            <= IDLE;
                  end if;

               -- ===================== reset clear pass =====================
               -- E..I first (one word per cycle into all five BRAMs), then the
               -- four SDRAM-backed banks over the srv_* write channel. No CPU
               -- or renderer op can be in flight: nds_top holds both CPUs and
               -- the render pipe until clr_busy drops, and `dispatch` is gated
               -- on state = IDLE so nothing is issued from here either.
               when CLR_BRAM =>
                  if (clr_addr = to_unsigned(CLR_BRAM_LAST, clr_addr'length)) then
                     clr_addr <= (others => '0');
                     state    <= CLR_SRV;
                  else
                     clr_addr <= clr_addr + 1;
                  end if;

               when CLR_SRV =>
                  srv_req  <= '1';
                  srv_rnw  <= '0';
                  srv_bank_int <= std_logic_vector(to_unsigned(clr_bank, 2));
                  srv_addr_int <= clr_addr;
                  srv_be   <= "1111";
                  srv_din  <= (others => '0');
                  state    <= CLR_SRVWAIT;

               when CLR_SRVWAIT =>
                  if (srv_done = '1') then
                     srv_req <= '0';
                     if (clr_addr = to_unsigned(CLR_SRV_LAST, clr_addr'length)) then
                        clr_addr <= (others => '0');
                        if (clr_bank = 3) then
                           clr_busy <= '0';
                           state    <= IDLE;
                        else
                           clr_bank <= clr_bank + 1;
                           state    <= CLR_SRV;
                        end if;
                     else
                        clr_addr <= clr_addr + 1;
                        state    <= CLR_SRV;
                     end if;
                  end if;

            end case;

            -- ---- posted write accept. Runs after the FSM so that v_wh/v_wcnt
            -- and v_wbusy already reflect any pop or issue on this edge, which is
            -- what makes the merge test below exact rather than conservative.
            --
            -- Merging is not an optimisation here, it is the reason the queue
            -- keeps up: a writer producing a halfword every two cycles produces a
            -- WORD every four, and srv_* sustains one every three. Without
            -- merging it would want one every two and the queue would back up.
            -- Adjacent halfwords of a 16-bit DMA burst land in the same word, so
            -- the tail entry is nearly always the right one to fold into.
            if (wq_push_now = '1') then
               if (v_wt = 0) then
                  v_wprev := WQ_DEPTH - 1;
               else
                  v_wprev := v_wt - 1;
               end if;
               if (v_wcnt > 0 and v_wq(v_wprev).valid = '1' and
                   v_wq(v_wprev).bank = wq_bank_now and
                   v_wq(v_wprev).addr = dec9_offs(wq_bank_now)(16 downto 2) and
                   not (v_wprev = v_wh and v_wbusy)) then
                  for j in 0 to 3 loop
                     if (cpu9_be(j) = '1') then
                        v_wq(v_wprev).din(j*8 + 7 downto j*8) := cpu9_din(j*8 + 7 downto j*8);
                     end if;
                  end loop;
                  v_wq(v_wprev).be := v_wq(v_wprev).be or cpu9_be;
               else
                  v_wq(v_wt) := ('1', wq_bank_now,
                                 dec9_offs(wq_bank_now)(16 downto 2), cpu9_be, cpu9_din);
                  if (v_wt = WQ_DEPTH - 1) then
                     v_wt := 0;
                  else
                     v_wt := v_wt + 1;
                  end if;
                  v_wcnt := v_wcnt + 1;
               end if;
            end if;

         end if;

         wq       <= v_wq;
         wq_head  <= v_wh;
         wq_tail  <= v_wt;
         wq_count <= v_wcnt;

      end if;
   end process;

end architecture;
