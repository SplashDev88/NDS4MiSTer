library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_syscnt_cold_reset is end entity;
architecture test of tb_nds_syscnt_cold_reset is
   signal clk : std_logic := '0';
   signal reset, cold : std_logic := '1';
   signal preset : std_logic := '0';
   signal bus9, bus7 : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',"10","1111",'0');
   signal q9, q7 : std_logic_vector(31 downto 0);
   signal wram : std_logic_vector(1 downto 0);
   signal vram : std_logic_vector(71 downto 0);
   signal pa, pb, ps : std_logic;
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_syscnt
   port map(clk => clk, reset => reset, cold_boot => cold,
      preset_direct => preset, bus9 => bus9, bus7 => bus7,
      wired_out9 => q9, wired_out7 => q7, wramcnt => wram, vramcnt => vram,
      pow_2da => pa, pow_2db => pb, pow_swap => ps);
   process
      procedure expect_reg(adr : natural; a, b : std_logic_vector(31 downto 0)) is
      begin
         bus9.Adr <= std_logic_vector(to_unsigned(adr, 28));
         bus7.Adr <= std_logic_vector(to_unsigned(adr, 28)); wait for 1 ns;
         assert q9 = a and q7 = b report "system control reset readback mismatch" severity failure;
      end;
   begin
      wait for 21 ns;
      expect_reg(16#204#, x"00006000", x"00006000");
      expect_reg(16#300#, x"00000000", x"00000000");
      assert wram="00" and vram=(vram'range=>'0') and pa='0' and pb='0' and ps='0'
         report "native WRAM/VRAM/power reset mismatch" severity failure;
      cold <= '0'; wait until rising_edge(clk); wait for 1 ns;
      expect_reg(16#204#, x"00006580", x"00006580");
      reset <= '0'; preset <= '1'; wait until rising_edge(clk); wait for 1 ns;
      preset <= '0';
      expect_reg(16#300#, x"00000001", x"00000001");
      assert wram="11" and pa='1' and pb='1' and ps='1'
         report "legacy direct-boot preset changed" severity failure;
      cold <= '1'; reset <= '1'; wait until rising_edge(clk); wait for 1 ns;
      expect_reg(16#204#, x"00006000", x"00006000");
      expect_reg(16#300#, x"00000000", x"00000000");
      assert wram="00" and pa='0' and pb='0' and ps='0'
         report "direct to native system reset retained state" severity failure;
      report "PASS: native system registers, direct defaults/presets, session reset";
      stop;
   end process;
end architecture;
