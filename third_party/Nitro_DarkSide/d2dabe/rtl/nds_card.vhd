-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS game-card slot (M8 part 1): AUXSPICNT/ROMCTRL register block, retail
-- read commands served from the staged card image, transfer-complete IRQ and
-- the per-word card DMA trigger. Behavior and timing follow melonDS 1.1
-- (NDSCart.cpp, the M7-established oracle); DualSOUP's measured pacing
-- refines this later if the frame diff demands it.
--
--   0x040001A0  AUXSPICNT  [15] slot enable, [14] transfer-IRQ enable,
--                          [13] SPI mode (blocks ROM transfers when set)
--   0x040001A2  AUXSPIDATA (backup SPI: 8 KB EEPROM state machine, melonDS
--               SRAMWrite_EEPROM semantics - RDSR/WRSR/READ/WRITE/WREN/WRDI,
--               9F answers FF; fresh save = FF fill; size/type per-cart and
--               save persistence come later with HPS integration)
--   0x040001A4  ROMCTRL    [12:0] gap1, [21:16] gap2, [23] word ready (RO),
--                          [26:24] block size, [27] clock divider,
--                          [30] write dir, [31] busy (write 1 starts)
--   0x040001A8+ 8 command bytes (byte-writable, big-endian order on the bus)
--   0x040001B0+ KEY2 seeds (write-only stubs)
--   0x04100010  read data port (pop: advances the transfer)
--
-- Commands implemented, by CmdEncMode. Direct boot hands the cart over already
-- in main data mode, so it only ever issues the last two; a firmware boot walks
-- the whole sequence from power-up (measured with sim/melonds_tracer --fw):
--
--   mode 0, raw:   9F dummy (FF fill), 00 header read from image byte 0,
--                  90 chip ID, 3C activate KEY1 -> mode 1
--   mode 1, KEY1:  command bytes are Blowfish-encrypted with a key schedule
--                  that lives in the ARM7 BIOS and this model does NOT decrypt
--                  them. They are decoded by block size plus two bits of state
--                  instead. The sequence is ROM-DEPENDENT, so do not assume a
--                  fixed command count:
--                    retail, secure area present (e.g. Kirby):
--                      4x KEY2-data-mode (0 words), 1x chip ID (1 word), four
--                      2x secure-area blocks (1024 words each, at 0x6000,
--                      0x7000, 0x5000 then 0x4000 - OUT OF ORDER), Ax -> mode 2
--                    homebrew, no secure area (e.g. sim/tests/nds_2d*.nds):
--                      4x, then Ax -> mode 2. Nothing else at all.
--                  4x and Ax both carry no data, so they are told apart by
--                  key1_seen4 (which came first), NOT by whether a secure-area
--                  block was read - keying off sec_cnt leaves the homebrew case
--                  stuck in KEY1 mode forever.
--   mode 2, main:  B7 block read (contiguous from the image; reads below 0x8000
--                  redirect to 0x8000+(addr&0x1FF) like real carts protect the
--                  secure area), B8 chip ID.
--
-- Anything else returns FF. KEY2 is deliberately not implemented: it is applied
-- and removed in cart/console hardware and is transparent to software, which is
-- why melonDS ignores it too (NDSCart.cpp serves 2x blocks straight from ROM).
-- Chip ID is Macronix NTR MROM with the capacity byte derived from the staged
-- image's header: the chipid input comes straight from nds_loader's cart_id,
-- so B8 answers exactly what the direct-boot env block at 0x02FFF800 says.
-- NitroSDK re-reads it from CARDi_CheckPulledOut, so the two must not differ.
--
-- Timing (33.514 MHz clk1x = melonDS system-cycle rate, applied 1:1):
-- 8-bit parallel bus, xfercycle = 8 cycles/byte (ROMCTRL[27]) or 5;
-- command = 8 bytes (+gap1, +gap2 when data follows, only while WR clear);
-- first word ready xfercycle*(cmd+4) after start, successive words
-- xfercycle*4 (+gap2 at each 512-byte boundary) after each pop.
--
-- Two things make a transfer take longer than that pacing says, and both are
-- ours, not the cart's:
--
--   1. The image word comes from DDR3 (NDS.sv CARD PAGER -> ddram ch2), and
--      the fetch used to be issued only AFTER the pacing delay expired, so
--      every word cost pacing + a full DDR3 round trip. melonDS charges zero
--      for that read - the ROM is a buffer in host RAM - so all of it was time
--      the hardware never spends. It is now a prefetch queue (pf_*, depth
--      CARDPREFETCH) that runs ahead of the cart bus, so the fetches happen
--      inside pacing delays that were going to be spent anyway. Depth matters
--      as much as the overlap: the same DDR3 port serves 128-beat framebuffer
--      bursts, and one word of run-ahead only covers one inter-word window
--      (20 cycles at default pacing) of that contention.
--   2. CARDSPEED_SHIFT divides the pacing itself by 2**n. This is deliberately
--      NOT hardware-faithful - it is here because a 4 KB ability-data read at
--      real cart speed is ~1 ms of DS time, and games that spin on ROMCTRL
--      rather than taking the IRQ pay all of it. Nothing can outrun the CPU:
--      word_ready holds until the data port is popped and FINISH needs every
--      word popped, so a shorter delay only removes idle waiting.
--
-- Slot ownership: EXMEMCNT[11] (card7 input). The non-owner reads the whole
-- block as zero and its writes are dropped; the DMA trigger and IRQ pulse go
-- to the owner (ARM7 trigger port exists for the future dma7 - unconnected
-- until then, ARM9 owns the slot in everything direct-booted so far).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_card is
   generic
   (
      -- Cart-bus pacing divider: the melonDS-faithful delay >> this. 0 keeps
      -- hardware timing exactly (~4 MB/s, what a retail NTR cart does), 2 is
      -- the shipped setting. See the Timing note in the header.
      CARDSPEED_SHIFT : integer := 0;
      -- Image words fetched ahead of the cart bus. 1 = the old behaviour with
      -- the fetch merely moved off the critical path. Max 7: the queue depth is
      -- reported in the 3-bit dbg_card field.
      CARDPREFETCH    : integer := 4
   );
   port
   (
      clk          : in  std_logic;
      ce           : in  std_logic;
      reset        : in  std_logic;

      card7        : in  std_logic;    -- EXMEMCNT[11]: '1' = ARM7 owns the slot

      -- '1' = firmware boot: the cart powers up in raw command mode and the
      -- ARM7 BIOS walks it through 3C/KEY1 into main data mode itself. Direct
      -- boot instead hands over with the cart already in main data mode, so it
      -- must power up there or B7 is answered as an unknown raw command.
      fw_boot      : in  std_logic := '0';

      chipid       : in  std_logic_vector(31 downto 0);  -- nds_loader cart_id, B8 answer

      bus9         : in  proc_bus_gb_type;
      wired_out9   : out std_logic_vector(31 downto 0);
      wired_done9  : out std_logic;

      bus7         : in  proc_bus_gb_type;
      wired_out7   : out std_logic_vector(31 downto 0);
      wired_done7  : out std_logic;

      irq9_xfer    : out std_logic := '0';   -- IRQ bit 19, one-cycle pulses
      irq7_xfer    : out std_logic := '0';

      -- Debug tap (nds_debug op 0x0D). This unit had NO visibility at all, which
      -- is why a game hang mid-card-transfer is indistinguishable from a healthy
      -- core through `probe`: every FSM it decodes sits in the ARM9 memory path,
      -- and a card stall never reaches there - the CPU just never gets told to
      -- continue. Behaviourally inert.
      dbg_card     : out std_logic_vector(31 downto 0) := (others => '0');
      dma9_card    : out std_logic := '0';   -- DMA start-mode 5 word-ready pulses
      dma7_card    : out std_logic := '0';

      -- Backup-memory port.  The byte-wide SPI side remains in this module,
      -- while the physical M10K lives at the product boundary so MiSTer's
      -- mounted .sav channel can use its second port without copying through
      -- the CPU or allocating another RAM.
      backup_addr         : out std_logic_vector(19 downto 0) := (others => '0');
      backup_write_data   : out std_logic_vector(7 downto 0) := (others => '0');
      backup_write_enable : out std_logic := '0';
      backup_read_data    : in  std_logic_vector(7 downto 0) := (others => '1');
      backup_write_toggle : out std_logic := '0';
      backup_save_type    : in  std_logic_vector(3 downto 0) := "0010";
      backup_access_active: out std_logic := '0';
      backup_cache_ready  : in  std_logic := '1';

      -- staged card image read port (shared with nds_loader, muxed in nds_top)
      card_ena     : out std_logic := '0';
      card_addr    : out std_logic_vector(26 downto 2) := (others => '0');
      card_din     : in  std_logic_vector(31 downto 0);
      card_done    : in  std_logic
   );
end entity;

architecture arch of nds_card is

   constant ADR_AUXSPI  : std_logic_vector(27 downto 0) := x"00001A0";
   constant ADR_ROMCTRL : std_logic_vector(27 downto 0) := x"00001A4";
   constant ADR_CMD0    : std_logic_vector(27 downto 0) := x"00001A8";
   constant ADR_CMD4    : std_logic_vector(27 downto 0) := x"00001AC";
   constant ADR_DATA    : std_logic_vector(27 downto 0) := x"0100010";

   signal spicnt     : std_logic_vector(15 downto 0) := (others => '0');
   signal romctrl    : std_logic_vector(31 downto 0) := (others => '0'); -- stored bits, 23/31 live below
   signal cmdbytes   : std_logic_vector(63 downto 0) := (others => '0'); -- cmd[0] in 63:56 (bus byte order)

   signal busy       : std_logic := '0';                 -- ROMCTRL[31]
   signal word_ready : std_logic := '0';                 -- ROMCTRL[23]
   signal romdata    : std_logic_vector(31 downto 0) := (others => '0');

   type tstate is
   (
      IDLE,
      CMDDELAY,    -- command bytes + gaps on the cart bus
      FETCH,       -- hand the word over (image prefetch, chip ID or FF fill)
      DATAREADY,   -- word_ready set, waiting for the data-port pop
      WORDDELAY,   -- inter-word cart-bus pacing
      FINISH       -- clear busy, raise IRQ
   );
   signal state      : tstate := IDLE;

   signal xferlen    : unsigned(12 downto 0) := (others => '0'); -- words, max 4096
   signal xferpos    : unsigned(12 downto 0) := (others => '0');
   signal delay_cnt  : unsigned(19 downto 0) := (others => '0');
   signal cmd_b7     : std_logic := '0';   -- serve words from the card image
   signal cmd_b8     : std_logic := '0';   -- serve the chip ID
   signal cmd_redir  : std_logic := '0';   -- apply the <0x8000 secure-area redirect
   signal b7_addr    : unsigned(31 downto 0) := (others => '0'); -- byte address of next word to FETCH

   -- Prefetch queue. The fetch engine runs ahead of the cart bus, one request
   -- in flight, and stops at the block end or a full queue; FETCH hands words
   -- out of it at the pace ROMCTRL dictates. Depth is the whole point: a single
   -- slot only covers one inter-word window (20 cycles at default pacing), and
   -- the DDR3 port next door serves 128-beat framebuffer bursts that block a
   -- card word for much longer than that. CARDPREFETCH words of run-ahead cover
   -- CARDPREFETCH windows of jitter.
   type t_pf is array (0 to CARDPREFETCH-1) of std_logic_vector(31 downto 0);
   signal pf         : t_pf := (others => (others => '0'));
   signal pf_wr      : integer range 0 to CARDPREFETCH-1 := 0;
   signal pf_rd      : integer range 0 to CARDPREFETCH-1 := 0;
   signal pf_cnt     : integer range 0 to CARDPREFETCH := 0;
   signal pf_inflt   : std_logic := '0';                          -- request outstanding
   signal pf_asked   : unsigned(12 downto 0) := (others => '0');  -- words requested so far

   -- The <0x8000 secure-area redirect, applied at every fetch issue point.
   function eff_addr(addr : unsigned(31 downto 0); redir : std_logic) return unsigned is
   begin
      -- Only B7 in main data mode gets it (redir). The raw header read and the
      -- KEY1 2x block reads must reach 0x0000 and 0x4000..0x7FFF for real, or a
      -- firmware boot gets the header and the secure area it is about to verify
      -- folded onto 0x8000.
      if (redir = '1' and addr < 16#8000#) then
         return to_unsigned(16#8000#, 32) + (addr and to_unsigned(16#1FF#, 32));
      end if;
      return addr;
   end function;

   -- Command-encryption mode, GBATEK's CmdEncMode: 0 = raw, 1 = KEY1, 2 = main
   -- (KEY2) data mode. Direct boot hands over with the cart already in mode 2,
   -- which is why only B7/B8 existed here; a firmware boot starts in mode 0 and
   -- walks the whole sequence, so fw_boot picks the power-up mode.
   signal cmd_mode   : unsigned(1 downto 0) := "10";
   -- Which secure-area block the next KEY1 2x command is for. In KEY1 mode the
   -- command bytes are Blowfish-encrypted with a key schedule that lives in the
   -- ARM7 BIOS, and this model cannot decrypt them - so KEY1 commands are
   -- decoded by their block SIZE plus this counter instead. That works only
   -- because the ARM7 BIOS issues one fixed sequence; the block addresses below
   -- are MEASURED from the melonDS oracle (sim/melonds_tracer --fw, KEY1DEC
   -- log), not assumed, because the BIOS reads them OUT OF ORDER:
   -- 0x6000, 0x7000, 0x5000, 0x4000. Assuming 0x4000 upward silently scrambles
   -- the secure area.
   signal sec_cnt    : unsigned(2 downto 0) := (others => '0');
   -- '1' once the KEY1 4x (KEY2-data-mode) command has been seen, so the next
   -- zero-length KEY1 command is recognised as Ax (enter main data mode).
   signal key1_seen4 : std_logic := '0';

   signal romctrl_rd : std_logic_vector(31 downto 0);
   signal own9, own7 : std_logic;

   -- registered request flags (bus pulses arrive with ce)
   signal pop_req    : std_logic;

   -- ================= AUXSPI cartridge backup =================
   -- Save types follow melonDS ROMList: 1=tiny EEPROM, 2..4=regular
   -- EEPROM/FRAM-compatible, 5..7=flash.  The physical memory is one 512-byte
   -- dual-clock cache.  backup_addr carries the complete masked chip address to
   -- the host bridge while its low nine bits select the cache M10K.  A sector
   -- miss holds AUXSPI busy until backup_cache_ready returns.
   signal sram_we_r   : std_logic := '0';
   signal sram_wa_r   : unsigned(19 downto 0) := (others => '0');
   signal sram_wd_r   : std_logic_vector(7 downto 0) := (others => '0');
   signal spi_data    : std_logic_vector(7 downto 0) := (others => '0');  -- AUXSPIDATA readback
   signal spi_hold    : std_logic := '0';
   signal spi_pos     : unsigned(15 downto 0) := (others => '0');
   signal spi_busy    : unsigned(9 downto 0) := (others => '0');          -- busy countdown, bit7 readback
   signal sram_cmd    : std_logic_vector(7 downto 0) := (others => '0');
   signal sram_addr   : unsigned(19 downto 0) := (others => '0');
   signal sram_status : std_logic_vector(7 downto 0) := (others => '0');  -- bit1 = WEL
   signal backup_access_r : std_logic := '0';
   signal erase_active    : std_logic := '0';
   signal erase_addr      : unsigned(19 downto 0) := (others => '0');
   signal erase_remaining : unsigned(16 downto 0) := (others => '0');
   signal auxspi_rd   : std_logic_vector(31 downto 0);
   signal spi_busy_bit : std_logic;

   function masked_save_addr(
      addr : unsigned(19 downto 0);
      kind : std_logic_vector(3 downto 0)) return unsigned is
      variable result : unsigned(19 downto 0) := addr;
   begin
      case to_integer(unsigned(kind)) is
         when 1      => result(19 downto 9)  := (others => '0');
         when 2      => result(19 downto 13) := (others => '0');
         when 3      => result(19 downto 16) := (others => '0');
         when 4      => result(19 downto 17) := (others => '0');
         when 5      => result(19 downto 18) := (others => '0');
         when 6      => result(19) := '0';
         when others => null; -- type 7 is the complete 20-bit address
      end case;
      return result;
   end function;

   function save_addr_bytes(kind : std_logic_vector(3 downto 0)) return integer is
   begin
      if (unsigned(kind) = 1) then
         return 1;
      elsif (unsigned(kind) = 2 or unsigned(kind) = 3) then
         return 2;
      else
         return 3;
      end if;
   end function;

begin

   backup_addr <= std_logic_vector(masked_save_addr(sram_wa_r, backup_save_type)) when
                     sram_we_r = '1' else
                  std_logic_vector(masked_save_addr(erase_addr, backup_save_type)) when
                     erase_active = '1' else
                  std_logic_vector(masked_save_addr(sram_addr, backup_save_type));
   backup_write_data <= sram_wd_r;
   backup_write_enable <= sram_we_r;
   backup_access_active <= backup_access_r or erase_active;

   own9 <= not card7;
   own7 <= card7;

   -- ================= combinational read data =================
   romctrl_rd <= busy & romctrl(30 downto 24) & word_ready & romctrl(22 downto 0);

   -- [31:29] state  [28] busy  [27] word_ready  [26] own9  [25] own7
   -- [24] spicnt(14) xfer-ready-IRQ enable   [23] pop_req
   -- [12:0] xferpos ... but xferlen matters as much, so pack both halves:
   -- [22:16] xferlen(6..0)   [15:13] prefetch queue depth   [12:0] xferpos
   --
   -- The queue depth is what separates the two ways a transfer stalls, which
   -- look identical from the CPU side: FETCH with depth 0 is the card waiting on
   -- DDR3 (we are starving it), DATAREADY is the card waiting on a pop that is
   -- not coming (the game is starving us).
   dbg_card <= std_logic_vector(to_unsigned(tstate'pos(state), 3))
               & busy & word_ready & own9 & own7 & spicnt(14) & pop_req
               & std_logic_vector(xferlen(6 downto 0))
               & std_logic_vector(to_unsigned(pf_cnt, 3))
               & std_logic_vector(xferpos);

   -- AUXSPICNT with the live SPI-busy bit, AUXSPIDATA in the upper half
   spi_busy_bit <= '1' when (spi_busy /= 0 or erase_active = '1' or
                              ((backup_access_r = '1') and
                               backup_cache_ready = '0')) else '0';
   auxspi_rd  <= x"00" & spi_data & spicnt(15 downto 8) &
                 spi_busy_bit & spicnt(6 downto 0);

   wired_out9 <= auxspi_rd                         when (own9 = '1' and bus9.Adr = ADR_AUXSPI)  else
                 romctrl_rd                        when (own9 = '1' and bus9.Adr = ADR_ROMCTRL) else
                 cmdbytes(39 downto 32) & cmdbytes(47 downto 40) & cmdbytes(55 downto 48) & cmdbytes(63 downto 56)
                                                   when (own9 = '1' and bus9.Adr = ADR_CMD0)    else
                 cmdbytes(7 downto 0) & cmdbytes(15 downto 8) & cmdbytes(23 downto 16) & cmdbytes(31 downto 24)
                                                   when (own9 = '1' and bus9.Adr = ADR_CMD4)    else
                 romdata                           when (own9 = '1' and bus9.Adr = ADR_DATA)    else
                 (others => '0');
   wired_done9 <= '1' when (bus9.Adr = ADR_AUXSPI or bus9.Adr = ADR_ROMCTRL or
                            bus9.Adr = ADR_CMD0 or bus9.Adr = ADR_CMD4 or
                            bus9.Adr(27 downto 4) = x"00001B" or bus9.Adr = ADR_DATA) else '0';

   wired_out7 <= auxspi_rd                         when (own7 = '1' and bus7.Adr = ADR_AUXSPI)  else
                 romctrl_rd                        when (own7 = '1' and bus7.Adr = ADR_ROMCTRL) else
                 romdata                           when (own7 = '1' and bus7.Adr = ADR_DATA)    else
                 (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_AUXSPI or bus7.Adr = ADR_ROMCTRL or
                            bus7.Adr = ADR_CMD0 or bus7.Adr = ADR_CMD4 or
                            bus7.Adr(27 downto 4) = x"00001B" or bus7.Adr = ADR_DATA) else '0';

   -- ================= state =================
   process (clk)
      variable wval      : std_logic_vector(31 downto 0);
      variable owner_bus : proc_bus_gb_type;
      variable v_start   : std_logic;
      variable v_size    : unsigned(2 downto 0);
      variable v_len     : unsigned(12 downto 0);
      variable v_cmddel  : unsigned(19 downto 0);
      variable v_xcyc    : unsigned(3 downto 0);
      variable v_pos     : unsigned(12 downto 0);
      variable v_b7      : std_logic;
      variable v_b8      : std_logic;
      variable v_redir   : std_logic;
      variable v_addr    : unsigned(31 downto 0);
      variable v_pfcnt   : integer range 0 to CARDPREFETCH;
      variable v_inflt   : std_logic;
      variable v_spival  : std_logic_vector(7 downto 0);
      variable v_spipos  : unsigned(15 downto 0);
      variable v_spilast : std_logic;
      variable v_addrbytes : integer range 1 to 3;
      variable v_next_sram_addr : unsigned(19 downto 0);
   begin
      if rising_edge(clk) then

         irq9_xfer <= '0';
         irq7_xfer <= '0';
         dma9_card <= '0';
         dma7_card <= '0';
         card_ena  <= '0';
         sram_we_r <= '0';

         if (sram_we_r = '1') then
            backup_write_toggle <= not backup_write_toggle;
         end if;

         if (reset = '1') then

            spicnt     <= (others => '0');
            romctrl    <= (others => '0');
            cmdbytes   <= (others => '0');
            busy       <= '0';
            word_ready <= '0';
            pop_req    <= '0';
            state      <= IDLE;
            -- raw for a firmware boot, main data mode for a direct boot
            if (fw_boot = '1') then
               cmd_mode <= "00";
            else
               cmd_mode <= "10";
            end if;
            sec_cnt     <= (others => '0');
            key1_seen4  <= '0';
            pf_wr       <= 0;
            pf_rd       <= 0;
            pf_cnt      <= 0;
            pf_inflt    <= '0';
            pf_asked    <= (others => '0');
            spi_data    <= (others => '0');
            spi_hold    <= '0';
            spi_pos     <= (others => '0');
            spi_busy    <= (others => '0');
            sram_cmd    <= (others => '0');
            sram_addr   <= (others => '0');
            sram_status <= (others => '0');
            backup_access_r <= '0';
            erase_active <= '0';
            erase_addr <= (others => '0');
            erase_remaining <= (others => '0');
            backup_write_toggle <= '0';

         elsif (ce = '1') then

            if (spi_busy /= 0) then
               spi_busy <= spi_busy - 1;
            end if;

            -- Flash erase is deliberately serialized through the same cache
            -- byte port as program/write.  Page erase covers 256 bytes and
            -- sector erase 64 KiB; crossing a 512-byte cache boundary naturally
            -- stalls here until the bridge flushes and loads the next sector.
            if (erase_active = '1' and backup_cache_ready = '1') then
               sram_we_r <= '1';
               sram_wa_r <= erase_addr;
               sram_wd_r <= x"FF";
               if (erase_remaining = 1) then
                  erase_active <= '0';
                  erase_remaining <= (others => '0');
                  backup_access_r <= '0';
                  sram_status(1) <= '0';
               else
                  erase_addr <= erase_addr + 1;
                  erase_remaining <= erase_remaining - 1;
               end if;
            end if;

            -- -------- prefetch queue: landing --------
            -- First thing in the cycle, so a word that arrives on this edge can
            -- still be handed over on this edge. Held in variables because the
            -- transfer-start block, the FSM and the fetch engine below all move
            -- the same two counts and each needs to see the others' effect.
            v_pfcnt := pf_cnt;
            v_inflt := pf_inflt;
            if (card_done = '1' and pf_inflt = '1') then
               pf(pf_wr) <= card_din;
               if (pf_wr = CARDPREFETCH-1) then pf_wr <= 0; else pf_wr <= pf_wr + 1; end if;
               v_pfcnt := v_pfcnt + 1;
               v_inflt := '0';
            end if;

            if (card7 = '1') then
               owner_bus := bus7;
            else
               owner_bus := bus9;
            end if;

            -- -------- register writes (owner only) --------
            v_start := '0';
            if (owner_bus.ena = '1' and owner_bus.rnw = '0') then

               if (owner_bus.Adr = ADR_AUXSPI) then
                  if (owner_bus.bEna(0) = '1') then
                     spicnt(7 downto 0)  <= owner_bus.Din(7 downto 0);
                  end if;
                  if (owner_bus.bEna(1) = '1') then
                     spicnt(15 downto 8) <= owner_bus.Din(15 downto 8);
                     if (owner_bus.Din(15) = '0') then
                        spi_hold <= '0';   -- disabling the slot drops the CS hold
                        backup_access_r <= '0';
                     end if;
                  end if;
                  -- AUXSPIDATA byte write: one SPI transfer to the backup chip
                  if (owner_bus.bEna(2) = '1' and spicnt(15) = '1' and spicnt(13) = '1' and
                      spi_busy = 0 and erase_active = '0' and
                      (backup_access_r = '0' or backup_cache_ready = '1')) then
                     v_spival := owner_bus.Din(23 downto 16);
                     -- pos/last bookkeeping (melonDS WriteSPIData)
                     if (spicnt(6) = '0') then
                        if (spi_hold = '1') then
                           v_spipos := spi_pos + 1;
                        else
                           v_spipos := (others => '0');
                        end if;
                        v_spilast := '1';
                        spi_hold <= '0';
                     elsif (spi_hold = '0') then
                        spi_hold <= '1';
                        v_spipos := (others => '0');
                        v_spilast := '0';
                     else
                        v_spipos := spi_pos + 1;
                        v_spilast := '0';
                     end if;
                     spi_pos <= v_spipos;
                     -- 8 bits at the AUXSPICNT baud rate (4 MHz >> baud)
                     spi_busy <= shift_left(to_unsigned(64, 10),
                                            to_integer(unsigned(spicnt(1 downto 0))));

                     -- Cartridge backup state machine. Command behavior follows
                     -- melonDS CartRetail, except flash page-program and erase use
                     -- the real 1->0 / FF semantics where melonDS marks its own
                     -- implementation TODO.
                     spi_data <= (others => '0');
                     if (v_spipos = 0) then
                        backup_access_r <= '0';
                        if (v_spival = x"04") then
                           sram_status(1) <= '0';                -- write disable
                        elsif (v_spival = x"06") then
                           sram_status(1) <= '1';                -- write enable
                        else
                           sram_cmd  <= v_spival;
                           sram_addr <= (others => '0');
                           spi_data  <= (others => '1');
                        end if;
                     else
                        v_addrbytes := save_addr_bytes(backup_save_type);

                        if (unsigned(backup_save_type) = 1) then
                           -- 512-byte tiny EEPROM: command selects the high
                           -- address bit and one following byte supplies A7..A0.
                           case sram_cmd is
                              when x"01" =>
                                 if (v_spipos = 1) then
                                    sram_status <= (sram_status and x"01") or
                                                   (v_spival and x"0C");
                                 end if;
                              when x"05" => spi_data <= sram_status or x"F0";
                              when x"02" | x"0A" | x"03" | x"0B" =>
                                 if (v_spipos = 1) then
                                    v_next_sram_addr := (others => '0');
                                    v_next_sram_addr(7 downto 0) := unsigned(v_spival);
                                    if (sram_cmd = x"0A" or sram_cmd = x"0B") then
                                       v_next_sram_addr(8) := '1';
                                    end if;
                                    sram_addr <= v_next_sram_addr;
                                    backup_access_r <= '1';
                                 elsif (sram_cmd = x"02" or sram_cmd = x"0A") then
                                    if (sram_status(1) = '1') then
                                       sram_we_r <= '1';
                                       sram_wa_r <= sram_addr;
                                       sram_wd_r <= v_spival;
                                    end if;
                                    sram_addr <= masked_save_addr(sram_addr + 1,
                                                                  backup_save_type);
                                 else
                                    spi_data <= backup_read_data;
                                    sram_addr <= masked_save_addr(sram_addr + 1,
                                                                  backup_save_type);
                                 end if;
                                 if (v_spilast = '1' and
                                     (sram_cmd = x"02" or sram_cmd = x"0A")) then
                                    sram_status(1) <= '0';
                                 end if;
                              when others => spi_data <= (others => '1');
                           end case;

                        else
                           case sram_cmd is
                              when x"01" =>
                                 if (v_spipos = 1 and
                                     unsigned(backup_save_type) <= 4) then
                                    sram_status <= (sram_status and x"01") or
                                                   (v_spival and x"0C");
                                 end if;
                              when x"05" => spi_data <= sram_status;

                              when x"02" | x"0A" =>
                                 if (v_spipos <= v_addrbytes) then
                                    v_next_sram_addr := shift_left(sram_addr, 8);
                                    v_next_sram_addr(7 downto 0) := unsigned(v_spival);
                                    sram_addr <= masked_save_addr(v_next_sram_addr,
                                                                  backup_save_type);
                                    if (v_spipos = v_addrbytes) then
                                       backup_access_r <= '1';
                                    end if;
                                 elsif (sram_cmd = x"02" or
                                        unsigned(backup_save_type) >= 5) then
                                    if (sram_status(1) = '1') then
                                       sram_we_r <= '1';
                                       sram_wa_r <= sram_addr;
                                       if (unsigned(backup_save_type) >= 5 and
                                           sram_cmd = x"02") then
                                          -- Flash page program can only clear bits.
                                          sram_wd_r <= backup_read_data and v_spival;
                                       else
                                          -- EEPROM/FRAM write and flash 0Ah page write.
                                          sram_wd_r <= v_spival;
                                       end if;
                                    end if;
                                    sram_addr <= masked_save_addr(sram_addr + 1,
                                                                  backup_save_type);
                                 end if;
                                 if (v_spilast = '1') then
                                    sram_status(1) <= '0';
                                 end if;

                              when x"03" | x"0B" =>
                                 if (v_spipos <= v_addrbytes) then
                                    v_next_sram_addr := shift_left(sram_addr, 8);
                                    v_next_sram_addr(7 downto 0) := unsigned(v_spival);
                                    sram_addr <= masked_save_addr(v_next_sram_addr,
                                                                  backup_save_type);
                                    if (v_spipos = v_addrbytes) then
                                       backup_access_r <= '1';
                                    end if;
                                 elsif (sram_cmd = x"0B" and
                                        unsigned(backup_save_type) >= 5 and
                                        v_spipos = v_addrbytes + 1) then
                                    spi_data <= (others => '0'); -- fast-read dummy
                                 else
                                    spi_data <= backup_read_data;
                                    sram_addr <= masked_save_addr(sram_addr + 1,
                                                                  backup_save_type);
                                 end if;

                              when x"D8" | x"DB" =>
                                 if (unsigned(backup_save_type) >= 5 and
                                     v_spipos <= 3) then
                                    v_next_sram_addr := shift_left(sram_addr, 8);
                                    v_next_sram_addr(7 downto 0) := unsigned(v_spival);
                                    sram_addr <= masked_save_addr(v_next_sram_addr,
                                                                  backup_save_type);
                                    if (v_spipos = 3 and sram_status(1) = '1') then
                                       if (sram_cmd = x"D8") then
                                          erase_addr <= masked_save_addr(
                                             v_next_sram_addr and x"F0000",
                                             backup_save_type);
                                          erase_remaining <= to_unsigned(65536, 17);
                                       else
                                          erase_addr <= masked_save_addr(
                                             v_next_sram_addr and x"FFF00",
                                             backup_save_type);
                                          erase_remaining <= to_unsigned(256, 17);
                                       end if;
                                       erase_active <= '1';
                                       backup_access_r <= '1';
                                    end if;
                                 end if;

                              when others =>
                                 -- 9F JEDEC ID is FF in the melonDS oracle for
                                 -- both regular EEPROM/FRAM and retail flash.
                                 spi_data <= (others => '1');
                           end case;
                        end if;

                        if (v_spilast = '1' and erase_active = '0') then
                           backup_access_r <= '0';
                        end if;
                     end if;
                  end if;

               elsif (owner_bus.Adr = ADR_ROMCTRL) then
                  wval := romctrl;
                  for i in 0 to 3 loop
                     if (owner_bus.bEna(i) = '1') then
                        wval(i*8 + 7 downto i*8) := owner_bus.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
                  romctrl <= wval;
                  -- start on writing 1 to bit31 while idle, slot enabled,
                  -- ROM mode (melonDS WriteROMCnt gate set)
                  if (wval(31) = '1' and busy = '0' and owner_bus.bEna(3) = '1' and
                      spicnt(15) = '1' and spicnt(13) = '0') then
                     v_start := '1';
                  end if;

               elsif (owner_bus.Adr = ADR_CMD0) then
                  if (owner_bus.bEna(0) = '1') then cmdbytes(63 downto 56) <= owner_bus.Din(7 downto 0); end if;
                  if (owner_bus.bEna(1) = '1') then cmdbytes(55 downto 48) <= owner_bus.Din(15 downto 8); end if;
                  if (owner_bus.bEna(2) = '1') then cmdbytes(47 downto 40) <= owner_bus.Din(23 downto 16); end if;
                  if (owner_bus.bEna(3) = '1') then cmdbytes(39 downto 32) <= owner_bus.Din(31 downto 24); end if;

               elsif (owner_bus.Adr = ADR_CMD4) then
                  if (owner_bus.bEna(0) = '1') then cmdbytes(31 downto 24) <= owner_bus.Din(7 downto 0); end if;
                  if (owner_bus.bEna(1) = '1') then cmdbytes(23 downto 16) <= owner_bus.Din(15 downto 8); end if;
                  if (owner_bus.bEna(2) = '1') then cmdbytes(15 downto 8)  <= owner_bus.Din(23 downto 16); end if;
                  if (owner_bus.bEna(3) = '1') then cmdbytes(7 downto 0)   <= owner_bus.Din(31 downto 24); end if;

               end if;
               -- 0x1B0+ KEY2 seeds: accepted and dropped

            end if;

            -- data-port pop (owner read, read direction only)
            pop_req <= '0';
            if (owner_bus.ena = '1' and owner_bus.rnw = '1' and owner_bus.Adr = ADR_DATA and
                romctrl(30) = '0' and word_ready = '1') then
               pop_req <= '1';
            end if;

            -- -------- transfer start --------
            if (v_start = '1') then
               v_size := unsigned(wval(26 downto 24));
               if (v_size = 7) then
                  v_len := to_unsigned(1, 13);              -- 4 bytes
               elsif (v_size = 0) then
                  v_len := (others => '0');
               else
                  v_len := shift_left(to_unsigned(64, 13), to_integer(v_size)); -- 0x100<<n bytes = 64<<n words
               end if;
               xferlen <= v_len;
               xferpos <= (others => '0');
               busy    <= '1';
               word_ready <= '0';

               -- decoded into variables, not straight onto the signals: the
               -- first word's image fetch is issued in this same cycle and
               -- needs the decode result now, not on the next edge
               v_b7    := '0';
               v_b8    := '0';
               v_redir := '0';
               v_addr  := unsigned(cmdbytes(55 downto 24));  -- cmd[1..4] big-endian address

               case to_integer(cmd_mode) is

                  when 0 =>      -- raw commands, plaintext
                     case cmdbytes(63 downto 56) is
                        when x"9F" =>
                           null;                        -- dummy read: FF fill
                        when x"00" =>
                           v_b7   := '1';               -- header, from image byte 0
                           v_addr := (others => '0');
                        when x"90" =>
                           v_b8 := '1';                 -- chip ID
                        when x"3C" =>
                           cmd_mode   <= "01";          -- activate KEY1
                           sec_cnt    <= (others => '0');
                           key1_seen4 <= '0';
                        when others =>
                           null;
                     end case;

                  when 1 =>      -- KEY1: encrypted, decoded by size + counters
                     if (v_len = 0) then
                        -- Both 4x (KEY2 data mode) and Ax (enter main data mode)
                        -- carry no data, so they are told apart by which comes
                        -- first, NOT by whether any secure-area block was read.
                        -- The number of KEY1 commands is ROM-DEPENDENT: a retail
                        -- cart with a secure area issues 4x, 1x, four 2x, Ax,
                        -- but a homebrew image with no secure area issues only
                        -- 4x, Ax. Keying off sec_cnt left the second case stuck
                        -- in KEY1 mode forever, because sec_cnt never left 0.
                        if (key1_seen4 = '0') then
                           key1_seen4 <= '1';           -- 4x: KEY2 data mode
                        else
                           cmd_mode <= "10";            -- Ax: enter main data mode
                        end if;
                     elsif (v_len = 1) then
                        v_b8 := '1';                    -- 1x: chip ID, 4 bytes
                     else
                        v_b7 := '1';                    -- 2x: 4 KB secure-area block
                        case to_integer(sec_cnt) is
                           when 0      => v_addr := x"00006000";
                           when 1      => v_addr := x"00007000";
                           when 2      => v_addr := x"00005000";
                           when others => v_addr := x"00004000";
                        end case;
                        if (sec_cnt /= 7) then
                           sec_cnt <= sec_cnt + 1;
                        end if;
                     end if;

                  when others => -- main (KEY2) data mode
                     if (cmdbytes(63 downto 56) = x"B7") then
                        v_b7    := '1';
                        v_redir := '1';
                     elsif (cmdbytes(63 downto 56) = x"B8") then
                        v_b8 := '1';
                     end if;

               end case;

               cmd_b7    <= v_b7;
               cmd_b8    <= v_b8;
               cmd_redir <= v_redir;
               b7_addr   <= v_addr;

               -- Empty the prefetch queue for the new block. The fetch engine at
               -- the bottom of the process picks it up from here and starts
               -- filling during the command time, which is time the cart bus was
               -- going to spend anyway - the DDR3 round trip is ours, not the
               -- cart's, and melonDS charges nothing for it.
               -- v_inflt is deliberately left alone: a transfer can only start
               -- with busy clear, and the engine stops asking at the block end,
               -- so the last word has always landed by then - there is never a
               -- request outstanding here. Not clearing it means that if that
               -- ever stops being true, the engine waits for the stale reply
               -- instead of putting two requests on a port that takes one.
               v_pfcnt  := 0;
               pf_wr    <= 0;
               pf_rd    <= 0;
               pf_asked <= (others => '0');

               -- synthesis translate_off
               report "CARD: mode=" & integer'image(to_integer(cmd_mode)) &
                      " cmd=" & to_hstring(cmdbytes(63 downto 56)) &
                      " addr=" & to_hstring(cmdbytes(55 downto 24)) &
                      " words=" & integer'image(to_integer(v_len));
               -- synthesis translate_on

               -- command time: 8 bytes, + gaps while WR clear, +4 data cycles
               -- before the first word; all times xfercycle per unit
               if (wval(27) = '1') then v_xcyc := to_unsigned(8, 4); else v_xcyc := to_unsigned(5, 4); end if;
               v_cmddel := to_unsigned(8, 20);
               if (wval(30) = '0') then
                  v_cmddel := v_cmddel + unsigned(wval(12 downto 0));
                  if (v_len /= 0) then
                     v_cmddel := v_cmddel + unsigned(wval(21 downto 16));
                  end if;
               end if;
               if (v_len /= 0) then
                  v_cmddel := v_cmddel + 4;
               end if;
               delay_cnt <= shift_right(resize(v_cmddel * v_xcyc, 20), CARDSPEED_SHIFT);
               state     <= CMDDELAY;
            end if;

            -- -------- transfer FSM --------
            case state is

               when IDLE => null;

               -- CMDDELAY/WORDDELAY only spend cart-bus time now; the word is
               -- handed over in FETCH, which is where every source (image
               -- prefetch, chip ID, FF fill) is presented from.
               when CMDDELAY =>
                  if (delay_cnt /= 0) then
                     delay_cnt <= delay_cnt - 1;
                  elsif (xferlen = 0) then
                     state <= FINISH;
                  else
                     state <= FETCH;
                  end if;

               when WORDDELAY =>
                  if (delay_cnt /= 0) then
                     delay_cnt <= delay_cnt - 1;
                  else
                     state <= FETCH;
                  end if;

               when FETCH =>
                  if (cmd_b7 = '0') then
                     if (cmd_b8 = '1') then
                        romdata <= chipid;
                     else
                        romdata <= (others => '1');
                     end if;
                     word_ready <= '1';
                     dma9_card  <= own9;
                     dma7_card  <= own7;
                     state      <= DATAREADY;
                  elsif (v_pfcnt /= 0) then
                     -- pf_cnt = 0 means this word landed on this very edge, so
                     -- the queue signal does not hold it yet - take it from the
                     -- port. pf_rd advances either way: the landing wrote it to
                     -- the slot pf_rd points at (an empty queue has pf_wr = pf_rd)
                     -- and the two must not drift apart.
                     if (pf_cnt = 0) then
                        romdata <= card_din;
                     else
                        romdata <= pf(pf_rd);
                     end if;
                     if (pf_rd = CARDPREFETCH-1) then pf_rd <= 0; else pf_rd <= pf_rd + 1; end if;
                     v_pfcnt    := v_pfcnt - 1;
                     word_ready <= '1';
                     dma9_card  <= own9;
                     dma7_card  <= own7;
                     state      <= DATAREADY;
                  end if;

               when DATAREADY =>
                  if (pop_req = '1') then
                     word_ready <= '0';
                     v_pos      := xferpos + 1;
                     xferpos    <= v_pos;
                     if (v_pos >= xferlen) then
                        state <= FINISH;
                     else
                        -- 4 bus cycles per word, +gap2 at 512-byte boundaries
                        if (romctrl(27) = '1') then v_xcyc := to_unsigned(8, 4); else v_xcyc := to_unsigned(5, 4); end if;
                        v_cmddel := to_unsigned(4, 20);
                        if (romctrl(30) = '0' and v_pos(6 downto 0) = 0) then
                           v_cmddel := v_cmddel + unsigned(romctrl(21 downto 16));
                        end if;
                        delay_cnt <= shift_right(resize(v_cmddel * v_xcyc, 20), CARDSPEED_SHIFT);
                        state     <= WORDDELAY;
                     end if;
                  end if;

               when FINISH =>
                  busy       <= '0';
                  word_ready <= '0';
                  if (spicnt(14) = '1') then
                     irq9_xfer <= own9;
                     irq7_xfer <= own7;
                  end if;
                  state <= IDLE;

            end case;

            -- -------- prefetch queue: fetch engine --------
            -- Runs on its own, ahead of the cart bus, one request in flight
            -- (NDS.sv's pager and ddram ch2 both serve exactly one) and never
            -- past the end of the block. This is the whole speedup: the pacing
            -- delays now cover the image fetches instead of following them.
            if (busy = '1' and cmd_b7 = '1' and v_inflt = '0' and
                v_pfcnt < CARDPREFETCH and pf_asked < xferlen) then
               card_ena  <= '1';
               card_addr <= std_logic_vector(eff_addr(b7_addr, cmd_redir)(26 downto 2));
               b7_addr   <= b7_addr + 4;
               pf_asked  <= pf_asked + 1;
               v_inflt   := '1';
            end if;

            pf_cnt   <= v_pfcnt;
            pf_inflt <= v_inflt;

         end if;

      end if;
   end process;

end architecture;
