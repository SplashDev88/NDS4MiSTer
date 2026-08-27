library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_high_block_address is end entity;

architecture sim of tb_nds_arm9_high_block_address is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal pending : std_logic := '0';
   signal request_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal saw_high_block_read : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"00001000",
         arm9_current_sp => x"FFFF0024", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"FFFF0024", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      case request_addr is
         when x"00000000" => rdata <= x"E93D0001"; -- ldmdb sp!,{r0}
         when x"00000004" => rdata <= x"EAFFFFFE"; -- b 0x4
         when x"FFFF0020" => rdata <= x"DEADBEEF";
         when others => rdata <= x"E1A00000";
      end case;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         done <= '0';
         if boot_reset = '1' then
            pending <= '0';
         elsif pending = '0' and ena = '1' then
            request_addr <= addr;
            pending <= '1';
         elsif pending = '1' then
            done <= '1';
            pending <= '0';
            if rnw = '1' and request_addr = x"FFFF0020" then
               saw_high_block_read <= '1';
            end if;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00000000"
      )
      port map (
         clk100 => clk, gb_on => '1', reset => boot_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => '1', done => open, CPU_bus_idle => open,
         PC_in_BIOS => open, lastread => open, jump_out => open,
         new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => '0', new_halt => '0', clear_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => open,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until saw_high_block_read = '1' for 10 us;
      assert saw_high_block_read = '1'
         report "ARM9 block transfer lost bit 31 of the base address"
         severity failure;
      report "PASS: ARM9 block transfer preserves high BIOS address bit 31"
         severity note;
      stop;
      wait;
   end process;
end architecture;
