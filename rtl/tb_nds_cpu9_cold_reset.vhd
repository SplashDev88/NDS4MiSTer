library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_cpu9_cold_reset is end entity;
architecture test of tb_nds_cpu9_cold_reset is
   signal clk : std_logic := '0';
   signal cold : std_logic := '0';
   signal regsel : unsigned(4 downto 0) := (others => '0');
   signal reg7, reg9 : std_logic_vector(31 downto 0);
   signal vec, pu, ic, dc, it, dt : std_logic;
   signal db : std_logic_vector(31 downto 12);
   signal ds, its : std_logic_vector(4 downto 0);
   signal ss : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',"10","1111",'1');
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_cpu9 generic map(is_simu => '1')
   port map(clk => clk, ce => '1', reset => '1', cold_boot => cold,
      dbg_regsel => regsel, dbg_regval => reg9,
      savestate_bus => ss, gb_bus_din => (others=>'0'), gb_bus_done => '0',
      dma_on => '0', IRQ_in => '0', unhalt => '0', new_halt => '0',
      cp15_vector_hi => vec, cp15_pu_enable => pu,
      cp15_icache_ena => ic, cp15_dcache_ena => dc,
      cp15_itcm_ena => it, cp15_dtcm_ena => dt,
      cp15_dtcm_base => db, cp15_dtcm_size => ds, cp15_itcm_size => its,
      cache_op_busy => '0');
   cpu7 : entity work.gba_cpu generic map(is_simu => '1')
   port map(clk => clk, ce => '1', reset => '1',
      dbg_regsel => regsel, dbg_regval => reg7,
      savestate_bus => ss, gb_bus_din => (others=>'0'), gb_bus_done => '0',
      dma_on => '0', IRQ_in => '0', unhalt => '0', new_halt => '0');
   process
   begin
      wait for 21 ns;
      assert vec='1' and pu='0' and ic='0' and dc='0' and it='0' and dt='1'
         and db=x"03000" and ds="00101" and its="10000"
         report "direct boot reset state changed" severity failure;
      cold <= '1'; wait until rising_edge(clk); wait for 1 ns;
      assert vec='1' and pu='0' and ic='0' and dc='0' and it='0' and dt='0'
         and db=x"00000" and ds="00000" and its="00000"
         report "native boot did not clear post-BIOS CP15 state" severity failure;
      cold <= '0'; wait until rising_edge(clk); wait for 1 ns;
      assert dt='1' and db=x"03000" and ds="00101" and its="10000"
         report "native to direct reset failed" severity failure;
      for i in 0 to 14 loop
         regsel <= to_unsigned(i, 5); wait for 1 ns;
         assert reg7 = x"00000000" and reg9 = x"00000000"
            report "native register reset not zero" severity failure;
      end loop;
      regsel <= to_unsigned(16, 5); wait for 1 ns;
      assert reg7 = x"000000D3" and reg9 = x"000000D3"
         report "ARM7/ARM9 reset CPSR does not match native oracle" severity failure;
      report "PASS: native cold CP15 reset, both CPUs R0-R14/CPSR and unchanged direct-boot reset";
      stop;
   end process;
end architecture;
