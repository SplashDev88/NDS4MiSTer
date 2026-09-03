-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS ARM9 DMA (M6): 4 channels, registers 0x040000B0-0x040000EF incl. the
-- FILL words. Semantics per DualSOUP dma.c (Jaklyy's hardware research) and
-- GBATEK:
--
--   * CNT: [20:0] word count (0 -> 0x200000), [22:21] dst ctrl (0 inc,
--     1 dec, 2 fixed, 3 inc-reload), [24:23] src ctrl (3 behaves as inc +
--     reload, DualSOUP), [25] repeat, [26] 32-bit, [29:27] start timing,
--     [30] IRQ, [31] enable. SAD/DAD/CNT all read back (NDS, unlike GBA).
--   * enable rising edge latches src/dst; the word count is latched lazily
--     when the remaining count is 0 (so repeat reloads it per trigger, and
--     ctrl-3 re-latches the address then too) - DualSOUP DMA_Run.
--   * start timings implemented: 0 immediate, 1 vblank, 2 hblank (visible
--     lines only - the gpu2d cadence pulses), 5 card (one pulse per ready
--     data word from nds_card; games arm count=1 + repeat), and 7 GX FIFO
--     when gx_supported is asserted. GX mode runs at most 112 words per FIFO
--     request, matching melonDS/DS behavior. Each completed slice releases
--     the CPU for an arbitration window before a still-requested continuation;
--     3/4/6 are
--     exotic (DualSOUP stubs them).
--   * repeat re-arms every trigger for non-immediate modes; immediate
--     transfers clear enable regardless. IRQ per completed transfer.
--   * transfers go through the ARM9 membus with the CPU paused (dma_on +
--     CPU_bus_idle grant) and the TCM windows bypassed (DMA cannot see
--     ITCM/DTCM). Addresses are masked to 0x0FFFFFFF and hold the size
--     alignment; 16-bit reads take the rotated lane, writes replicate.
--
-- Timing is functional-only for now: one read + one write handshake per
-- unit, no cycle accuracy. The M9 pacing target is the DualSOUP dma.txt
-- measurement: NR+NW first pair, then SR/SW pairs, a 1-cycle stall after
-- a fast first read, and main-RAM read prefetch making later SRs
-- single-cycle. The FSM shape below (first-pair / steady-pair) is chosen
-- so those timings can be dialed in without restructuring.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_dma9 is
   port
   (
      clk          : in  std_logic;
      reset        : in  std_logic;

      gb_bus       : in  proc_bus_gb_type;
      wired_out    : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done   : out std_logic;

      -- trigger pulses (gpu2d cadence: vblank start / visible-line hblank;
      -- card: one pulse per ready data word from nds_card)
      trig_vblank  : in  std_logic;
      trig_hblank  : in  std_logic;
      trig_card    : in  std_logic;

      -- GX FIFO timing-7 ownership. Defaults preserve the pre-3D product:
      -- mode 7 remains armed but cannot start until an explicit local GX owner
      -- is wired. trig_gx may be held as the architectural below-half level;
      -- a rising edge, or arming a channel while it is high, creates a request.
      -- Keeping it high lets the current transfer cross 112-word boundaries,
      -- but does not make a repeat channel restart after total completion.
      -- gx_write_ready is the lossless hybrid transport credit for the word
      -- currently presented by the DMA IO fast lane.  The name is retained
      -- for source compatibility with the original GXFIFO-only path, but the
      -- handshake now covers every DMA IO write: the downstream recorder
      -- filters ordinary IO and retains GXFIFO plus the 2D/VRAM-map display
      -- state needed by the ARM renderer.  Deasserting it suppresses
      -- io_fast_ena and holds the exact write.
      gx_supported   : in std_logic := '0';
      trig_gx        : in std_logic := '0';
      gx_write_ready : in std_logic := '1';
      -- Held DMA IO-write request, independent of gx_write_ready.  The product
      -- event gate uses this as ready/valid `valid`; io_fast_ena below remains
      -- the actual peripheral accept and is qualified by gx_write_ready.
      gx_write_valid : out std_logic := '0';

      -- membus grant: dma_on pauses the CPU, the bus is ours once idle
      cpu_bus_idle : in  std_logic;
      dma_on       : out std_logic := '0';
      dma_bus_on   : out std_logic := '0';
      -- Observation-only scheduler state. These ports have defaults so the
      -- standalone DMA users remain source-compatible; the product line-30
      -- trace uses them to distinguish a late HDMA re-arm from a channel that
      -- is already pending but waiting for the ARM9 bus.
      dbg_active_channel : out std_logic_vector(1 downto 0) := (others => '0');
      dbg_active_timing  : out std_logic_vector(2 downto 0) := (others => '0');
      dbg_pending        : out std_logic_vector(3 downto 0) := (others => '0');
      dbg_state          : out std_logic_vector(3 downto 0) := (others => '0');

      -- ARM9 membus access port (muxed onto the CPU port in nds_top)
      mb_ena       : out std_logic := '0';
      mb_rnw       : out std_logic := '1';
      mb_adr       : out std_logic_vector(31 downto 0) := (others => '0');
      mb_acc       : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      mb_lowbits   : out std_logic_vector(1 downto 0) := "00";
      mb_dout      : out std_logic_vector(31 downto 0) := (others => '0');
      mb_din       : in  std_logic_vector(31 downto 0);
      mb_done      : in  std_logic;

      -- clk1x fast lane straight into the IO fabric.
      --
      -- The island bridge costs 5 clk1x cycles on every IO access - request CDC
      -- out (clk1x -> clk2x), the clk1x IO fabric, then the completion CDC back
      -- through cdc_io_cpl and cpu9_done_1x - and nds_dma9 is already a clk1x
      -- unit, so it can address the peripherals directly and skip all of it.
      -- Measured 5 -> 1 cycle per IO access, and IO is where a DMA reads its
      -- source whenever software points SAD at a register (the NITRO Tester's
      -- [04-02] uses TM3CNT_L; sound and card streaming do the same).
      --
      -- Needs no arbitration with the island: dma_on pauses the CPU, the grant
      -- waits for cpu_bus_idle - which only returns to '1' on gb_bus_done, so the
      -- CPU's last access has completed - and nds_top hands the fabric over for
      -- exactly as long as dma_bus_on is held.
      io_fast_ena  : out std_logic := '0';
      io_fast_rnw  : out std_logic := '1';
      io_fast_adr  : out std_logic_vector(27 downto 0) := (others => '0');
      io_fast_acc  : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      io_fast_be   : out std_logic_vector(3 downto 0) := "1111";
      io_fast_dout : out std_logic_vector(31 downto 0) := (others => '0');
      io_fast_din  : in  std_logic_vector(31 downto 0);

      -- clk1x fast lane straight into nds_vram, on the same argument as the IO
      -- one above: nds_vram lives in clk1x, and its cpu9 port is idle for the
      -- whole dma_bus_on window because the requester it belongs to is paused.
      --
      -- This lane bypasses nds_membus9, so it owes the two things membus9 would
      -- have done: byte enables from the address, and rotating a halfword read
      -- down out of the returned word.
      vram_fast_ena  : out std_logic := '0';
      vram_fast_rnw  : out std_logic := '1';
      vram_fast_addr : out unsigned(23 downto 2) := (others => '0');
      vram_fast_be   : out std_logic_vector(3 downto 0) := "1111";
      vram_fast_din  : out std_logic_vector(31 downto 0) := (others => '0');
      vram_fast_dout : in  std_logic_vector(31 downto 0);
      vram_fast_done : in  std_logic;
      -- posted writes: nds_vram takes the write in the cycle vram_fast_wok is
      -- high and never pulses done for it, so a VRAM write costs one cycle
      -- instead of a round trip through the off-chip banks. welig says the write
      -- is postable at all (single bank, no E..I); wok adds "and there is room".
      -- Both are combinational from the address this module is presenting.
      vram_fast_wpost : out std_logic := '1';
      vram_fast_welig : in  std_logic;
      vram_fast_wok   : in  std_logic;
      -- Held write request, independent of vram_fast_wok. The product event
      -- gate uses it as ready/valid `valid`; vram_fast_ena remains the actual
      -- nds_vram acceptance and is qualified by wok for posted writes.
      vram_write_valid : out std_logic := '0';

      irq_dma      : out std_logic_vector(3 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_dma9 is

   constant ADR_BASE : unsigned(27 downto 0) := x"00000B0";

   type t_chan is record
      sad      : std_logic_vector(27 downto 0);
      dad      : std_logic_vector(27 downto 0);
      count    : std_logic_vector(20 downto 0);
      dstctl   : std_logic_vector(1 downto 0);
      srcctl   : std_logic_vector(1 downto 0);
      repeat   : std_logic;
      word32   : std_logic;
      timing   : std_logic_vector(2 downto 0);
      irqena   : std_logic;
      enable   : std_logic;
      -- latched transfer state
      cur_src  : unsigned(27 downto 0);
      cur_dst  : unsigned(27 downto 0);
      remain   : unsigned(21 downto 0);   -- 0x200000 max
      pend     : std_logic;
   end record;
   constant CHAN_INIT : t_chan := ((others => '0'), (others => '0'), (others => '0'),
                                   "00", "00", '0', '0', "000", '0', '0',
                                   (others => '0'), (others => '0'), (others => '0'), '0');
   type t_chans is array (0 to 3) of t_chan;
   signal ch : t_chans := (others => CHAN_INIT);

   type t_fill is array (0 to 3) of std_logic_vector(31 downto 0);
   signal fill : t_fill := (others => (others => '0'));

   -- RD_IOW / WR_IOW are the fast-lane counterparts of RD_WAIT / WR_WAIT: the
   -- peripherals see io_fast_ena during that single cycle and answer
   -- combinationally, so there is nothing to wait for beyond it.
   --
   -- RD_VRW / WR_VRW are the VRAM fast lane. Unlike IO, nds_vram takes several
   -- cycles and pulses done, so these do wait - just without the island in the
   -- middle.
   type t_state is (IDLE, GRANT, LATCH, RD, RD_WAIT, RD_VRW,
                    WR, WR_WAIT, WR_VRW, GX_PAUSE, COMPLETE);
   signal state  : t_state := IDLE;
   signal active : integer range 0 to 3 := 0;

   signal rdval  : std_logic_vector(31 downto 0) := (others => '0');

   -- one cycle per retired unit, for the census below
   signal unit_ret : std_logic := '0';

   -- melonDS/DS service at most 112 GXFIFO words per below-half request.
   -- Total remaining count stays in the channel; this counter only marks the
   -- current service slice. Seven bits hold the inclusive 1..112 range.
   signal gx_chunk_rem : unsigned(6 downto 0) := (others => '0');
   signal trig_gx_d    : std_logic := '0';
   signal gx_write_valid_s : std_logic;
   signal vram_write_valid_s : std_logic;

   -- register write/read decode
   signal regsel_ch  : integer range 0 to 3;
   signal regsel_reg : integer range 0 to 2;
   signal reg_hit    : std_logic;
   signal fill_hit   : std_logic;

   -- NDS IO is 0x04000000-0x04FFFFFF, and DMA addresses are already masked to 28
   -- bits, so the region is exactly the top nibble.
   function is_io(a : unsigned(27 downto 0)) return boolean is
   begin
      return a(27 downto 24) = 4;
   end function;

   -- VRAM is 0x06000000-0x06FFFFFF. nds_vram's own decoder takes adr(23:2) and
   -- resolves the bank from VRAMCNT, so the region nibble goes no further -
   -- exactly what nds_membus9 does for T_VRAM.
   function is_vram(a : unsigned(27 downto 0)) return boolean is
   begin
      return a(27 downto 24) = 6;
   end function;

   -- byte enables for an access of this size at this address, matching the
   -- decode nds_membus9 applies on the slow path
   function be_of(a : unsigned(27 downto 0); w32 : std_logic) return std_logic_vector is
   begin
      if (w32 = '1') then
         return "1111";
      elsif (a(1) = '1') then
         return "1100";
      else
         return "0011";
      end if;
   end function;

   function inc_of(ctl : std_logic_vector(1 downto 0); w32 : std_logic) return integer is
      variable step : integer;
   begin
      if (w32 = '1') then step := 4; else step := 2; end if;
      case ctl is
         when "01"   => return -step;
         when "10"   => return 0;
         when others => return step;      -- 0 and 3: increment
      end case;
   end function;

begin

   -- ================= per-access cost census (sim only) =================
   -- [04-02] DMA PRIORITY requires a 16-bit unit to cost 2 clk1x cycles and this
   -- FSM costs 20 (11 even into palette, the lowest-latency target in the core).
   -- Splitting that between the two waits and the FSM's own states is what says
   -- whether the read path or the write path is the thing to restructure. Prints
   -- once per completed transfer, so it is quiet on ordinary DMA.
   -- synthesis translate_off
   p_census : process (clk)
      variable rw, ww, un, cy : integer := 0;
   begin
      if rising_edge(clk) then
         if (state /= IDLE)     then cy := cy + 1; end if;
         if (state = RD_WAIT or state = RD_VRW) then rw := rw + 1; end if;
         if (state = WR_WAIT or state = WR_VRW) then ww := ww + 1; end if;
         if (unit_ret = '1')    then un := un + 1; end if;
         if (state = COMPLETE and un > 0) then
            report "dma9 census ch" & integer'image(active) & ": " &
                   integer'image(un) & " units, " & integer'image(cy) &
                   " cycles = " & integer'image(cy / un) & "/unit  (rd_wait " &
                   integer'image(rw / un) & ", wr_wait " & integer'image(ww / un) &
                   ", fsm " & integer'image((cy - rw - ww) / un) & ")";
            rw := 0; ww := 0; un := 0; cy := 0;
         end if;
      end if;
   end process;
   -- synthesis translate_on

   -- ================= fast-lane request, combinational =================
   -- These used to be registered, which cost a cycle per access: one to present
   -- the address, another to capture the answer. Hardware spends ONE bus cycle
   -- per access, so matching it leaves room for neither. Driving the request
   -- straight out of `state` and the channel's live pointers makes the address
   -- valid in the same cycle the FSM is in RD or WR, and both targets answer
   -- within it - the IO fabric because its wired-OR is combinational from the
   -- address, nds_vram because an eligible write is posted rather than performed.
   --
   -- The cost is that a fast-lane access is now one long combinational path:
   -- channel register -> active mux -> nds_top's dma_bus_on mux -> the target's
   -- decode -> back here to be captured. That is the shape of a single-cycle bus
   -- and it is the thing to watch in the fit, not a functional risk.
   -- All DMA IO writes share the existing held GXFIFO request lane.  The
   -- downstream H3D recorder rejects unrelated IO addresses immediately, so
   -- this adds no second queue or qualifier cone to the already-full FPGA.
   -- Most importantly, HDMA writes to BGx scroll/control registers can no
   -- longer bypass the Engine-B shadow while their local FPGA effects retire.
   gx_write_valid_s <= '1' when state = WR and
                               is_io(ch(active).cur_dst) else '0';
   gx_write_valid <= gx_write_valid_s;
   io_fast_ena <= '1' when (state = RD and is_io(ch(active).cur_src)) or
                           (state = WR and is_io(ch(active).cur_dst) and
                            (gx_write_valid_s = '0' or
                             gx_write_ready = '1')) else '0';
   io_fast_rnw <= '1' when state = RD else '0';
   io_fast_adr <= x"0" & std_logic_vector(ch(active).cur_src(23 downto 2)) & "00"
                     when state = RD else
                  x"0" & std_logic_vector(ch(active).cur_dst(23 downto 2)) & "00";
   io_fast_be  <= be_of(ch(active).cur_src, ch(active).word32) when state = RD else
                  be_of(ch(active).cur_dst, ch(active).word32);
   io_fast_acc <= ACCESS_32BIT when ch(active).word32 = '1' else ACCESS_16BIT;
   -- bEna picks the lane, so a halfword goes out replicated
   io_fast_dout <= rdval when ch(active).word32 = '1' else
                   rdval(15 downto 0) & rdval(15 downto 0);

   -- A VRAM read is presented for the single RD cycle (RD always advances to
   -- RD_VRW) and answered by done, like any other read. A write is presented
   -- only when nds_vram will actually take it: with room in the posted queue, or
   -- when the access cannot be posted at all and has to go the slow way. With
   -- neither, ena stays low and the FSM stalls in WR - that is the backpressure.
   vram_write_valid_s <= '1' when state = WR and
                                 is_vram(ch(active).cur_dst) else '0';
   vram_write_valid <= vram_write_valid_s;
   vram_fast_ena  <= '1' when (state = RD and is_vram(ch(active).cur_src)) or
                              (state = WR and is_vram(ch(active).cur_dst) and
                               (vram_fast_welig = '0' or vram_fast_wok = '1')) else '0';
   vram_fast_rnw  <= '1' when state = RD else '0';
   vram_fast_addr <= ch(active).cur_src(23 downto 2) when state = RD else
                     ch(active).cur_dst(23 downto 2);
   vram_fast_be   <= be_of(ch(active).cur_src, ch(active).word32) when state = RD else
                     be_of(ch(active).cur_dst, ch(active).word32);
   vram_fast_din  <= rdval when ch(active).word32 = '1' else
                     rdval(15 downto 0) & rdval(15 downto 0);

   dbg_active_channel <= std_logic_vector(to_unsigned(active, 2));
   dbg_active_timing <= ch(active).timing;
   dbg_pending <= ch(3).pend & ch(2).pend & ch(1).pend & ch(0).pend;
   with state select dbg_state <=
      x"0" when IDLE,
      x"1" when GRANT,
      x"2" when LATCH,
      x"3" when RD,
      x"4" when RD_WAIT,
      x"5" when RD_VRW,
      x"6" when WR,
      x"7" when WR_WAIT,
      x"8" when WR_VRW,
      x"9" when GX_PAUSE,
      x"A" when COMPLETE;

   -- ================= register decode =================
   process (all)
      variable off : integer;
   begin
      reg_hit    <= '0';
      fill_hit   <= '0';
      regsel_ch  <= 0;
      regsel_reg <= 0;
      if (unsigned(gb_bus.Adr) >= ADR_BASE and unsigned(gb_bus.Adr) < ADR_BASE + 16#40#) then
         off := to_integer(unsigned(gb_bus.Adr) - ADR_BASE) / 4;
         if (off < 12) then
            reg_hit    <= '1';
            -- Four channels, three words each. An arithmetic /3 and mod 3
            -- here makes Quartus build two full combinational dividers for a
            -- twelve-value MMIO decode; spell out the exact fixed mapping.
            case off is
               when 0  => regsel_ch <= 0; regsel_reg <= 0;
               when 1  => regsel_ch <= 0; regsel_reg <= 1;
               when 2  => regsel_ch <= 0; regsel_reg <= 2;
               when 3  => regsel_ch <= 1; regsel_reg <= 0;
               when 4  => regsel_ch <= 1; regsel_reg <= 1;
               when 5  => regsel_ch <= 1; regsel_reg <= 2;
               when 6  => regsel_ch <= 2; regsel_reg <= 0;
               when 7  => regsel_ch <= 2; regsel_reg <= 1;
               when 8  => regsel_ch <= 2; regsel_reg <= 2;
               when 9  => regsel_ch <= 3; regsel_reg <= 0;
               when 10 => regsel_ch <= 3; regsel_reg <= 1;
               when 11 => regsel_ch <= 3; regsel_reg <= 2;
               when others => null;
            end case;
         else
            fill_hit  <= '1';
            regsel_ch <= off mod 4;
         end if;
      end if;
   end process;

   wired_done <= reg_hit or fill_hit;
   wired_out  <= fill(regsel_ch) when fill_hit = '1' else
                 x"0" & ch(regsel_ch).sad when (reg_hit = '1' and regsel_reg = 0) else
                 x"0" & ch(regsel_ch).dad when (reg_hit = '1' and regsel_reg = 1) else
                 ch(regsel_ch).enable & ch(regsel_ch).irqena & ch(regsel_ch).timing &
                 ch(regsel_ch).word32 & ch(regsel_ch).repeat & ch(regsel_ch).srcctl &
                 ch(regsel_ch).dstctl & ch(regsel_ch).count
                 when reg_hit = '1' else (others => '0');

   -- ================= main FSM + register writes =================
   process (clk)
      variable v_ena   : std_logic;
      variable v_pick  : integer range 0 to 3;
      variable v_got   : std_logic;
      variable v_inc   : integer;
      variable lane16  : std_logic_vector(15 downto 0);
      variable v_total : unsigned(21 downto 0);

      -- End of a unit: step both pointers, drop the count and either start the
      -- next read or finish. This used to be its own NEXTUNIT state, which cost a
      -- whole cycle per unit for work that fits in the cycle the write retires.
      procedure retire_unit is
         variable inc       : integer;
         variable preempt   : boolean;
      begin
         unit_ret <= '1';
         inc := inc_of(ch(active).srcctl, ch(active).word32);
         ch(active).cur_src <= ch(active).cur_src + inc;  -- wraps mod 2^28 (address mask)
         inc := inc_of(ch(active).dstctl, ch(active).word32);
         ch(active).cur_dst <= ch(active).cur_dst + inc;
         ch(active).remain  <= ch(active).remain - 1;

         -- NDS DMA priority is reconsidered between transfer units. A newly
         -- pending lower-numbered channel interrupts the active lower-priority
         -- channel after the current read/write pair has retired. Include live
         -- trigger levels because their pend assignments occur in this same
         -- clocked process and are not visible through ch(i).pend until the
         -- following edge.
         preempt := false;
         for i in 0 to 2 loop
            if (i < active and ch(i).enable = '1') then
               if (ch(i).pend = '1') or
                  (trig_vblank = '1' and ch(i).timing = "001") or
                  (trig_hblank = '1' and ch(i).timing = "010") or
                  (trig_card = '1' and ch(i).timing = "101") then
                  preempt := true;
               end if;
            end if;
         end loop;

         if (ch(active).remain = 1 or ch(active).enable = '0') then
            state <= COMPLETE;
         elsif preempt then
            -- The pointers/count above already describe the next unit. Keep
            -- that continuation pending and reuse the ordinary fixed-priority
            -- IDLE arbitration; LATCH will not reload a nonzero remainder.
            ch(active).pend <= '1';
            if (ch(active).timing = "111") then
               gx_chunk_rem <= (others => '0');
            end if;
            state <= IDLE;
         elsif (ch(active).timing = "111" and gx_chunk_rem = 1) then
            if (gx_supported = '1' and trig_gx = '1') then
               -- Re-arbitrate between hardware-sized GX slices so a pending
               -- higher-priority DMA can run without losing GX progress. The
               -- DS also resumes ARM9 at this boundary before rechecking the
               -- FIFO request; expose that arbitration window even when the
               -- normalized downstream FIFO keeps trig_gx continuously high.
               ch(active).pend <= '1';
               gx_chunk_rem <= (others => '0');
               dma_bus_on <= '0';
               dma_on <= '0';
               state <= IDLE;
            else
               -- FIFO no longer requests data. Preserve cur_src/cur_dst and
               -- total remaining count, but release the CPU until a fresh
               -- trig_gx request resumes this channel.
               gx_chunk_rem <= (others => '0');
               state <= GX_PAUSE;
            end if;
         else
            if (ch(active).timing = "111") then
               gx_chunk_rem <= gx_chunk_rem - 1;
            end if;
            state <= RD;
         end if;
      end procedure;
   begin
      if rising_edge(clk) then

         irq_dma     <= (others => '0');
         mb_ena        <= '0';
         unit_ret      <= '0';
         trig_gx_d     <= trig_gx;

         if (reset = '1') then
            ch     <= (others => CHAN_INIT);
            state  <= IDLE;
            dma_on <= '0';
            dma_bus_on <= '0';
            gx_chunk_rem <= (others => '0');
            trig_gx_d <= '0';
         else

            -- -------- CPU register writes --------
            if (gb_bus.ena = '1' and gb_bus.rnw = '0') then
               if (fill_hit = '1') then
                  for i in 0 to 3 loop
                     if (gb_bus.bEna(i) = '1') then
                        fill(regsel_ch)(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
               elsif (reg_hit = '1') then
                  case regsel_reg is
                     when 0 =>
                        for i in 0 to 3 loop
                           if (gb_bus.bEna(i) = '1' and i < 4) then
                              if (i = 3) then
                                 ch(regsel_ch).sad(27 downto 24) <= gb_bus.Din(27 downto 24);
                              else
                                 ch(regsel_ch).sad(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                              end if;
                           end if;
                        end loop;
                     when 1 =>
                        for i in 0 to 3 loop
                           if (gb_bus.bEna(i) = '1') then
                              if (i = 3) then
                                 ch(regsel_ch).dad(27 downto 24) <= gb_bus.Din(27 downto 24);
                              else
                                 ch(regsel_ch).dad(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                              end if;
                           end if;
                        end loop;
                     when others =>
                        v_ena := ch(regsel_ch).enable;
                        if (gb_bus.bEna(0) = '1') then ch(regsel_ch).count(7 downto 0)   <= gb_bus.Din(7 downto 0);   end if;
                        if (gb_bus.bEna(1) = '1') then ch(regsel_ch).count(15 downto 8)  <= gb_bus.Din(15 downto 8);  end if;
                        if (gb_bus.bEna(2) = '1') then
                           ch(regsel_ch).count(20 downto 16) <= gb_bus.Din(20 downto 16);
                           ch(regsel_ch).dstctl <= gb_bus.Din(22 downto 21);
                           ch(regsel_ch).srcctl(0) <= gb_bus.Din(23);
                        end if;
                        if (gb_bus.bEna(3) = '1') then
                           ch(regsel_ch).srcctl(1) <= gb_bus.Din(24);
                           ch(regsel_ch).repeat <= gb_bus.Din(25);
                           ch(regsel_ch).word32 <= gb_bus.Din(26);
                           ch(regsel_ch).timing <= gb_bus.Din(29 downto 27);
                           ch(regsel_ch).irqena <= gb_bus.Din(30);
                           ch(regsel_ch).enable <= gb_bus.Din(31);
                           -- enable rising edge: latch addresses, arm
                           if (gb_bus.Din(31) = '1' and v_ena = '0') then
                              ch(regsel_ch).cur_src <= unsigned(ch(regsel_ch).sad);
                              ch(regsel_ch).cur_dst <= unsigned(ch(regsel_ch).dad);
                              ch(regsel_ch).remain  <= (others => '0');
                              ch(regsel_ch).pend    <= '0';
                              if (gb_bus.Din(29 downto 27) = "000") then
                                 ch(regsel_ch).pend <= '1';
                              elsif (gb_bus.Din(29 downto 27) = "111" and
                                     gx_supported = '1' and trig_gx = '1') then
                                 ch(regsel_ch).pend <= '1';
                              end if;
                           end if;
                        end if;
                  end case;
               end if;
            end if;

            -- -------- triggers --------
            for i in 0 to 3 loop
               if (ch(i).enable = '1') then
                  if (trig_vblank = '1' and ch(i).timing = "001") then
                     ch(i).pend <= '1';
                  end if;
                  if (trig_hblank = '1' and ch(i).timing = "010") then
                     ch(i).pend <= '1';
                  end if;
                  if (trig_card = '1' and ch(i).timing = "101") then
                     ch(i).pend <= '1';
                  end if;
                  if (gx_supported = '1' and trig_gx = '1' and
                      trig_gx_d = '0' and ch(i).timing = "111") then
                     ch(i).pend <= '1';
                  end if;
               end if;
            end loop;

            -- -------- transfer FSM --------
            case state is

               when IDLE =>
                  dma_bus_on <= '0';
                  v_got  := '0';
                  v_pick := 0;
                  for i in 3 downto 0 loop
                     if (ch(i).pend = '1' and ch(i).enable = '1') then
                        v_pick := i;
                        v_got  := '1';
                     end if;
                  end loop;
                  if (v_got = '1') then
                     active <= v_pick;
                     dma_on <= '1';
                     state  <= GRANT;
                  else
                     dma_on <= '0';
                  end if;

               when GRANT =>
                  if (cpu_bus_idle = '1') then
                     dma_bus_on <= '1';
                     state      <= LATCH;
                  end if;

               when LATCH =>
                  -- LATCH consumes the request that selected this channel, but
                  -- a new edge-timed request can arrive on this exact clock.
                  -- Keep that later event pending instead of letting this
                  -- assignment overwrite the trigger loop above. NSMB does a
                  -- one-halfword repeating HBlank DMA into BG1HOFS; losing one
                  -- such collision shifts the rest of its parallax table.
                  if ((trig_vblank = '1' and ch(active).timing = "001") or
                      (trig_hblank = '1' and ch(active).timing = "010") or
                      (trig_card = '1' and ch(active).timing = "101") or
                      (gx_supported = '1' and trig_gx = '1' and
                       trig_gx_d = '0' and ch(active).timing = "111")) then
                     ch(active).pend <= '1';
                  else
                     ch(active).pend <= '0';
                  end if;
                  -- lazy count latch (DualSOUP): remaining 0 means reload;
                  -- ctrl 3 re-latches its address too
                  if (ch(active).remain = 0) then
                     if (unsigned(ch(active).count) = 0) then
                        v_total := to_unsigned(16#200000#, v_total'length);
                     else
                        v_total := unsigned('0' & ch(active).count);
                     end if;
                     ch(active).remain <= v_total;
                     if (ch(active).srcctl = "11") then
                        ch(active).cur_src <= unsigned(ch(active).sad);
                     end if;
                     if (ch(active).dstctl = "11") then
                        ch(active).cur_dst <= unsigned(ch(active).dad);
                     end if;
                  else
                     v_total := ch(active).remain;
                  end if;
                  if (ch(active).timing = "111") then
                     if (v_total > to_unsigned(112, v_total'length)) then
                        gx_chunk_rem <= to_unsigned(112, gx_chunk_rem'length);
                     else
                        gx_chunk_rem <= resize(v_total, gx_chunk_rem'length);
                     end if;
                  end if;
                  state <= RD;

               when RD =>
                  if (is_io(ch(active).cur_src)) then
                     -- the request is already on the wire (see the concurrent
                     -- drivers above) and the wired-OR answered inside this
                     -- cycle, so the read completes here. The rotation that
                     -- nds_membus9 would have done is ours: the rest of the FSM
                     -- wants the halfword in the low half.
                     if (ch(active).word32 = '1') then
                        rdval <= io_fast_din;
                     elsif (ch(active).cur_src(1) = '1') then
                        rdval <= x"0000" & io_fast_din(31 downto 16);
                     else
                        rdval <= x"0000" & io_fast_din(15 downto 0);
                     end if;
                     state <= WR;
                  elsif (is_vram(ch(active).cur_src)) then
                     state <= RD_VRW;
                  else
                     mb_ena     <= '1';
                     mb_rnw     <= '1';
                     if (ch(active).word32 = '1') then
                        mb_adr     <= x"0" & std_logic_vector(ch(active).cur_src(27 downto 2)) & "00";
                        mb_acc     <= ACCESS_32BIT;
                        mb_lowbits <= "00";
                     else
                        mb_adr     <= x"0" & std_logic_vector(ch(active).cur_src(27 downto 1)) & '0';
                        mb_acc     <= ACCESS_16BIT;
                        mb_lowbits <= std_logic_vector(ch(active).cur_src(1 downto 1)) & '0';
                     end if;
                     state <= RD_WAIT;
                  end if;

               when RD_WAIT =>
                  if (mb_done = '1') then
                     rdval <= mb_din;   -- membus rotates: low half = the halfword
                     state <= WR;
                  end if;

               when RD_VRW =>
                  if (vram_fast_done = '1') then
                     -- same rotation as the IO read above, for the same reason
                     if (ch(active).word32 = '1') then
                        rdval <= vram_fast_dout;
                     elsif (ch(active).cur_src(1) = '1') then
                        rdval <= x"0000" & vram_fast_dout(31 downto 16);
                     else
                        rdval <= x"0000" & vram_fast_dout(15 downto 0);
                     end if;
                     state <= WR;
                  end if;

               when WR =>
                  if (is_io(ch(active).cur_dst)) then
                     if (gx_write_ready = '0') then
                        -- io_fast_ena is suppressed too, so the sink cannot
                        -- sample this payload twice while transport is full.
                        null;
                     else
                        -- the peripheral latched it on this edge
                        retire_unit;
                     end if;
                  elsif (is_vram(ch(active).cur_dst)) then
                     if (vram_fast_welig = '1') then
                        -- posted, or stalled here until the queue has room. Note
                        -- ena is gated on wok too, so a stalled cycle presents
                        -- nothing and cannot be taken twice.
                        if (vram_fast_wok = '1') then
                           retire_unit;
                        end if;
                     else
                        -- not postable (spans two banks): ena was presented for
                        -- this one cycle and nds_vram latched it the ordinary way
                        state <= WR_VRW;
                     end if;
                  else
                     mb_ena <= '1';
                     mb_rnw <= '0';
                     if (ch(active).word32 = '1') then
                        mb_adr  <= x"0" & std_logic_vector(ch(active).cur_dst(27 downto 2)) & "00";
                        mb_acc  <= ACCESS_32BIT;
                        mb_dout <= rdval;
                     else
                        mb_adr  <= x"0" & std_logic_vector(ch(active).cur_dst(27 downto 1)) & '0';
                        mb_acc  <= ACCESS_16BIT;
                        lane16  := rdval(15 downto 0);
                        mb_dout <= lane16 & lane16;
                     end if;
                     mb_lowbits <= "00";
                     state <= WR_WAIT;
                  end if;

               when WR_WAIT =>
                  if (mb_done = '1') then
                     retire_unit;
                  end if;

               when WR_VRW =>
                  if (vram_fast_done = '1') then
                     retire_unit;
                  end if;

               when GX_PAUSE =>
                  ch(active).pend <= '0';
                  dma_bus_on <= '0';
                  dma_on     <= '0';
                  state      <= IDLE;

               when COMPLETE =>
                  -- repeat keeps the channel armed for the next trigger;
                  -- immediate transfers always disable (DualSOUP)
                  if (ch(active).repeat = '0' or ch(active).timing = "000") then
                     ch(active).enable <= '0';
                  end if;
                  if (ch(active).irqena = '1') then
                     irq_dma(active) <= '1';
                  end if;
                  if (ch(active).timing = "111") then
                     -- A constant empty/below-half approximation must not
                     -- turn repeat into an artificial infinite transfer. A
                     -- genuinely fresh request on this exact completion edge
                     -- is retained; an older/stale request is consumed.
                     ch(active).pend <= '0';
                     if (ch(active).repeat = '1' and trig_gx = '1' and
                         trig_gx_d = '0' and gx_supported = '1') then
                        ch(active).pend <= '1';
                     end if;
                  end if;
                  dma_bus_on <= '0';
                  gx_chunk_rem <= (others => '0');
                  state      <= IDLE;

            end case;

         end if;
      end if;
   end process;

end architecture;
