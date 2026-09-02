-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
--
-- Hardware performance counters: the numbers LINEPROF/OBJPROF produce in
-- simulation, but on silicon and while a game is actually running.
--
-- WHY THIS EXISTS. Every renderer decision in this core so far - GPU_CE_DIV,
-- PQ_DEPTH, the screen clip, the drain-bubble fix - was measured in nvc, on a
-- bench scene, against a golden model. That is the right place to measure
-- correctness and it is a poor place to measure PACE: the sim has no SDRAM
-- refresh, no card latency, no ARM contending for main RAM, and no game
-- deciding to put 128 sprites on one line during a boss. This block answers
-- "did the renderer keep up, on hardware, in THIS scene".
--
-- WHAT IT COSTS. Everything here is behind ENABLE, defaulting to 1 but meant
-- to be switched off for an area-constrained image the same way DEBUG_ENABLE
-- is. The design sits at 98% LABs, so counters are not free - see the width
-- choices below, which are picked to be honest about a frame's actual range
-- rather than lazily 32 bits wide.
--
-- COHERENCE. The host reads one 32-bit word per mailbox round trip (~122 us),
-- so reading eight live counters would sample them across several frames and
-- silently mix them. Everything is therefore SNAPSHOT at vblank into a shadow
-- set, and only the shadow is readable: one host poll sees one frame, and a
-- slow poll misses frames rather than tearing them.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_perf is
   generic
   (
      -- 0 compiles the counters away and ties the read port to zero. The
      -- instantiation stays, so nothing above has to be conditional.
      ENABLE : integer := 1
   );
   port
   (
      clk          : in  std_logic;
      reset        : in  std_logic;

      -- pulse, once per frame: the snapshot edge
      vblank       : in  std_logic;
      -- pulse, once per rendered line, per engine trigger
      drawline     : in  std_logic;
      drawObj      : in  std_logic;
      -- high from drawline until that line is merged, per engine. A drawline
      -- arriving while this is still high is a DROPPED line - the renderer did
      -- not finish the previous one inside its budget.
      line_busy_a  : in  std_logic;
      line_busy_b  : in  std_logic;

      -- 0..7, selects which snapshot word `value` presents (combinational, so
      -- the mailbox can mux on cmd_arg without a round trip of its own)
      index        : in  std_logic_vector(2 downto 0);
      value        : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of nds_perf is

   -- Widths are sized to one frame at clk1x, not to 32 bits, because at 98%
   -- LABs 8 lazy counters is ~200 flops of pure waste:
   --   frame cycles  a 60 Hz frame at 33.5 MHz is 558k cycles -> 20 bits is
   --                 not enough headroom if the core is paced slower, 24 is
   --                 (16.7M, i.e. down to 2 fps before it wraps)
   --   busy cycles   bounded by frame cycles, same 24
   --   drops         192 lines in a frame -> 8 bits
   --   frames        free-running, and the host wants long-baseline fps, so
   --                 this one genuinely is 32
   signal frames      : unsigned(31 downto 0) := (others => '0');
   signal fcyc        : unsigned(23 downto 0) := (others => '0');
   signal busy_a      : unsigned(23 downto 0) := (others => '0');
   signal busy_b      : unsigned(23 downto 0) := (others => '0');
   signal drop_a      : unsigned( 7 downto 0) := (others => '0');
   signal drop_b      : unsigned( 7 downto 0) := (others => '0');
   -- cumulative drops survive the per-frame reset: a game that drops one line
   -- every few seconds shows up here and nowhere else
   signal drop_a_tot  : unsigned(15 downto 0) := (others => '0');
   signal drop_b_tot  : unsigned(15 downto 0) := (others => '0');

   signal s_fcyc      : unsigned(23 downto 0) := (others => '0');
   signal s_busy_a    : unsigned(23 downto 0) := (others => '0');
   signal s_busy_b    : unsigned(23 downto 0) := (others => '0');
   signal s_drop_a    : unsigned( 7 downto 0) := (others => '0');
   signal s_drop_b    : unsigned( 7 downto 0) := (others => '0');

begin

   goff : if ENABLE = 0 generate
      value <= (others => '0');
   end generate;

   gon : if ENABLE /= 0 generate

      process (clk)
         -- a drop is a new line arriving on top of one still being rendered.
         -- drawObj is a separate trigger from drawline, so engine A can drop
         -- on either; both map to the same "did not keep up" event.
         variable v_drop_a : boolean;
         variable v_drop_b : boolean;
      begin
         if rising_edge(clk) then

            v_drop_a := (drawline = '1' or drawObj = '1') and line_busy_a = '1';
            v_drop_b := (drawline = '1' or drawObj = '1') and line_busy_b = '1';

            -- saturate rather than wrap. A wrapped counter reads as a small
            -- number and lies quietly; a stuck maximum is visibly wrong.
            if (fcyc /= x"FFFFFF") then fcyc <= fcyc + 1; end if;
            if (line_busy_a = '1' and busy_a /= x"FFFFFF") then busy_a <= busy_a + 1; end if;
            if (line_busy_b = '1' and busy_b /= x"FFFFFF") then busy_b <= busy_b + 1; end if;

            if (v_drop_a) then
               if (drop_a     /= x"FF")   then drop_a     <= drop_a + 1;         end if;
               if (drop_a_tot /= x"FFFF") then drop_a_tot <= drop_a_tot + 1;     end if;
            end if;
            if (v_drop_b) then
               if (drop_b     /= x"FF")   then drop_b     <= drop_b + 1;         end if;
               if (drop_b_tot /= x"FFFF") then drop_b_tot <= drop_b_tot + 1;     end if;
            end if;

            if (vblank = '1') then
               -- snapshot, then restart the per-frame set. The drop that
               -- happens ON the vblank edge is counted into the frame that is
               -- closing, which is where a reader would look for it.
               s_fcyc   <= fcyc;
               s_busy_a <= busy_a;
               s_busy_b <= busy_b;
               s_drop_a <= drop_a;
               s_drop_b <= drop_b;

               frames   <= frames + 1;
               fcyc     <= (others => '0');
               busy_a   <= (others => '0');
               busy_b   <= (others => '0');
               drop_a   <= (others => '0');
               drop_b   <= (others => '0');
            end if;

            if (reset = '1') then
               frames <= (others => '0');
               fcyc   <= (others => '0');
               busy_a <= (others => '0'); busy_b <= (others => '0');
               drop_a <= (others => '0'); drop_b <= (others => '0');
               drop_a_tot <= (others => '0'); drop_b_tot <= (others => '0');
               s_fcyc <= (others => '0');
               s_busy_a <= (others => '0'); s_busy_b <= (others => '0');
               s_drop_a <= (others => '0'); s_drop_b <= (others => '0');
            end if;

         end if;
      end process;

      -- index 0 frames        (32) - host differences this for fps
      --       1 frame cycles  (24) - clk1x cycles in the last frame = frame time
      --       2 busy A        (24) - renderer-busy cycles, engine A
      --       3 busy B        (24)
      --       4 drops A       ( 8) in the last frame
      --       5 drops B       ( 8)
      --       6 drops A total (16) since reset
      --       7 drops B total (16)
      with index select value <=
         std_logic_vector(frames)                                   when "000",
         x"00" & std_logic_vector(s_fcyc)                            when "001",
         x"00" & std_logic_vector(s_busy_a)                          when "010",
         x"00" & std_logic_vector(s_busy_b)                          when "011",
         x"000000" & std_logic_vector(s_drop_a)                      when "100",
         x"000000" & std_logic_vector(s_drop_b)                      when "101",
         x"0000" & std_logic_vector(drop_a_tot)                      when "110",
         x"0000" & std_logic_vector(drop_b_tot)                      when others;

   end generate;

end architecture;
