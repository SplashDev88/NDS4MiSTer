library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- The ARM9 BIOS halt service executes MCR p15,0,r0,c7,c0,4 (WFI) at
-- 0x01FFA6B8.  The reused GBA CPU must stop before the following instruction
-- and resume only when an enabled IRQ is accepted.  This directed test keeps
-- the program minimal so treating WFI as a generic CP15 no-op is unambiguous.
entity tb_nds_arm9_wfi_irq is
end entity;

architecture sim of tb_nds_arm9_wfi_irq is
   signal clk, reset, descriptor_valid, cpu_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, execute_pc : std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal irq : std_logic := '0';
   signal saw_wfi, saw_after_wfi, saw_high_vector : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"02000000", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => cpu_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      case addr is
         when x"02000000" => rdata <= x"E3A0001F"; -- MOV r0,#SYS
         when x"02000004" => rdata <= x"E129F000"; -- MSR CPSR_fc,r0
         when x"02000008" => rdata <= x"E3A00000"; -- MOV r0,#0
         when x"0200000C" => rdata <= x"EE070F90"; -- WFI
         when x"02000010" => rdata <= x"EAFFFFFE"; -- must wait for IRQ
         when x"FFFF0018" => rdata <= x"EAFFFFFE"; -- observable IRQ vector
         when others      => rdata <= x"E1A00000";
      end case;
      bus_done <= ena;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         if cpu_reset = '1' then
            saw_wfi <= '0';
            saw_after_wfi <= '0';
            saw_high_vector <= '0';
         else
            if execute_pc = x"0200000C" then
               saw_wfi <= '1';
            elsif execute_pc = x"02000010" then
               saw_after_wfi <= '1';
            end if;
            if ena = '1' and rnw = '1' and addr = x"FFFF0018" then
               saw_high_vector <= '1';
            end if;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '0', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078"
      )
      port map (
         clk100 => clk, gb_on => '1', reset => cpu_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => bus_done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => '1', done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => irq, new_halt => '0', clear_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => open, debug_cpu_execute_pc => open,
         -- ARM9 debug_cpu_mixed is execute_PCprev, the instruction actually
         -- resident in the execute stage. debug_cpu_execute_pc is one
         -- pipeline stage ahead and would falsely mark the post-WFI branch
         -- while WFI itself is still executing.
         debug_cpu_mixed => execute_pc, arm9_dtcm_region => open,
         arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until saw_wfi = '1' for 20 us;
      assert saw_wfi = '1'
         report "ARM9 did not execute the WFI probe" severity failure;

      -- Long enough for the next instruction to execute if WFI is decoded as
      -- a generic CP15 no-op, but no IRQ has been presented yet.
      wait for 2 us;
      assert saw_after_wfi = '0'
         report "ARM9 WFI executed the following instruction before IRQ"
         severity failure;

      irq <= '1';
      wait until saw_high_vector = '1' for 20 us;
      irq <= '0';
      assert saw_high_vector = '1'
         report "ARM9 WFI did not wake and take the enabled IRQ"
         severity failure;
      report "PASS: ARM9 CP15 WFI halts until IRQ and then enters high vector"
         severity note;
      stop;
      wait;
   end process;
end architecture;
