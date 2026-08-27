-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Card-header HLE loader (M4). The .nds image is pre-staged in SDRAM (on
-- MiSTer the HPS puts it there; in sim the testbench preloads the model).
-- On start it parses the header:
--
--   +0x20 ARM9 rom offset   +0x24 ARM9 entry   +0x28 ARM9 load addr  +0x2C size
--   +0x30 ARM7 rom offset   +0x34 ARM7 entry   +0x38 ARM7 load addr  +0x3C size
--
-- then copies both sections word-by-word from the card image to their load
-- addresses and reports the entry points. The write port carries full 32-bit
-- CPU addresses - the integration routes main RAM (0x02xxxxxx) and ARM7 WRAM
-- (0x037xxxxx) targets; anything else is an error (secure-area/ITCM-loading
-- images are out of scope until real card emulation).
--
-- The cartridge chip ID is derived from the header's used-ROM-size word
-- (+0x80) with the melonDS size formula and exported on cart_id: the same
-- value goes into the direct-boot env block below and answers nds_card's B8
-- command, so NitroSDK's CARDi_CheckPulledOut sees what it booted with.
--
-- direct='1' additionally synthesizes the firmware direct-boot environment
-- (M7, spec = melonDS SetupDirectBoot; calico's bootstubs do their own CP15
-- and stack setup so only the memory image matters):
--   0x02FFFE00  header copy (0x170 bytes from card offset 0)
--   0x02FFF800/C00 blocks: chip ID x2 (cart_id), header +
--     secure-area CRC16 (read from the header itself), boot flags,
--     user-settings mirror words for melonDS's generated default firmware
--   0x02FFFC80  0x70-byte default user settings (version 5, all defaults)
-- The integration also presets WRAMCNT=3, POSTFLG=1, POWCNT1=0x820F when
-- direct (nds_syscnt preset_direct) - firmware leaves them that way.
--
-- The CPUs are expected to be held in reset while busy='1'; the testbench
-- (and later nds_top) presets their boot PCs from arm9_entry/arm7_entry
-- through the savestate buses before releasing them.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_loader is
   generic
   (
      -- '1' skips the 4 MB main-RAM clear pass. That pass exists for hardware,
      -- where SDRAM comes up holding garbage and the SDK's read-before-write
      -- (the cartridge lock via SWP) then latches nonsense. Every simulation
      -- main-RAM model already powers up all-zero, so in simulation the pass is
      -- a no-op that costs ~1M word writes - well over a hundred milliseconds of
      -- simulated time before the CPUs are even released, which is most of the
      -- cost of every boot-length run. Skipping it changes no simulated state.
      is_simu     : std_logic := '0';
      -- '1' skips the ARM9/ARM7 binary copy passes for sections that land in main
      -- RAM, on the promise that the testbench has already placed them there. The
      -- copy is 443,230 words for Kirby at roughly five clk1x cycles each - about
      -- 70 ms of simulated time before the CPUs are released, which dominates the
      -- wall clock of every boot-length run and measures nothing. Sections that
      -- target WRAM7 are still copied normally: only main RAM is preloadable.
      -- Never set this for hardware; there is nothing to preload there.
      skip_copy   : std_logic := '0'
   );
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;
      start       : in  std_logic;                     -- one-cycle pulse
      direct      : in  std_logic := '0';              -- synth direct-boot env
      -- '1' = FIRMWARE BOOT: clear memory and derive the cartridge chip ID, then
      -- stop. Do NOT stage the ARM9/ARM7 images and do NOT write the direct-boot
      -- env block - under firmware boot the ARM7 BIOS pulls the firmware over SPI
      -- and the firmware reads the cartridge itself, exactly as real hardware
      -- does. nds_card serves the cart from its own channel either way, so the
      -- images do not need to be in main RAM first.
      fw_boot     : in  std_logic := '0';
      busy        : out std_logic := '0';
      done        : out std_logic := '0';              -- level, stays high
      load_error  : out std_logic := '0';

      arm9_entry  : out std_logic_vector(31 downto 0) := (others => '0');
      arm7_entry  : out std_logic_vector(31 downto 0) := (others => '0');
      cart_id     : out std_logic_vector(31 downto 0) := (others => '0');  -- valid from done
      -- Chrono Trigger USA's little-endian header game code is 0x45555159
      -- ("YQUE"). It uses the regular EEPROM protocol with 64 KiB storage.
      save_is_64k : out std_logic := '0';
      save_gamecode : out std_logic_vector(31 downto 0) := (others => '0');
      save_gamecode_valid : out std_logic := '0';

      -- card image read port (word addressed into the staged .nds)
      card_ena    : out std_logic := '0';
      card_addr   : out std_logic_vector(26 downto 2) := (others => '0');
      card_done   : in  std_logic;
      card_rdata  : in  std_logic_vector(31 downto 0);

      -- destination write port (full CPU byte address, word writes). wr_rnw='1'
      -- turns an access into a read that answers on rd_data - used only by the
      -- post-copy verify pass below.
      wr_ena      : out std_logic := '0';
      wr_rnw      : out std_logic := '0';
      wr_addr     : out std_logic_vector(31 downto 0) := (others => '0');
      wr_data     : out std_logic_vector(31 downto 0) := (others => '0');
      wr_done     : in  std_logic;
      rd_data     : in  std_logic_vector(31 downto 0) := (others => '0');

      -- main-RAM verify results. After the copy (and env) pass, both CPU
      -- binaries are re-read from the card and compared against what main RAM
      -- actually returns. This is the only way to observe the SDRAM main-RAM
      -- path on real hardware: the simulator substitutes a perfect behavioural
      -- model, so a fault in SDRAM itself, in the clkMemIndex=0 issue gate, in
      -- the VRAM-borrow park/resume handshake, or in the CPU-channel mux is
      -- invisible to every existing gate. Non-zero vfy_bad means main RAM does
      -- not read back what was written, and vfy_addr is the first such address.
      vfy_bad     : out std_logic_vector(17 downto 0) := (others => '0');
      vfy_addr    : out std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_loader is

   type t_state is
   (
      IDLE,
      CLR_WR, CLR_WR_WAIT,   -- zero all 4 MB of main RAM before anything is staged
      HDR_REQ, HDR_WAIT,     -- read the 8 header words at 0x20..0x3C, + 0x80
      CP_RD, CP_RD_WAIT,     -- copy loop: card read ...
      CP_WR, CP_WR_WAIT,     -- ... destination write
      NEXT_CPU,
      CARTID_CALC,           -- one round-up-to-power-of-two step per cycle
      ENV_SET, ENV_WR, ENV_WR_WAIT,   -- direct-boot env table
      VF_RD, VF_RD_WAIT,     -- verify pass: re-read the card word ...
      VF_MEM, VF_MEM_WAIT,   -- ... then read main RAM back and compare
      FINISHED
   );
   signal state : t_state := IDLE;

   type t_hdr is array (0 to 7) of std_logic_vector(31 downto 0);
   signal hdr     : t_hdr := (others => (others => '0'));
   signal hdr_i   : integer range 0 to 9 := 0;

   -- Main RAM must be ZERO before the CPUs run. NitroSDK's MI_LockByWord does
   -- `swp r0,r0,[0x027FFFE8]` with lock id 0x40: SWP always writes the id and
   -- returns the OLD word, so acquisition succeeds only if that word was 0.
   -- The loader stages only the ARM9/ARM7 images, so 0x023FFFE8 (the mirror of
   -- 0x027FFFE8) was left at whatever the SDRAM powered up holding. Simulation
   -- hid this completely - its behavioral SDRAM starts all-zero, so the sim
   -- always acquired the lock on the first try and booted, while real SDRAM
   -- comes up with garbage, the first SWP fails, and every retry then reads
   -- back its own 0x40 and fails forever: both CPUs spin, no IRQ is ever
   -- enabled, and the screen stays white. Real hardware gets this clearing from
   -- the firmware boot we skip in direct boot.
   signal clr_i   : unsigned(19 downto 0) := (others => '0');   -- 0..1048575 words = 4 MB
   -- '0' = clearing main RAM (0x02xxxxxx), '1' = clearing ARM7-private WRAM
   -- (0x03800000, 64 KB = 16384 words). See the CLR_WR comment for why WRAM7
   -- has to be cleared too.
   signal clr_w7  : std_logic := '0';

   signal cpu_sel : integer range 0 to 2 := 0;         -- 0 = ARM9, 1 = ARM7, 2 = header env copy
   signal src     : unsigned(26 downto 2) := (others => '0');
   signal dst     : unsigned(31 downto 0) := (others => '0');
   signal words   : unsigned(21 downto 0) := (others => '0');

   -- chip-ID input, read in the header pass so cart_id is produced whether or
   -- not the direct-boot env block is written
   signal env_size   : unsigned(31 downto 0) := (others => '0');       -- hdr+0x80 used ROM size
   -- direct-boot env: values captured during the header copy pass
   signal env_hdrcrc : std_logic_vector(15 downto 0) := (others => '0'); -- hdr+0x15E
   signal env_seccrc : std_logic_vector(15 downto 0) := (others => '0'); -- hdr+0x6C
   signal cart_p     : unsigned(31 downto 0) := to_unsigned(512, 32);
   signal cart_iter  : integer range 9 to 28 := 9;
   signal cartid     : std_logic_vector(31 downto 0) := (others => '0');
   signal crcword    : std_logic_vector(31 downto 0) := (others => '0');
   signal env_i      : integer range 0 to 41 := 0;

   -- post-copy main-RAM verify
   signal verifying  : std_logic := '0';
   signal vfy_exp    : std_logic_vector(31 downto 0) := (others => '0');
   signal vfy_cnt    : unsigned(17 downto 0) := (others => '0');
   signal vfy_seen   : std_logic := '0';   -- first mismatch address latched
   signal vfy_at     : std_logic_vector(31 downto 0) := (others => '0');

   -- table entries 0..12, then the 0x70-byte default user settings block
   -- (melonDS LoadDefaultFirmware: version 5, defaults, name empty)
   function env_addr(i : integer) return unsigned is
   begin
      case i is
         when  0 => return x"02FFF800";
         when  1 => return x"02FFF804";
         when  2 => return x"02FFF808";
         when  3 => return x"02FFF850";
         when  4 => return x"02FFFC00";
         when  5 => return x"02FFFC04";
         when  6 => return x"02FFFC08";
         when  7 => return x"02FFFC10";
         when  8 => return x"02FFFC30";
         when  9 => return x"02FFFC40";
         when 10 => return x"02FFF864";
         when 11 => return x"02FFF868";
         when 12 => return x"02FFF874";
         when others => return to_unsigned(16#02FFFC80# + (i - 13) * 4, 32);
      end case;
   end function;

begin

   cart_id  <= cartid;
   vfy_bad  <= std_logic_vector(vfy_cnt);
   vfy_addr <= vfy_at;

   process (clk)
      variable romoff, loadaddr, size : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then

         card_ena <= '0';
         wr_ena   <= '0';
         save_gamecode_valid <= '0';

         if (reset = '1') then
            state      <= IDLE;
            busy       <= '0';
            done       <= '0';
            load_error <= '0';
            save_is_64k <= '0';
            save_gamecode <= (others => '0');
            verifying  <= '0';
            vfy_cnt    <= (others => '0');
            vfy_seen   <= '0';
            wr_rnw     <= '0';
         else
            case state is

               when IDLE =>
                  if (start = '1') then
                     busy  <= '1';
                     done  <= '0';
                     hdr_i <= 0;
                     save_is_64k <= '0';
                     save_gamecode <= (others => '0');
                     clr_i  <= (others => '0');
                     clr_w7 <= '0';
                     if (is_simu = '1') then
                        state <= HDR_REQ;      -- model RAM is already zero
                     else
                        state <= CLR_WR;
                     end if;
                  end if;

               -- Zero main RAM AND ARM7-private WRAM first, then stage the images
               -- over the top. WRAM7 is here for the same reason main RAM is: with
               -- direct boot there is no firmware to clear it, so anything the ARM7
               -- reads before writing sees stale contents - and on a MiSTer the FPGA
               -- is not reconfigured between ROM loads, so "stale" means the
               -- previous game's data.
               --
               -- HONESTY NOTE, so nobody credits this with more than it does: this
               -- is NOT known to fix Kirby's freeze. Kirby's ARM7 does wedge from
               -- ~instruction 400,000 in a 23-instruction doubly-linked-list drain
               -- at 0x037FC48C..0x037FC4B0 (dequeue helper at 0x037FC9C4), looping
               -- on `[r5] /= 0` with r5 = 0x0380B2FC and a `next` reading
               -- 0x950000E5, which is not a pointer - and it then stops servicing
               -- IPC (ARM9 sent 5, ARM7 drained 2, 3 left queued), which is what
               -- leaves the ARM9 in the idle thread with a white screen. But the
               -- SIMULATION reproduces that wedge, and in simulation WRAM7 powers up
               -- ALL-ZERO (SyncRamDualByteEnable's model initialises its array), so
               -- an uncleared WRAM7 cannot be the cause there. The ARM7 builds that
               -- corrupt list itself. Root cause still open.
               -- ~1M word writes; at clk1x this costs a fraction of a second
               -- once, at boot, and it is what makes the cartridge lock (and any
               -- other read-before-write the SDK does) behave like real hardware.
               when CLR_WR =>
                  wr_ena  <= '1';
                  wr_rnw  <= '0';
                  if (clr_w7 = '0') then
                     wr_addr <= x"02" & "00" & std_logic_vector(clr_i) & "00";
                  else
                     -- ARM7-private WRAM at 0x03800000, 64 KB. ld_to_wram7 in
                     -- nds_top routes any 0x03xxxxxx loader write here already.
                     wr_addr <= x"038" & x"0" & std_logic_vector(clr_i(13 downto 0)) & "00";
                  end if;
                  wr_data <= (others => '0');
                  state   <= CLR_WR_WAIT;

               when CLR_WR_WAIT =>
                  if (wr_done = '1') then
                     if (clr_w7 = '0') then
                        if (clr_i = to_unsigned(1048575, clr_i'length)) then
                           -- main RAM done; now ARM7 WRAM
                           clr_i  <= (others => '0');
                           clr_w7 <= '1';
                           state  <= CLR_WR;
                        else
                           clr_i <= clr_i + 1;
                           state <= CLR_WR;
                        end if;
                     else
                        if (clr_i = to_unsigned(16383, clr_i'length)) then
                           state <= HDR_REQ;
                        else
                           clr_i <= clr_i + 1;
                           state <= CLR_WR;
                        end if;
                     end if;
                  end if;

               when HDR_REQ =>
                  card_ena <= '1';
                  if (hdr_i = 8) then                                        -- one extra word:
                     card_addr <= std_logic_vector(to_unsigned(3, 25));      -- byte 0x0C, game code
                  elsif (hdr_i = 9) then
                     card_addr <= std_logic_vector(to_unsigned(16#20#, 25)); -- byte 0x80, used ROM size
                  else
                     card_addr <= std_logic_vector(to_unsigned(8 + hdr_i, 25)); -- word 8 = byte 0x20
                  end if;
                  state <= HDR_WAIT;

               when HDR_WAIT =>
                  if (card_done = '1') then
                     if (hdr_i = 8) then
                        save_gamecode <= card_rdata;
                        save_gamecode_valid <= '1';
                        if (card_rdata = x"45555159") then
                           save_is_64k <= '1';
                        else
                           save_is_64k <= '0';
                        end if;
                        hdr_i <= hdr_i + 1;
                        state <= HDR_REQ;
                     elsif (hdr_i = 9) then
                        env_size <= unsigned(card_rdata);
                        cpu_sel  <= 0;
                        if (fw_boot = '1') then
                           -- firmware boot: skip the staging copies entirely. The
                           -- header is still read because CARTID_CALC needs the
                           -- used-ROM-size word, and nds_card must answer B8 with a
                           -- chip ID consistent with the image.
                           -- CARTID_CALC rounds cart_p up to a power of two until
                           -- it reaches env_size, so it must start at 512 exactly
                           -- as the normal path sets it.
                           cart_p    <= to_unsigned(512, cart_p'length);
                           cart_iter <= 9;
                           state     <= CARTID_CALC;
                        else
                           state <= NEXT_CPU;
                        end if;
                     else
                        hdr(hdr_i) <= card_rdata;
                        hdr_i      <= hdr_i + 1;
                        state      <= HDR_REQ;
                     end if;
                  end if;

               when NEXT_CPU =>
                  romoff   := hdr(cpu_sel*4 + 0);
                  loadaddr := hdr(cpu_sel*4 + 2);
                  size     := hdr(cpu_sel*4 + 3);
                  arm9_entry <= hdr(1) and x"FFFFFFFE";
                  arm7_entry <= hdr(5) and x"FFFFFFFE";
                  if (loadaddr(31 downto 24) /= x"02" and loadaddr(31 downto 20) /= x"037") then
                     load_error <= '1';
                     busy       <= '0';
                     state      <= FINISHED;
                  else
                     src <= unsigned(romoff(26 downto 2));
                     dst <= unsigned(loadaddr);
                     if (skip_copy = '1' and loadaddr(31 downto 24) = x"02") then
                        words <= (others => '0');   -- already in the model's RAM
                     elsif (size(1 downto 0) = "00") then
                        words <= unsigned(size(23 downto 2));
                     else
                        words <= unsigned(size(23 downto 2)) + 1;
                     end if;
                     if (verifying = '1') then
                        state <= VF_RD;
                     else
                        state <= CP_RD;
                     end if;
                  end if;

               when CP_RD =>
                  if (words = 0) then
                     if (cpu_sel = 0) then
                        cpu_sel <= 1;
                        state   <= NEXT_CPU;
                     elsif (cpu_sel = 1 and direct = '1') then
                        cpu_sel <= 2;                  -- header copy to 0x02FFFE00
                        src     <= (others => '0');
                        dst     <= x"02FFFE00";
                        words   <= to_unsigned(16#5C#, words'length);
                        state   <= CP_RD;
                     else
                        -- melonDS chip-ID formula starts by rounding the
                        -- used ROM size up from 512 bytes to a power of two.
                        -- Do the 19 shifts over 19 clocks: the former VHDL
                        -- function unrolled into a 49-logic-level path that
                        -- missed this clock by more than 16 ns in Quartus.
                        cart_p    <= to_unsigned(512, cart_p'length);
                        cart_iter <= 9;
                        crcword <= env_seccrc & env_hdrcrc;
                        env_i   <= 0;
                        state   <= CARTID_CALC;
                     end if;
                  else
                     card_ena  <= '1';
                     card_addr <= std_logic_vector(src);
                     state     <= CP_RD_WAIT;
                  end if;

               when CP_RD_WAIT =>
                  if (card_done = '1') then
                     wr_data <= card_rdata;
                     state   <= CP_WR;
                     if (cpu_sel = 2) then             -- env values ride along
                        if (src = 16#1B#) then         -- byte 0x6C: secure-area CRC16
                           env_seccrc <= card_rdata(15 downto 0);
                        elsif (src = 16#57#) then      -- byte 0x15C: header CRC16 in [31:16]
                           env_hdrcrc <= card_rdata(31 downto 16);
                        end if;
                     end if;
                  end if;

               when CP_WR =>
                  wr_ena  <= '1';
                  wr_addr <= std_logic_vector(dst);
                  state   <= CP_WR_WAIT;

               when CP_WR_WAIT =>
                  if (wr_done = '1') then
                     src   <= src + 1;
                     dst   <= dst + 4;
                     words <= words - 1;
                     state <= CP_RD;
                  end if;

               when CARTID_CALC =>
                  if (cart_iter <= 27) then
                     if (cart_p < env_size) then
                        cart_p <= shift_left(cart_p, 1);
                     end if;
                     cart_iter <= cart_iter + 1;
                  else
                     if (cart_p >= x"00100000") then
                        cartid <= std_logic_vector(
                           x"000000C2" or
                           shift_left(resize(shift_right(cart_p, 20) - 1, 32), 8));
                     else
                        cartid <= x"000100C2"; -- melonDS small-ROM encoding
                     end if;
                     if (fw_boot = '1') then
                        -- firmware boot: nothing more to do. The chip ID above is
                        -- still needed so nds_card answers B8 correctly.
                        busy  <= '0';
                        done  <= '1';
                        state <= FINISHED;
                     elsif (direct = '1') then
                        state <= ENV_SET;
                     else
                        -- busy stays high: nds_top only muxes this port onto
                        -- the ARM9 main-RAM channel while ld_busy is set, and
                        -- the verify pass needs that mux.
                        verifying <= '1';
                        cpu_sel   <= 0;
                        state     <= NEXT_CPU;
                     end if;
                  end if;

               when ENV_SET =>
                  if (env_i = 41) then
                     -- busy stays high through the verify pass (see above)
                     verifying <= '1';
                     cpu_sel   <= 0;
                     state     <= NEXT_CPU;
                  else
                     dst <= env_addr(env_i);
                     case env_i is
                        when 0 | 1 | 4 | 5 => wr_data <= cartid;
                        when 2 | 6         => wr_data <= crcword;
                        when 3 | 7         => wr_data <= x"00005835";
                        when 8             => wr_data <= x"0000FFFF";
                        when 9             => wr_data <= x"00000001";
                        when 10            => wr_data <= x"00000000";
                        when 11            => wr_data <= x"0007FE00"; -- fw user-settings offset
                        when 12            => wr_data <= x"0000FFFF"; -- fw data/gui CRC16s
                        -- user settings: version 5, favorite color/birthday
                        -- defaults, halfword 0x0031 at +0x64
                        when 13            => wr_data <= x"01000005";
                        when 14            => wr_data <= x"00000001";
                        when 38            => wr_data <= x"00000031";
                        when others        => wr_data <= x"00000000";
                     end case;
                     state <= ENV_WR;
                  end if;

               when ENV_WR =>
                  wr_ena  <= '1';
                  wr_addr <= std_logic_vector(dst);
                  state   <= ENV_WR_WAIT;

               when ENV_WR_WAIT =>
                  if (wr_done = '1') then
                     env_i <= env_i + 1;
                     state <= ENV_SET;
                  end if;

               -- ============ post-copy main-RAM verify ============
               -- Walks both CPU binaries again: read the card word, read the
               -- destination back through the real ARM9 main-RAM channel, and
               -- compare. Only 0x02xxxxxx targets are checked; ARM7-WRAM writes
               -- are acknowledged by a synthetic pulse in nds_top and have no
               -- read path here, so those words are skipped rather than counted
               -- as failures.
               when VF_RD =>
                  if (words = 0) then
                     if (cpu_sel = 0) then
                        cpu_sel <= 1;
                        state   <= NEXT_CPU;
                     else
                        busy  <= '0';
                        done  <= '1';
                        state <= FINISHED;
                     end if;
                  elsif (dst(31 downto 24) /= x"02") then
                     src   <= src + 1;
                     dst   <= dst + 4;
                     words <= words - 1;
                  else
                     card_ena  <= '1';
                     card_addr <= std_logic_vector(src);
                     state     <= VF_RD_WAIT;
                  end if;

               when VF_RD_WAIT =>
                  if (card_done = '1') then
                     vfy_exp <= card_rdata;
                     state   <= VF_MEM;
                  end if;

               when VF_MEM =>
                  wr_ena  <= '1';
                  wr_rnw  <= '1';
                  wr_addr <= std_logic_vector(dst);
                  state   <= VF_MEM_WAIT;

               when VF_MEM_WAIT =>
                  if (wr_done = '1') then
                     wr_rnw <= '0';
                     if (rd_data /= vfy_exp) then
                        if (vfy_cnt /= 2#111111111111111111#) then
                           vfy_cnt <= vfy_cnt + 1;
                        end if;
                        if (vfy_seen = '0') then
                           vfy_seen <= '1';
                           vfy_at   <= std_logic_vector(dst);
                        end if;
                     end if;
                     src   <= src + 1;
                     dst   <= dst + 4;
                     words <= words - 1;
                     state <= VF_RD;
                  end if;

               when FINISHED =>
                  null;

            end case;
         end if;
      end if;
   end process;

end architecture;
