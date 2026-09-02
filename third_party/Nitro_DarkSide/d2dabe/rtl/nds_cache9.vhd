-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- ARM946E-S caches for the NDS ARM9: 8 KB I-cache + 4 KB write-back D-cache,
-- both 4-way set-associative with 32-byte (8-word) lines and per-set
-- round-robin replacement. Sits between nds_membus9's main-RAM decode and the
-- nds_mainram port; everything else (TCM/IO/VRAM/WRAM) stays uncached, which
-- matches how NDS software actually configures the PU.
--
--   * I-cache: read-allocate on cachable code fetches.
--   * D-cache: read-allocate, write-back. Write hit updates the line and
--     marks it dirty; write miss goes straight to memory (no allocate).
--     Dirty victims are written back before the fill.
--   * Uncachable accesses bypass both caches entirely (like the real PU:
--     changing a region's cachability without cleaning gives stale aliases,
--     on hardware and here).
--   * Maintenance ops (op_* interface, issued by nds_cpu9's MCR c7 path):
--     invalidate I all/line, invalidate D all/line/index, clean D line/index,
--     clean+invalidate D line/index. Invalidate-without-clean drops dirty
--     data - architecturally intended. op_busy is combinationally high from
--     the op_ena pulse until the op retires; the CPU stalls on it.
--
-- Storage (the M9 BRAM passes): line DATA lives in independent per-way
-- SyncRamDualByteEnable blocks. Each way's I- and D-cache tags share one shallow
-- 128-row store: I sets occupy rows 0..63 and D sets rows 64..95. The two RAM
-- ports preserve the retired design's simultaneous I/D reads and speculative
-- early-hit timing while using the otherwise-empty depth of each tag M10K.
-- All four tags for both selected sets are read in parallel. Valid, dirty and RR
-- state remain as small flop arrays so invalidate-all stays atomic. Cacheable
-- requests and address-based maintenance gain one cycle; associativity,
-- replacement and write-back behavior are unchanged. WB_PREP lets the first
-- data beat's registered read land before a writeback starts.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

entity nds_cache9 is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;

      -- CPU request (main-RAM accesses only, one ena pulse per request)
      req_ena       : in  std_logic;
      req_rnw       : in  std_logic;
      req_code      : in  std_logic;
      req_cacheable : in  std_logic;
      req_addr      : in  std_logic_vector(31 downto 0);
      req_be        : in  std_logic_vector(3 downto 0);
      req_wdata     : in  std_logic_vector(31 downto 0);
      -- The CPU's live address, one cycle AHEAD of req_addr: the membus
      -- registers req_* on the edge it accepts, so req_addr only becomes valid
      -- the cycle after the CPU presented it. Indexing the tag/data BRAMs off
      -- this instead spends that otherwise-idle cycle on the lookup read, which
      -- is what lets a read hit answer in 2 cycles instead of 3. Speculative and
      -- unqualified on purpose - a wrong index just reads a line nobody uses.
      spec_addr     : in  std_logic_vector(31 downto 0);
      resp_done     : out std_logic := '0';
      resp_rdata    : out std_logic_vector(31 downto 0) := (others => '0');

      -- memory side (nds_mainram mem9 port)
      mem_ena       : out std_logic := '0';
      mem_rnw       : out std_logic := '1';
      mem_addr      : out std_logic_vector(21 downto 2) := (others => '0');
      mem_be        : out std_logic_vector(3 downto 0) := (others => '0');
      mem_wdata     : out std_logic_vector(31 downto 0) := (others => '0');
      mem_done      : in  std_logic;
      mem_rdata     : in  std_logic_vector(31 downto 0);
      -- PAIR FILLS. The SDRAM controller runs BURST_LENGTH=4 and so moves 64
      -- bits on every access; ch2 used to discard half (rtl/sdram.sv
      -- ch2_dout_hi). Asking nds_mainram for the aligned pair makes a 32-byte
      -- line four requests instead of eight, and each request saved is a whole
      -- clk1x handshake plus a wait for clkMemIndex = 0 with mainram_allow -
      -- which costs far more than the burst does. mem_addr is always even in
      -- pair mode: a line is 32-byte aligned, so its four pairs are too.
      mem_pair      : out std_logic := '0';
      mem_rdata_hi  : in  std_logic_vector(31 downto 0) := (others => '0');

      -- maintenance (see nds_cpu9 cache_op encoding)
      op_ena        : in  std_logic;
      op            : in  std_logic_vector(3 downto 0);
      op_addr       : in  std_logic_vector(31 downto 0);
      op_busy       : out std_logic;

      -- diagnostic export: {r_code, beat[2:0], state[3:0]}. Read out through the
      -- ch4 debug mailbox so a wedged ARM9 can be told apart from a slow one
      -- without a waveform. Costs a 8-bit encoder; leave it wired.
      dbg_state     : out std_logic_vector(7 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_cache9 is

   -- I: 4 ways x 64 sets x 8 words, tag = addr(31 downto 11)
   -- D: 4 ways x 32 sets x 8 words, tag = addr(31 downto 10)
   type t_rr6   is array (0 to 63) of unsigned(1 downto 0);
   type t_rr5   is array (0 to 31) of unsigned(1 downto 0);

   signal ivalid  : std_logic_vector(255 downto 0) := (others => '0');
   signal irr     : t_rr6 := (others => "00");

   signal dvalid  : std_logic_vector(127 downto 0) := (others => '0');
   signal ddirty  : std_logic_vector(127 downto 0) := (others => '0');
   signal drr     : t_rr5 := (others => "00");

   -- One tag RAM per way, with the two cache tag spaces packed by depth.
   type t_wayq is array (0 to 3) of std_logic_vector(31 downto 0);
   signal it_raddr : integer range 0 to 63;
   signal dt_raddr : integer range 0 to 31;
   signal it_tag_addr : integer range 0 to 127;
   signal dt_tag_addr : integer range 0 to 127;
   signal it_q     : t_wayq;
   signal dt_q     : t_wayq;
   signal it_we    : std_logic_vector(3 downto 0);
   signal dt_we    : std_logic_vector(3 downto 0);
   signal it_waddr : integer range 0 to 63;
   signal dt_waddr : integer range 0 to 31;
   signal it_tag_write : std_logic;
   signal dt_tag_write : std_logic;
   signal id_raddr : integer range 0 to 511;
   signal dd_raddr : integer range 0 to 255;
   signal id_q     : t_wayq;
   signal dd_q     : t_wayq;
   signal id_we    : std_logic_vector(3 downto 0);
   signal dd_we    : std_logic_vector(3 downto 0);
   signal id_waddr : integer range 0 to 511;
   -- was hardwired to mem_rdata at the BRAM; a pair fill has to steer the
   -- second word through the same port on the following cycle
   signal id_wdata : std_logic_vector(31 downto 0);
   signal dd_waddr : integer range 0 to 255;
   signal dd_wdata : std_logic_vector(31 downto 0);
   signal dd_wbe   : std_logic_vector(3 downto 0);

   -- response routing: on a hit the data comes off the way BRAM output
   -- (captured at the lookup edge), on a fill/bypass it comes from resp_hold
   signal resp_way   : integer range 0 to 3 := 0;
   signal resp_use_i : std_logic := '0';
   signal resp_use_d : std_logic := '0';

   -- D write hit: the BRAM write commits during HIT_RESP (one cycle after
   -- the lookup - invisible, the next lookup's read capture is >= 2 edges
   -- later, and resp_done timing is unchanged)
   signal dwr_pend : std_logic := '0';
   signal dwr_way  : integer range 0 to 3 := 0;
   signal dwr_addr : integer range 0 to 255 := 0;
   signal dwr_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal dwr_data : std_logic_vector(31 downto 0) := (others => '0');

   -- writeback read cursor (port A of the victim way during WB states)
   signal wb_way   : integer range 0 to 3 := 0;
   signal wb_raddr : integer range 0 to 255 := 0;

   -- Speculative-index bookkeeping. spec_sel is the cycle in which the BRAM read
   -- address came from spec_addr rather than from a request already in flight;
   -- spec_ok is that fact delayed by one edge, i.e. "the tags now on it_q/dt_q
   -- belong to whatever the CPU was presenting last cycle". Since the membus
   -- registers req_addr from the same CPU address on the same edge, spec_ok = '1'
   -- together with req_ena = '1' proves the latched tags are this request's.
   signal spec_sel : std_logic := '0';
   signal spec_ok  : std_logic := '0';

   -- One shared 4-way comparator set, address-muxed between the early lookup
   -- (IDLE, comparing req_addr) and the normal one (REQ_LOOKUP, comparing the
   -- registered r_addr). Hoisted out of the FSM process deliberately: a second
   -- private comparator in the IDLE branch would cost ALMs, and this device is
   -- already the binding constraint.
   signal cmp_addr : std_logic_vector(31 downto 0);
   signal ihit_c   : std_logic;
   signal dhit_c   : std_logic;
   signal ihway_c  : integer range 0 to 3;
   signal dhway_c  : integer range 0 to 3;

   type t_state is
   (
      IDLE,
      REQ_LOOKUP,    -- synchronous per-way tags are now valid; resolve hit
      OP_LOOKUP,     -- resolve an address/index maintenance operation
      HIT_RESP,      -- registered hit / end of fill: put data on resp
      BYPASS_ISSUE,  -- uncachable or D write miss: single memory beat
      BYPASS_WAIT,
      WB_PREP,       -- one cycle so the victim way's beat-0 read lands
      WB_BEAT,       -- write back one dirty line (victim or clean op)
      WB_WAIT,
      FILL_BEAT,     -- fill one line from memory, an aligned PAIR per request
      FILL_WAIT,     -- pair arrived: low word to the way BRAM
      FILL_HI,       -- ...and its high word, the next cycle
      OP_FINISH
   );
   signal state : t_state := IDLE;

   function state_code (s : t_state) return std_logic_vector is
   begin
      case s is
         when IDLE         => return x"0";
         when REQ_LOOKUP   => return x"1";
         when OP_LOOKUP    => return x"2";
         when HIT_RESP     => return x"3";
         when BYPASS_ISSUE => return x"4";
         when BYPASS_WAIT  => return x"5";
         when WB_PREP      => return x"6";
         when WB_BEAT      => return x"7";
         when WB_WAIT      => return x"8";
         when FILL_BEAT    => return x"9";
         when FILL_WAIT    => return x"A";
         when OP_FINISH    => return x"B";
         when FILL_HI      => return x"C";
      end case;
   end function;

   -- latched CPU request
   signal r_rnw   : std_logic := '1';
   signal r_code  : std_logic := '0';
   signal r_addr  : std_logic_vector(31 downto 0) := (others => '0');
   signal r_be    : std_logic_vector(3 downto 0) := (others => '0');
   signal r_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal r_op     : std_logic_vector(3 downto 0) := (others => '0');
   signal r_opaddr : std_logic_vector(31 downto 0) := (others => '0');

   -- fill/writeback bookkeeping
   signal beat        : unsigned(2 downto 0) := (others => '0');
   -- CRITICAL WORD FIRST. beat no longer starts at 0 and runs to 7; it starts
   -- at the PAIR holding the word the CPU asked for and wraps (6 -> 0 falls out
   -- of the 3-bit width), so the requested word is in the very first memory
   -- round trip instead of the 2.5th on average. That only pays because the
   -- response is now sent the moment that word lands rather than at the end of
   -- the line, which leaves up to three of the four round trips overlapping
   -- real CPU work. Since beat wraps, it can no longer be the end-of-fill test
   -- - fill_cnt counts the four pairs instead.
   signal fill_cnt    : unsigned(1 downto 0) := (others => '0');
   signal fill_way    : integer range 0 to 3 := 0;
   signal wb_line     : integer range 0 to 255 := 0;   -- D line being written back
   signal wb_addrbase : std_logic_vector(21 downto 5) := (others => '0');
   signal after_wb_fill : std_logic := '0';            -- WB is a victim clean before a fill
   signal op_invalidate_after : std_logic := '0';      -- clean+invalidate

   -- pending maintenance op (an op can arrive while a fetch is in flight),
   -- and a pending CPU request (a prefetch can arrive while an op runs)
   signal op_pending  : std_logic := '0';
   signal op_active   : std_logic := '0';
   signal p_op        : std_logic_vector(3 downto 0) := (others => '0');
   signal p_addr      : std_logic_vector(31 downto 0) := (others => '0');
   signal req_pending : std_logic := '0';

   signal resp_hold   : std_logic_vector(31 downto 0) := (others => '0');

begin

   op_busy <= op_ena or op_pending or op_active;

   dbg_state <= r_code & std_logic_vector(beat) & state_code(state);

   -- ================= tag and line-data stores =================
   -- At IDLE, select the address of the operation that wins arbitration.
   -- The per-way synchronous tag outputs are consumed in REQ_LOOKUP or
   -- OP_LOOKUP on the following edge.
   -- spec_sel: IDLE with nothing already in flight, so the read port is free to
   -- prefetch the tags of the address the CPU is presenting right now.
   spec_sel <= '1' when (state = IDLE and op_ena = '0' and op_pending = '0' and
                         req_ena = '0' and req_pending = '0') else '0';

   it_raddr <= to_integer(unsigned(op_addr(10 downto 5))) when (state = IDLE and op_ena = '1') else
               to_integer(unsigned(p_addr(10 downto 5))) when (state = IDLE and op_pending = '1') else
               to_integer(unsigned(spec_addr(10 downto 5))) when (spec_sel = '1') else
               to_integer(unsigned(req_addr(10 downto 5)));
   dt_raddr <= to_integer(unsigned(op_addr(9 downto 5))) when (state = IDLE and op_ena = '1') else
               to_integer(unsigned(p_addr(9 downto 5))) when (state = IDLE and op_pending = '1') else
               to_integer(unsigned(spec_addr(9 downto 5))) when (spec_sel = '1') else
               to_integer(unsigned(req_addr(9 downto 5)));

   -- Shared hit resolution. In IDLE the candidate is the incoming req_addr (whose
   -- tags spec_sel prefetched last cycle); everywhere else it is r_addr, which is
   -- what REQ_LOOKUP has always compared.
   cmp_addr <= req_addr when (state = IDLE) else r_addr;

   process (all)
      variable s : integer range 0 to 63;
   begin
      ihit_c  <= '0';
      ihway_c <= 0;
      s := to_integer(unsigned(cmp_addr(10 downto 5)));
      for w in 0 to 3 loop
         if (ivalid(w*64 + s) = '1' and it_q(w)(20 downto 0) = cmp_addr(31 downto 11)) then
            ihit_c  <= '1';
            ihway_c <= w;
         end if;
      end loop;
   end process;

   process (all)
      variable s : integer range 0 to 31;
   begin
      dhit_c  <= '0';
      dhway_c <= 0;
      s := to_integer(unsigned(cmp_addr(9 downto 5)));
      for w in 0 to 3 loop
         if (dvalid(w*32 + s) = '1' and dt_q(w)(21 downto 0) = cmp_addr(31 downto 10)) then
            dhit_c  <= '1';
            dhway_c <= w;
         end if;
      end loop;
   end process;

   it_waddr <= to_integer(unsigned(r_addr(10 downto 5)));
   dt_waddr <= to_integer(unsigned(r_addr(9 downto 5)));
   it_tag_write <= it_we(0) or it_we(1) or it_we(2) or it_we(3);
   dt_tag_write <= dt_we(0) or dt_we(1) or dt_we(2) or dt_we(3);
   -- Preserve the retired design's simultaneous I/D reads by assigning one RAM
   -- port to each cache. A completed fill borrows that cache's own port for its
   -- tag write; no tag output is consumed on that edge, and the other cache's
   -- speculative read continues uninterrupted.
   it_tag_addr <= it_waddr when it_tag_write = '1' else it_raddr;
   dt_tag_addr <= 64 + dt_waddr when dt_tag_write = '1' else 64 + dt_raddr;

   process (all)
   begin
      it_we <= (others => '0');
      dt_we <= (others => '0');
      -- The LAST cycle of the fill, which pairing moved: beats now walk
      -- 0,2,4,6 and the eighth word lands in the FILL_HI that follows beat 6,
      -- so `beat = 7` never happens. Leaving this on the old condition writes
      -- the line's data and never its tag - the line is then unfindable, every
      -- later access misses, and a dirty write goes straight to memory. That
      -- is a silent correctness bug, not a stall: sim/tests/arm9_cache.s test 1
      -- catches it exactly (write-back looks like write-through).
      if (state = FILL_HI and fill_cnt = 3) then
         if (r_code = '1') then
            it_we(fill_way) <= '1';
         else
            dt_we(fill_way) <= '1';
         end if;
      end if;
   end process;

   -- Port A: free-running registered-address read. It follows the incoming
   -- request's set/word (the membus holds req_addr stable until resp_done,
   -- so the capture at the lookup edge is the wanted word of every way);
   -- during WB states it follows the writeback cursor instead.
   id_raddr <= to_integer(unsigned(spec_addr(10 downto 2))) when (spec_sel = '1')
          else to_integer(unsigned(req_addr(10 downto 2)));
   dd_raddr <= wb_raddr when (state = WB_PREP or state = WB_BEAT or state = WB_WAIT)
          else to_integer(unsigned(spec_addr(9 downto 2))) when (spec_sel = '1')
          else to_integer(unsigned(req_addr(9 downto 2)));

   -- Port B: writes. A pended write hit (during HIT_RESP) or a fill beat.
   process (all)
   begin
      dd_we    <= (others => '0');
      dd_waddr <= dwr_addr;
      dd_wdata <= dwr_data;
      dd_wbe   <= dwr_be;
      if (dwr_pend = '1') then
         dd_we(dwr_way) <= '1';
      elsif (state = FILL_WAIT and mem_done = '1' and r_code = '0') then
         dd_we(fill_way) <= '1';
         dd_waddr <= to_integer(unsigned(r_addr(9 downto 5))) * 8 + to_integer(beat);
         dd_wdata <= mem_rdata;
         dd_wbe   <= "1111";
      elsif (state = FILL_HI and r_code = '0') then
         -- beat still holds the EVEN index here; it advances on the way out
         dd_we(fill_way) <= '1';
         dd_waddr <= to_integer(unsigned(r_addr(9 downto 5))) * 8 + to_integer(beat) + 1;
         dd_wdata <= mem_rdata_hi;
         dd_wbe   <= "1111";
      end if;
   end process;

   process (all)
   begin
      id_we    <= (others => '0');
      id_waddr <= to_integer(unsigned(r_addr(10 downto 5))) * 8 + to_integer(beat);
      id_wdata <= mem_rdata;
      if (state = FILL_WAIT and mem_done = '1' and r_code = '1') then
         id_we(fill_way) <= '1';
      elsif (state = FILL_HI and r_code = '1') then
         id_we(fill_way) <= '1';
         id_waddr <= to_integer(unsigned(r_addr(10 downto 5))) * 8 + to_integer(beat) + 1;
         id_wdata <= mem_rdata_hi;
      end if;
   end process;

   gways : for w in 0 to 3 generate
   begin
      packed_tags : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         ADDR_WIDTH  => 7,
         BYTES       => 4
      )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => it_tag_addr,
         datain_a0 => r_addr(18 downto 11),
         datain_a1 => r_addr(26 downto 19),
         datain_a2 => "000" & r_addr(31 downto 27),
         datain_a3 => x"00",
         dataout_a => it_q(w),
         we_a      => it_we(w),
         be_a      => "1111",
         ce_b      => '1',
         addr_b    => dt_tag_addr,
         datain_b0 => r_addr(17 downto 10),
         datain_b1 => r_addr(25 downto 18),
         datain_b2 => "00" & r_addr(31 downto 26),
         datain_b3 => x"00",
         dataout_b => dt_q(w),
         we_b      => dt_we(w),
         be_b      => "1111"
      );

      iidata : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         ADDR_WIDTH  => 9,
         BYTES       => 4
      )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => id_raddr,
         datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
         dataout_a => id_q(w),
         we_a      => '0',
         be_a      => "0000",
         ce_b      => '1',
         addr_b    => id_waddr,
         datain_b0 => id_wdata( 7 downto  0),
         datain_b1 => id_wdata(15 downto  8),
         datain_b2 => id_wdata(23 downto 16),
         datain_b3 => id_wdata(31 downto 24),
         dataout_b => open,
         we_b      => id_we(w),
         be_b      => "1111"
      );

      iddata : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         ADDR_WIDTH  => 8,
         BYTES       => 4
      )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => dd_raddr,
         datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
         dataout_a => dd_q(w),
         we_a      => '0',
         be_a      => "0000",
         ce_b      => '1',
         addr_b    => dd_waddr,
         datain_b0 => dd_wdata( 7 downto  0),
         datain_b1 => dd_wdata(15 downto  8),
         datain_b2 => dd_wdata(23 downto 16),
         datain_b3 => dd_wdata(31 downto 24),
         dataout_b => open,
         we_b      => dd_we(w),
         be_b      => dd_wbe
      );
   end generate;

   process (clk)
      variable iset, dset  : integer range 0 to 63;
      variable ihit, dhit  : boolean;
      variable hway        : integer range 0 to 3;
      variable dline       : integer range 0 to 127;
      variable v_op        : std_logic_vector(3 downto 0);
      variable v_opaddr    : std_logic_vector(31 downto 0);
      variable run_op      : boolean;
   begin
      if rising_edge(clk) then

         mem_ena   <= '0';
         resp_done <= '0';
         dwr_pend  <= '0';
         spec_ok   <= spec_sel;

         if (reset = '1') then
            spec_ok     <= '0';
            state       <= IDLE;
            ivalid      <= (others => '0');
            dvalid      <= (others => '0');
            ddirty      <= (others => '0');
            op_pending  <= '0';
            op_active   <= '0';
            req_pending <= '0';
         else

            -- park an op that arrives while the FSM is busy
            if (op_ena = '1') then
               op_pending <= '1';
               p_op       <= op;
               p_addr     <= op_addr;
            end if;
            -- park a CPU request that loses arbitration to an op (the request
            -- inputs stay stable: the membus holds them until resp_done)
            if (req_ena = '1' and (state /= IDLE or op_ena = '1' or op_pending = '1')) then
               req_pending <= '1';
            end if;

            case state is

               when IDLE =>
                  run_op := false;
                  if (op_ena = '1') then
                     v_op := op; v_opaddr := op_addr; run_op := true;
                     op_pending <= '0';
                  elsif (op_pending = '1') then
                     v_op := p_op; v_opaddr := p_addr; run_op := true;
                     op_pending <= '0';
                  end if;

                  if (run_op) then
                     op_active <= '1';
                     case v_op is

                        when "0000" =>                    -- invalidate I all
                           ivalid <= (others => '0');
                           state  <= OP_FINISH;

                        when "0001" =>                    -- invalidate I line MVA
                           r_op     <= v_op;
                           r_opaddr <= v_opaddr;
                           state    <= OP_LOOKUP;

                        when "0010" =>                    -- invalidate D all
                           dvalid <= (others => '0');
                           ddirty <= (others => '0');
                           state  <= OP_FINISH;

                        when "0011" | "0100" | "0101" | "0110" | "0111" | "1000" =>
                           r_op     <= v_op;
                           r_opaddr <= v_opaddr;
                           state    <= OP_LOOKUP;

                        when others =>
                           state <= OP_FINISH;
                     end case;

                  elsif (req_ena = '1' or req_pending = '1') then
                     req_pending <= '0';
                     r_rnw   <= req_rnw;
                     r_code  <= req_code;
                     r_addr  <= req_addr;
                     r_be    <= req_be;
                     r_wdata <= req_wdata;

                     if (req_cacheable = '0') then
                        state <= BYPASS_ISSUE;
                     elsif (spec_ok = '1' and req_pending = '0' and
                            ((req_code = '1' and ihit_c = '1') or
                             (req_code = '0' and dhit_c = '1' and req_rnw = '1'))) then
                        -- Early read hit: spec_sel prefetched this address's tags
                        -- last cycle, so the lookup REQ_LOOKUP would have done next
                        -- cycle is already resolvable. Answer now and stay in IDLE,
                        -- which also leaves the read port free to prefetch the
                        -- following access - back-to-back hits settle at 2 cycles
                        -- per access instead of 3.
                        --
                        -- Hits only. A miss falls through to REQ_LOOKUP below and
                        -- costs exactly what it always did (the mux re-presents
                        -- req_addr this cycle, so its tags are valid there as
                        -- before); duplicating the fill/writeback setup here would
                        -- buy one cycle on misses for a lot of logic. Write hits
                        -- likewise still take HIT_RESP, where the line update is
                        -- issued on port B.
                        resp_done  <= '1';
                        resp_use_i <= '0';
                        resp_use_d <= '0';
                        if (req_code = '1') then
                           resp_rdata <= id_q(ihway_c);
                        else
                           resp_rdata <= dd_q(dhway_c);
                        end if;
                     else
                        state <= REQ_LOOKUP;
                     end if;
                  end if;

               when REQ_LOOKUP =>
                  -- Hit resolution comes from the shared comparator above, which
                  -- in this state compares r_addr - the same thing this branch
                  -- used to compute inline with its own 4-way compare.
                  if (r_code = '1') then
                     iset := to_integer(unsigned(r_addr(10 downto 5)));
                     ihit := (ihit_c = '1');
                     hway := ihway_c;
                     if (ihit) then
                        -- I-cache read hit: answer in THIS cycle instead of
                        -- spending a HIT_RESP cycle. id_q is already valid here
                        -- (id_raddr is a free-running read off req_addr, which
                        -- the membus holds stable until resp_done), and hway is
                        -- resolved combinationally just above, so the way mux can
                        -- move into this cycle. Saves one cycle on every fetch
                        -- that hits, which is the dominant ARM9 memory event:
                        -- measured CPI was 2.65 against the ARM7's 1.12.
                        -- Reads only - a D-cache *write* hit still needs
                        -- HIT_RESP, where the line update is issued.
                        resp_done  <= '1';
                        resp_rdata <= id_q(hway);
                        resp_use_i <= '0';
                        resp_use_d <= '0';
                        state      <= IDLE;
                     else
                        fill_way <= to_integer(irr(iset));
                        beat     <= unsigned(r_addr(4 downto 3)) & '0';
                        fill_cnt <= (others => '0');
                        state    <= FILL_BEAT;
                     end if;
                  else
                     dset := to_integer(unsigned(r_addr(9 downto 5)));
                     dhit := (dhit_c = '1');
                     hway := dhway_c;

                     if (dhit) then
                        if (r_rnw = '1') then
                           -- D-cache READ hit: same one-cycle answer as the
                           -- I-side above. dd_q is valid here too (dd_raddr
                           -- follows req_addr outside the writeback states).
                           resp_done  <= '1';
                           resp_rdata <= dd_q(hway);
                           resp_use_i <= '0';
                           resp_use_d <= '0';
                           state      <= IDLE;
                        else
                           -- WRITE hit keeps HIT_RESP: that is the cycle in
                           -- which dwr_pend drives the port-B line update.
                           dwr_pend <= '1';
                           dwr_way  <= hway;
                           dwr_addr <= dset*8 + to_integer(unsigned(r_addr(4 downto 2)));
                           dwr_be   <= r_be;
                           dwr_data <= r_wdata;
                           ddirty(hway*32 + dset) <= '1';
                           resp_use_i <= '0';
                           resp_use_d <= '0';
                           state    <= HIT_RESP;
                        end if;
                     elsif (r_rnw = '0') then
                        state <= BYPASS_ISSUE;
                     else
                        hway     := to_integer(drr(dset));
                        fill_way <= hway;
                        beat     <= (others => '0');
                        if (dvalid(hway*32 + dset) = '1' and ddirty(hway*32 + dset) = '1') then
                           wb_line       <= hway*32 + dset;
                           wb_way        <= hway;
                           wb_raddr      <= dset*8;
                           wb_addrbase   <= dt_q(hway)(11 downto 0) & r_addr(9 downto 5);
                           after_wb_fill <= '1';
                           state         <= WB_PREP;
                        else
                           beat     <= unsigned(r_addr(4 downto 3)) & '0';
                           fill_cnt <= (others => '0');
                           state    <= FILL_BEAT;
                        end if;
                     end if;
                  end if;

               when OP_LOOKUP =>
                  if (r_op = "0001") then
                     iset := to_integer(unsigned(r_opaddr(10 downto 5)));
                     for w in 0 to 3 loop
                        if (ivalid(w*64 + iset) = '1' and it_q(w)(20 downto 0) = r_opaddr(31 downto 11)) then
                           ivalid(w*64 + iset) <= '0';
                        end if;
                     end loop;
                     state <= OP_FINISH;
                  else
                     dhit := false;
                     dset := to_integer(unsigned(r_opaddr(9 downto 5)));
                     if (r_op = "0100" or r_op = "0110" or r_op = "1000") then
                        hway  := to_integer(unsigned(r_opaddr(31 downto 30)));
                        dline := hway*32 + dset;
                        dhit  := dvalid(dline) = '1';
                     else
                        for w in 0 to 3 loop
                           if (dvalid(w*32 + dset) = '1' and dt_q(w)(21 downto 0) = r_opaddr(31 downto 10)) then
                              hway  := w;
                              dline := w*32 + dset;
                              dhit  := true;
                           end if;
                        end loop;
                     end if;

                     if (not dhit) then
                        state <= OP_FINISH;
                     elsif (r_op = "0011" or r_op = "0100") then
                        dvalid(dline) <= '0';
                        ddirty(dline) <= '0';
                        state <= OP_FINISH;
                     elsif (ddirty(dline) = '0') then
                        if (r_op = "0111" or r_op = "1000") then
                           dvalid(dline) <= '0';
                        end if;
                        state <= OP_FINISH;
                     else
                        wb_line       <= dline;
                        wb_way        <= hway;
                        wb_raddr      <= dset * 8;
                        wb_addrbase   <= dt_q(hway)(11 downto 0) & std_logic_vector(to_unsigned(dset, 5));
                        beat          <= (others => '0');
                        after_wb_fill <= '0';
                        op_invalidate_after <= '0';
                        if (r_op = "0111" or r_op = "1000") then
                           op_invalidate_after <= '1';
                        end if;
                        state <= WB_PREP;
                     end if;
                  end if;

               when HIT_RESP =>
                  resp_done  <= '1';
                  if (resp_use_i = '1') then
                     resp_rdata <= id_q(resp_way);
                  elsif (resp_use_d = '1') then
                     resp_rdata <= dd_q(resp_way);
                  else
                     resp_rdata <= resp_hold;
                  end if;
                  state <= IDLE;

               when BYPASS_ISSUE =>
                  mem_ena   <= '1';
                  mem_pair  <= '0';
                  mem_rnw   <= r_rnw;
                  mem_addr  <= r_addr(21 downto 2);
                  mem_be    <= r_be;
                  mem_wdata <= r_wdata;
                  state     <= BYPASS_WAIT;

               when BYPASS_WAIT =>
                  if (mem_done = '1') then
                     resp_done  <= '1';
                     resp_rdata <= mem_rdata;
                     state      <= IDLE;
                  end if;

               when WB_PREP =>
                  -- beat 0's registered read (wb_raddr on port A) lands here
                  state <= WB_BEAT;

               when WB_BEAT =>
                  mem_ena   <= '1';
                  -- writes never pair (nds_mainram masks it anyway), and this
                  -- must be HELD like mem_rnw/mem_addr rather than pulsed: the
                  -- request crosses into clk1x through a toggle handshake, so
                  -- nds_mainram samples the attributes some cycles later. A
                  -- one-cycle mem_pair reads as low by then, which is what
                  -- broke the first attempt at this.
                  mem_pair  <= '0';
                  mem_rnw   <= '0';
                  mem_addr  <= wb_addrbase & std_logic_vector(beat);
                  mem_be    <= "1111";
                  mem_wdata <= dd_q(wb_way);
                  -- advance the read cursor to the next beat; its data is
                  -- captured at the next edge and holds through WB_WAIT
                  if (beat /= 7) then
                     wb_raddr <= wb_raddr + 1;
                  end if;
                  state <= WB_WAIT;

               when WB_WAIT =>
                  if (mem_done = '1') then
                     if (beat = 7) then
                        ddirty(wb_line) <= '0';
                        if (after_wb_fill = '1') then
                           beat     <= unsigned(r_addr(4 downto 3)) & '0';
                           fill_cnt <= (others => '0');
                           state    <= FILL_BEAT;
                        else
                           -- maintenance clean: optionally invalidate too
                           if (op_invalidate_after = '1') then
                              dvalid(wb_line) <= '0';
                           end if;
                           state <= OP_FINISH;
                        end if;
                     else
                        beat  <= beat + 1;
                        state <= WB_BEAT;
                     end if;
                  end if;

               -- beat is always EVEN here: the fill walks 0,2,4,6 and each
               -- request brings back that word and the one above it.
               when FILL_BEAT =>
                  mem_ena  <= '1';
                  mem_pair <= '1';
                  mem_rnw  <= '1';
                  mem_addr <= r_addr(21 downto 5) & std_logic_vector(beat);
                  mem_be   <= "1111";
                  state    <= FILL_WAIT;

               when FILL_WAIT =>
                  if (mem_done = '1') then
                     -- the low word lands in the way BRAM via port B (see the
                     -- id_we/dd_we processes); only the bookkeeping is here.
                     -- Critical-word-first means this match, when it happens,
                     -- happens on the FIRST pair - so the CPU is released after
                     -- one round trip and the other three overlap its work.
                     -- Safe because nothing is served from the line until the
                     -- fill writes its tag: a request the CPU issues in the gap
                     -- is caught by req_pending and replayed against a complete,
                     -- valid line, so it cannot hit a half-filled one.
                     if (beat = to_integer(unsigned(r_addr(4 downto 2)))) then
                        resp_rdata <= mem_rdata;
                        resp_done  <= '1';
                     end if;
                     -- one extra cycle to push the high word through the same
                     -- single write port, rather than widening the way BRAMs
                     state <= FILL_HI;
                  end if;

               when FILL_HI =>
                  if (beat + 1 = unsigned(r_addr(4 downto 2))) then
                     resp_rdata <= mem_rdata_hi;
                     resp_done  <= '1';
                  end if;
                  if (fill_cnt = 3) then
                     if (r_code = '1') then
                        iset := to_integer(unsigned(r_addr(10 downto 5)));
                        ivalid(fill_way*64 + iset) <= '1';
                        irr(iset) <= irr(iset) + 1;
                     else
                        dset := to_integer(unsigned(r_addr(9 downto 5)));
                        dvalid(fill_way*32 + dset) <= '1';
                        ddirty(fill_way*32 + dset) <= '0';
                        drr(dset) <= drr(dset) + 1;
                     end if;
                     -- The response already went out with the critical word,
                     -- so the line simply completes and the cache frees itself.
                     -- IDLE replays whatever req_pending caught meanwhile; the
                     -- tag and valid bit are set in this same cycle, so that
                     -- replay hits the line rather than allocating it twice.
                     state <= IDLE;
                  else
                     -- 3-bit beat wraps 6 -> 0, which is the wrap fetch
                     beat     <= beat + 2;
                     fill_cnt <= fill_cnt + 1;
                     state    <= FILL_BEAT;
                  end if;

               when OP_FINISH =>
                  op_active <= '0';
                  state     <= IDLE;

            end case;
         end if;
      end if;
   end process;

end architecture;
