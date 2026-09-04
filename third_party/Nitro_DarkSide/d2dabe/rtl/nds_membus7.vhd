-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- ARM7 memory bus decoder (the NDS equivalent of the GBA memorymux for the
-- ARM7 side). Single master (no DMA yet), decodes the ARM7 address map:
--
--   0x00000000  BIOS (16 KB, read-only; backing store external)
--   0x02000000  main RAM, 4 MB mirrored through the 16 MB window (nds_mainram)
--   0x03000000  shared WRAM (nds_wram arm7 port); falls back to the ARM7-
--               private WRAM when WRAMCNT maps nothing to us (hardware mirror)
--   0x03800000  ARM7-private WRAM (64 KB, mirrored; backing store external)
--   0x04000000  IO registers via proc_bus (timers/IRQ/IPC/... OR-reduced
--               wired_out, combinational done — same idiom as GBA memorymux)
--   0x06000000  VRAM C/D as ARM7 WRAM (nds_vram cpu7 port)
--   everything else: open bus (CPU's lastread fed back)
--
-- Read rotation and write lane placement replicate gba_mem_readrotate /
-- gba_mem_writerotate: the CPU emits raw low-lane data and consumes the
-- rotated dword (it only extends from the low lane). done is always
-- registered, earliest one cycle after ena, with read data valid on the done
-- cycle. Block-transfer bus_lowbits are accepted but, like the GBA mux,
-- unused for lane math (LDM/STM are word accesses).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_membus7 is
   port
   (
      clk            : in  std_logic;
      reset          : in  std_logic;

      -- gba_cpu side
      cpu_adr        : in  std_logic_vector(31 downto 0);
      cpu_rnw        : in  std_logic;
      cpu_ena        : in  std_logic;
      cpu_acc        : in  std_logic_vector(1 downto 0);
      cpu_dout       : in  std_logic_vector(31 downto 0);
      cpu_lowbits    : in  std_logic_vector(1 downto 0);
      cpu_lastread   : in  std_logic_vector(31 downto 0);
      cpu_din        : out std_logic_vector(31 downto 0);
      cpu_done       : out std_logic;

      -- BIOS store: address registered here, data expected combinational
      bios_addr      : out unsigned(13 downto 2) := (others => '0');
      bios_data      : in  std_logic_vector(31 downto 0);

      -- ARM7-private WRAM store: sync-read BRAM. Address/write presented
      -- combinationally in the accept cycle; the store registers the address
      -- (read data valid in the FINISH cycle, same bus timing as the old
      -- registered-address/asynchronous-read pair) and captures writes at
      -- the accept edge.
      w7p_addr       : out unsigned(15 downto 2);
      w7p_we         : out std_logic;
      w7p_be         : out std_logic_vector(3 downto 0);
      w7p_writedata  : out std_logic_vector(31 downto 0);
      w7p_readdata   : in  std_logic_vector(31 downto 0);

      -- shared WRAM (nds_wram arm7 port)
      wsh_ena        : out std_logic := '0';
      wsh_rnw        : out std_logic := '1';
      wsh_addr       : out unsigned(14 downto 2) := (others => '0');
      wsh_be         : out std_logic_vector(3 downto 0) := (others => '0');
      wsh_din        : out std_logic_vector(31 downto 0) := (others => '0');
      wsh_dout       : in  std_logic_vector(31 downto 0);
      wsh_done       : in  std_logic;
      wsh_mapped     : in  std_logic;

      -- VRAM (nds_vram cpu7 port)
      vram_ena       : out std_logic := '0';
      vram_rnw       : out std_logic := '1';
      vram_addr      : out unsigned(23 downto 2) := (others => '0');
      vram_be        : out std_logic_vector(3 downto 0) := (others => '0');
      vram_din       : out std_logic_vector(31 downto 0) := (others => '0');
      vram_dout      : in  std_logic_vector(31 downto 0);
      vram_done      : in  std_logic;

      -- main RAM (nds_mainram mem7 port)
      mr_ena         : out std_logic := '0';
      mr_rnw         : out std_logic := '1';
      mr_addr        : out std_logic_vector(21 downto 2) := (others => '0');
      mr_be          : out std_logic_vector(3 downto 0) := (others => '0');
      mr_writedata   : out std_logic_vector(31 downto 0) := (others => '0');
      mr_done        : in  std_logic;
      mr_readdata    : in  std_logic_vector(31 downto 0);

      -- IO register bus (wired_out/-done OR-reduced over all banks outside).
      -- io_ce_next: the ce-gated peripherals' enable in the NEXT cycle; the
      -- 1-cycle io_bus.ena pulse is only issued when it will land on an
      -- active peripheral cycle. Tie to '1' at full rate.
      io_ce_next     : in  std_logic := '1';
      io_bus         : out proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
      io_wired_out   : in  std_logic_vector(31 downto 0);
      io_wired_done  : in  std_logic
   );
end entity;

architecture arch of nds_membus7 is

   type t_target is (T_BIOS, T_MAIN, T_WRAMSH, T_WRAM7, T_IO, T_VRAM, T_WIFI, T_OPEN);
   type t_state  is (IDLE, FINISH, W_WRAMSH, W_VRAM, W_MAIN, W_IO_ALIGN);

   signal state    : t_state  := IDLE;
   signal target   : t_target := T_OPEN;
   signal r_acc    : std_logic_vector(1 downto 0) := "10";
   signal r_low    : std_logic_vector(1 downto 0) := "00";

   signal dec_target : t_target;
   signal wdata      : std_logic_vector(31 downto 0);
   signal be         : std_logic_vector(3 downto 0);

   signal accept_now : std_logic;
   signal w7p_sel    : std_logic;

   signal din_unrot  : std_logic_vector(31 downto 0);

   -- Wifi I/O register file (0x04800000/0x04808000 mirrors, byte offsets
   -- 0x000-0x3FE). This range fell all the way through to T_OPEN before --
   -- see the header comment -- open bus, i.e. cpu_lastread, genuinely
   -- non-deterministic stale data, on both read and write (a write to T_OPEN
   -- is simply discarded; see the T_OPEN case below).
   --
   -- Confirmed root cause of Pokemon SoulSilver/HeartGold's Continue-path
   -- "a communication error has occurred": disassembled the real ARM7 driver
   -- code from a melonDS oracle's VRAM (it runs from a VRAM bank borrowed as
   -- ARM7 WRAM, per this file's own header comment on the 0x06000000 target).
   -- It runs a write-then-read self-test across ~25 of these registers, then
   -- writes W_PowerForce (0x040) requesting the radio powered off and polls
   -- W_PowerState (0x03C)/W_RFStatus (0x214) for confirmation, with NO
   -- bounded timeout on that final wait. Open bus can satisfy neither
   -- deterministically -- the self-test needs what it wrote to read back,
   -- and nothing will ever autonomously produce the PowerState/RFStatus
   -- values the unbounded wait needs. Verified against melonDS's own
   -- Wifi.cpp: the driver reaches the real success screen (save loaded,
   -- overworld, menu functional) in the oracle with exactly persistent
   -- storage plus this one side effect, and does not with any weaker model
   -- (a fixed fallback value, or storage without the side effect, both
   -- still fail, the latter as a genuine unbounded hang -- see
   -- HANDOFF_20260903_soulsilver_comm_error.md section 9 for the full
   -- verification trail before trusting this).
   -- Indexed by cpu_adr(9 downto 1) -- 512 halfwords, byte offsets
   -- 0x000-0x3FE. melonDS's own Wifi::Read/Write mask the incoming address
   -- with 0x7FFE before dispatch, which is what makes 0x04800xxx and
   -- 0x04808xxx the same register; indexing by bits (9 downto 1) alone
   -- (ignoring bit 15 and everything above it, which the decode process
   -- below has already reduced to "this is the wifi range") reproduces that
   -- same mirroring for free.
   -- W_PowerState (0x03C) and W_RFStatus (0x214) are held as individual
   -- registers rather than array entries. The PowerForce side effect below
   -- updates both of them in the same cycle as an unrelated array write, and
   -- a memory with three write ports in one cycle cannot infer into an M10K --
   -- it lands in fabric as ~8k flops plus a 512-way mux and decoder, which
   -- overruns this device by ~680 LABs (measured: 4873 required vs 4191
   -- available). Splitting them out leaves the array with a single write port
   -- and a registered read, so it infers as block RAM and costs no logic.
   type t_wifi_regs is array (0 to 511) of std_logic_vector(15 downto 0);
   signal wifi_regs : t_wifi_regs := (others => (others => '0'));
   signal wifi_rdata : std_logic_vector(15 downto 0) := (others => '0');
   signal wifi_powerstate : std_logic_vector(15 downto 0) := (others => '0');
   signal wifi_rfstatus   : std_logic_vector(15 downto 0) := (others => '0');
   signal wifi_sel_ps : std_logic := '0';
   signal wifi_sel_rf : std_logic := '0';
   signal wifi_wdata16 : std_logic_vector(15 downto 0);
   signal wifi_dout : std_logic_vector(15 downto 0);
   signal wifi_idx  : natural range 0 to 511;
   signal wifi_sel  : std_logic;
   signal wifi_we   : std_logic;

   constant WIFI_IDX_POWERSTATE : natural := 16#03C# / 2;   -- 30
   constant WIFI_IDX_POWERFORCE : natural := 16#040# / 2;   -- 32
   constant WIFI_IDX_RFSTATUS   : natural := 16#214# / 2;   -- 266
   constant WIFI_IDX_BBCNT      : natural := 16#158# / 2;   -- 172
   constant WIFI_IDX_BBWRITE    : natural := 16#15A# / 2;   -- 173
   constant WIFI_IDX_BBREAD     : natural := 16#15C# / 2;   -- 174
   constant WIFI_IDX_BBBUSY     : natural := 16#15E# / 2;   -- 175
   constant WIFI_IDX_RFBUSY     : natural := 16#180# / 2;   -- 192

   -- Baseband register file (melonDS Wifi.cpp: BBRegs[0x100]).  The wifi
   -- driver does not address the baseband directly: it writes an index and a
   -- direction code into W_BBCnt (0x158), and the chip answers on W_BBRead
   -- (0x15C).  Serving 0x15C out of the flat wifi array -- which is what this
   -- file did before -- returns whatever the driver last wrote to 0x15C
   -- itself, i.e. zero, so BB register 0x00 reads back 0x00 instead of the
   -- baseband chip ID 0x6D.  Pokemon SoulSilver's wireless init treats that
   -- as a dead transceiver and aborts the CONTINUE path with "A communication
   -- error has occurred" (see HANDOFF section 13).
   --
   -- Every register melonDS marks BBRegsRO is a fixed constant, so the RAM
   -- only has to hold the writable ones and the constants come out of a mux
   -- on the read path.  That keeps this independent of whether Quartus
   -- honours a VHDL initial value for an inferred M10K.
   -- 8 KiB wifi RAM (melonDS Wifi::RAM[0x2000], reached at byte offsets
   -- 0x4000-0x5FFF via RAM[addr & 0x1FFE]).  This is what the failure was:
   -- the region was not decoded at all, so the driver's power-on memory test
   -- read back open bus.  That test is a three-pass walk over all 4096
   -- halfwords -- 0x5A5A everywhere, then 0xA5A5, then a UNIQUE per-address
   -- value (0xFFFF at 0x4000 counting down to 0xF000 at 0x5FFE, an
   -- address-aliasing check that only real per-address storage can pass).
   -- When it fails the driver declares the wireless hardware dead and Pokemon
   -- SoulSilver aborts the CONTINUE path with "A communication error has
   -- occurred" (HANDOFF section 14).
   type t_wifi_ram is array (0 to 4095) of std_logic_vector(15 downto 0);
   signal wifi_ram   : t_wifi_ram;
   signal wram_rdata : std_logic_vector(15 downto 0) := (others => '0');
   signal wram_idx   : natural range 0 to 4095 := 0;
   signal wram_we    : std_logic := '0';
   signal wifi_is_ram  : std_logic;
   signal wifi_is_ffff : std_logic;
   signal wifi_is_reg  : std_logic;
   signal wifi_sel_ram  : std_logic := '0';
   signal wifi_sel_ffff : std_logic := '0';
   signal wifi_sel_none : std_logic := '0';

   type t_bb_regs is array (0 to 255) of std_logic_vector(7 downto 0);
   signal bb_regs  : t_bb_regs := (others => (others => '0'));
   signal bb_rdata : std_logic_vector(7 downto 0) := (others => '0');
   signal bb_fixed : std_logic_vector(7 downto 0) := (others => '0');
   signal bb_is_ro : std_logic := '0';
   signal bb_ridx  : natural range 0 to 255 := 0;
   signal bb_widx  : natural range 0 to 255 := 0;
   signal bb_wdata : std_logic_vector(7 downto 0) := (others => '0');
   signal bb_we    : std_logic := '0';

   signal wifi_bbcnt   : std_logic_vector(15 downto 0) := (others => '0');
   signal wifi_bbwrite : std_logic_vector(15 downto 0) := (others => '0');
   signal wifi_sel_bbcnt : std_logic := '0';
   signal wifi_sel_bbwr  : std_logic := '0';
   signal wifi_sel_bbrd  : std_logic := '0';
   signal wifi_sel_zero  : std_logic := '0';
   signal bb_read_val : std_logic_vector(15 downto 0);

   -- melonDS BBREG_FIXED table.  Only three entries are non-zero; the rest of
   -- the read-only ids answer 0x00.
   function bb_ro_value(idx : natural) return std_logic_vector is
   begin
      case idx is
         when 16#00# => return x"6D";   -- baseband chip ID
         when 16#5D# => return x"01";
         when 16#64# => return x"FF";
         when others => return x"00";
      end case;
   end function;

   function bb_is_readonly(idx : natural) return std_logic is
   begin
      if (idx = 16#00#) or
         (idx >= 16#0D# and idx <= 16#12#) or
         (idx >= 16#16# and idx <= 16#1A#) or
         (idx = 16#27#) or (idx = 16#4D#) or
         (idx >= 16#5D# and idx <= 16#61#) or
         (idx = 16#64#) or (idx = 16#66#) or
         (idx >= 16#69#) then
         return '1';
      else
         return '0';
      end if;
   end function;

begin

   -- wdata is already rotated so a 16-bit access sits in the upper or lower
   -- half depending on cpu_adr(1) (see the write-lane placement process);
   -- select the matching half once here rather than at every use.
   wifi_wdata16 <= wdata(31 downto 16) when cpu_adr(1) = '1'
                   else wdata(15 downto 0);

   -- melonDS returns BBRegs[W_BBCnt & 0xFF] only when the direction nibble of
   -- W_BBCnt says "read" (0x6000); any other code reads back 0.
   bb_read_val <= x"00" & bb_fixed when (bb_is_ro = '1' and
                                         wifi_bbcnt(15 downto 12) = x"6") else
                  x"00" & bb_rdata when wifi_bbcnt(15 downto 12) = x"6" else
                  (others => '0');

   wifi_dout <= wram_rdata     when wifi_sel_ram = '1' else
                x"FFFF"        when wifi_sel_ffff = '1' else
                x"0000"        when wifi_sel_none = '1' else
                wifi_powerstate when wifi_sel_ps = '1' else
                wifi_rfstatus   when wifi_sel_rf = '1' else
                wifi_bbcnt      when wifi_sel_bbcnt = '1' else
                wifi_bbwrite    when wifi_sel_bbwr = '1' else
                bb_read_val     when wifi_sel_bbrd = '1' else
                x"0000"         when wifi_sel_zero = '1' else
                wifi_rdata;

   -- Same shape as the ARM7-private WRAM store drive above: the select and
   -- address are combinational in the accept cycle, and the storage itself is
   -- a plain synchronous-read/synchronous-write block below.
   wifi_idx <= to_integer(unsigned(cpu_adr(9 downto 1)));
   wifi_sel <= '1' when (accept_now = '1' and cpu_ena = '1' and
                         dec_target = T_WIFI) else '0';
   wifi_we  <= '1' when (wifi_sel = '1' and cpu_rnw = '0' and
                         wifi_is_reg = '1' and
                         wifi_idx /= WIFI_IDX_POWERSTATE and
                         wifi_idx /= WIFI_IDX_RFSTATUS and
                         wifi_idx /= WIFI_IDX_BBCNT and
                         wifi_idx /= WIFI_IDX_BBWRITE) else '0';

   -- Simple dual-port inference: one write address, one read address, one
   -- unconditional registered read -- same template as wifi_store above.
   -- The read index tracks W_BBCnt, which the driver always writes in an
   -- earlier transfer than the W_BBRead that consumes it, so bb_rdata is
   -- settled by the time it is muxed out.
   -- melonDS masks the incoming address with 0x7FFE, so bit 15 and above are
   -- the mirror and bits 14..1 are the halfword index inside the 32 KiB wifi
   -- window.  Region split is melonDS's: 0x4000-0x5FFF is RAM, 0x2000-0x3FFF
   -- reads all-ones, below 0x0400 is the register file, everything else 0.
   wifi_is_ram  <= '1' when (cpu_adr(14) = '1' and cpu_adr(13) = '0') else '0';
   wifi_is_ffff <= '1' when (cpu_adr(14) = '0' and cpu_adr(13) = '1') else '0';
   wifi_is_reg  <= '1' when (unsigned(cpu_adr(14 downto 10)) = 0) else '0';

   wram_idx <= to_integer(unsigned(cpu_adr(12 downto 1)));
   wram_we  <= '1' when (wifi_sel = '1' and cpu_rnw = '0' and
                         wifi_is_ram = '1') else '0';

   wifi_ram_store : process (clk)
   begin
      if rising_edge(clk) then
         if wram_we = '1' then
            wifi_ram(wram_idx) <= wifi_wdata16;
         end if;
         wram_rdata <= wifi_ram(wram_idx);
      end if;
   end process;

   bb_ridx  <= to_integer(unsigned(wifi_bbcnt(7 downto 0)));

   bb_store : process (clk)
   begin
      if rising_edge(clk) then
         if bb_we = '1' then
            bb_regs(bb_widx) <= bb_wdata;
         end if;
         bb_rdata <= bb_regs(bb_ridx);
         bb_fixed <= bb_ro_value(bb_ridx);
         bb_is_ro <= bb_is_readonly(bb_ridx);
      end if;
   end process;

   -- Kept deliberately as the bare textbook inference template -- one
   -- unconditional registered read, one guarded write, nothing else in the
   -- process. Folding the read into the request FSM's case branch instead
   -- makes Quartus report "uninferred due to asynchronous read logic" and
   -- drop the whole 512x16 array into fabric, which costs ~680 LABs more
   -- than this device has (measured).
   wifi_store : process (clk)
   begin
      if rising_edge(clk) then
         if wifi_we = '1' then
            wifi_regs(wifi_idx) <= wifi_wdata16;
         end if;
         wifi_rdata <= wifi_regs(wifi_idx);
      end if;
   end process;

   -- BIOS is now a synchronous hot-loadable RAM in hardware. Present the
   -- request address during the accept cycle so its registered data is ready
   -- in FINISH, matching the TCM/WRAM store timing below.
   bios_addr <= unsigned(cpu_adr(13 downto 2));

   -- ================= request accept (combinational mirror of can_accept) =================
   accept_now <= '1' when reset = '0' and
                          (state = IDLE or state = FINISH or
                           (state = W_WRAMSH and wsh_done  = '1') or
                           (state = W_VRAM   and vram_done = '1') or
                           (state = W_MAIN   and mr_done   = '1')) else '0';

   -- ================= ARM7-private WRAM store drive =================
   -- Presented in the accept cycle so the BRAM's internal address register
   -- takes the role of the old registered w7p_addr: read data is valid in
   -- the FINISH cycle, writes land at the accept edge (one cycle earlier
   -- than the old external write process - unobservable, the next request
   -- is accepted no earlier than the FINISH edge).
   w7p_sel       <= '1' when (accept_now = '1' and cpu_ena = '1' and dec_target = T_WRAM7) else '0';
   w7p_addr      <= unsigned(cpu_adr(15 downto 2));
   w7p_we        <= w7p_sel and not cpu_rnw;
   w7p_be        <= be;
   w7p_writedata <= wdata;

   -- ================= decode (combinational, sampled at ena) =================
   process (all)
   begin
      dec_target <= T_OPEN;
      if (cpu_adr(31 downto 28) = x"0") then
         case cpu_adr(27 downto 24) is
            when x"0" =>
               if (unsigned(cpu_adr(23 downto 14)) = 0) then
                  dec_target <= T_BIOS;
               end if;
            when x"2" => dec_target <= T_MAIN;
            when x"3" =>
               if (cpu_adr(23) = '1' or wsh_mapped = '0') then
                  dec_target <= T_WRAM7;
               else
                  dec_target <= T_WRAMSH;
               end if;
            when x"4" =>
               if (cpu_adr(23) = '0') then
                  dec_target <= T_IO;      -- includes IPCFIFORECV at +0x100000
               -- bit 15 is left free: it is the 0x04800xxx/0x04808xxx mirror
               -- (matches melonDS's own `addr &= 0x7FFE` masking), not part
               -- of the range check.
               elsif (unsigned(cpu_adr(22 downto 16)) = 0) then
                  -- Whole 32 KiB wifi window, not just the register page:
                  -- 0x4000-0x5FFF is the 8 KiB wifi RAM the driver memory-
                  -- tests at power-on. Bit 15 is the 0x04808xxx mirror and is
                  -- deliberately excluded from the index, matching melonDS's
                  -- `addr &= 0x7FFE`.
                  dec_target <= T_WIFI;    -- 0x0480{0,8}000-0x0480{0,8}FFFE
               end if;
            when x"6" => dec_target <= T_VRAM;
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
   -- The CPU asserts the next ena in the same cycle it samples done, so a
   -- request must be accepted on every completing cycle (FINISH / W_* with
   -- done high), not just in IDLE — the GBA memorymux behaves the same way.
   process (clk)
      variable can_accept : boolean;
   begin
      if rising_edge(clk) then

         wsh_ena  <= '0';
         vram_ena <= '0';
         mr_ena   <= '0';
         io_bus.ena <= '0';
         io_bus.rst <= reset;
         -- Single-cycle strobe: the baseband commit below is the only thing
         -- that raises it, and it must not persist into the next cycle or the
         -- write would repeat for as long as the FSM stays out of T_WIFI.
         bb_we    <= '0';

         if (reset = '1') then
            state <= IDLE;
         else
            can_accept := (accept_now = '1');

            if (state = W_IO_ALIGN) then
               if (io_ce_next = '1') then
                  io_bus.ena <= '1';
                  state      <= FINISH;
               end if;
            elsif can_accept then
               state <= IDLE;
               if (cpu_ena = '1') then
                  target <= dec_target;
                  r_acc  <= cpu_acc;
                  r_low  <= cpu_adr(1 downto 0);

                  case dec_target is

                     when T_BIOS =>
                        state     <= FINISH;   -- writes fall through as no-ops

                     when T_WRAM7 =>
                        state <= FINISH;   -- store drive is combinational above

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

                     when T_MAIN =>
                        mr_ena       <= '1';
                        mr_rnw       <= cpu_rnw;
                        mr_addr      <= cpu_adr(21 downto 2);
                        mr_be        <= be;
                        mr_writedata <= wdata;
                        state        <= W_MAIN;

                     when T_IO =>
                        io_bus.rnw  <= cpu_rnw;
                        io_bus.Adr  <= x"0" & cpu_adr(23 downto 2) & "00";
                        io_bus.acc  <= cpu_acc;
                        io_bus.Din  <= wdata;
                        io_bus.bEna <= be;
                        if (io_ce_next = '1') then
                           io_bus.ena <= '1';
                           state      <= FINISH;
                        else
                           state <= W_IO_ALIGN;
                        end if;

                     when T_WIFI =>
                        -- The array read/write lives in the wifi_store
                        -- process above (block-RAM inference template); only
                        -- the two individually-registered specials and the
                        -- read-mux selects are handled here.
                        -- Region selects, registered alongside the
                        -- per-register ones so they line up with the
                        -- block-RAM read latency.
                        wifi_sel_ram  <= wifi_is_ram;
                        wifi_sel_ffff <= wifi_is_ffff;
                        if (wifi_is_ram = '0' and wifi_is_ffff = '0' and
                            wifi_is_reg = '0') then
                           wifi_sel_none <= '1';
                        else
                           wifi_sel_none <= '0';
                        end if;

                        if (wifi_idx = WIFI_IDX_POWERSTATE and wifi_is_reg = '1') then
                           wifi_sel_ps <= '1';
                        else
                           wifi_sel_ps <= '0';
                        end if;
                        if (wifi_idx = WIFI_IDX_RFSTATUS and wifi_is_reg = '1') then
                           wifi_sel_rf <= '1';
                        else
                           wifi_sel_rf <= '0';
                        end if;

                        -- W_BBCnt / W_BBWrite are held as individual
                        -- registers (the BB logic needs W_BBCnt
                        -- combinationally to index the baseband file, which a
                        -- block-RAM read cannot provide in the same cycle).
                        if (wifi_idx = WIFI_IDX_BBCNT and wifi_is_reg = '1') then
                           wifi_sel_bbcnt <= '1';
                        else
                           wifi_sel_bbcnt <= '0';
                        end if;
                        if (wifi_idx = WIFI_IDX_BBWRITE and wifi_is_reg = '1') then
                           wifi_sel_bbwr <= '1';
                        else
                           wifi_sel_bbwr <= '0';
                        end if;
                        if (wifi_idx = WIFI_IDX_BBREAD and wifi_is_reg = '1') then
                           wifi_sel_bbrd <= '1';
                        else
                           wifi_sel_bbrd <= '0';
                        end if;
                        -- W_BBBusy (0x15E) and W_RFBusy (0x180) are the two
                        -- ports the driver spins on; melonDS hardcodes both to
                        -- 0 ("never busy"), and the driver's polls only
                        -- terminate on that.
                        if (wifi_is_reg = '1' and
                            (wifi_idx = WIFI_IDX_BBBUSY or
                             wifi_idx = WIFI_IDX_RFBUSY)) then
                           wifi_sel_zero <= '1';
                        else
                           wifi_sel_zero <= '0';
                        end if;

                        if (cpu_rnw = '0') then
                           -- Only 16-bit accesses are modelled: these
                           -- registers are 16-bit and the driver uses
                           -- ldrh/strh throughout (disassembled).
                           if (wifi_is_reg = '0') then
                              null;   -- RAM / mirror region: no side effects
                           elsif (wifi_idx = WIFI_IDX_POWERSTATE) then
                              wifi_powerstate <= wifi_wdata16;
                           elsif (wifi_idx = WIFI_IDX_RFSTATUS) then
                              wifi_rfstatus <= wifi_wdata16;
                           elsif (wifi_idx = WIFI_IDX_BBCNT) then
                              wifi_bbcnt <= wifi_wdata16;
                           elsif (wifi_idx = WIFI_IDX_BBWRITE) then
                              wifi_bbwrite <= wifi_wdata16;
                           end if;

                           -- melonDS Wifi.cpp, case W_BBCnt: a write whose
                           -- direction nibble is 0x5000 commits W_BBWrite's
                           -- low byte into the addressed baseband register,
                           -- unless that register is read-only.
                           -- No read-only test on the write side: evaluating
                           -- bb_is_readonly() here costs a full 256-way
                           -- decoder on wifi_wdata16, and it is redundant --
                           -- the read mux already answers every read-only id
                           -- from bb_ro_value() and never from the array, so
                           -- letting a stray write land in an unread array
                           -- slot is unobservable. (Worth 5 LABs: the first
                           -- fit of this change missed by exactly that.)
                           if (wifi_is_reg = '1' and
                               wifi_idx = WIFI_IDX_BBCNT and
                               wifi_wdata16(15 downto 12) = x"5") then
                              bb_we    <= '1';
                              bb_widx  <=
                                 to_integer(unsigned(wifi_wdata16(7 downto 0)));
                              bb_wdata <= wifi_bbwrite(7 downto 0);
                           end if;

                           -- W_PowerForce (0x040): melonDS's own write handler
                           -- (Wifi.cpp, case W_PowerForce) masks to 0x8001 and,
                           -- for exactly this "force the radio off, not
                           -- currently transmitting" pattern, synchronously
                           -- sets W_PowerState bits[9:8] to "10" and
                           -- W_RFStatus to 9 -- the two values the driver's
                           -- unbounded wait polls for. No other PowerForce
                           -- pattern is exercised by this driver, so no
                           -- broader power/RF sequencing is implemented.
                           if (wifi_is_reg = '1' and
                               wifi_idx = WIFI_IDX_POWERFORCE and
                               wifi_wdata16(15) = '1' and
                               wifi_wdata16(0) = '1') then
                              wifi_powerstate <=
                                 (wifi_powerstate and not x"0301") or x"0200";
                              wifi_rfstatus <= x"0009";
                           end if;
                        end if;
                        state <= FINISH;

                     when T_OPEN =>
                        state <= FINISH;

                  end case;
               end if;
            end if;
         end if;
      end if;
   end process;

   cpu_done <= '1'       when state = FINISH  else
               wsh_done  when state = W_WRAMSH else
               vram_done when state = W_VRAM   else
               mr_done   when state = W_MAIN   else '0';

   -- ================= read data mux + rotation (gba_mem_readrotate) =================
   din_unrot <= bios_data     when target = T_BIOS   else
                w7p_readdata  when target = T_WRAM7  else
                -- Replicated into both halves: this file's downstream read
                -- rotation extracts whichever 16-bit lane the original
                -- address selected (see r_low/r_acc), and duplicating avoids
                -- having to reproduce that selection here a second time.
                wifi_dout & wifi_dout when target = T_WIFI else
                wsh_dout      when target = T_WRAMSH else
                vram_dout     when target = T_VRAM   else
                mr_readdata   when target = T_MAIN   else
                io_wired_out  when (target = T_IO and io_wired_done = '1') else
                x"00000000"   when target = T_IO else -- unclaimed NDS7 IO reads 0 (not GBA open bus): calico probes SCFG for NTR/TWL detection
                cpu_lastread;  -- open bus for unmapped regions

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
