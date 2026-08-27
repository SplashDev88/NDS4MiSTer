library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_eor_tst_alignment_branch is
end entity;

architecture sim of tb_nds_arm9_eor_tst_alignment_branch is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready :
      std_logic := '0';
   signal save, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_execute : std_logic_vector(31 downto 0);
   signal rnw, ena, cpu_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal success_seen, failure_seen : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"020670B0", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"2000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save, save7 => save7
      );

   -- Reproduce NSMB's first copy-alignment decision exactly:
   --   r0 = 0x02096a81, r1 = 0x027e37d8
   --   EOR r12,r1,r0 => 0x00775d59
   --   TST r12,#1 must clear Z, so BEQ must not be taken.
   process(all)
   begin
      case addr is
         when x"020670B0" => rdata <= x"E59F0038"; -- ldr r0,=source
         when x"020670B4" => rdata <= x"E59F1038"; -- ldr r1,=destination
         when x"020670B8" => rdata <= x"E59F4038"; -- ldr r4,=result port
         when x"020670BC" => rdata <= x"E021C000"; -- eor r12,r1,r0
         when x"020670C0" => rdata <= x"E31C0001"; -- tst r12,#1
         when x"020670C4" => rdata <= x"0A000002"; -- beq failure
         when x"020670C8" => rdata <= x"E3A03053"; -- mov r3,#0x53
         when x"020670CC" => rdata <= x"E5843000"; -- str r3,[r4]
         when x"020670D0" => rdata <= x"EAFFFFFE"; -- b .
         when x"020670D4" => rdata <= x"E3A03046"; -- failure marker
         when x"020670D8" => rdata <= x"E5843000"; -- str r3,[r4]
         when x"020670DC" => rdata <= x"EAFFFFFE"; -- b .
         when x"020670F0" => rdata <= x"02096A81";
         when x"020670F4" => rdata <= x"027E37D8";
         when x"020670F8" => rdata <= x"04000000";
         when others => rdata <= (others => '0');
      end case;
      cpu_done <= ena;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            success_seen <= '0';
            failure_seen <= '0';
         elsif ena = '1' and rnw = '0' and addr = x"04000000" then
            if wdata = x"00000053" then
               success_seen <= '1';
            elsif wdata = x"00000046" then
               failure_seen <= '1';
            end if;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078",
         arm9_alignment_snapshot_telemetry => '1'
      )
      port map (
         clk100 => clk, gb_on => '1', reset => boot_reset,
         savestate_bus => save,
         gb_bus_Adr => addr, gb_bus_rnw => rnw, gb_bus_ena => ena,
         gb_bus_acc => acc, gb_bus_dout => wdata, gb_bus_din => rdata,
         gb_bus_done => cpu_done, wait_cnt_value => (others => '0'),
         wait_cnt_update => '0', Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => '0', new_halt => '0', DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => open,
         debug_cpu_execute_pc => debug_execute, debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until success_seen = '1' or failure_seen = '1' for 20 us;
      assert success_seen = '1' and failure_seen = '0'
         report "ARM9 took BEQ despite odd source/destination alignment XOR"
         severity failure;
      assert debug_execute = x"D059D881"
         report "ARM9 alignment snapshot mismatch: " &
            to_hstring(debug_execute)
         severity failure;
      report "PASS: ARM9 EOR/TST clears Z and rejects NSMB alignment BEQ"
         severity note;
      stop;
      wait;
   end process;
end architecture;
