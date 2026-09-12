-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Derived from Nitro_DarkSide's sim/tb_gpu_obj.vhd. The production drawer
-- runs against registered OAM/palette memories and a pipelined VRAM server
-- with variable acceptance and reply delays. Synthetic overlap cases from
-- tools/gen_nds_obj_priority.py verify that transparency cannot change the
-- priority or blend mode of a pixel supplied by another opaque sprite.
-- Run tools/test_nds_obj_priority.sh; no commercial assets are required.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

entity tb_nds_obj_priority is
   generic
   (
      VRAMFILE   : string := "gpu_obj_vram.hex";
      PALFILE    : string := "gpu_obj_pal.hex";
      EXTPALFILE : string := "gpu_obj_extpal.hex";
      VECFILE    : string := "gpu_obj_vectors.hex";
      TIMEOUT_MS : integer := 10
   );
end entity;

architecture sim of tb_nds_obj_priority is

   signal clk : std_logic := '0';

   type t_words is array (natural range <>) of std_logic_vector(31 downto 0);

   impure function load_hex(fname : string; size : integer) return t_words is
      file f       : text;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : t_words(0 to size - 1) := (others => (others => '0'));
      variable i   : integer := 0;
   begin
      file_open(f, fname, read_mode);
      while not endfile(f) and i < size loop
         readline(f, l);
         hread(l, w);
         mem(i) := w;
         i := i + 1;
      end loop;
      file_close(f);
      report "loaded " & integer'image(i) & " words from " & fname severity note;
      return mem;
   end function;

   constant vram    : t_words(0 to 65535) := load_hex(VRAMFILE, 65536);
   constant pal     : t_words(0 to 127)   := load_hex(PALFILE, 128);
   constant extpal  : t_words(0 to 2047)  := load_hex(EXTPALFILE, 2048);
   -- 1 count word + up to MAXCASES x 776 (8 header + 256 OAM + 256 colour +
   -- 256 settings). load_hex zero-fills a short file, so this only has to be
   -- an upper bound - raise it when gen_gpu_obj.py grows past it.
   constant MAXCASES : integer := 64;
   constant vectors  : t_words(0 to MAXCASES * 776) := load_hex(VECFILE, MAXCASES * 776 + 1);

   -- config
   signal ypos, ypos_mosaic : integer range 0 to 191 := 0;
   signal one_dim_mapping    : std_logic := '0';
   signal tile_boundary      : unsigned(1 downto 0) := "00";
   signal bitmap_1d          : std_logic := '0';
   signal bitmap_2d_wide     : std_logic := '0';
   signal bitmap_1d_boundary : std_logic := '0';
   signal obj_extpal         : std_logic := '0';
   signal mosaic_h           : unsigned(3 downto 0) := (others => '0');

   signal drawline : std_logic := '0';

   -- OAM: 128 sprites x 8 bytes = 256 words. The drawer reads it by SPRITE
   -- (whole 8-byte entry per read) and reads rot/scal groups from a separate
   -- port; nds_gpu2d builds both out of write-through shadows of the same
   -- 256-word array, so the bench models them as two views of `oam` with the
   -- same one-cycle registered read the real RAMs have.
   type t_oam is array (0 to 255) of std_logic_vector(31 downto 0);
   signal oam      : t_oam := (others => (others => '0'));
   signal oam_addr : integer range 0 to 127;
   signal oam_data : std_logic_vector(63 downto 0) := (others => '0');

   signal oamaff_addr : integer range 0 to 31;
   signal oamaff_data : std_logic_vector(63 downto 0) := (others => '0');

   -- drawer memory ports
   signal o_pal_addr    : integer range 0 to 127;
   signal o_extpal_addr : integer range 0 to 2047;
   signal o_vram_addr   : integer range 0 to 65535;
   signal o_vram_req    : std_logic;
   signal o_vram_done   : std_logic := '0';
   signal o_vram_accept : std_logic;

   -- Pipelined line-server model, see p_vram
   constant VQ_DEPTH : integer := 8;
   type t_vq_ent is record
      data : std_logic_vector(31 downto 0);
      lat  : integer range 0 to 15;
   end record;
   type t_vq is array (0 to VQ_DEPTH-1) of t_vq_ent;
   signal vq       : t_vq := (others => ((others => '0'), 0));
   signal vq_head  : integer range 0 to VQ_DEPTH-1 := 0;
   signal vq_tail  : integer range 0 to VQ_DEPTH-1 := 0;
   signal vq_cnt   : integer range 0 to VQ_DEPTH := 0;
   signal vpend    : std_logic := '0';
   signal acc_gate : std_logic := '1';
   signal vram_take : std_logic;
   signal o_pal_data, o_extpal_data, o_vram_data : std_logic_vector(31 downto 0);


   -- pixel outputs
   signal pixel_we_color    : std_logic;
   signal busy              : std_logic;
   signal cyc_case          : integer := 0;
   signal px_case           : integer := 0;
   signal pixeldata_color   : std_logic_vector(15 downto 0);
   signal pixel_we_settings : std_logic;
   signal pixeldata_settings : std_logic_vector(7 downto 0);
   signal pixel_x           : integer range 0 to 255;
   signal pixel_objwnd      : std_logic;

   type t_line16 is array (0 to 255) of std_logic_vector(15 downto 0);
   type t_line8  is array (0 to 255) of std_logic_vector(7 downto 0);
   signal linecol  : t_line16 := (others => (others => '0'));
   signal lineset  : t_line8  := (others => (others => '0'));
   signal set_wr   : std_logic_vector(255 downto 0) := (others => '0');
   signal ownd     : std_logic_vector(255 downto 0) := (others => '0');
   signal clear_line : std_logic := '0';

   signal vram_reqs_case  : integer := 0;   -- VRAM fetches in the current case
   signal vram_reqs_total : integer := 0;

   signal tests_done : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   idrawer_obj : entity work.nds_drawer_obj
   port map
   (
      clk                  => clk,
      drawline             => drawline,
      busy                 => busy,
      ypos                 => ypos,
      ypos_mosaic          => ypos_mosaic,
      one_dim_mapping      => one_dim_mapping,
      tile_boundary        => tile_boundary,
      bitmap_1d            => bitmap_1d,
      bitmap_2d_wide       => bitmap_2d_wide,
      bitmap_1d_boundary   => bitmap_1d_boundary,
      obj_extpal           => obj_extpal,
      Mosaic_H_Size        => mosaic_h,
      hblankfree           => '0',
      pixel_we_color       => pixel_we_color,
      pixeldata_color      => pixeldata_color,
      pixel_we_settings    => pixel_we_settings,
      pixeldata_settings   => pixeldata_settings,
      pixel_x              => pixel_x,
      pixel_objwnd         => pixel_objwnd,
      OAMRAM_Drawer_addr   => oam_addr,
      OAMRAM_Drawer_data   => oam_data,
      OAMAFF_Drawer_addr   => oamaff_addr,
      OAMAFF_Drawer_data   => oamaff_data,
      PALETTE_Drawer_addr  => o_pal_addr,
      PALETTE_Drawer_data  => o_pal_data,
      EXTPAL_Drawer_addr   => o_extpal_addr,
      EXTPAL_Drawer_data   => o_extpal_data,
      VRAM_Drawer_req      => o_vram_req,
      VRAM_Drawer_addr     => o_vram_addr,
      VRAM_Drawer_data     => o_vram_data,
      VRAM_Drawer_done     => o_vram_done,
      VRAM_Drawer_accept   => o_vram_accept
   );

   -- OAM: plain registered reads, data one cycle after address. The entry read
   -- is the two words of the sprite; the affine read is the attr3 field of the
   -- four entries of the group (words 8G+1/3/5/7, upper halfword each).
   p_oam : process (clk)
   begin
      if rising_edge(clk) then
         oam_data <= oam(oam_addr * 2 + 1) & oam(oam_addr * 2);

         oamaff_data <= oam(oamaff_addr * 8 + 7)(31 downto 16)
                      & oam(oamaff_addr * 8 + 5)(31 downto 16)
                      & oam(oamaff_addr * 8 + 3)(31 downto 16)
                      & oam(oamaff_addr * 8 + 1)(31 downto 16);
      end if;
   end process;

   -- palette/ext-pal: plain 1-cycle registered reads (local BRAMs); VRAM
   -- char/bitmap data on req/done with random latency (line-server contract)
   p_mem : process (clk)
   begin
      if rising_edge(clk) then
         o_pal_data    <= pal(o_pal_addr);
         o_extpal_data <= extpal(o_extpal_addr);
      end if;
   end process;

   -- Pipelined line-server model: latch the request pulse (nds_vram's rpend),
   -- accept at most one per cycle, hold several in flight, and retire IN ISSUE
   -- ORDER after a random latency.
   --
   -- The model this replaces waited for one req, slept, then answered - so a
   -- second request issued while it slept was silently DROPPED, and the answer
   -- was read from `vram(o_vram_addr)` at answer time, i.e. from whatever
   -- address the client had moved on to. Against a one-request-at-a-time
   -- client both mistakes were invisible. Against a pipelined one the drawer
   -- deadlocked with vram_reqs=0 and every pixel transparent, which reads like
   -- a drawer bug and is not one. Same lesson as VRSRV_ONE in the frame
   -- benches: a permissive memory model hides exactly the bugs it should find.
   vram_take <= '1' when ((o_vram_req = '1' or vpend = '1')
                          and vq_cnt < VQ_DEPTH and acc_gate = '1') else '0';
   o_vram_accept <= vram_take;

   p_vram : process (clk)
      variable seed : unsigned(31 downto 0) := to_unsigned(44444, 32);
      variable v_vq : t_vq;
      variable v_c  : integer range 0 to VQ_DEPTH;
      variable v_h  : integer range 0 to VQ_DEPTH-1;
      variable v_t  : integer range 0 to VQ_DEPTH-1;
   begin
      if rising_edge(clk) then
         o_vram_done <= '0';

         v_vq := vq;
         v_c  := vq_cnt;
         v_h  := vq_head;
         v_t  := vq_tail;

         seed := seed xor shift_left(seed, 13);
         seed := seed xor shift_right(seed, 17);
         seed := seed xor shift_left(seed, 5);
         acc_gate <= seed(9) or seed(10);   -- occasionally refuse, to exercise
                                            -- the client's unaccepted path

         for k in 0 to VQ_DEPTH-1 loop
            if (v_vq(k).lat > 0) then v_vq(k).lat := v_vq(k).lat - 1; end if;
         end loop;

         -- retire the oldest only: in-order, at most one per cycle
         if (v_c > 0 and v_vq(v_h).lat = 0) then
            o_vram_data <= v_vq(v_h).data;
            o_vram_done <= '1';
            v_h := (v_h + 1) mod VQ_DEPTH;
            v_c := v_c - 1;
         end if;

         -- take the request, capturing the address THIS cycle
         if (o_vram_req = '1' and vpend = '0') then
            vpend <= '1';
         end if;
         if (vram_take = '1') then
            vpend          <= '0';
            v_vq(v_t).data := vram(o_vram_addr);
            v_vq(v_t).lat  := 1 + to_integer(seed(2 downto 0));
            v_t := (v_t + 1) mod VQ_DEPTH;
            v_c := v_c + 1;
         end if;

         vq      <= v_vq;
         vq_cnt  <= v_c;
         vq_head <= v_h;
         vq_tail <= v_t;
      end if;
   end process;

   -- VRAM request counter. Correctness is what the golden model checks; this is
   -- the other half - a drawer that fetches the same word repeatedly is right
   -- and slow, and nothing else here would notice. Reported per case so an
   -- affine case can be told apart from a tile one.
   p_vramcount : process (clk)
   begin
      if rising_edge(clk) then
         if (clear_line = '1') then
            vram_reqs_case <= 0;
         elsif (o_vram_req = '1') then
            vram_reqs_case  <= vram_reqs_case + 1;
            vram_reqs_total <= vram_reqs_total + 1;
         end if;
      end if;
   end process;

   -- Cost model for the line, which is what sizes any rework of this drawer.
   -- vram_reqs alone cannot: measured in the full system, only 244 of the OBJ
   -- drawer's 3,036 cycles on a sprite-bearing line are VRAM round-trip stall, so
   -- 92% of the cost is this FSM walking per pixel. cyc/px is the number to move.
   p_cost : process (clk)
   begin
      if rising_edge(clk) then
         if (clear_line = '1') then
            cyc_case <= 0;
            px_case  <= 0;
         else
            if (busy = '1') then cyc_case <= cyc_case + 1; end if;
            if (pixel_we_color = '1') then px_case <= px_case + 1; end if;
         end if;
      end if;
   end process;

   -- pixel collect
   p_collect : process (clk)
   begin
      if rising_edge(clk) then
         if (clear_line = '1') then
            linecol <= (others => x"8000");
            lineset <= (others => x"00");
            set_wr  <= (others => '0');
            ownd    <= (others => '0');
         else
            if (pixel_we_color = '1') then
               linecol(pixel_x) <= pixeldata_color;
            end if;
            if (pixel_we_settings = '1') then
               lineset(pixel_x) <= pixeldata_settings;
               set_wr(pixel_x)  <= '1';
            end if;
            if (pixel_objwnd = '1') then
               ownd(pixel_x) <= '1';
            end if;
         end if;
      end if;
   end process;

   -- case driver
   p_drive : process
      variable ncases  : integer;
      variable base    : integer;
      variable flags   : std_logic_vector(31 downto 0);
      variable exp_c   : std_logic_vector(15 downto 0);
      variable exp_s   : std_logic_vector(31 downto 0);
      variable got_s   : std_logic_vector(31 downto 0);
      variable nfail   : integer := 0;
   begin
      ncases := to_integer(unsigned(vectors(0)));
      report "running " & integer'image(ncases) & " cases" severity note;

      for c in 0 to ncases - 1 loop
         base := 1 + c * 776;

         ypos        <= to_integer(unsigned(vectors(base + 0)));
         ypos_mosaic <= to_integer(unsigned(vectors(base + 1)));
         flags       := vectors(base + 2);
         one_dim_mapping    <= flags(0);
         bitmap_1d          <= flags(1);
         bitmap_2d_wide     <= flags(2);
         bitmap_1d_boundary <= flags(3);
         obj_extpal         <= flags(4);
         tile_boundary <= unsigned(vectors(base + 3)(1 downto 0));
         mosaic_h      <= unsigned(vectors(base + 4)(3 downto 0));

         for i in 0 to 255 loop
            oam(i) <= vectors(base + 8 + i);
         end loop;

         clear_line <= '1';
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         clear_line <= '0';
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;

         drawline <= '1';
         wait until rising_edge(clk);
         drawline <= '0';

         -- bounded by the pixeltime budget (2130); busy is now wired for the
         -- cost report, but the wait stays fixed so case timing is unchanged
         for k in 1 to 2600 loop wait until rising_edge(clk); end loop;

         for x in 0 to 255 loop
            exp_c := vectors(base + 264 + x)(15 downto 0);
            if (linecol(x) /= exp_c) then
               nfail := nfail + 1;
               report "case " & integer'image(c) & " x=" & integer'image(x) &
                      " color expected=" & to_hstring(exp_c) &
                      " got=" & to_hstring(linecol(x)) severity error;
            end if;
            exp_s := vectors(base + 520 + x);
            got_s := (others => '0');
            got_s(7 downto 0) := lineset(x);
            got_s(8)          := not set_wr(x);
            got_s(12)         := ownd(x);
            if (got_s /= exp_s) then
               nfail := nfail + 1;
               report "case " & integer'image(c) & " x=" & integer'image(x) &
                      " settings expected=" & to_hstring(exp_s) &
                      " got=" & to_hstring(got_s) severity error;
            end if;
         end loop;
         report "case " & integer'image(c) & " done  vram_reqs=" &
                integer'image(vram_reqs_case) &
                "  busy_cyc=" & integer'image(cyc_case) &
                " pixels=" & integer'image(px_case) &
                "  cyc/px=" & integer'image(cyc_case * 100 /
                   (px_case + 1)) & "/100  (budget 2130)" severity note;
      end loop;

      if (nfail = 0) then
         report "tb_nds_obj_priority: PASS  " & integer'image(ncases) & " cases  total vram_reqs=" &
                integer'image(vram_reqs_total) severity note;
      else
         report "tb_nds_obj_priority: FAIL  " & integer'image(nfail) & " mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_nds_obj_priority: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
