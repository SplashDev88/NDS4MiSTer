-- SPDX-License-Identifier: GPL-2.0-or-later
-- HW_TIME_LIMIT budget-polarity check for nds_drawer_obj.
--
-- Proves the 954/1210 H-Blank budget switch AND the truncation behaviour on a
-- line whose hardware charge sits between the two budgets:
--
--   16 x 64x64 sprites on one line, all opaque colour 1 of their own palette,
--   every OAM slot distinct so the walk's truncation point is observable:
--   sprites 0-6 stacked at x=0, 7-13 at x=64, 14 at x=128, 15 at x=192.
--   Hardware charge (non-affine, all on-screen): 16*64 = 1024 cycles.
--
--   hblankfree='0'  -> budget 1210  -> every sprite renders
--   hblankfree='1'  -> budget 954   -> sprites 0-13 render (896), sprite 14
--                     truncates after 58 of its 64 pixels (x 128..185),
--                     sprite 15 (the "HP bar" marker) is dropped entirely.
--
-- The line cost sits inside (954, 1210]: a line under 954 proves nothing
-- (both budgets render it) and one over 1210 makes the low budget look like
-- the only difference. 64 pixels wide (1024 total) is what real busy lines
-- look like: it gets the asymmetry visible as exactly one dropped tile.
--
-- The walk's charge is 1 cycle per field pixel plus the leading/trailing
-- screen-clip elisions, all charged when the walk advances (nds_drawer_obj.vhd);
-- setting every sprite fully on-screen makes that 64 per sprite exactly.
--
-- Run: sim/run_gpu_obj_budget.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

entity tb_gpu_obj_budget is
   generic
   (
      TIMEOUT_MS : integer := 10
   );
end entity;

architecture sim of tb_gpu_obj_budget is

   signal clk : std_logic := '0';

   signal hblankfree : std_logic := '0';
   signal drawline   : std_logic := '0';
   signal ypos       : integer range 0 to 191 := 0;
   signal busy       : std_logic;

   -- OAM: 128 sprites x 8 bytes = 256 words, model the gpu2d shadows
   type t_oam is array (0 to 255) of std_logic_vector(31 downto 0);
   signal oam      : t_oam := (others => (others => '0'));
   signal oam_addr : integer range 0 to 127;
   signal oam_data : std_logic_vector(63 downto 0) := (others => '0');

   signal oamaff_addr : integer range 0 to 31;
   signal oamaff_data : std_logic_vector(63 downto 0) := (others => '0');

   type t_pal is array (0 to 127) of std_logic_vector(31 downto 0);
   signal pal : t_pal := (others => (others => '0'));

   type t_vram is array (0 to 65535) of std_logic_vector(31 downto 0);
   signal vram : t_vram := (others => (others => '0'));

   signal o_pal_addr    : integer range 0 to 127;
   signal o_extpal_addr : integer range 0 to 2047;
   signal o_vram_addr   : integer range 0 to 65535;
   signal o_vram_req    : std_logic;
   signal o_vram_done   : std_logic := '0';
   signal o_vram_accept : std_logic;
   signal o_pal_data, o_extpal_data, o_vram_data : std_logic_vector(31 downto 0);

   -- pipelined line-server model (same shape as tb_gpu_obj's): several
   -- requests in flight, retired in issue order
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

   signal pixel_we_color   : std_logic;
   signal pixeldata_color  : std_logic_vector(15 downto 0);
   signal pixel_we_settings : std_logic;
   signal pixeldata_settings : std_logic_vector(7 downto 0);
   signal pixel_x          : integer range 0 to 255;
   signal pixel_objwnd     : std_logic;

   type t_line is array (0 to 255) of std_logic_vector(15 downto 0);
   signal linecol : t_line := (others => (others => '0'));
   signal clear_line : std_logic := '0';

   signal tests_done : boolean := false;

   -- hardware charge of a fully on-screen 64px sprite
   constant SPRITE_PX : integer := 64;
   constant LINE_COST : integer := 16 * SPRITE_PX;   -- 1024

   -- expect_col: colour p (out of palette p) as emitted pixels
   impure function colof(p : integer) return std_logic_vector is
   begin
      return '0' & std_logic_vector(to_unsigned(p, 15));
   end function;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   idrawer_obj : entity work.nds_drawer_obj
   port map
   (
      clk                  => clk,
      drawline             => drawline,
      busy                 => busy,
      ypos                 => ypos,
      ypos_mosaic          => ypos,
      one_dim_mapping      => '0',
      tile_boundary        => "00",
      bitmap_1d            => '0',
      bitmap_2d_wide       => '0',
      bitmap_1d_boundary   => '0',
      obj_extpal           => '0',
      Mosaic_H_Size        => "0000",
      hblankfree           => hblankfree,
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

   p_mem : process (clk)
   begin
      if rising_edge(clk) then
         o_pal_data    <= pal(o_pal_addr);
         o_extpal_data <= (others => '0');
      end if;
   end process;

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
         acc_gate <= seed(9) or seed(10);

         for k in 0 to VQ_DEPTH-1 loop
            if (v_vq(k).lat > 0) then v_vq(k).lat := v_vq(k).lat - 1; end if;
         end loop;

         if (v_c > 0 and v_vq(v_h).lat = 0) then
            o_vram_data <= v_vq(v_h).data;
            o_vram_done <= '1';
            v_h := (v_h + 1) mod VQ_DEPTH;
            v_c := v_c - 1;
         end if;

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

   p_collect : process (clk)
   begin
      if rising_edge(clk) then
         if (clear_line = '1') then
            linecol <= (others => x"8000");
         elsif (pixel_we_color = '1') then
            linecol(pixel_x) <= pixeldata_color;
         end if;
      end if;
   end process;

   -- load OAM + VRAM + palettes, then run the line under both budgets
   p_drive : process
      variable nfail : integer := 0;
      variable x     : integer;

      procedure check(x : integer; expect : std_logic_vector(15 downto 0);
                      label_s : string) is
      begin
         if (linecol(x) /= expect) then
            nfail := nfail + 1;
            report label_s & " x=" & integer'image(x) &
                   " expected=" & to_hstring(expect) &
                   " got=" & to_hstring(linecol(x)) severity error;
         end if;
      end procedure;

      procedure run_line(efree : std_logic; what : string) is
      begin
         hblankfree <= efree;
         wait until rising_edge(clk);
         -- let maxhwtime latch the new budget before the line starts
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;
         clear_line <= '1';
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         clear_line <= '0';
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;
         drawline <= '1';
         wait until rising_edge(clk);
         drawline <= '0';
         -- bounded by the pixeltime budget; the walk is ~1024 cycles
         for k in 1 to 3000 loop wait until rising_edge(clk); end loop;
         report what & ": line rendered, busy=" & std_logic'image(busy) severity note;
      end procedure;

   begin
      -- VRAM tile 0 (and the whole 2 KB row block it repeats into): every
      -- pixel of the shared 64x64 sprite is colour 1 of its palette
      for w in 0 to 511 loop
         vram(w) <= x"11111111";
      end loop;
      -- std palette: colour 1 of palette p = p (distinct per sprite); odd colours
      -- live in the upper halfword (PALETTE_byteaddr bit1 = colour LSB)
      for p in 0 to 15 loop
         pal(p * 8) <= "000" & std_logic_vector(to_unsigned(p, 13)) & x"0000";
      end loop;
      -- OAM: 16 sprites all at y=0, 64x64 (attr1 size "11"), tile 0
      for i in 0 to 15 loop
         if    (i < 7)  then x := 0;
         elsif (i < 14) then x := 64;
         elsif (i = 14) then x := 128;
         else               x := 192;
         end if;
         oam(2 * i)     <= std_logic_vector(to_unsigned(x + 16#C000#, 16)) & x"0000";  -- attr1=x w/ size "11" | attr0=0
         oam(2 * i + 1) <= std_logic_vector(to_unsigned(i * 4096, 32));
      end loop;
      -- everything above OAM 15 disabled (attr0 bit 9)
      for i in 16 to 127 loop
         oam(2 * i)     <= x"00000200";
         oam(2 * i + 1) <= x"00000000";
      end loop;

      wait until rising_edge(clk);

      -- run 1: hblankfree='0', budget 1210 > 1024 -> the whole line renders
      run_line('0', "budget 1210 (bit23 set)");
      check(4,   colof(0),  "1210 sprite0");   -- x=0 column, first prio
      check(68,  colof(7),  "1210 sprite7");   -- x=64 column
      check(132, colof(14), "1210 sprite14");
      check(186, colof(14), "1210 sprite14 full");
      check(196, colof(15), "1210 HP-bar sprite");

      -- run 2: hblankfree='1', budget 954 < 1024 -> sprites 0..13 (896),
      -- then sprite 14 truncates after 58 px (x 128..185) and sprite 15 at
      -- x=192 never starts
      run_line('1', "budget 954 (bit23 clear)");
      check(4,   colof(0),  "954 sprite0");
      check(132, colof(14), "954 sprite14 start");
      check(185, colof(14), "954 sprite14 last kept pixel");
      check(186, x"8000",   "954 sprite14 truncation");
      check(196, x"8000",   "954 HP-bar dropped");

      if (nfail = 0) then
         report "tb_gpu_obj_budget: PASS  (line cost " & integer'image(LINE_COST) &
                " hw cycles; budgets 1210/954)" severity note;
      else
         report "tb_gpu_obj_budget: FAIL  " & integer'image(nfail) &
                " mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_gpu_obj_budget: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;