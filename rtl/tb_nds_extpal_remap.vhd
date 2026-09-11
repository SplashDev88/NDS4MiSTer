-- Focused reproduction: exact GPU refill FSM + production VRAM/BRAM service.
-- No commercial assets. The palette contains a known non-black color.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_nds_extpal_remap is
   generic (
      REMAP : boolean := true;
      UNMAP_CYCLE : natural := 7*2130 + 1600;
      RESTORE_CYCLE : natural := 10*2130 + 1500
   );
end entity;
architecture test of tb_nds_extpal_remap is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal vblank_trigger : std_logic := '0';
   signal maps : std_logic_vector(71 downto 0) := (others => '0');
   signal cpu_ena, cpu_done, clear_busy, srv_req : std_logic := '0';
   signal cpu_addr : unsigned(23 downto 2) := (others => '0');
   signal srv_bgep_req, srv_bgep_done, srv_objep_req, srv_objep_done : std_logic := '0';
   signal srv_bgep_addr : integer range 0 to 8191 := 0;
   signal srv_objep_addr : integer range 0 to 2047 := 0;
   signal srv_bgep_data, srv_objep_data : std_logic_vector(31 downto 0);
   type t_epfill is (EPIDLE, EPBG_REQ, EPBG_WAIT, EPOBJ_REQ, EPOBJ_WAIT);
   signal epfill : t_epfill := EPIDLE;
   signal epfill_addr : integer range 0 to 8191 := 0;
   signal epfill_pending : std_logic := '0';
   signal extpal_config, extpal_config_prev : std_logic_vector(23 downto 0) := (others => '0');
   type t_bg is array(0 to 8191) of std_logic_vector(31 downto 0);
   type t_obj is array(0 to 2047) of std_logic_vector(31 downto 0);
   signal bg_shadow : t_bg := (others => (others => '0'));
   signal objep_shadow : t_obj := (others => (others => '0'));
   signal measure : boolean := false;
   signal cycle : natural := 0;
   signal zero_count : natural := 0;
   signal last_bg_write_cycle : natural := 0;
begin
   clk <= not clk after 5 ns;
   extpal_config <= maps(55 downto 32);
   ivram : entity work.nds_vram
   generic map(is_simu => '1')
   port map(
      clk => clk, reset => reset, vramcnt => maps,
      cpu9_ena => cpu_ena, cpu9_rnw => '0', cpu9_addr => cpu_addr,
      cpu9_be => "1111", cpu9_din => x"421F421F", cpu9_dout => open,
      cpu9_done => cpu_done, cpu9_welig => open, cpu9_wok => open,
      cpu7_ena => '0', cpu7_rnw => '1', cpu7_addr => (others => '0'),
      cpu7_be => "0000", cpu7_din => (others => '0'), cpu7_dout => open, cpu7_done => open,
      srv_req => srv_req, srv_rnw => open, srv_bank => open, srv_addr => open,
      srv_be => open, srv_din => open, srv_dout => (others => '0'), srv_done => srv_req,
      rdr_bgep_req => srv_bgep_req, rdr_bgep_addr => to_unsigned(srv_bgep_addr, 13),
      rdr_bgep_dout => srv_bgep_data, rdr_bgep_done => srv_bgep_done,
      rdr_objep_req => srv_objep_req, rdr_objep_addr => to_unsigned(srv_objep_addr, 11),
      rdr_objep_dout => srv_objep_data, rdr_objep_done => srv_objep_done,
      clr_busy => clear_busy, dbg_rbusy => open
   );

   -- PRODUCTION_REFILL_PROCESS

   process(clk)
   begin
      if rising_edge(clk) then
         if measure then cycle <= cycle + 1; end if;
         if epfill = EPBG_WAIT and srv_bgep_done = '1' then
            bg_shadow(epfill_addr) <= srv_bgep_data;
            if measure then last_bg_write_cycle <= cycle; end if;
            if measure and srv_bgep_data = x"00000000" then zero_count <= zero_count + 1; end if;
            if measure and (epfill_addr mod 2048 = 0 or epfill_addr = 8191) then
               report "palette word=" & integer'image(epfill_addr) &
                  " cycle=" & integer'image(cycle) &
                  " line=" & integer'image(192 + cycle / 2130) &
                  " data=" & to_hstring(srv_bgep_data);
            end if;
         end if;
      end if;
   end process;

   process
      procedure step(n : natural := 1) is
      begin
         for i in 1 to n loop wait until rising_edge(clk); wait for 1 ns; end loop;
      end;
      variable bad, bad_first_palette, bad_all : natural := 0;
   begin
      step(4); reset <= '0';
      wait until clear_busy = '0'; step(2);
      maps(39 downto 32) <= x"80";
      step(2);
      for i in 0 to 8191 loop
         cpu_addr <= to_unsigned(16#880000#/4 + i, 22);
         cpu_ena <= '1'; step; cpu_ena <= '0';
         while cpu_done /= '1' loop step; end loop;
         step;
      end loop;
      maps(39 downto 32) <= x"84";
      -- Quiesce setup-triggered retries before the measured VBlank. The
      -- old and new refill processes therefore begin at the same boundary.
      step(4);
      while epfill /= EPIDLE or epfill_pending = '1' loop step; end loop;
      measure <= true; vblank_trigger <= '1'; step;
      vblank_trigger <= '0';
      -- Hardware trace: E is LCDC during lines199..202/203, restored before
      -- the next visible frame. These offsets lie within the observed lines.
      while cycle < UNMAP_CYCLE loop step; end loop;
      if REMAP then maps(39 downto 32) <= x"80"; end if;
      while cycle < RESTORE_CYCLE loop step; end loop;
      if REMAP then maps(39 downto 32) <= x"84"; end if;
      while cycle < 70*2130 loop step; end loop;
      for i in 6144 to 8191 loop
         if bg_shadow(i) /= x"421F421F" then bad := bad + 1; end if;
      end loop;
      for i in 6144 to 6271 loop
         if bg_shadow(i) /= x"421F421F" then bad_first_palette := bad_first_palette + 1; end if;
      end loop;
      for i in bg_shadow'range loop
         if bg_shadow(i) /= x"421F421F" then bad_all := bad_all + 1; end if;
      end loop;
      report "REMAP=" & boolean'image(REMAP) &
         " unmap_cycle=" & integer'image(UNMAP_CYCLE) &
         " restore_cycle=" & integer'image(RESTORE_CYCLE) &
         " invalid_BG_words=" & integer'image(bad_all) &
         " invalid_BG3_words=" & integer'image(bad) &
         " invalid_BG3_palette0_words=" & integer'image(bad_first_palette) &
         " zero_refill_responses=" & integer'image(zero_count) &
         " final_BG_write_line=" & integer'image(192 + last_bg_write_cycle / 2130);
      assert bad = 0 report "BG3 palette corrupted by VBlank LCDC remap" severity failure;
      assert bad_all = 0 report "BG palette retry incomplete" severity failure;
      assert epfill = EPIDLE report "Palette retry missed next visible frame" severity failure;
      finish;
   end process;
   process
   begin
      wait for 10 ms;
      assert false report "VRAM/refill handshake timed out" severity failure;
      wait;
   end process;
end architecture;
