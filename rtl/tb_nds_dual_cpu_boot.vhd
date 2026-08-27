library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_dual_cpu_boot is end entity;

architecture sim of tb_nds_dual_cpu_boot is
   signal clk, reset, descriptor_valid, boot_ready : std_logic := '0';
   signal addr9, wdata9, rdata9, addr7, wdata7, rdata7 :
      std_logic_vector(31 downto 0);
   signal rnw9, ena9, done9, rnw7, ena7, done7 : std_logic;
   signal acc9, acc7 : std_logic_vector(1 downto 0);
   signal seen9, seen7 : std_logic := '0';
   signal cycles_valid9, cycles_valid7 : std_logic;
   signal cycle_events9, cycle_events7 : natural := 0;
begin
   clk <= not clk after 5 ns;
   rdata9 <= x"EAFFFFFE";
   rdata7 <= x"EAFFFFFE";
   done9 <= ena9;
   done7 <= ena7;

   dut : entity work.nds_dual_cpu_core
      generic map (
         -- Exercise the enabled local-DMA mux. The entry address has the
         -- same low 28-bit value as DMA0SAD, but it is main RAM and must
         -- remain an external CPU fetch.
         LOCAL_DMA_ENABLE => 1
      )
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"020000B0", arm7_entry => x"020000B0",
         arm9_current_sp => x"03002F7C", arm9_irq_sp => x"03003F80",
         arm9_saved_sp => x"03003FC0", arm7_current_sp => x"0380FD80",
         arm7_irq_sp => x"0380FF80", arm7_saved_sp => x"0380FFC0",
         initial_cpsr => x"000000D3", boot_ready => boot_ready,
         arm9_cycles => open, arm9_cycles_valid => cycles_valid9,
         arm7_cycles => open, arm7_cycles_valid => cycles_valid7,
         arm9_debug_pc => open, arm7_debug_pc => open,
         arm9_diag_word => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open,
         arm9_addr => addr9, arm9_rnw => rnw9, arm9_ena => ena9,
         arm9_acc => acc9, arm9_wdata => wdata9, arm9_rdata => rdata9,
         arm9_done => done9, arm7_addr => addr7, arm7_rnw => rnw7,
         arm7_ena => ena7, arm7_acc => acc7, arm7_wdata => wdata7,
         arm7_rdata => rdata7, arm7_done => done7
      );

   process(clk)
   begin
      if rising_edge(clk) then
         assert boot_ready = '1' or (ena9 = '0' and ena7 = '0')
            report "CPU bus request escaped before boot_ready" severity failure;
         if ena9 = '1' and seen9 = '0' then
            assert rnw9 = '1' and addr9 = x"020000B0"
               report "ARM9 first fetch did not use descriptor entry" severity failure;
            seen9 <= '1';
         end if;
         if ena7 = '1' and seen7 = '0' then
            assert rnw7 = '1' and addr7 = x"020000B0"
               report "ARM7 first fetch did not use descriptor entry" severity failure;
            seen7 <= '1';
         end if;
         if cycles_valid9 = '1' then cycle_events9 <= cycle_events9 + 1; end if;
         if cycles_valid7 = '1' then cycle_events7 <= cycle_events7 + 1; end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until seen9 = '1' and seen7 = '1' for 5 us;
      assert seen9 = '1' and seen7 = '1'
         report "both CPUs did not fetch after boot release" severity failure;
      wait for 5 us;
      assert cycle_events9 > 0 and cycle_events7 > 0
         report "both directly connected boot CPUs did not retire instructions"
         severity failure;
      report "PASS: integrated dual CPUs stay silent then fetch descriptor entries"
         severity note;
      stop;
      wait;
   end process;
end architecture;
