library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.pProc_bus_gba.all;

-- Readback-only footprint of a disabled GPU2D engine.  Games commonly read a
-- control register, change one field, and write the complete word back.  When
-- Engine B's large FPGA renderer is omitted, returning an incomplete DISPCNT
-- silently clears unrelated fields before the ARM video mirror sees the
-- write. Retain DISPCNT and all four BGxCNT words: games also read their
-- character/screen bases to calculate graphics upload destinations. Dropping
-- those readbacks sends correct tile data to the wrong VRAM addresses.
-- WININ/WINOUT and BLDCNT/BLDALPHA are also readable. Metroid Prime Pinball
-- updates its two horizontal windows separately with read/modify/write;
-- returning zero for WININ clears the other window's layers and removes
-- exactly half of Engine B's image. Preserve the blend controls for the
-- same reason. Scroll, affine, window-coordinate, mosaic and BLDY registers
-- remain write-only; the ARM renderer still receives their writes normally.
-- MASTER_BRIGHT is readable too: retain its programmed factor and mode so
-- a software fade can change one field without clearing the other.
-- This module does not enable rendering or transport for Engine B. The
-- 0xC0B1FFF7 mask matches melonDS's Engine-B register semantics. Engine A
-- retains the original GPU's full DISPCNT, full address decode and bus reset.
-- This allows its private drawers to disappear when ARM owns the full frame.
entity nds_gpu2d_register_shadow is
   generic (is_engine_b : boolean := true; EXPERIMENTAL_CHECKPOINT : boolean := false);
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;
      gb_bus     : in  proc_bus_gb_type;
      wired_out  : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done : out std_logic := '0';
      checkpoint_idle : out std_logic := '0';
      checkpoint_address : in unsigned(2 downto 0) := (others => '0');
      checkpoint_data : out std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_valid : out std_logic := '0';
      checkpoint_restore : in std_logic := '0';
      checkpoint_write : in std_logic := '0';
      checkpoint_write_data : in std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_restore_ready : out std_logic := '0';
      checkpoint_restore_error : out std_logic := '0'
   );
end entity;

architecture rtl of nds_gpu2d_register_shadow is
   function display_mask return std_logic_vector is
   begin
      if is_engine_b then return x"C0B1FFF7"; end if;
      return x"FFFFFFFF";
   end function;
   signal address_selected : boolean;
   signal disp_cnt : std_logic_vector(31 downto 0) := (others => '0');
   signal bg01_cnt, bg23_cnt : std_logic_vector(31 downto 0) := (others => '0');
   signal win_cnt, blend_cnt : std_logic_vector(31 downto 0) := (others => '0');
   signal master_bright : std_logic_vector(15 downto 0) := (others => '0');
   signal restore_active, restore_write_valid : std_logic;
   signal restore_count : unsigned(2 downto 0) := (others => '0');
   signal restore_error : std_logic := '0';
   function valid_word(a : unsigned(2 downto 0); d : std_logic_vector(31 downto 0)) return boolean is
   begin
      case to_integer(a) is
         when 0 => return (d and not display_mask) = x"00000000";
         when 1 | 2 => return true;
         when 3 => return (d and not x"3F3F3F3F") = x"00000000";
         when 4 => return (d and not x"1F1F3FFF") = x"00000000";
         when 5 => return (d and not x"0000C01F") = x"00000000";
         when others => return false;
      end case;
   end function;
begin
   checkpoint_idle <= '1' when EXPERIMENTAL_CHECKPOINT and reset = '0' and gb_bus.rst = '0' and gb_bus.ena = '0' else '0';
   restore_active <= '1' when EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0';
   restore_write_valid <= '1' when restore_active = '1' and gb_bus.ena = '0' and restore_error = '0' and checkpoint_write = '1' and
      restore_count < 6 and checkpoint_address = restore_count and valid_word(checkpoint_address,checkpoint_write_data) else '0';
   checkpoint_restore_ready <= '1' when restore_active = '1' and gb_bus.ena = '0' and restore_error = '0' and
      restore_count = 6 and checkpoint_write = '0' else '0';
   checkpoint_restore_error <= restore_error when EXPERIMENTAL_CHECKPOINT else '0';
   process(clk)
   begin
      if rising_edge(clk) then
         if not EXPERIMENTAL_CHECKPOINT or checkpoint_restore = '0' then restore_count <= (others => '0'); restore_error <= '0';
         elsif reset = '0' or gb_bus.ena = '1' then restore_error <= '1';
         elsif checkpoint_write = '1' then
            if restore_write_valid = '1' then restore_count <= restore_count + 1;
            else restore_error <= '1'; end if;
         end if;
      end if;
   end process;
   process(all)
   begin
      checkpoint_data <= (others => '0'); checkpoint_valid <= '0';
      if EXPERIMENTAL_CHECKPOINT and checkpoint_address < 6 and
         ((checkpoint_idle = '1' and checkpoint_restore = '0') or checkpoint_restore_ready = '1') then
         checkpoint_valid <= '1';
         case to_integer(checkpoint_address) is
            when 0 => checkpoint_data <= disp_cnt;
            when 1 => checkpoint_data <= bg01_cnt;
            when 2 => checkpoint_data <= bg23_cnt;
            when 3 => checkpoint_data <= win_cnt;
            when 4 => checkpoint_data <= blend_cnt;
            when 5 => checkpoint_data(15 downto 0) <= master_bright;
            when others => null;
         end case;
      end if;
   end process;
   -- Engine A must decode the full address like the original eProcReg bank.
   -- Engine B keeps its existing translated-window behavior.
   address_selected <= is_engine_b or gb_bus.Adr(27 downto 12) = x"0000";
   process (clk)
      variable next_disp_cnt : std_logic_vector(31 downto 0);
      variable next_effect_cnt : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then
         if restore_active = '1' then
            if restore_write_valid = '1' then
               case to_integer(checkpoint_address) is
                  when 0 => disp_cnt <= checkpoint_write_data;
                  when 1 => bg01_cnt <= checkpoint_write_data;
                  when 2 => bg23_cnt <= checkpoint_write_data;
                  when 3 => win_cnt <= checkpoint_write_data;
                  when 4 => blend_cnt <= checkpoint_write_data;
                  when 5 => master_bright <= checkpoint_write_data(15 downto 0);
                  when others => null;
               end case;
            end if;
         elsif (is_engine_b and reset = '1') or gb_bus.rst = '1' then
            disp_cnt <= (others => '0');
            bg01_cnt <= (others => '0');
            bg23_cnt <= (others => '0');
            win_cnt <= (others => '0');
            blend_cnt <= (others => '0');
            master_bright <= (others => '0');
         elsif address_selected and gb_bus.ena = '1' and gb_bus.rnw = '0' and
               gb_bus.Adr(11 downto 0) = x"06C" then
            if gb_bus.bEna(0) = '1' then
               master_bright(7 downto 0) <= gb_bus.Din(7 downto 0) and x"1F";
            end if;
            if gb_bus.bEna(1) = '1' then
               master_bright(15 downto 8) <= gb_bus.Din(15 downto 8) and x"C0";
            end if;
         elsif address_selected and gb_bus.ena = '1' and gb_bus.rnw = '0' and
               (gb_bus.Adr(11 downto 0) = x"048" or
                gb_bus.Adr(11 downto 0) = x"050") then
            if gb_bus.Adr(4) = '0' then
               next_effect_cnt := win_cnt;
            else
               next_effect_cnt := blend_cnt;
            end if;
            for lane in 0 to 3 loop
               if gb_bus.bEna(lane) = '1' then
                  next_effect_cnt(lane * 8 + 7 downto lane * 8) :=
                     gb_bus.Din(lane * 8 + 7 downto lane * 8);
               end if;
            end loop;
            if gb_bus.Adr(4) = '0' then
               win_cnt <= next_effect_cnt and x"3F3F3F3F";
            else
               -- Keep the programmed 5-bit alpha coefficients in readback.
               -- Rendering clamps them to 16 separately in the ARM helper.
               blend_cnt <= next_effect_cnt and x"1F1F3FFF";
            end if;
         elsif address_selected and gb_bus.ena = '1' and gb_bus.rnw = '0' and
               (gb_bus.Adr(11 downto 0) = x"008" or
                gb_bus.Adr(11 downto 0) = x"00C") then
            for lane in 0 to 3 loop
               if gb_bus.bEna(lane) = '1' then
                  if gb_bus.Adr(2) = '0' then
                     bg01_cnt(lane * 8 + 7 downto lane * 8) <=
                        gb_bus.Din(lane * 8 + 7 downto lane * 8);
                  else
                     bg23_cnt(lane * 8 + 7 downto lane * 8) <=
                        gb_bus.Din(lane * 8 + 7 downto lane * 8);
                  end if;
               end if;
            end loop;
         elsif address_selected and gb_bus.ena = '1' and gb_bus.rnw = '0' and
               gb_bus.Adr(11 downto 0) = x"000" then
            next_disp_cnt := disp_cnt;
            for lane in 0 to 3 loop
               if gb_bus.bEna(lane) = '1' then
                  next_disp_cnt(lane * 8 + 7 downto lane * 8) :=
                     gb_bus.Din(lane * 8 + 7 downto lane * 8);
               end if;
            end loop;
            disp_cnt <= next_disp_cnt and display_mask;
         end if;
      end if;
   end process;

   process (all)
   begin
      wired_out <= (others => '0');
      wired_done <= '0';
      if address_selected then
         if gb_bus.Adr(11 downto 0) = x"000" then
            wired_out <= disp_cnt;
            wired_done <= '1';
         elsif gb_bus.Adr(11 downto 0) = x"008" then
            wired_out <= bg01_cnt;
            wired_done <= '1';
         elsif gb_bus.Adr(11 downto 0) = x"00C" then
            wired_out <= bg23_cnt;
            wired_done <= '1';
         elsif gb_bus.Adr(11 downto 0) = x"048" then
            wired_out <= win_cnt;
            wired_done <= '1';
         elsif gb_bus.Adr(11 downto 0) = x"050" then
            wired_out <= blend_cnt;
            wired_done <= '1';
         elsif gb_bus.Adr(11 downto 0) = x"06C" then
            wired_out <= x"0000" & master_bright;
            wired_done <= '1';
         end if;
      end if;
   end process;
end architecture;
