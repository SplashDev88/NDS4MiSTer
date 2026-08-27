library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- The HPS oracle returns IRQ state on the same completion that releases a
-- serviced request.  r114 keeps both CPUs paused until that request has fully
-- released.  An IRQ may become pending during the pause, but it must not
-- change architectural state or redirect fetch until do_step resumes.
entity tb_nds_arm9_pause_irq is
end entity;

architecture sim of tb_nds_arm9_pause_irq is
   signal clk, reset, descriptor_valid, cpu_reset, boot_ready : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata : std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal do_step : std_logic := '1';
   signal irq : std_logic := '0';
   signal fetches : natural := 0;
   signal saw_high_vector : std_logic := '0';
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

   rdata <= x"E3A0001F" when addr = x"02000000" else
            x"E129F000" when addr = x"02000004" else
            x"EAFFFFFE" when addr = x"02000008" else
            x"EAFFFFFE" when addr = x"FFFF0018" else
            x"E1A00000";
   bus_done <= ena;

   process(clk)
   begin
      if rising_edge(clk) then
         if cpu_reset = '1' then
            fetches <= 0;
            saw_high_vector <= '0';
         elsif ena = '1' and rnw = '1' then
            if addr = x"02000008" then
               fetches <= fetches + 1;
            elsif addr = x"FFFF0018" then
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
         dma_on => '0', do_step => do_step, done => open,
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
         debug_cpu_mixed => open, arm9_dtcm_region => open,
         arm9_dtcm_enable => open
      );

   process
      variable paused_fetches : natural;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until fetches >= 4 for 20 us;
      assert fetches >= 4
         report "ARM9 did not reach the pre-IRQ loop" severity failure;

      do_step <= '0';
      wait for 100 ns;
      paused_fetches := fetches;
      irq <= '1';
      wait until rising_edge(clk);
      irq <= '0';
      wait for 500 ns;
      assert saw_high_vector = '0'
         report "ARM9 accepted an IRQ while shared oracle pause was active"
         severity failure;
      assert fetches = paused_fetches
         report "ARM9 continued fetching while shared oracle pause was active"
         severity failure;

      do_step <= '1';
      wait until saw_high_vector = '1' for 20 us;
      assert saw_high_vector = '1'
         report "pending ARM9 IRQ was lost when shared oracle pause released"
         severity failure;
      report "PASS: ARM9 defers a pending IRQ until shared pause releases"
         severity note;
      stop;
      wait;
   end process;
end architecture;
