library ieee;
use ieee.std_logic_1164.all;

-- Synthesis-only mixed-language simulation seam. GHDL converts this wrapper
-- and the reused VHDL CPUs to Verilog so Verilator can run them together with
-- the production SystemVerilog memory router and HPS mailbox.
entity nds_dual_cpu_cosim_top is
   port (
      clk, reset, descriptor_valid, global_step_enable : in std_logic;
      arm9_entry, arm7_entry : in std_logic_vector(31 downto 0);
      arm9_current_sp, arm9_irq_sp, arm9_saved_sp :
         in std_logic_vector(31 downto 0);
      arm7_current_sp, arm7_irq_sp, arm7_saved_sp :
         in std_logic_vector(31 downto 0);
      initial_cpsr : in std_logic_vector(31 downto 0);
      boot_ready : out std_logic;
      arm9_cycles, arm7_cycles : out std_logic_vector(7 downto 0);
      arm9_cycles_valid, arm7_cycles_valid : out std_logic;
      arm9_debug_pc, arm7_debug_pc : out std_logic_vector(31 downto 0);
      arm9_diag_word : out std_logic_vector(31 downto 0);
      arm9_dtcm_region : out std_logic_vector(31 downto 0);
      arm9_dtcm_enable : out std_logic;
      irq_arm9, irq_arm7, halt_arm9, halt_arm7 : in std_logic;
      ext_addr, ext_wdata, ext_debug_pc : out std_logic_vector(31 downto 0);
      ext_rnw, ext_ena, ext_cpu_is_arm9 : out std_logic;
      ext_acc : out std_logic_vector(1 downto 0);
      ext_rdata : in std_logic_vector(31 downto 0);
      ext_done : in std_logic
   );
end entity;

architecture rtl of nds_dual_cpu_cosim_top is
   signal addr9, wdata9, rdata9, addr7, wdata7, rdata7 :
      std_logic_vector(31 downto 0);
   signal rnw9, ena9, done9, rnw7, ena7, done7 : std_logic;
   signal acc9, acc7 : std_logic_vector(1 downto 0);
begin
   cpus : entity work.nds_dual_cpu_core
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => arm9_entry, arm7_entry => arm7_entry,
         arm9_current_sp => arm9_current_sp, arm9_irq_sp => arm9_irq_sp,
         arm9_saved_sp => arm9_saved_sp, arm7_current_sp => arm7_current_sp,
         arm7_irq_sp => arm7_irq_sp, arm7_saved_sp => arm7_saved_sp,
         initial_cpsr => initial_cpsr,
         global_step_enable => global_step_enable, boot_ready => boot_ready,
         arm9_cycles => arm9_cycles, arm7_cycles => arm7_cycles,
         arm9_cycles_valid => arm9_cycles_valid,
         arm7_cycles_valid => arm7_cycles_valid,
         arm9_debug_pc => arm9_debug_pc, arm7_debug_pc => arm7_debug_pc,
         arm9_diag_word => arm9_diag_word,
         arm9_dtcm_region => arm9_dtcm_region,
         arm9_dtcm_enable => arm9_dtcm_enable,
         arm9_addr => addr9, arm9_rnw => rnw9, arm9_ena => ena9,
         arm9_acc => acc9, arm9_wdata => wdata9, arm9_rdata => rdata9,
         arm9_done => done9, arm9_irq => irq_arm9, arm9_halt => halt_arm9,
         arm7_addr => addr7, arm7_rnw => rnw7, arm7_ena => ena7,
         arm7_acc => acc7, arm7_wdata => wdata7, arm7_rdata => rdata7,
         arm7_done => done7, arm7_irq => irq_arm7, arm7_halt => halt_arm7
      );

   shared_bus : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => reset,
         arm9_addr => addr9, arm9_rnw => rnw9, arm9_ena => ena9,
         arm9_acc => acc9, arm9_wdata => wdata9,
         arm9_debug_pc => arm9_debug_pc,
         arm9_rdata => rdata9, arm9_done => done9,
         arm7_addr => addr7, arm7_rnw => rnw7, arm7_ena => ena7,
         arm7_acc => acc7, arm7_wdata => wdata7,
         arm7_debug_pc => arm7_debug_pc,
         arm7_rdata => rdata7, arm7_done => done7,
         ext_addr => ext_addr, ext_rnw => ext_rnw, ext_ena => ext_ena,
         ext_acc => ext_acc, ext_wdata => ext_wdata,
         ext_cpu_is_arm9 => ext_cpu_is_arm9,
         ext_debug_pc => ext_debug_pc,
         ext_rdata => ext_rdata, ext_done => ext_done
      );
end architecture;
