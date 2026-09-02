-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- ARM9 memory bus decoder. Same request/done idiom as nds_membus7 (accepts a
-- new CPU request on every completing cycle), plus the ARM946E-S TCM overlay:
--
--   ITCM: physical 32 KB mirrored through [0, 512B << cp15_itcm_size), takes
--         priority over everything; in load mode writes hit the TCM while
--         reads fall through to the external map
--   DTCM: physical 16 KB mirrored through [base, base + 512B << size); data
--         accesses only (never instruction fetches), below ITCM priority
--
--   external map: 0x02 main RAM, 0x03 shared WRAM, 0x04 IO proc-bus,
--   0x06 VRAM (cpu9 port), 0xFFFF0000 boot ROM (32 KB, read-only).
--   Unmapped: open bus (CPU lastread).
--
-- The TCM and boot-ROM backing stores are external ports (combinational read,
-- clocked write) so the island testbench can own them; the synthesizable core
-- will move them into BRAM primitives later.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_membus9 is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk            : in  std_logic;
      reset          : in  std_logic;

      -- CP15 configuration (from nds_cpu9)
      itcm_ena       : in  std_logic;
      itcm_load      : in  std_logic;
      itcm_size      : in  std_logic_vector(4 downto 0);
      dtcm_ena       : in  std_logic;
      dtcm_load      : in  std_logic;
      dtcm_base      : in  std_logic_vector(31 downto 12);
      dtcm_size      : in  std_logic_vector(4 downto 0);

      -- cache attributes of the current address + maintenance (from nds_cpu9)
      bus_cacheable_i : in  std_logic;
      bus_cacheable_d : in  std_logic;
      cache_op_ena    : in  std_logic;
      cache_op        : in  std_logic_vector(3 downto 0);
      cache_op_addr   : in  std_logic_vector(31 downto 0);
      cache_op_busy   : out std_logic;

      -- gba_cpu-style bus
      -- '1' while the DMA owns the bus: DMA cannot access the TCMs, so
      -- their windows fall through to the external map (GBATEK/DualSOUP)
      dma_bus        : in  std_logic := '0';

      cpu_adr        : in  std_logic_vector(31 downto 0);
      cpu_rnw        : in  std_logic;
      cpu_ena        : in  std_logic;
      cpu_code       : in  std_logic;
      cpu_acc        : in  std_logic_vector(1 downto 0);
      cpu_dout       : in  std_logic_vector(31 downto 0);
      cpu_lowbits    : in  std_logic_vector(1 downto 0);
      cpu_lastread   : in  std_logic_vector(31 downto 0);
      cpu_din        : out std_logic_vector(31 downto 0);
      cpu_done       : out std_logic;

      -- ITCM store (32 KB): sync-read BRAM, addr/write presented
      -- combinationally in the accept cycle (the store registers the
      -- address; read data valid in the FINISH cycle)
      itcm_addr      : out unsigned(14 downto 2);
      itcm_we        : out std_logic;
      itcm_be        : out std_logic_vector(3 downto 0);
      itcm_writedata : out std_logic_vector(31 downto 0);
      itcm_readdata  : in  std_logic_vector(31 downto 0);

      -- DTCM store (16 KB). Port A is now READ-ONLY and keeps the ITCM's
      -- contract: address presented combinationally in the accept cycle, read
      -- data valid in FINISH. The store moved to port B one cycle later, so its
      -- write enable comes straight off a flop instead of off the CPU's address
      -- - see "DTCM deferred store" below. The write ports are deliberately
      -- renamed rather than reused: an instantiation that still wires the old
      -- port-A write fails analysis instead of quietly writing twice.
      dtcm_addr        : out unsigned(13 downto 2);
      dtcm_readdata    : in  std_logic_vector(31 downto 0);
      dtcm_addr_b      : out unsigned(13 downto 2) := (others => '0');
      dtcm_we_b        : out std_logic := '0';
      dtcm_be_b        : out std_logic_vector(3 downto 0) := (others => '0');
      dtcm_writedata_b : out std_logic_vector(31 downto 0) := (others => '0');

      -- boot ROM store (32 KB at 0xFFFF0000, read-only)
      brom_addr      : out unsigned(14 downto 2) := (others => '0');
      brom_data      : in  std_logic_vector(31 downto 0);

      -- shared WRAM (nds_wram arm9 port)
      wsh_ena        : out std_logic := '0';
      wsh_rnw        : out std_logic := '1';
      wsh_addr       : out unsigned(14 downto 2) := (others => '0');
      wsh_be         : out std_logic_vector(3 downto 0) := (others => '0');
      wsh_din        : out std_logic_vector(31 downto 0) := (others => '0');
      wsh_dout       : in  std_logic_vector(31 downto 0);
      wsh_done       : in  std_logic;
      wsh_mapped     : in  std_logic;

      -- VRAM (nds_vram cpu9 port)
      vram_ena       : out std_logic := '0';
      vram_rnw       : out std_logic := '1';
      vram_addr      : out unsigned(23 downto 2) := (others => '0');
      vram_be        : out std_logic_vector(3 downto 0) := (others => '0');
      vram_din       : out std_logic_vector(31 downto 0) := (others => '0');
      vram_dout      : in  std_logic_vector(31 downto 0);
      vram_done      : in  std_logic;

      -- palette / OAM write ports (word index 0..255 = engine A, 256..511 =
      -- engine B half of each 2 KB mirror; the integration splits them onto
      -- the two nds_gpu2d instances. CPU readback is a known gap - reads
      -- return 0 until the BRAMs grow a read port)
      pal_we         : out std_logic := '0';
      pal_addr       : out integer range 0 to 511 := 0;
      pal_din        : out std_logic_vector(31 downto 0) := (others => '0');
      pal_be         : out std_logic_vector(3 downto 0) := (others => '0');
      oam_we         : out std_logic := '0';
      oam_addr       : out integer range 0 to 511 := 0;
      oam_din        : out std_logic_vector(31 downto 0) := (others => '0');
      oam_be         : out std_logic_vector(3 downto 0) := (others => '0');

      -- main RAM (nds_mainram mem9 port)
      mr_ena         : out std_logic := '0';
      mr_rnw         : out std_logic := '1';
      mr_addr        : out std_logic_vector(21 downto 2) := (others => '0');
      mr_be          : out std_logic_vector(3 downto 0) := (others => '0');
      mr_writedata   : out std_logic_vector(31 downto 0) := (others => '0');
      mr_done        : in  std_logic;
      mr_readdata    : in  std_logic_vector(31 downto 0);
      -- cache line fills ask for an aligned 8-byte pair per request; the second
      -- word arrives beside mr_readdata on the same mr_done
      mr_pair        : out std_logic := '0';
      mr_readdata_hi : in  std_logic_vector(31 downto 0) := (others => '0');

      -- IO register bus. The peripherals may live in a slower ce domain
      -- (33 MHz vs the 66 MHz ARM9): io_ce_next is the value their ce will
      -- have in the NEXT cycle - the 1-cycle io_bus.ena pulse is only issued
      -- when it will land on an active peripheral cycle. Tie to '1' when the
      -- peripherals run at full rate.
      io_ce_next     : in  std_logic := '1';
      io_bus         : out proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
      io_wired_out   : in  std_logic_vector(31 downto 0);
      io_wired_done  : in  std_logic;

      -- diagnostic export for the ch4 debug mailbox:
      -- {cpu_ena, cpu_done, membus state[2:0]} and the cache's own word
      dbg_mb         : out std_logic_vector(7 downto 0) := (others => '0');
      dbg_cache      : out std_logic_vector(7 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_membus9 is

   type t_target is (T_ITCM, T_DTCM, T_BROM, T_MAIN, T_WRAMSH, T_IO, T_VRAM, T_PAL, T_OAM, T_OPEN);
   -- W_IO_RESP: wait for the IO fabric's completion before retiring the access.
   -- Before the ARM9 moved to its own clock the IO fabric shared clk1x with the
   -- CPU, so io_wired_done was already valid in FINISH and going straight there
   -- was correct. Across the island bridge the round trip takes several island
   -- cycles, so FINISH was reached with io_wired_done still low - and the read mux
   -- falls back to x"00000000" for an unclaimed T_IO. Every ARM9 IO read returned
   -- zero. Measured with sim/tests/iotest: IPCSYNC, IE, DISPCNT and POWCNT1 all
   -- read back 0 where melonDS returns the written value.
   type t_state  is (IDLE, FINISH, W_WRAMSH, W_VRAM, W_MAIN, W_IO_ALIGN, W_IO_RESP);

   signal state    : t_state  := IDLE;
   signal target   : t_target := T_OPEN;
   signal r_acc    : std_logic_vector(1 downto 0) := "10";
   signal r_low    : std_logic_vector(1 downto 0) := "00";

   -- "bits at or above the region size" mask for a TCM size code: the region is
   -- 512 << size bytes, so bit 9+size and everything above it must be clear (or
   -- match the base) for an address to be inside. Pure function of the size
   -- register - see the TCM decode below for why that matters.
   function region_mask (size : std_logic_vector(4 downto 0)) return unsigned is
      variable m : unsigned(32 downto 0) := (others => '0');
   begin
      for i in 0 to 32 loop
         if (i >= 9 + to_integer(unsigned(size))) then
            m(i) := '1';
         end if;
      end loop;
      return m;
   end function;

   signal itcm_size_ovf : std_logic;
   signal dtcm_size_ovf : std_logic;

   signal itcm_hit   : std_logic;
   signal dtcm_hit   : std_logic;
   signal dec_target : t_target;
   signal wdata      : std_logic_vector(31 downto 0);
   signal be         : std_logic_vector(3 downto 0);

   signal accept_now : std_logic;
   signal itcm_sel   : std_logic;
   signal dtcm_sel   : std_logic;

   signal din_unrot  : std_logic_vector(31 downto 0);

   -- DTCM deferred store (see the block comment at the drive below).
   -- dw_* is the write presented on port B *this* cycle; it commits at the edge
   -- ending this cycle. dwq_* is that same write one cycle later, which is what
   -- a read accepted alongside it has to be bypassed against.
   signal dw_pend    : std_logic := '0';
   signal dw_addr    : unsigned(13 downto 2) := (others => '0');
   signal dw_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal dw_be      : std_logic_vector(3 downto 0) := (others => '0');

   signal dwq_pend   : std_logic := '0';
   signal dwq_addr   : unsigned(13 downto 2) := (others => '0');
   signal dwq_data   : std_logic_vector(31 downto 0) := (others => '0');
   signal dwq_be     : std_logic_vector(3 downto 0) := (others => '0');

   -- the accepted read's own address, one cycle on: both valid in FINISH.
   -- Registering the address here rather than comparing against the live
   -- cpu_adr in the accept cycle is the point: it keeps the 12-bit bypass
   -- compare off the ALU's address path, where the old dtcm_we already was.
   signal dr_pend    : std_logic := '0';
   signal dr_addr    : unsigned(13 downto 2) := (others => '0');
   signal dtcm_rd_eff : std_logic_vector(31 downto 0);

   -- cache <-> CPU-request side (main RAM only; the cache owns the mr_* port)
   signal creq_ena       : std_logic := '0';
   signal creq_rnw       : std_logic := '1';
   signal creq_code      : std_logic := '0';
   signal creq_cacheable : std_logic := '0';
   signal creq_addr      : std_logic_vector(31 downto 0) := (others => '0');
   signal creq_be        : std_logic_vector(3 downto 0) := (others => '0');
   signal creq_wdata     : std_logic_vector(31 downto 0) := (others => '0');
   signal cresp_done     : std_logic;
   signal cresp_rdata    : std_logic_vector(31 downto 0);

   -- IO read data, held past the completion pulse.
   --
   -- io_wired_done is not a level here. nds_top generates it as a one-island-cycle
   -- COMPLETION event, unconditionally, so that reads of UNCLAIMED addresses retire
   -- too (see the "IO completion, clk1x -> island" block there). The read mux below
   -- therefore presents io_wired_out for exactly that one cycle and falls through to
   -- x"00000000" on every other cycle.
   --
   -- The CPU is inside the island and samples in precisely that cycle, so its reads
   -- are correct. nds_dma9 is not: it is a clk1x unit driven by the stretched
   -- cpu9_done_1x, which is a registered toggle-edge and so lands one to two clk1x
   -- cycles LATER. By then T_IO read 0. Every ARM9 DMA read from an IO register
   -- returned zero, in both the 1:1 and 2:1 island configurations.
   --
   -- Found via the NITRO Tester's [04-02] DMA PRIORITY test (progress 011/058),
   -- which DMAs from TM3CNT_L and so filled both of its VRAM buffers with zeroes -
   -- reproduced standalone by sim/tests/dmaprio. Only the DMA is affected; every
   -- other source (VRAM, main RAM, shared WRAM) answers from a register that stays
   -- valid, which is why ordinary memory-to-memory DMA always worked.
   signal io_rd_hold     : std_logic_vector(31 downto 0) := (others => '0');
   signal io_rd_eff      : std_logic_vector(31 downto 0);

begin

   -- BIOS9 uses a synchronous hot-loadable RAM in hardware. Drive its read
   -- address in the accept cycle so the registered word is ready in FINISH.
   brom_addr <= unsigned(cpu_adr(14 downto 2));

   icache : entity work.nds_cache9
   generic map
   (
      is_simu => is_simu
   )
   port map
   (
      clk           => clk,
      reset         => reset,
      req_ena       => creq_ena,
      req_rnw       => creq_rnw,
      req_code      => creq_code,
      req_cacheable => creq_cacheable,
      req_addr      => creq_addr,
      req_be        => creq_be,
      req_wdata     => creq_wdata,
      -- the CPU's address before this membus registers it into creq_addr, so the
      -- cache can index its tag/data BRAMs a cycle earlier (see nds_cache9)
      spec_addr     => cpu_adr,
      resp_done     => cresp_done,
      resp_rdata    => cresp_rdata,
      mem_ena       => mr_ena,
      mem_rnw       => mr_rnw,
      mem_addr      => mr_addr,
      mem_be        => mr_be,
      mem_wdata     => mr_writedata,
      mem_done      => mr_done,
      mem_rdata     => mr_readdata,
      mem_pair      => mr_pair,
      mem_rdata_hi  => mr_readdata_hi,
      op_ena        => cache_op_ena,
      op            => cache_op,
      op_addr       => cache_op_addr,
      op_busy       => cache_op_busy,
      dbg_state     => dbg_cache
   );

   -- cpu_done is an out port (unreadable in VHDL-93), so export the terms that
   -- decide it instead: whichever target the current state is waiting on.
   dbg_mb <= cpu_ena & accept_now & cresp_done & mr_done & "0" &
             std_logic_vector(to_unsigned(t_state'pos(state), 3));

   -- ================= request accept (combinational mirror of can_accept) =================
   accept_now <= '1' when reset = '0' and
                          (state = IDLE or state = FINISH or
                           (state = W_WRAMSH and wsh_done   = '1') or
                           (state = W_VRAM   and vram_done  = '1') or
                           (state = W_MAIN   and cresp_done = '1') or
                           (state = W_IO_RESP and io_wired_done = '1')) else '0';

   -- ================= TCM store drive =================
   -- Presented in the accept cycle so the BRAM's internal address register
   -- takes the role of the old registered itcm_addr/dtcm_addr: read data is
   -- valid in the FINISH cycle, writes land at the accept edge (one cycle
   -- earlier than the old external write process - unobservable, the next
   -- request is accepted no earlier than the FINISH edge).
   -- These test the hit bits directly rather than `dec_target = T_*`, which is
   -- the same Boolean function and a shorter path. dec_target is an enum: the
   -- region decode below encodes itcm_hit/dtcm_hit into it and this comparison
   -- decodes them back out, two LUT levels of round trip on a signal that is
   -- already the far end of the ARM9's longest path. The DTCM store's M10K
   -- write-enable was the worst endpoint in the design after imainram|req9_lock
   -- (-4.196 ns), and it is reached exactly this way:
   --    ALU -> bus address -> dtcm_hit -> dec_target -> dtcm_sel -> dtcm_we.
   --
   -- Equivalence is by construction from the priority order below:
   --   dec_target = T_ITCM  <->  itcm_hit
   --   dec_target = T_DTCM  <->  dtcm_hit and not itcm_hit
   -- and nothing above ITCM can claim the address.
   itcm_sel       <= accept_now and cpu_ena and itcm_hit;
   itcm_addr      <= unsigned(cpu_adr(14 downto 2));
   itcm_we        <= itcm_sel and not cpu_rnw;
   itcm_be        <= be;
   itcm_writedata <= wdata;

   dtcm_sel       <= accept_now and cpu_ena and dtcm_hit and not itcm_hit;
   dtcm_addr      <= unsigned(cpu_adr(13 downto 2));

   -- ================= DTCM deferred store =================
   -- This store's M10K write enable (`idtcm|ram_block1a*~porta_we_reg`) was the
   -- single biggest timing family in the design: 46 of the 50 worst setup paths in
   -- build/artifacts-t5, and **2,009 of the ~3,000 paths that violate at 67 MHz**
   -- across the whole NDS.paths_67mhz.rpt, worst -2.535 ns. ~3.46 ns of it was the
   -- M10K's own write-enable routing and setup, which no logic work touches.
   -- Presenting the write in the accept cycle put the whole chain
   --     ALU -> cpu_adr -> dtcm_hit -> dtcm_sel -> dtcm_we -> M10K we setup
   -- inside one island cycle. Port B was unused (`ce_b => '0'`), so the write
   -- moves there with a registered address/data/we: the write enable is now a
   -- flop output and the M10K tail gets a full cycle of its own.
   --
   -- Do not expect this alone to close clk2x. The four other violating families
   -- (store data -> pal/vram/oam/wsh_din at -2.491, io_bus -2.278, creq_* -2.254,
   -- shifter/execute_busaddress -2.170) sit within 0.37 ns of this one, so
   -- removing 67% of the violating paths still leaves WNS near -2.49. See the
   -- "UPDATE 2026-07-28" section of HANDOFF.md: the front is broad, and the lever
   -- that moves all of it at once is the island's clock, not its logic.
   --
   -- One pending slot is sufficient. This bus accepts at most one request per
   -- cycle, so a store accepted in cycle N is always issued in N+1 before a
   -- store accepted in N+1 can need the slot.
   --
   -- THE HAZARD, and why the bypass below is not optional. Port A reads
   -- combinationally off the live cpu_adr and altsyncram registers that address
   -- at the edge ending the accept cycle. A store accepted in N-1 is presented
   -- on port B during N and commits at that *same* edge, so a read accepted in
   -- cycle N is a mixed-port read-during-write at one address on Cyclone V,
   -- which returns OLD data. The store-forward merge below substitutes the
   -- pending bytes into the read data in FINISH. Note the merge is safe
   -- regardless of what the silicon actually returns for mixed-port RDW: it
   -- substitutes exactly the bytes the write wrote, so if the M10K did return
   -- new data the bypass is a no-op on an identical value.
   --
   -- The simulation model has the same behaviour (`gsimu` reads `ram(addr_a)` as
   -- a signal, i.e. the pre-edge value), so a sim run does exercise this hazard
   -- rather than hiding it.
   process (clk)
   begin
      if rising_edge(clk) then
         -- age this cycle's port-B write by one, for the bypass compare
         dwq_pend <= dw_pend;
         dwq_addr <= dw_addr;
         dwq_data <= dw_data;
         dwq_be   <= dw_be;

         dw_pend  <= '0';
         dr_pend  <= '0';

         if (reset = '0') then
            dw_addr <= unsigned(cpu_adr(13 downto 2));
            dw_data <= wdata;
            dw_be   <= be;
            dr_addr <= unsigned(cpu_adr(13 downto 2));

            if (dtcm_sel = '1') then
               dw_pend <= not cpu_rnw;
               dr_pend <=     cpu_rnw;
            end if;
         else
            dwq_pend <= '0';
         end if;
      end if;
   end process;

   dtcm_addr_b      <= dw_addr;
   dtcm_we_b        <= dw_pend;
   dtcm_be_b        <= dw_be;
   dtcm_writedata_b <= dw_data;

   -- store-forward merge, consumed in FINISH via din_unrot below. Both operands
   -- are flops, so this whole compare-and-merge starts at the top of the cycle.
   process (all)
   begin
      dtcm_rd_eff <= dtcm_readdata;
      if (dr_pend = '1' and dwq_pend = '1' and dwq_addr = dr_addr) then
         for i in 0 to 3 loop
            if (dwq_be(i) = '1') then
               dtcm_rd_eff(8*i + 7 downto 8*i) <= dwq_data(8*i + 7 downto 8*i);
            end if;
         end loop;
      end if;
   end process;

   -- size > 23 makes 512 << size overflow the 33-bit limit the old compares
   -- used, which turned every hit test false. See the TCM decode below.
   itcm_size_ovf <= '1' when (unsigned(itcm_size) > 23) else '0';
   dtcm_size_ovf <= '1' when (unsigned(dtcm_size) > 23) else '0';

   -- ================= TCM decode =================
   -- Both hit tests used to be unsigned magnitude compares against runtime
   -- limits, which put the *address* on a carry chain: `a < itcm_limit` for
   -- ITCM and `a >= dtcm_lo and a < dtcm_hi` for DTCM. In the 88% island build
   -- that chain (`imembus9|LessThan2~15/34/44/45`) was 3.46 ns of the 21.8 ns
   -- `decode_RM_op2 -> vram_din` worst path, and it is most of the separate
   -- `io_bus.Adr -> vram_din` family too.
   --
   -- Same rewrite as the CP15 PU region compare above: a TCM region is a power
   -- of two, so "inside the region" is a test on the address bits *above* the
   -- region size - an and + zero-detect instead of a compare.
   --
   --   ITCM (base is architecturally 0):  a < 2^k          <->  (a and mask) = 0
   --   DTCM:                              a in [lo,lo+2^k) <->  ((a xor lo) and mask) = 0
   --
   -- with mask(i) = '1' iff i >= k. The masks derive from itcm_size/dtcm_size
   -- only - both registers - so the shift stays off the address path exactly as
   -- it does for the PU compare.
   --
   -- Two things the old form did that this has to keep doing:
   --
   -- * 512 << size is computed in 33 bits, so any size > 23 shifted the region
   --   bit off the top and left a limit of 0 - which made the compare false for
   --   every address. A mask built from k > 32 is all-zero, i.e. hit for every
   --   address: the exact opposite. `*_size_ovf` restores the old answer, and
   --   being size-derived it costs nothing on the address path. melonDS wraps
   --   the same way (u32 `0x200 << N`), so "no hit" is also the oracle's answer.
   -- * a(32) is always '0' (cpu_adr is 32 bits), so size 23 - mask = bit 32
   --   alone - hits for every address, which is what `a < 2^32` did.
   --
   -- The ITCM form is an identity. The DTCM form additionally assumes the base
   -- is aligned to the region size; the ARM946E-S requires that (an unaligned
   -- TCM base is UNPREDICTABLE) and melonDS - the trace oracle - enforces it by
   -- masking the base. Masking dtcm_lo here makes the two agree.
   process (all)
      variable a         : unsigned(32 downto 0);
      variable itcm_mask : unsigned(32 downto 0);
      variable dtcm_mask : unsigned(32 downto 0);
      variable dtcm_lo   : unsigned(32 downto 0);
   begin
      a := unsigned('0' & cpu_adr);

      itcm_mask := region_mask(itcm_size);
      itcm_hit  <= '0';
      if (itcm_ena = '1' and itcm_size_ovf = '0' and (a and itcm_mask) = 0 and dma_bus = '0') then
         -- load mode: writes land in the TCM, reads see the external map
         if (cpu_rnw = '0' or itcm_load = '0') then
            itcm_hit <= '1';
         end if;
      end if;

      dtcm_mask := region_mask(dtcm_size);
      dtcm_lo   := unsigned('0' & dtcm_base & x"000") and dtcm_mask;
      dtcm_hit  <= '0';
      if (dtcm_ena = '1' and cpu_code = '0' and dtcm_size_ovf = '0' and
          ((a xor dtcm_lo) and dtcm_mask) = 0 and dma_bus = '0') then
         if (cpu_rnw = '0' or dtcm_load = '0') then
            dtcm_hit <= '1';
         end if;
      end if;
   end process;

   -- ================= region decode =================
   process (all)
   begin
      dec_target <= T_OPEN;
      if (itcm_hit = '1') then
         dec_target <= T_ITCM;
      elsif (dtcm_hit = '1') then
         dec_target <= T_DTCM;
      elsif (cpu_adr(31 downto 16) = x"FFFF" and cpu_adr(15) = '0') then
         dec_target <= T_BROM;
      elsif (cpu_adr(31 downto 28) = x"0") then
         case cpu_adr(27 downto 24) is
            when x"2" => dec_target <= T_MAIN;
            when x"3" =>
               if (wsh_mapped = '1') then
                  dec_target <= T_WRAMSH; -- unmapped shared WRAM: ARM9 sees open bus
               end if;
            when x"4" =>
               if (cpu_adr(23) = '0') then
                  dec_target <= T_IO;
               end if;
            when x"5" => dec_target <= T_PAL;
            when x"6" => dec_target <= T_VRAM;
            when x"7" => dec_target <= T_OAM;
            when others => null;
         end case;
      end if;
   end process;

   -- ================= write lane placement (gba_mem_writerotate) =================
   process (all)
   begin
      wdata <= cpu_dout;
      if (cpu_acc = ACCESS_8BIT) then
         case (cpu_adr(1 downto 0)) is
            when "00" => wdata( 7 downto  0) <= cpu_dout(7 downto 0);
            when "01" => wdata(15 downto  8) <= cpu_dout(7 downto 0);
            when "10" => wdata(23 downto 16) <= cpu_dout(7 downto 0);
            when "11" => wdata(31 downto 24) <= cpu_dout(7 downto 0);
            when others => null;
         end case;
      elsif (cpu_acc = ACCESS_16BIT and cpu_adr(1) = '1') then
         wdata(31 downto 16) <= cpu_dout(15 downto 0);
      end if;

      be <= "1111";
      case (cpu_acc) is
         when ACCESS_8BIT =>
            case (cpu_adr(1 downto 0)) is
               when "00" => be <= "0001";
               when "01" => be <= "0010";
               when "10" => be <= "0100";
               when "11" => be <= "1000";
               when others => null;
            end case;
         when ACCESS_16BIT =>
            if (cpu_adr(1) = '1') then be <= "1100"; else be <= "0011"; end if;
         when others => null;
      end case;
   end process;

   -- ================= request FSM =================
   process (clk)
      variable can_accept : boolean;
   begin
      if rising_edge(clk) then

         wsh_ena  <= '0';
         vram_ena <= '0';
         creq_ena <= '0';
         pal_we   <= '0';
         oam_we   <= '0';
         io_bus.ena <= '0';
         io_bus.rst <= reset;

         if (reset = '1') then
            state <= IDLE;
         else
            can_accept := (accept_now = '1');

            if (state = W_IO_ALIGN) then
               if (io_ce_next = '1') then
                  io_bus.ena <= '1';
                  state      <= W_IO_RESP;
               end if;
            -- No dedicated W_IO_RESP branch on purpose. accept_now already covers
            -- "W_IO_RESP and io_wired_done", so this state completes through the
            -- shared accept path below exactly like W_MAIN / W_VRAM / W_WRAMSH do.
            -- A private branch here looks harmless but silently drops a request:
            -- this bus accepts a new access in the very cycle it completes one, so
            -- handling the completion without also honouring cpu_ena loses the
            -- CPU's next request and it waits forever for a done that never comes.
            -- That is exactly how the first version of this fix hung the ARM9 on
            -- its second IO access.
            elsif can_accept then
               state <= IDLE;
               if (cpu_ena = '1') then
                  target <= dec_target;
                  r_acc  <= cpu_acc;
                  r_low  <= cpu_adr(1 downto 0);

                  case dec_target is

                     when T_ITCM =>
                        state <= FINISH;   -- store drive is combinational above

                     when T_DTCM =>
                        state <= FINISH;   -- store drive is combinational above

                     when T_BROM =>
                        state     <= FINISH; -- writes are no-ops

                     when T_WRAMSH =>
                        wsh_ena  <= '1';
                        wsh_rnw  <= cpu_rnw;
                        wsh_addr <= unsigned(cpu_adr(14 downto 2));
                        wsh_be   <= be;
                        wsh_din  <= wdata;
                        state    <= W_WRAMSH;

                     when T_VRAM =>
                        vram_ena  <= '1';
                        vram_rnw  <= cpu_rnw;
                        vram_addr <= unsigned(cpu_adr(23 downto 2));
                        vram_be   <= be;
                        vram_din  <= wdata;
                        state     <= W_VRAM;

                     when T_PAL =>
                        -- std palettes: 2 KB mirror, engine A low / B high
                        if (cpu_rnw = '0') then
                           pal_we   <= '1';
                           pal_addr <= to_integer(unsigned(cpu_adr(10 downto 2)));
                           pal_be   <= be;
                           pal_din  <= wdata;
                        end if;
                        state <= FINISH;

                     when T_OAM =>
                        -- OAM: 2 KB mirror, engine A low / B high
                        if (cpu_rnw = '0') then
                           oam_we   <= '1';
                           oam_addr <= to_integer(unsigned(cpu_adr(10 downto 2)));
                           oam_be   <= be;
                           oam_din  <= wdata;
                        end if;
                        state <= FINISH;

                     when T_MAIN =>
                        creq_ena   <= '1';
                        creq_rnw   <= cpu_rnw;
                        creq_code  <= cpu_code;
                        creq_addr  <= cpu_adr;
                        creq_be    <= be;
                        creq_wdata <= wdata;
                        -- A DMA access is never cacheable. Two independent reasons,
                        -- either of which is sufficient:
                        --
                        -- 1. Hardware. The ARM9 DMA is a separate bus master; it
                        --    does not see the CPU's caches. That is precisely why
                        --    NitroSDK calls DC_FlushRange before a DMA and
                        --    DC_InvalidateRange after one.
                        -- 2. bus_cacheable_i/_d are decoded in nds_cpu9 from
                        --    gb_bus_Adr - the CPU's OWN address register (see
                        --    nds_cpu9.vhd:642-659) - not from the muxed bus. While
                        --    the DMA owns the bus that value is whatever address
                        --    the CPU last presented, which has nothing to do with
                        --    the address being transferred.
                        --
                        -- Leaving it stale is what broke bootreq subtest 14. The
                        -- CPU was paused mid instruction-fetch from main RAM, i.e.
                        -- inside the one PU region the test marks cacheable, so
                        -- bus_cacheable_d read '1' for the whole transfer. The
                        -- DMA's read of 0x02FFFF60 then allocated a line and its
                        -- write of 0x02FFFF70 hit that same line and stopped there,
                        -- dirty. The CPU's read-back went through the uncached
                        -- mirror straight to main RAM and saw 0. On the bus the
                        -- transfer looked perfect - correct address, correct data,
                        -- correct handshake - which is why this survived a probe of
                        -- the DMA path itself.
                        if (dma_bus = '1') then
                           creq_cacheable <= '0';
                        elsif (cpu_code = '1') then
                           creq_cacheable <= bus_cacheable_i;
                        else
                           creq_cacheable <= bus_cacheable_d;
                        end if;
                        state <= W_MAIN;

                     when T_IO =>
                        io_bus.rnw  <= cpu_rnw;
                        io_bus.Adr  <= x"0" & cpu_adr(23 downto 2) & "00";
                        io_bus.acc  <= cpu_acc;
                        io_bus.Din  <= wdata;
                        io_bus.bEna <= be;
                        if (io_ce_next = '1') then
                           io_bus.ena <= '1';
                           state      <= W_IO_RESP;
                        else
                           state <= W_IO_ALIGN;
                        end if;

                     when T_OPEN =>
                        state <= FINISH;

                  end case;
               end if;
            end if;
         end if;
      end if;
   end process;

   cpu_done <= '1'            when state = FINISH    else
               wsh_done       when state = W_WRAMSH  else
               vram_done      when state = W_VRAM    else
               cresp_done     when state = W_MAIN    else
               io_wired_done  when state = W_IO_RESP else '0';

   -- ================= read data mux + rotation (gba_mem_readrotate) =================
   din_unrot <= itcm_readdata when target = T_ITCM   else
                dtcm_rd_eff   when target = T_DTCM   else
                brom_data     when target = T_BROM   else
                wsh_dout      when target = T_WRAMSH else
                vram_dout     when target = T_VRAM   else
                x"00000000"   when (target = T_PAL or target = T_OAM) else -- readback gap: BRAMs are write-only from the CPU
                cresp_rdata   when target = T_MAIN   else
                -- unclaimed NDS9 IO reads 0 (not GBA open bus): calico probes SCFG
                -- 0x04004000 for NTR/TWL detection. io_wired_out is a wired-OR tree
                -- and is already 0 when nothing claims the address, so capturing it
                -- in the completion cycle preserves that and also survives into the
                -- cycle nds_dma9 retires the access - see io_rd_hold above.
                io_rd_eff     when target = T_IO     else
                cpu_lastread;

   io_rd_eff <= io_wired_out when io_wired_done = '1' else io_rd_hold;

   process (clk)
   begin
      if rising_edge(clk) then
         if (io_wired_done = '1') then
            io_rd_hold <= io_wired_out;
         end if;
      end if;
   end process;

   process (all)
   begin
      cpu_din <= (others => '0');
      if (r_acc = ACCESS_8BIT) then
         case (r_low) is
            when "00" => cpu_din <= x"000000" & din_unrot(7 downto 0);
            when "01" => cpu_din <= x"000000" & din_unrot(15 downto 8);
            when "10" => cpu_din <= x"000000" & din_unrot(23 downto 16);
            when "11" => cpu_din <= x"000000" & din_unrot(31 downto 24);
            when others => null;
         end case;
      elsif (r_acc = ACCESS_16BIT) then
         case (r_low) is
            when "00" => cpu_din <= x"0000" & din_unrot(15 downto 0);
            when "01" => cpu_din <= din_unrot(7 downto 0) & x"0000" & din_unrot(15 downto 8);
            when "10" => cpu_din <= x"0000" & din_unrot(31 downto 16);
            when "11" => cpu_din <= din_unrot(23 downto 16) & x"0000" & din_unrot(31 downto 24);
            when others => null;
         end case;
      else
         case (r_low) is
            when "00" => cpu_din <= din_unrot;
            when "01" => cpu_din <= din_unrot(7 downto 0) & din_unrot(31 downto 8);
            when "10" => cpu_din <= din_unrot(15 downto 0) & din_unrot(31 downto 16);
            when "11" => cpu_din <= din_unrot(23 downto 0) & din_unrot(31 downto 24);
            when others => null;
         end case;
      end if;
   end process;

end architecture;
