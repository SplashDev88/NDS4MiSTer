-- SPDX-License-Identifier: GPL-3.0-or-later
-- Focused differential test for engine-A 3D-as-BG0 composition.  Expected
-- results come from tools/gen_h3d_merge_vectors.py; every 2D-only vector is
-- also compared cycle-for-cycle with the pre-H3D merge RTL in library legacy.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;
use std.env.all;

library legacy;

entity tb_nds_h3d_merge is
   generic
   (
      VECTOR_FILE : string := "h3d-merge-vectors.txt"
   );
end entity;

architecture sim of tb_nds_h3d_merge is
   signal clk        : std_logic := '0';
   signal enable     : std_logic := '0';
   signal hblank     : std_logic := '0';
   signal xpos       : integer range 0 to 255 := 0;
   signal ypos       : integer range 0 to 191 := 10;

   signal wnd0_on, wnd1_on, wndobj_on : std_logic := '0';
   signal wnd0_x1, wnd0_x2, wnd0_y1, wnd0_y2 : unsigned(7 downto 0) := (others => '0');
   signal wnd1_x1, wnd1_x2, wnd1_y1, wnd1_y2 : unsigned(7 downto 0) := (others => '0');
   signal enables_wnd0, enables_wnd1 : std_logic_vector(5 downto 0) := (others => '0');
   signal enables_wndobj, enables_wndout : std_logic_vector(5 downto 0) := (others => '0');

   signal special_effect : unsigned(1 downto 0) := (others => '0');
   signal first_target, second_target : std_logic_vector(5 downto 0) := (others => '0');
   signal prio_bg0, prio_bg1, prio_bg2, prio_bg3 : unsigned(1 downto 0) := (others => '0');
   signal eva, evb, bldy : unsigned(4 downto 0) := (others => '0');
   signal layer_enable : std_logic_vector(4 downto 0) := (others => '0');

   signal pixel_bg0, pixel_bg1, pixel_bg2, pixel_bg3 : std_logic_vector(15 downto 0) := x"8000";
   signal pixel_obj : std_logic_vector(23 downto 0) := x"008000";
   signal pixel_back : std_logic_vector(15 downto 0) := (others => '0');
   signal objwindow : std_logic := '0';
   signal bg0_3d, h3d_valid : std_logic := '0';
   signal pixel_h3d : std_logic_vector(22 downto 0) := (others => '0');

   signal dut_pixel, legacy_pixel : std_logic_vector(17 downto 0);
   signal dut_x, legacy_x : integer range 0 to 255;
   signal dut_y, legacy_y : integer range 0 to 191;
   signal dut_we, legacy_we : std_logic;

   function bit(value : integer) return std_logic is
   begin
      if value = 0 then
         return '0';
      end if;
      return '1';
   end function;
begin
   clk <= not clk after 5 ns;

   idut : entity work.nds_drawer_merge
   port map
   (
      clk => clk,
      enable => enable,
      hblank => hblank,
      xpos => xpos,
      ypos => ypos,
      in_WND0_on => wnd0_on,
      in_WND1_on => wnd1_on,
      in_WNDOBJ_on => wndobj_on,
      in_WND0_X1 => wnd0_x1,
      in_WND0_X2 => wnd0_x2,
      in_WND0_Y1 => wnd0_y1,
      in_WND0_Y2 => wnd0_y2,
      in_WND1_X1 => wnd1_x1,
      in_WND1_X2 => wnd1_x2,
      in_WND1_Y1 => wnd1_y1,
      in_WND1_Y2 => wnd1_y2,
      in_enables_wnd0 => enables_wnd0,
      in_enables_wnd1 => enables_wnd1,
      in_enables_wndobj => enables_wndobj,
      in_enables_wndout => enables_wndout,
      in_special_effect_in => special_effect,
      in_effect_1st_bg0 => first_target(0),
      in_effect_1st_bg1 => first_target(1),
      in_effect_1st_bg2 => first_target(2),
      in_effect_1st_bg3 => first_target(3),
      in_effect_1st_obj => first_target(4),
      in_effect_1st_BD => first_target(5),
      in_effect_2nd_bg0 => second_target(0),
      in_effect_2nd_bg1 => second_target(1),
      in_effect_2nd_bg2 => second_target(2),
      in_effect_2nd_bg3 => second_target(3),
      in_effect_2nd_obj => second_target(4),
      in_effect_2nd_BD => second_target(5),
      in_Prio_BG0 => prio_bg0,
      in_Prio_BG1 => prio_bg1,
      in_Prio_BG2 => prio_bg2,
      in_Prio_BG3 => prio_bg3,
      in_EVA => eva,
      in_EVB => evb,
      in_BLDY => bldy,
      in_ena_bg0 => layer_enable(0),
      in_ena_bg1 => layer_enable(1),
      in_ena_bg2 => layer_enable(2),
      in_ena_bg3 => layer_enable(3),
      in_ena_obj => layer_enable(4),
      pixeldata_bg0 => pixel_bg0,
      pixeldata_bg1 => pixel_bg1,
      pixeldata_bg2 => pixel_bg2,
      pixeldata_bg3 => pixel_bg3,
      pixeldata_obj => pixel_obj,
      pixeldata_back => pixel_back,
      in_bg0_3d => bg0_3d,
      h3d_valid => h3d_valid,
      pixeldata_h3d => pixel_h3d,
      objwindow_in => objwindow,
      pixeldata_out => dut_pixel,
      pixel_x => dut_x,
      pixel_y => dut_y,
      pixel_we => dut_we
   );

   ilegacy : entity legacy.nds_drawer_merge
   port map
   (
      clk => clk,
      enable => enable,
      hblank => hblank,
      xpos => xpos,
      ypos => ypos,
      in_WND0_on => wnd0_on,
      in_WND1_on => wnd1_on,
      in_WNDOBJ_on => wndobj_on,
      in_WND0_X1 => wnd0_x1,
      in_WND0_X2 => wnd0_x2,
      in_WND0_Y1 => wnd0_y1,
      in_WND0_Y2 => wnd0_y2,
      in_WND1_X1 => wnd1_x1,
      in_WND1_X2 => wnd1_x2,
      in_WND1_Y1 => wnd1_y1,
      in_WND1_Y2 => wnd1_y2,
      in_enables_wnd0 => enables_wnd0,
      in_enables_wnd1 => enables_wnd1,
      in_enables_wndobj => enables_wndobj,
      in_enables_wndout => enables_wndout,
      in_special_effect_in => special_effect,
      in_effect_1st_bg0 => first_target(0),
      in_effect_1st_bg1 => first_target(1),
      in_effect_1st_bg2 => first_target(2),
      in_effect_1st_bg3 => first_target(3),
      in_effect_1st_obj => first_target(4),
      in_effect_1st_BD => first_target(5),
      in_effect_2nd_bg0 => second_target(0),
      in_effect_2nd_bg1 => second_target(1),
      in_effect_2nd_bg2 => second_target(2),
      in_effect_2nd_bg3 => second_target(3),
      in_effect_2nd_obj => second_target(4),
      in_effect_2nd_BD => second_target(5),
      in_Prio_BG0 => prio_bg0,
      in_Prio_BG1 => prio_bg1,
      in_Prio_BG2 => prio_bg2,
      in_Prio_BG3 => prio_bg3,
      in_EVA => eva,
      in_EVB => evb,
      in_BLDY => bldy,
      in_ena_bg0 => layer_enable(0),
      in_ena_bg1 => layer_enable(1),
      in_ena_bg2 => layer_enable(2),
      in_ena_bg3 => layer_enable(3),
      in_ena_obj => layer_enable(4),
      pixeldata_bg0 => pixel_bg0,
      pixeldata_bg1 => pixel_bg1,
      pixeldata_bg2 => pixel_bg2,
      pixeldata_bg3 => pixel_bg3,
      pixeldata_obj => pixel_obj,
      pixeldata_back => pixel_back,
      objwindow_in => objwindow,
      pixeldata_out => legacy_pixel,
      pixel_x => legacy_x,
      pixel_y => legacy_y,
      pixel_we => legacy_we
   );

   p_test : process
      file vectors : text open read_mode is VECTOR_FILE;
      variable row : line;
      variable ident : integer;
      variable h3d_on_i, h3d_valid_i, h3d_i : integer;
      variable wnd_on_i, wnd_inside_i, wnd0_mask_i, wndout_mask_i : integer;
      variable effect_i, first_i, second_i : integer;
      variable p0_i, p1_i, p2_i, p3_i : integer;
      variable eva_i, evb_i, bldy_i, ena_i : integer;
      variable bg0_i, bg1_i, bg2_i, bg3_i, obj_i, back_i : integer;
      variable expected_i : integer;
      variable latency : integer;
      variable count : integer := 0;
   begin
      wnd0_x1 <= to_unsigned(0, 8);
      wnd0_x2 <= to_unsigned(20, 8);
      wnd0_y1 <= to_unsigned(0, 8);
      wnd0_y2 <= to_unsigned(20, 8);
      wait until rising_edge(clk);

      while not endfile(vectors) loop
         readline(vectors, row);
         read(row, ident);
         read(row, h3d_on_i);
         read(row, h3d_valid_i);
         read(row, h3d_i);
         read(row, wnd_on_i);
         read(row, wnd_inside_i);
         read(row, wnd0_mask_i);
         read(row, wndout_mask_i);
         read(row, effect_i);
         read(row, first_i);
         read(row, second_i);
         read(row, p0_i);
         read(row, p1_i);
         read(row, p2_i);
         read(row, p3_i);
         read(row, eva_i);
         read(row, evb_i);
         read(row, bldy_i);
         read(row, ena_i);
         read(row, bg0_i);
         read(row, bg1_i);
         read(row, bg2_i);
         read(row, bg3_i);
         read(row, obj_i);
         read(row, back_i);
         read(row, expected_i);

         bg0_3d <= bit(h3d_on_i);
         h3d_valid <= bit(h3d_valid_i);
         pixel_h3d <= std_logic_vector(to_unsigned(h3d_i, 23));
         wnd0_on <= bit(wnd_on_i);
         if wnd_inside_i /= 0 then
            xpos <= 10;
         else
            xpos <= 30;
         end if;
         enables_wnd0 <= std_logic_vector(to_unsigned(wnd0_mask_i, 6));
         enables_wndout <= std_logic_vector(to_unsigned(wndout_mask_i, 6));
         special_effect <= to_unsigned(effect_i, 2);
         first_target <= std_logic_vector(to_unsigned(first_i, 6));
         second_target <= std_logic_vector(to_unsigned(second_i, 6));
         prio_bg0 <= to_unsigned(p0_i, 2);
         prio_bg1 <= to_unsigned(p1_i, 2);
         prio_bg2 <= to_unsigned(p2_i, 2);
         prio_bg3 <= to_unsigned(p3_i, 2);
         eva <= to_unsigned(eva_i, 5);
         evb <= to_unsigned(evb_i, 5);
         bldy <= to_unsigned(bldy_i, 5);
         layer_enable <= std_logic_vector(to_unsigned(ena_i, 5));
         pixel_bg0 <= std_logic_vector(to_unsigned(bg0_i, 16));
         pixel_bg1 <= std_logic_vector(to_unsigned(bg1_i, 16));
         pixel_bg2 <= std_logic_vector(to_unsigned(bg2_i, 16));
         pixel_bg3 <= std_logic_vector(to_unsigned(bg3_i, 16));
         pixel_obj <= std_logic_vector(to_unsigned(obj_i, 24));
         pixel_back <= std_logic_vector(to_unsigned(back_i, 16));

         -- Latch per-line merge state, then allow window Y and coefficient
         -- pipeline state to settle before presenting the single test pixel.
         hblank <= '1';
         wait until rising_edge(clk);
         hblank <= '0';
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         enable <= '1';
         wait until rising_edge(clk);
         enable <= '0';

         latency := 0;
         while dut_we /= '1' loop
            wait until rising_edge(clk);
            wait for 1 ns;
            latency := latency + 1;
            assert latency < 8
               report "H3D merge timeout at vector " & integer'image(ident)
               severity failure;
         end loop;

         assert dut_pixel = std_logic_vector(to_unsigned(expected_i, 18))
            report "H3D merge mismatch at vector " & integer'image(ident) &
                   ": got=" & to_hstring(dut_pixel) &
                   " expected=" & to_hstring(std_logic_vector(to_unsigned(expected_i, 18)))
            severity failure;
         assert dut_x = xpos and dut_y = ypos
            report "H3D merge coordinate mismatch at vector " & integer'image(ident)
            severity failure;

         if h3d_on_i = 0 then
            assert legacy_we = dut_we and legacy_x = dut_x and legacy_y = dut_y
               report "2D merge timing regression at vector " & integer'image(ident)
               severity failure;
            assert legacy_pixel = dut_pixel
               report "2D merge data regression at vector " & integer'image(ident) &
                      ": new=" & to_hstring(dut_pixel) &
                      " legacy=" & to_hstring(legacy_pixel)
               severity failure;
         end if;

         count := count + 1;
         wait until rising_edge(clk);
         wait for 1 ns;
      end loop;

      report "PASS: H3D merge " & integer'image(count) &
             " model vectors plus legacy 2D differential" severity note;
      stop;
      wait;
   end process;
end architecture;
